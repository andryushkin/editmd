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

    /// How long an *unsolicited* alert waits for its moment before giving up.
    /// Past this the news is stale enough not to be worth ambushing anyone
    /// with, and the caller is told nothing was shown. An answer the user
    /// asked for has no such limit — they are owed it whenever they come back.
    nonisolated static let unsolicitedPatience: TimeInterval = 5 * 60

    @discardableResult
    func present(_ result: UpdateCheckResult, checker: UpdateChecker,
                 urgency: PresentationUrgency) async -> Bool {
        // Nested runModal traps the user; an alert while they are in another
        // app lands unseen. Wait for a calm moment — a release is not urgent.
        let patience = urgency == .unsolicited ? Self.unsolicitedPatience : nil
        guard await waitForCalm(patience: patience) else { return false }
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
        return true
    }

    /// Polls, not observes: AppKit posts nothing when a modal session ends
    /// while the app stays active, so an activation observer would leave the
    /// alert pending and fire it at an unrelated moment. `patience == nil`
    /// waits indefinitely (the requested answer must not evaporate).
    private func waitForCalm(patience: TimeInterval?) async -> Bool {
        let deadline = patience.map { Date().addingTimeInterval($0) }
        while !UpdateDecision.canPresentNow(appIsActive: NSApp.isActive,
                                            hasModalWindow: NSApp.modalWindow != nil) {
            if let deadline, Date() >= deadline { return false }
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                // Cancelled: give up now rather than spinning on a sleep that
                // throws immediately for the rest of the deadline.
                return false
            }
        }
        return true
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
