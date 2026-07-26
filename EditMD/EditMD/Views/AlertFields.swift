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
func alertTextField(width: CGFloat) -> NSTextField {
    let field = BoxedTextField(frame: NSRect(x: 0, y: 0, width: width, height: 24))
    // One-line prompts. This is layout only — it does not filter a pasted
    // newline, which the readers of these fields strip themselves
    // (`singleLineFieldText`).
    field.usesSingleLineMode = true
    field.drawBox()
    return field
}

/// One line of what an alert field holds: the control characters a paste can
/// carry — newline, tab — folded to spaces, runs of spaces collapsed, ends
/// trimmed. A field is single-line in layout only, so this is the filter; a
/// name or a link label must never carry a line break into a path or into
/// markdown syntax.
func singleLineFieldText(_ raw: String) -> String {
    let folded = String(raw.unicodeScalars.map {
        CharacterSet.controlCharacters.contains($0) ? " " : Character($0)
    })
    return folded.split(separator: " ", omittingEmptySubsequences: true)
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespaces)
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
    /// How long to keep re-claiming after the panel becomes key, and how often.
    /// Short on purpose: AppKit's pass runs immediately, and a window this brief
    /// cannot collide with a Tab or a click of the user's own.
    private static let watch: TimeInterval = 0.15
    private static let tick: TimeInterval = 0.05

    private let field: NSView
    private var token: NSObjectProtocol?
    private var timer: Timer?
    private var deadline: Date?
    private var claims = 0

    init(field: NSView, window: NSWindow) {
        self.field = field
        // The watch is armed from `didBecomeKey`, not from here: the panel may
        // become key seconds later — the app need not even be frontmost when the
        // dialog is raised — and the observer lives until the modal ends so that
        // late arrival still gets its field focused.
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panelBecameKey()
            }
        }
    }

    func cancel() {
        if let token { NotificationCenter.default.removeObserver(token) }
        token = nil
        stopWatching()
    }

    private func panelBecameKey() {
        // First opening: claim over whatever AppKit's own pass does, for a moment.
        // A later return to the panel (back from another app) claims only if no
        // field is being edited — by then the focus is the user's to place.
        let opening = claims == 0 && timer == nil
        claim(force: opening)
        guard opening else { return }
        deadline = Date().addingTimeInterval(Self.watch)
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

    /// AppKit's pass runs once, so a claim that has had to take focus *back* is
    /// the last one needed: stop there rather than watch to the deadline, which
    /// is only the fallback for a pass that never comes. Only the timer stops —
    /// the observer stays for the rest of the dialog.
    private func tick() {
        // Focus already where it belongs — either our claim stood or AppKit's
        // pass has been corrected — so there is nothing left to watch, and
        // staying would only risk taking focus from where the user just put it.
        if isFocused { stopWatching(); return }
        claim(force: true)
        let expired = deadline.map { Date() >= $0 } ?? true
        if claims >= 2 || expired { stopWatching() }
    }

    /// True while `field` is the one being edited.
    private var isFocused: Bool {
        guard let editor = field.window?.firstResponder as? NSTextView,
              let edited = editor.delegate as? NSView
        else { return false }
        return edited === field
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        deadline = nil
    }

    private func claim(force: Bool) {
        guard let window = field.window, window.isKeyWindow else { return }
        // Already editing this field: re-claiming would reselect its whole
        // contents, discarding what the user has typed by then.
        if isFocused { return }
        // A later return to the panel claims only when nothing at all holds
        // focus. Anything that does — another field, a template popup — was put
        // there by the user, not by AppKit's opening pass; only that pass, inside
        // the opening moment, is worth claiming over.
        if !force, window.firstResponder !== window { return }
        // Counting successes only: two refusals must not look like two claims and
        // end the watch before the field has focus at all.
        if window.makeFirstResponder(field) { claims += 1 }
    }
}
