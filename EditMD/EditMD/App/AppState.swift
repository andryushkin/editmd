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

    /// Active path of the main window.
    /// - file URL → editor
    /// - directory URL → folder info card
    /// - `nil` + `isUntitled == false` → welcome home
    /// - `nil` + `isUntitled == true` → empty scratch (File ▸ New)
    @Published var currentURL: URL?

    /// When `currentURL` is `nil`, distinguishes welcome home from an untitled
    /// scratch document. Cold launch starts on welcome (`false`).
    @Published var isUntitled: Bool = false

    private var openWindow: OpenWindowAction?
    private var pendingSeparateURLs: [URL] = []

    /// Pending control-channel jump (url + UTF-16 markdown offset), consumed
    /// by the main window once the target file is mounted. Replaces the old
    /// fixed-delay notification, which silently dropped the jump whenever the
    /// file took longer than the timer to open.
    private var pendingControlJump: (url: URL, offset: Int)?

    private init() {}

    // MARK: Control-channel jump

    /// Control channel requests a caret/scroll jump. If the target is already
    /// mounted, the notification handler consumes it immediately; otherwise
    /// ContentView consumes it on mount (onAppear / fileURL change).
    func requestControlJump(url: URL, offset: Int) {
        pendingControlJump = (url.standardizedFileURL, offset)
        NotificationCenter.default.post(name: .editMDControlJump, object: nil)
    }

    /// Returns the pending offset if it targets `url`, clearing it.
    func consumeControlJump(for url: URL?) -> Int? {
        guard let url, let pending = pendingControlJump,
              pending.url == url.standardizedFileURL else { return nil }
        pendingControlJump = nil
        return pending.offset
    }

    /// Main pane is the app welcome (not a document / folder).
    var isWelcome: Bool { currentURL == nil && !isUntitled }

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
    /// Always starts in Preview — Finder/Dock opens are read-first; mode
    /// switches still persist for subsequent in-app opens (sidebar, wiki, etc.).
    func handleOpen(_ url: URL) {
        // Same key as ContentView's `@AppStorage("editorMode")`.
        UserDefaults.standard.set(EditorMode.preview.rawValue, forKey: "editorMode")
        // Finder only delivers files (and packages); folders come from the sidebar.
        if EditorSettings.shared.general.liteMode {
            openInSeparateWindow(url)
        } else {
            openInMainWindow(url)
        }
    }

    /// Shows the welcome home screen in the main window (cold-start default;
    /// also reachable via View ▸ Welcome when we add it later).
    func showWelcome() {
        isUntitled = false
        currentURL = nil
        openWindow?(id: WindowID.main)
    }

    /// Empty untitled markdown in the main window (File ▸ New).
    func openUntitled() {
        isUntitled = true
        currentURL = nil
        openWindow?(id: WindowID.main)
    }

    /// Loads `url` into the main window, bringing it to the front.
    /// Directories open the folder info card; files open the editor.
    /// Pass `nil` only to return to welcome — prefer `openUntitled()` for New.
    func openInMainWindow(_ url: URL?) {
        let std = url?.standardizedFileURL
        if let std {
            isUntitled = false
            currentURL = std
            if !Self.isFolder(std) {
                WorkspaceModel.shared.noteOpened(std)
            }
            // The branch the next launch reopens (the sidebar collapses the rest).
            WorkspaceModel.shared.noteActive(std)
            DocumentHistory.shared.recordVisit(std)
        } else {
            // Explicit nil → welcome (not a scratch). Callers that want New
            // use `openUntitled()`.
            isUntitled = false
            currentURL = nil
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
