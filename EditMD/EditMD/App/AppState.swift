import SwiftUI
import AppKit

/// App-wide window routing state (Phase 2 of the move off DocumentGroup).
///
/// The MAIN workspace window is a single `Window` scene that shows whatever
/// file `currentURL` points at — opening a file "in place" is just a mutation
/// of this property. Separate (lite) windows are value-based `WindowGroup`
/// windows opened via the captured `openWindow` action.
///
/// SwiftUI's `openWindow`/`Window` actions only exist inside a live scene, so
/// the main window view hands them here on appear; AppKit-side callers (the
/// `AppDelegate` Finder-open handler, menu commands) then drive windows through
/// this object. Opens that arrive before a scene is alive are buffered.
@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    /// Active file of the main window. `nil` = untitled scratch.
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
        if EditorSettings.shared.general.liteMode {
            openInSeparateWindow(url)
        } else {
            openInMainWindow(url)
        }
    }

    /// Loads `url` (or a blank scratch when `nil`) into the main window,
    /// bringing it to the front.
    func openInMainWindow(_ url: URL?) {
        currentURL = url
        if let url { WorkspaceModel.shared.noteOpened(url) }
        openWindow?(id: WindowID.main)
    }

    /// Opens `url` in its own sidebar-less window. Buffered if no scene has
    /// handed us the action yet.
    func openInSeparateWindow(_ url: URL) {
        if let openWindow {
            openWindow(value: url)
        } else {
            pendingSeparateURLs.append(url)
        }
    }
}

enum WindowID {
    static let main = "main"
}
