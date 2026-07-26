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
    let field = BoxedTextField(frame: NSRect(x: 0, y: 0, width: width, height: height))
    // One-line prompts: a pasted newline would otherwise survive into a file
    // name or a link destination.
    field.usesSingleLineMode = true
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.drawBox()
    return field
}

/// The field of `alertTextField`, drawing its own box. A subclass so the colours
/// can be resolved again under the field's *own* effective appearance — the alert
/// panel's, once it is in the window — instead of being frozen as CGColors under
/// whatever appearance happened to be current at construction time.
private final class BoxedTextField: NSTextField {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        drawBox()
    }

    func drawBox() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        }
    }
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

/// Claims first responder for `field` while the alert opens: when the panel
/// becomes key, and then on a short repeating tick, because AppKit's own
/// first-responder pass can land on either side of `didBecomeKey` — in the app it
/// ran *after* the notification and moved focus to the first accessory field.
///
/// The claiming window is deliberately short and self-closing. Once it is over
/// the alert is the user's: a claim that outlived the opening would steal focus
/// back — and reselect the whole field — every time the panel became key again,
/// e.g. after a trip to another app to copy the URL.
@MainActor
private final class FirstResponderClaim {
    /// How long to keep watching after the panel opens, and how often. The watch
    /// normally ends long before the deadline — see `tick()`.
    private static let window: TimeInterval = 0.3
    private static let tick: TimeInterval = 0.05

    private let field: NSView
    private var token: NSObjectProtocol?
    private var timer: Timer?
    private var deadline: Date?
    private var claims = 0

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
        deadline = Date().addingTimeInterval(Self.window)
        // Scheduled by hand in the modal mode: the main queue does not drain
        // while an alert is up.
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick()
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
        deadline = nil
    }

    /// AppKit's pass runs once, so a claim that has had to take focus *back* is
    /// the last one needed: stop there rather than keep watching to the deadline,
    /// which is only the fallback for a pass that never comes.
    private func tick() {
        claim()
        let expired = deadline.map { Date() >= $0 } ?? true
        if claims >= 2 || expired { cancel() }
    }

    private func claim() {
        guard let window = field.window else { return }
        // Already editing this field: re-claiming would reselect its whole
        // contents, discarding what the user has typed by then.
        if let editor = window.firstResponder as? NSTextView,
           let edited = editor.delegate as? NSView, edited === field { return }
        window.makeFirstResponder(field)
        claims += 1
    }
}
