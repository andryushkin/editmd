import Foundation
import Combine

/// Back/Forward history for the MAIN window's document trail (FSNotes' note
/// history idea). Scope is deliberately the main window only: it swaps files
/// in place, and every such open records a visit via `recordVisit`
/// (`AppState.openInMainWindow`). Detached lite windows are independent and
/// neither feed nor are targeted by this history — that keeps the caret-offset
/// restore, which rides the main window's control-jump path, consistent.
///
/// Each entry also remembers a caret offset so Back/Forward returns the reader
/// to *where they were*, not the top of the file — filled from
/// `currentOffsetProvider` at the moment a visit is left (a new navigation or a
/// Back/Forward step), and restored through AppState's control-jump path. The
/// offset is the Source/Visual caret; Preview has no cheap reading position, so
/// a file last read in Preview restores to its last caret (often the top).
@MainActor
final class DocumentHistory: ObservableObject {

    static let shared = DocumentHistory()

    /// One visited document: its URL plus the caret offset the reader last had
    /// there (UTF-16 into the markdown text; 0 until stamped).
    struct Visit: Equatable {
        let url: URL
        var offset: Int
    }

    @Published private(set) var entries: [Visit] = []
    @Published private(set) var index = -1

    /// Returns the live caret offset of the active main editor. Set by the main
    /// `ContentView` on appear so a departing entry can remember its position;
    /// nil when no editor is mounted (folder/welcome), which leaves the last
    /// stamped offset intact.
    var currentOffsetProvider: (() -> Int?)?

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < entries.count - 1 }

    func goBack(open: (Visit) -> Void) { navigate(to: index - 1, open: open) }
    func goForward(open: (Visit) -> Void) { navigate(to: index + 1, open: open) }

    /// Records a main-window visit (file or folder). AppState calls this from
    /// `openInMainWindow` — the sole entry, so every in-place file swap is a
    /// visit (deduped on the current URL).
    func recordVisit(_ url: URL) {
        record(url.standardizedFileURL)
    }

    /// Preserves Back/Forward targets when a workspace root is renamed.
    func relocateFolder(from oldRoot: URL, to newRoot: URL) {
        entries = entries.map {
            Visit(url: WorkspaceModel.relocatedURL($0.url, from: oldRoot, to: newRoot),
                  offset: $0.offset)
        }
    }

    /// Preserves Back/Forward targets for a closed file moved on disk.
    func relocateFile(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL
        let new = newURL.standardizedFileURL
        entries = entries.map {
            $0.url.standardizedFileURL == old ? Visit(url: new, offset: $0.offset) : $0
        }
    }

    /// Removes Back/Forward targets whose filesystem outcome is ambiguous.
    /// Keeping them would let a later navigation recreate a path that the move
    /// transaction deliberately dropped from AppState/Review/registry state.
    func discardPaths(inside rawRoots: [URL]) {
        let roots = rawRoots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return }
        let oldIndex = index
        var kept: [Visit] = []
        var keptIndex = -1
        for (position, visit) in entries.enumerated() {
            let shouldDrop = roots.contains {
                PathScope.contains(visit.url.standardizedFileURL.path, under: $0.path)
            }
            guard !shouldDrop else { continue }
            kept.append(visit)
            if position <= oldIndex { keptIndex = kept.count - 1 }
        }
        entries = kept
        if kept.isEmpty {
            index = -1
        } else if keptIndex >= 0 {
            index = keptIndex
        } else {
            index = 0
        }
    }

    private func record(_ url: URL) {
        // Re-focusing the current entry (app switch, a navigation landing on
        // its target) is not a new visit — and must not re-stamp its offset,
        // since we are arriving, not leaving.
        if index >= 0, index < entries.count, entries[index].url == url { return }
        // Leaving the current entry: remember where the reader was so Back
        // returns there.
        stampCurrentOffset()
        // A new visit truncates the forward tail — browser-history semantics.
        entries.removeSubrange((index + 1)...)
        entries.append(Visit(url: url, offset: 0))
        index = entries.count - 1
    }

    /// Writes the live caret offset into the current entry. No-op when there is
    /// no current entry or no editor is mounted to report a position.
    private func stampCurrentOffset() {
        guard index >= 0, index < entries.count,
              let offset = currentOffsetProvider?() else { return }
        entries[index].offset = offset
    }

    private func navigate(to newIndex: Int, open: (Visit) -> Void) {
        guard newIndex >= 0, newIndex < entries.count else { return }
        // Remember the current position first, so the reverse step returns here.
        stampCurrentOffset()
        index = newIndex
        open(entries[newIndex])
    }
}
