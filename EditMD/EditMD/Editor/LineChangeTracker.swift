import Foundation

// MARK: - Session dirty-line tracking (v34.1)

/// Tracks which **current** 1-based line numbers differ from a per-file baseline.
/// Baseline resets on open and on external disk apply; marks clear on app quit
/// (in-memory only) and later on git commit (stage 3).
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

    private init() {}

    // MARK: - Queries

    func dirtyLines(for url: URL?) -> Set<Int> {
        guard let url else { return [] }
        return dirty[url.standardizedFileURL] ?? []
    }

    func isDirty(line: Int, url: URL?) -> Bool {
        dirtyLines(for: url).contains(line)
    }

    // MARK: - Lifecycle

    /// Open / external apply / Take Disk: new anchor, no marks.
    func noteBaseline(url: URL?, content: String) {
        guard let url else { return }
        let key = url.standardizedFileURL
        baseline[key] = content
        dirty[key] = []
        bump()
    }

    /// User typed or paste: recompute dirty vs baseline.
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
        let next = Self.dirtyLineNumbers(baseline: base, current: content)
        if dirty[key] != next {
            dirty[key] = next
            bump()
        }
    }

    /// Drop marks (and keep baseline) — used after commit of this path.
    func clearMarks(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        if dirty[key]?.isEmpty == false {
            dirty[key] = []
            bump()
        }
    }

    /// Forget a file entirely (closed last window, optional).
    func forget(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        baseline.removeValue(forKey: key)
        dirty.removeValue(forKey: key)
        bump()
    }

    func clearAll() {
        baseline.removeAll()
        dirty.removeAll()
        bump()
    }

    // MARK: - Pure recompute

    /// Current-document line numbers (1-based) that are inserts or replacements
    /// relative to baseline (LCS line diff).
    static func dirtyLineNumbers(baseline: String, current: String) -> Set<Int> {
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
            self?.revision &+= 1
        }
    }
}
