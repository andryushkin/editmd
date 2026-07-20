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
        // Editor mode is sticky within a session but not across launches: a cold
        // launch always starts in read-first Preview (see helper for details).
        resetEditorModeForColdLaunch(.standard)
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
            // Warm the link graph right away when a workspace exists —
            // otherwise the first scan starts only when an editor pane calls
            // ensureIndex, so the welcome/folder screen sat idle and the user
            // paid the full scan on their first opened file instead. The
            // status-bar chip shows its progress. Skipped under XCTest: the
            // test host must not walk the developer's real vault.
            if !WorkspaceModel.shared.workspaces.isEmpty {
                LinkIndex.shared.ensureIndex()
            }
            installBackForwardMouseMonitor()
        }
    }

    /// Retained so `applicationWillTerminate` can remove it — AppKit already
    /// keeps the monitor alive on its own, but holding the token keeps install
    /// and teardown symmetric with the other launch-time services.
    private var backForwardMonitor: Any?

    /// Mouse side buttons → Back/Forward, like a browser. Button 3 is the
    /// "back" thumb button, 4 is "forward" (macOS numbering). Consumed only
    /// when the main window is key — history is that window's trail, so the
    /// buttons stay free in lite windows and elsewhere; the nav itself no-ops
    /// at the ends. Not installed under XCTest, matching the IDE/control
    /// services.
    private func installBackForwardMouseMonitor() {
        backForwardMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
            guard AppState.shared.mainWindowIsKey else { return event }
            switch event.buttonNumber {
            case 3: AppState.shared.historyBack(); return nil
            case 4: AppState.shared.historyForward(); return nil
            default: return event
            }
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
        if let backForwardMonitor {
            NSEvent.removeMonitor(backForwardMonitor)
            self.backForwardMonitor = nil
        }
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
