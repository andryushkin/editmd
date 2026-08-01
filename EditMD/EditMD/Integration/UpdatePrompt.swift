import AppKit

/// The face of `UpdateChecker`: one alert per outcome. Kept apart from the
/// checker so the whole judgement stays testable as values — this file is the
/// only part that needs a screen.
@MainActor
enum UpdatePrompt {

    /// The Homebrew line, spelled exactly as the cask is installed. Shown (and
    /// copied) only to a copy that really came from brew, so nobody is handed
    /// a command they cannot run.
    static let brewCommand = "brew upgrade --cask andryushkin/apps/editmd"

    static func present(_ update: AvailableUpdate, checker: UpdateChecker) {
        present(.available(update), checker: checker)
    }

    static func present(_ result: UpdateCheckResult, checker: UpdateChecker) {
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

    private static func offer(_ update: AvailableUpdate, checker: UpdateChecker) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "EditMD \(update.version) is available")

        // Three buttons, in AppKit's order: the action, the dismissal, the
        // opt-out. A fourth would push the row into a stack and bury "Later".
        switch update.channel {
        case .homebrew:
            alert.informativeText = String(localized: "You are running \(update.current). This copy was installed with Homebrew, so update it there:\n\n\(brewCommand)")
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
                pasteboard.setString(brewCommand, forType: .string)
            case .direct:
                if let page = update.page { NSWorkspace.shared.open(page) }
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

    private static func inform(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
