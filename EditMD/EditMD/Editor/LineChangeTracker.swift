import Foundation

// MARK: - Session dirty-line tracking

/// Tracks which **current** 1-based lines differ from a per-file baseline.
/// Baseline resets on open and external disk apply; marks clear on quit
/// (in-memory) and when a git commit touches the path (`GitCommitWatcher`).
/// Not git working-tree dirty: baseline is "content when last anchored", not HEAD.
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

    /// Recompute dirty vs baseline on typing/paste. Small buffers diff inline;
    /// large ones debounce + diff off-main (a Myers line diff per keystroke on
    /// main hitched typing in big files).
    ///
    /// `caretUTF16Offset` breaks the duplicate-line tie: a line diff can't tell
    /// which of several equal lines is new, so the mark snaps to the caret. An
    /// offset, not a resolved line, so the O(n) offset→line scan runs where the
    /// diff runs — off-main for large buffers.
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

    /// Forget every tracked file at or under `root` (folder moved to the
    /// Trash) — a restored file must re-anchor, not inherit stale marks.
    func forget(under root: URL) {
        let rootPath = root.standardizedFileURL.path
        let keys = baseline.keys.filter {
            $0.path == rootPath || $0.path.hasPrefix(rootPath + "/")
        }
        guard !keys.isEmpty else { return }
        for key in keys {
            cancelRecompute(key)
            baseline.removeValue(forKey: key)
            dirty.removeValue(forKey: key)
            GitCommitWatcher.shared.forget(url: key)
        }
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

    /// 1-based current lines that are inserts/replacements vs baseline (LCS line
    /// diff). Pure — callable off-main. `caretLine` disambiguates duplicate-line
    /// insertions (see `noteContent`).
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

    /// Moves a mark onto the caret line when the caret's line is
    /// content-identical to a marked line with only equal lines between (the
    /// run is ambiguous). Mark count unchanged; never fires for
    /// distinct-content changes, so multi-region edits are untouched.
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
