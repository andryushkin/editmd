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
        // launch starts in read-first Preview — unless the launch itself was an
        // open that already picked a mode or has one in flight, which is what
        // an `editmd://` clip does (its Apple Event beats this callback).
        AppState.shared.applyColdLaunchEditorMode()
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
            seedStarterFolder()
        }
    }

    /// First launch of an installation: create `~/Documents/EditMD` with the
    /// README and the guide (see `StarterFolder`). Off the main actor — it is
    /// a handful of file copies nobody is waiting for. On a genuinely fresh
    /// start it also becomes the first workspace and the README opens; an
    /// existing sidebar is left exactly as the user arranged it, and a launch
    /// that already has something to show (an `editmd://` clip arrives before
    /// this callback) keeps its own document.
    private func seedStarterFolder() {
        Task.detached(priority: .utility) {
            guard let root = StarterFolder.seedIfNeeded() else { return }
            await MainActor.run {
                switch StarterFolder.presentation(
                    sidebarIsEmpty: WorkspaceModel.shared.workspaces.isEmpty,
                    mainPaneIsWelcome: AppState.shared.isWelcome,
                    hasEditorModeClaim: AppState.shared.hasEditorModeClaim
                ) {
                case .none:
                    break
                case .adopt:
                    WorkspaceModel.shared.addWorkspace(root)
                case .adoptAndOpenReadme:
                    WorkspaceModel.shared.addWorkspace(root)
                    AppState.shared.openInMainWindow(
                        root.appendingPathComponent("README.md"))
                }
            }
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

    /// Finder / `open` file opens AND the `editmd://` scheme (web clipper) —
    /// AppKit delivers both through this one callback.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme?.lowercased() == EditMDURLCommand.scheme {
                AppState.shared.handleURLCommand(url)
            } else {
                AppState.shared.handleOpen(url.standardizedFileURL)
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        GitCommitWatcher.shared.scheduleCheck(reason: "becomeActive")
    }
}
