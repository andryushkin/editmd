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
    func noteContent(url: URL?, content: String) {
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
            applyDirty(Self.dirtyLineNumbers(baseline: base, current: content), for: key)
            return
        }
        recomputeTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let next = await Task.detached(priority: .utility) {
                LineChangeTracker.dirtyLineNumbers(baseline: base, current: content)
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
    nonisolated static func dirtyLineNumbers(baseline: String, current: String) -> Set<Int> {
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
        return dirty
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
