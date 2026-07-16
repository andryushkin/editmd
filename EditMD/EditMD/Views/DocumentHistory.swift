import AppKit
import Combine

/// App-wide Back/Forward history over document windows (FSNotes' note
/// history idea, mapped onto DocumentGroup's window-per-document model).
///
/// A visit is recorded whenever a document window becomes key — DocumentGroup
/// sets `representedURL` on its windows, so no per-view wiring is needed
/// (untitled documents have no URL and stay out of the history). Navigating
/// re-activates the neighbouring document's window, or reopens the file if
/// the window was closed.
@MainActor
final class DocumentHistory: ObservableObject {

    static let shared = DocumentHistory()

    @Published private(set) var urls: [URL] = []
    @Published private(set) var index = -1

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)
    }

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index >= 0 && index < urls.count - 1 }

    func goBack(open: (URL) -> Void) { navigate(to: index - 1, open: open) }
    func goForward(open: (URL) -> Void) { navigate(to: index + 1, open: open) }

    /// Records a main-window visit (file or folder). In-place replacement does
    /// not re-key the window, so AppState calls this explicitly; key-window
    /// focus still records via the notification below (deduped).
    func recordVisit(_ url: URL) {
        record(url.standardizedFileURL)
    }

    /// Preserves Back/Forward targets when a workspace root is renamed.
    func relocateFolder(from oldRoot: URL, to newRoot: URL) {
        urls = urls.map {
            WorkspaceModel.relocatedURL($0, from: oldRoot, to: newRoot)
        }
    }

    /// Preserves Back/Forward targets for a closed file moved on disk.
    func relocateFile(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL
        let new = newURL.standardizedFileURL
        urls = urls.map { $0.standardizedFileURL == old ? new : $0 }
    }

    /// Removes Back/Forward targets whose filesystem outcome is ambiguous.
    /// Keeping them would let a later navigation recreate a path that the move
    /// transaction deliberately dropped from AppState/Review/registry state.
    func discardPaths(inside rawRoots: [URL]) {
        let roots = rawRoots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return }
        let oldIndex = index
        var kept: [URL] = []
        var keptIndex = -1
        for (position, url) in urls.enumerated() {
            let shouldDrop = roots.contains { root in
                let path = url.standardizedFileURL.path
                return path == root.path || path.hasPrefix(root.path + "/")
            }
            guard !shouldDrop else { continue }
            kept.append(url)
            if position <= oldIndex { keptIndex = kept.count - 1 }
        }
        urls = kept
        if kept.isEmpty {
            index = -1
        } else if keptIndex >= 0 {
            index = keptIndex
        } else {
            index = 0
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let url = (notification.object as? NSWindow)?.representedURL else { return }
        record(url.standardizedFileURL)
    }

    private func record(_ url: URL) {
        // Re-focusing the current entry (app switch, a navigation landing on
        // its target) is not a new visit.
        if index >= 0, index < urls.count, urls[index] == url { return }
        // A new visit truncates the forward tail — browser-history semantics.
        urls.removeSubrange((index + 1)...)
        urls.append(url)
        index = urls.count - 1
    }

    private func navigate(to newIndex: Int, open: (URL) -> Void) {
        guard newIndex >= 0, newIndex < urls.count else { return }
        index = newIndex
        let url = urls[newIndex]
        if let window = NSApp.windows.first(where: {
            $0.representedURL?.standardizedFileURL == url
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            open(url)
        }
    }
}
