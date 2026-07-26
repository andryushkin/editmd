import AppKit

// Text fields inside an NSAlert accessory view, and their keyboard focus. Both
// halves exist because AppKit does not hold up its end inside our own alerts.

/// A text field for an alert's accessory view.
///
/// AppKit does not paint the system bezel of an *unfocused* field there: the
/// text floats on the alert background and reads as a caption rather than
/// something to type into (measured on the ⌘K dialog — that row was the alert's
/// background colour edge to edge, while an isolated alert built from the very
/// same code paints the bezel). So the resting box is drawn by our own layer;
/// the white pill and focus ring of the focused field still come from AppKit,
/// which covers this border.
@MainActor
func alertTextField(width: CGFloat, height: CGFloat = 24) -> NSTextField {
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: height))
    field.wantsLayer = true
    field.layer?.cornerRadius = 6
    field.layer?.borderWidth = 1
    field.layer?.borderColor = NSColor.separatorColor.cgColor
    field.layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    return field
}

/// Runs `alert` modally with `field` focused, so the user can type straight
/// away. Use instead of `alert.runModal()` for every alert whose accessory view
/// holds a text field.
///
/// `alert.window.initialFirstResponder = field` does not survive: AppKit applies
/// the panel's own initial first responder while the alert becomes key, after
/// our assignment (setting it once more after `alert.layout()` changes nothing —
/// both measured). The panel itself then stays first responder, so every
/// keystroke is dropped until the user clicks into a field. Claiming focus from
/// `didBecomeKey` — once AppKit has had its say — works.
@MainActor
func runModal(_ alert: NSAlert, focusing field: NSView) -> NSApplication.ModalResponse {
    let claim = FirstResponderClaim(field: field, window: alert.window)
    let response = alert.runModal()
    claim.cancel()
    return response
}

/// Makes `field` the first responder as soon as its window becomes key, and
/// once more when the modal loop starts: AppKit's own first-responder pass can
/// land on either side of `didBecomeKey`, and in the app it ran *after* it and
/// moved focus to the first field of the accessory view.
@MainActor
private final class FirstResponderClaim {
    private let field: NSView
    private var token: NSObjectProtocol?
    private var timer: Timer?

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
        // Scheduled by hand in the modal mode: the main queue does not drain
        // while an alert is up.
        let timer = Timer(timeInterval: 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.claim()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        self.timer = timer
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        timer?.invalidate()
        timer = nil
    }

    private func claim() {
        guard let window = field.window else { return }
        // Already editing this field: re-claiming would reselect its whole
        // contents, which would undo what the user has typed by then.
        if let editor = window.firstResponder as? NSTextView,
           let edited = editor.delegate as? NSView, edited === field { return }
        window.makeFirstResponder(field)
    }
}
