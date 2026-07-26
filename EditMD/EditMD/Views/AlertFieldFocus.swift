import AppKit

// Keyboard focus for an NSAlert whose accessory view holds a text field.
//
// `alert.window.initialFirstResponder = field` does not survive: AppKit applies
// the panel's own initial first responder while the alert becomes key, after
// our assignment (setting it once more after `alert.layout()` changes nothing —
// both measured). The panel itself then stays first responder, so every
// keystroke is dropped until the user clicks into a field. Claiming focus from
// `didBecomeKey` — once AppKit has had its say — works.

/// Runs `alert` modally with `field` focused, so the user can type straight
/// away. Use instead of `alert.runModal()` for every alert whose accessory view
/// holds a text field.
@MainActor
func runModal(_ alert: NSAlert, focusing field: NSView) -> NSApplication.ModalResponse {
    let claim = FirstResponderClaim(field: field, window: alert.window)
    let response = alert.runModal()
    claim.cancel()
    return response
}

/// Makes `field` the first responder as soon as its window becomes key.
@MainActor
private final class FirstResponderClaim {
    private let field: NSView
    private var token: NSObjectProtocol?

    init(field: NSView, window: NSWindow) {
        self.field = field
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.claim()
            }
        }
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
    }

    private func claim() {
        field.window?.makeFirstResponder(field)
    }
}
