import AppKit

/// Handles Finder / `open` events now that DocumentGroup no longer does it.
/// Each opened file is routed through `AppState` (Lite-mode decides main vs
/// separate window). Wired into the app via `NSApplicationDelegateAdaptor`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Always land on Files after a cold launch; keep @AppStorage so the
        // tab still sticks when the sidebar view is recreated mid-session (A4).
        UserDefaults.standard.set("files", forKey: "sidebarTab")
        // Install didBecomeActive observer for git commit → clear dirty marks.
        _ = GitCommitWatcher.shared
        // Claude Code IDE channel: follows Settings ▸ General (default on).
        // Skipped under XCTest — the unit-test host would open a real listener
        // and drop a lock file into the developer's own `~/.claude/ide`.
        if !Self.isRunningUnitTests {
            ClaudeIDEService.shared.activate()
            // Always-on control socket for `editmdctl` (v38). Not under XCTest —
            // would clobber the developer's Application Support socket.
            ControlService.shared.activate()
        }
    }

    /// The test bundle sets this; `xcodebuild test` launches the app as host.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The lock file must not outlive the process — a stale one makes the
        // CLI dial a dead port on the next `/ide`.
        ClaudeIDEService.shared.stopBeforeTerminate()
        ControlService.shared.stopBeforeTerminate()
        // Whatever the debounce hasn't written yet is the next launch's first
        // frame — write it synchronously, the process is going away.
        WorkspaceModel.shared.snapshot.flushSync()
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
