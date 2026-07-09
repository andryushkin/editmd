import AppKit

/// Handles Finder / `open` events now that DocumentGroup no longer does it.
/// Each opened file is routed through `AppState` (Lite-mode decides main vs
/// separate window). Wired into the app via `NSApplicationDelegateAdaptor`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install didBecomeActive observer for git commit → clear dirty marks.
        _ = GitCommitWatcher.shared
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            AppState.shared.handleOpen(url.standardizedFileURL)
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GitCommitWatcher.shared.scheduleCheck(reason: "becomeActive")
    }
}
