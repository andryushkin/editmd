import Foundation

// MARK: - Session dirty-line tracking (v34.1)

/// Tracks which **current** 1-based line numbers differ from a per-file baseline.
/// Baseline resets on open and on external disk apply; marks clear on app quit
/// (in-memory) and when git commit touches the path (`GitCommitWatcher`).
///
/// Not the same as git working-tree dirty: baseline is “content when we last
/// anchored”, not HEAD.
@MainActor
final class LineChangeTracker: ObservableObject {
    static let shared = LineChangeTracker()

    /// Fires when any file’s dirty set changes — gutters redraw.
    @Published private(set) var revision: UInt = 0

    private var baseline: [URL: String] = [:]
    private var dirty: [URL: Set<Int>] = [:]
    /// Pending debounced recompute per file (large buffers only).
    private var recomputeTasks: [URL: Task<Void, Never>] = [:]

    /// Above this combined size the per-keystroke diff moves off-main + debounced.
    private static let inlineDiffLimit = 32_768

    private init() {}

    // MARK: - Queries

    func dirtyLines(for url: URL?) -> Set<Int> {
        guard let url else { return [] }
        return dirty[url.standardizedFileURL] ?? []
    }

    /// Files with a session baseline (open / recently edited).
    func trackedURLs() -> [URL] {
        Array(baseline.keys)
    }

    // MARK: - Lifecycle

    /// Open / external apply / Take Disk: new anchor, no marks.
    func noteBaseline(url: URL?, content: String) {
        guard let url else { return }
        let key = url.standardizedFileURL
        cancelRecompute(key)
        baseline[key] = content
        dirty[key] = []
        bump()
        GitCommitWatcher.shared.noteOpened(url: key)
    }

    /// User typed or paste: recompute dirty vs baseline. Small buffers diff
    /// inline; large ones are debounced and diffed off the main actor — a full
    /// Myers line diff per keystroke on main hitched typing in big files.
    ///
    /// `caretUTF16Offset` (into `content`) breaks the tie when an inserted line
    /// is a duplicate of a neighbour: a pure line diff can't tell which of the
    /// equal lines is the new one, so it would mark an untouched line. The caret
    /// is where the user actually typed, so we snap the mark there.
    ///
    /// The offset is passed instead of a resolved line so the O(n) offset→line
    /// scan happens where the diff already runs — inline for small buffers, but
    /// off the main actor for large ones (converting on main per keystroke would
    /// undo the very hitch-avoidance the debounced path exists for).
    func noteContent(url: URL?, content: String, caretUTF16Offset: Int? = nil) {
        guard let url else { return }
        let key = url.standardizedFileURL
        guard let base = baseline[key] else {
            // First sight without open hook — treat as baseline.
            baseline[key] = content
            dirty[key] = []
            bump()
            return
        }
        cancelRecompute(key)
        if base.utf16.count + content.utf16.count <= Self.inlineDiffLimit {
            let caretLine = caretUTF16Offset.map { sourceLineNumber(at: $0, in: content) }
            applyDirty(Self.dirtyLineNumbers(baseline: base, current: content,
                                             caretLine: caretLine), for: key)
            return
        }
        recomputeTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let next = await Task.detached(priority: .utility) {
                let caretLine = caretUTF16Offset.map { sourceLineNumber(at: $0, in: content) }
                return LineChangeTracker.dirtyLineNumbers(baseline: base, current: content,
                                                          caretLine: caretLine)
            }.value
            guard let self, !Task.isCancelled else { return }
            // Baseline moved while diffing (external reload / commit) — stale.
            guard self.baseline[key] == base else { return }
            self.recomputeTasks[key] = nil
            self.applyDirty(next, for: key)
        }
    }

    /// Drop marks (and keep baseline) — used after commit of this path.
    func clearMarks(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        cancelRecompute(key)
        if dirty[key]?.isEmpty == false {
            dirty[key] = []
            bump()
        }
    }

    /// Forget a file entirely (closed last window, optional).
    func forget(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        cancelRecompute(key)
        baseline.removeValue(forKey: key)
        dirty.removeValue(forKey: key)
        GitCommitWatcher.shared.forget(url: key)
        bump()
    }

    private func cancelRecompute(_ key: URL) {
        recomputeTasks[key]?.cancel()
        recomputeTasks[key] = nil
    }

    private func applyDirty(_ next: Set<Int>, for key: URL) {
        if dirty[key] != next {
            dirty[key] = next
            bump()
        }
    }

    // MARK: - Pure recompute

    /// Current-document line numbers (1-based) that are inserts or replacements
    /// relative to baseline (LCS line diff). Pure — callable off the main actor.
    ///
    /// `caretLine`, when given, disambiguates a duplicate-line insertion (see
    /// `noteContent`): the line diff is free to attribute a new line to any of
    /// several equal lines in a run, so it may light up an untouched one. The
    /// caret pins the mark to the line the user is actually editing.
    nonisolated static func dirtyLineNumbers(baseline: String, current: String,
                                             caretLine: Int? = nil) -> Set<Int> {
        if baseline == current { return [] }
        let result = lineDiff(before: baseline, after: current)
        var dirty = Set<Int>()
        for line in result.lines {
            if line.kind == .insert, let n = line.newNumber {
                dirty.insert(n)
            }
            // Replacements appear as delete+insert; inserts cover the new side.
            // Pure deletes leave no current line to mark.
        }
        if let caretLine {
            dirty = snapMarksToCaret(dirty, caretLine: caretLine, current: current)
        }
        return dirty
    }

    /// A pure line-diff can attribute a duplicate insertion to any equal line in
    /// a contiguous run. When the caret isn't on one of the marked lines but its
    /// line is content-identical to a marked line — with only equal lines in
    /// between — the run is ambiguous, so move that mark onto the caret line.
    /// Keeps the mark count identical; never fires for real (distinct-content)
    /// changes, so multi-region edits are untouched.
    nonisolated static func snapMarksToCaret(_ marks: Set<Int>, caretLine caret: Int,
                                             current: String) -> Set<Int> {
        guard !marks.isEmpty, !marks.contains(caret) else { return marks }
        let lines = splitDiffLines(current)
        guard caret >= 1, caret <= lines.count else { return marks }
        let caretText = lines[caret - 1]
        var best: Int?
        for d in marks {
            guard d >= 1, d <= lines.count, lines[d - 1] == caretText else { continue }
            let lo = min(caret, d), hi = max(caret, d)
            var contiguous = true
            if hi - lo > 1 {
                for i in (lo + 1)..<hi where lines[i - 1] != caretText {
                    contiguous = false
                    break
                }
            }
            if contiguous, best == nil || abs(d - caret) < abs(best! - caret) {
                best = d
            }
        }
        guard let d = best else { return marks }
        var next = marks
        next.remove(d)
        next.insert(caret)
        return next
    }

    /// Never publish during an in-flight SwiftUI body / AppKit layout pass
    /// (`noteContent` can run from `textDidChange` mid-update).
    private func bump() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.revision &+= 1
            NotificationCenter.default.post(name: .lineChangeMarksDidChange, object: nil)
        }
    }
}
