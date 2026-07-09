import SwiftUI
import AppKit

/// App-wide window routing state (Phase 2 of the move off DocumentGroup).
///
/// The MAIN workspace window is a single `Window` scene that shows whatever
/// `currentURL` points at — a markdown file (editor) or a directory (folder
/// info card). Opening "in place" is just a mutation of this property.
/// Separate (lite) windows are value-based `WindowGroup` windows opened via
/// the captured `openWindow` action (files only).
///
/// SwiftUI's `openWindow`/`Window` actions only exist inside a live scene, so
/// the main window view hands them here on appear; AppKit-side callers (the
/// `AppDelegate` Finder-open handler, menu commands) then drive windows through
/// this object. Opens that arrive before a scene is alive are buffered.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    /// Active path of the main window. `nil` = untitled scratch.
    /// A directory URL shows the folder info card; a file URL opens the editor.
    @Published var currentURL: URL?

    private var openWindow: OpenWindowAction?
    private var pendingSeparateURLs: [URL] = []

    private init() {}

    // MARK: Scene wiring

    /// Called from the main window's `onAppear` — captures the environment's
    /// window action and flushes anything that wanted a window before now.
    func bindOpenWindow(_ action: OpenWindowAction) {
        openWindow = action
        let pending = pendingSeparateURLs
        pendingSeparateURLs.removeAll()
        for url in pending { action(value: url) }
    }

    // MARK: Routing

    /// Routes a file opened from Finder per the Lite-mode setting.
    func handleOpen(_ url: URL) {
        // Finder only delivers files (and packages); folders come from the sidebar.
        if EditorSettings.shared.general.liteMode {
            openInSeparateWindow(url)
        } else {
            openInMainWindow(url)
        }
    }

    /// Loads `url` (or a blank scratch when `nil`) into the main window,
    /// bringing it to the front. Directories open the folder info card;
    /// files open the editor. Records the visit for Back/Forward.
    func openInMainWindow(_ url: URL?) {
        let std = url?.standardizedFileURL
        currentURL = std
        if let std {
            if !Self.isFolder(std) {
                WorkspaceModel.shared.noteOpened(std)
            }
            DocumentHistory.shared.recordVisit(std)
        }
        openWindow?(id: WindowID.main)
    }

    /// Opens `url` in its own sidebar-less window. Buffered if no scene has
    /// handed us the action yet. Folders are rejected (no lite folder UI).
    func openInSeparateWindow(_ url: URL) {
        let std = url.standardizedFileURL
        guard !Self.isFolder(std) else { return }
        if let openWindow {
            openWindow(value: std)
        } else {
            pendingSeparateURLs.append(std)
        }
    }

    /// True for a real directory on disk that is not a package (`.textbundle`
    /// is a document, not a folder panel target).
    static func isFolder(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        return !isPackage
    }
}

enum WindowID {
    static let main = "main"
}
