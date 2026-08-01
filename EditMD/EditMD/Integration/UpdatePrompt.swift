import AppKit

/// The face of `UpdateChecker`: one alert per outcome. Kept behind
/// `UpdatePresenting` so the whole judgement stays testable as values — this
/// file is the only part that needs a screen.
@MainActor
struct UpdateAlertPresenter: UpdatePresenting {

    /// The Homebrew line, spelled exactly as the cask is installed. Shown (and
    /// copied) only to a copy that really came from brew, so nobody is handed
    /// a command they cannot run.
    static let brewCommand = "brew upgrade --cask andryushkin/apps/editmd"

    func present(_ result: UpdateCheckResult, checker: UpdateChecker) {
        // `runModal` nested inside an open panel or another alert traps the
        // user, and an alert raised while they are in another app arrives
        // where they are not looking. Wait for a calm moment instead — a
        // release is not urgent enough to interrupt anything.
        guard UpdateDecision.canPresentNow(appIsActive: NSApp.isActive,
                                           hasModalWindow: NSApp.modalWindow != nil) else {
            waitForCalm { present(result, checker: checker) }
            return
        }
        switch result {
        case .upToDate:
            inform(title: String(localized: "EditMD is up to date"),
                   text: String(localized: "You are running version \(AppVersion.current)."))
        case .requiresNewerSystem(let version, let minimum):
            inform(title: String(localized: "EditMD \(version) needs a newer macOS"),
                   text: String(localized: "It requires macOS \(minimum), and this Mac runs macOS \(AppVersion.currentSystem). You are running EditMD \(AppVersion.current), which keeps working."))
        case .failed(let message):
            inform(title: String(localized: "Could not check for updates"),
                   text: message)
        case .available(let update):
            offer(update, checker: checker)
        }
    }

    /// One-shot: fires on the next activation, then unsubscribes. Only ever
    /// one is outstanding, because a single request presents at most once.
    private func waitForCalm(_ retry: @escaping @MainActor () -> Void) {
        var token: (any NSObjectProtocol)?
        token = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            MainActor.assumeIsolated { retry() }
        }
    }

    private func offer(_ update: AvailableUpdate, checker: UpdateChecker) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "EditMD \(update.version) is available")

        // Three buttons, in AppKit's order: the action, the dismissal, the
        // opt-out. A fourth would push the row into a stack and bury "Later".
        switch update.channel {
        case .homebrew:
            alert.informativeText = String(localized: "You are running \(update.current). This copy was installed with Homebrew, so update it there:\n\n\(Self.brewCommand)")
            alert.addButton(withTitle: String(localized: "Copy Command"))
        case .direct:
            alert.informativeText = String(localized: "You are running \(update.current). The download page has the new version and what changed in it.")
            alert.addButton(withTitle: String(localized: "Open Download Page"))
        }
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            switch update.channel {
            case .homebrew:
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(Self.brewCommand, forType: .string)
            case .direct:
                // Always a link to our own site: the feed's URL survived
                // decoding only if it was one, and otherwise this is the
                // page compiled into the app.
                NSWorkspace.shared.open(update.page)
            }
        case .alertThirdButtonReturn:
            // Remembered by version, not as a blanket "stop asking": the next
            // release is announced again, and Check for Updates… still
            // answers about this one.
            checker.skippedVersion = update.version
        default:
            break
        }
    }

    private func inform(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
