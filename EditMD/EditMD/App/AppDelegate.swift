import AppKit

/// Finder / `open` events (DocumentGroup no longer handles them), routed via
/// `AppState`; Lite mode decides main vs separate window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Cold launch lands on Files; @AppStorage keeps the tab sticky across
        // mid-session sidebar recreation.
        UserDefaults.standard.set("files", forKey: "sidebarTab")
        // Cold launch resets editor mode to Preview — unless an open already
        // picked/claimed one (an `editmd://` clip's Apple Event beats this callback).
        AppState.shared.applyColdLaunchEditorMode()
        // didBecomeActive observer: git commit → clear dirty marks.
        _ = GitCommitWatcher.shared
        // XCTest guard: the test host would open real listeners, drop a lock
        // file into the developer's ~/.claude/ide, and clobber the real
        // Application Support socket.
        if !Self.isRunningUnitTests {
            // Both follow Settings ▸ General (default on).
            ClaudeIDEService.shared.activate()
            ControlService.shared.activate()
            // Warm the link graph now — otherwise the first scan waits for an
            // editor pane's ensureIndex and the user pays it on first open.
            // XCTest must not walk the developer's real vault.
            if !WorkspaceModel.shared.workspaces.isEmpty {
                LinkIndex.shared.ensureIndex()
            }
            installBackForwardMouseMonitor()
            seedStarterFolder()
            // Daily, silent unless newer. The app has no updater — this is the
            // only release-discovery path. Settings ▸ General (default on).
            UpdateChecker.shared.checkAutomaticallyIfDue()
        }
    }

    /// First launch: seed `~/Documents/EditMD` (see `StarterFolder`), off-main.
    /// Fresh start also adopts it and opens the README; an existing sidebar, or
    /// a launch already showing a document (`editmd://` clip beats this
    /// callback), is left alone.
    private func seedStarterFolder() {
        Task.detached(priority: .utility) {
            guard let root = await StarterFolder.seedIfNeeded() else { return }
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

    /// Token kept only for symmetric teardown; AppKit retains the monitor itself.
    private var backForwardMonitor: Any?

    /// Mouse buttons 3/4 → history Back/Forward (macOS numbering). Consumed
    /// only while the main window is key — history is that window's trail, so
    /// the buttons stay free in lite windows. Not installed under XCTest.
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
        // Stale lock file → CLI dials a dead port on the next `/ide`.
        ClaudeIDEService.shared.stopBeforeTerminate()
        ControlService.shared.stopBeforeTerminate()
        if let backForwardMonitor {
            NSEvent.removeMonitor(backForwardMonitor)
            self.backForwardMonitor = nil
        }
        // Sync flush: the undebounced snapshot is the next launch's first frame.
        WorkspaceModel.shared.snapshot.flushSync()
    }

    /// AppKit delivers both Finder/`open` files and `editmd://` URLs here.
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
