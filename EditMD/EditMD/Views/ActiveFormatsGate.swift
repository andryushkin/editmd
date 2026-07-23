import Foundation

/// Epoch gate for `ActiveInlineFormats` publishes. Every mode delivers caret
/// formats through an async hop — Source/Visual via a main-queue dispatch,
/// Preview via the WKWebView script-message queue — so a value computed before
/// a mode switch can land after `setEditorMode` reset the shared strip state
/// and re-light stale flags. `ContentView` stamps each publisher's sink with
/// the epoch current at render; `advance()` on a mode switch retires every
/// sink the outgoing editor still holds. A file switch recreates `ContentView`
/// (`.id(url)`) and deallocates the gate, so the weak reference drops those
/// late publishes the same way.
@MainActor
final class ActiveFormatsGate {
    private(set) var epoch: UInt64 = 0
    /// Mode last seen at render (`noteMode`).
    private var notedMode: EditorMode?

    /// Retire every sink created so far (mode switch).
    func advance() { epoch &+= 1 }

    /// Render-time funnel: called at the top of `editorArea`, strictly before
    /// any sink of that pass is built. Catches EVERY writer of the shared
    /// mode default — the strip/menu go through `setEditorMode`, but the
    /// control socket (`editmdctl mode …`) writes UserDefaults directly and
    /// would otherwise never advance the gate. Running during view evaluation
    /// guarantees the order "advance, then build this pass's sinks"; an
    /// `.onChange` bump could not (its ordering against child body evaluation
    /// is unspecified, and a late bump would retire the fresh sinks).
    func noteMode(_ mode: EditorMode) {
        guard notedMode != mode else { return }
        let isFirstObservation = notedMode == nil
        notedMode = mode
        if !isFirstObservation { advance() }
    }

    /// Wraps `deliver` with the current epoch. The returned closure is handed
    /// to AppKit/WebKit publishers that only ever call it on the main thread
    /// (main-queue hop, WKScriptMessageHandler) — hence `assumeIsolated`.
    func sink(_ deliver: @escaping @MainActor (ActiveInlineFormats) -> Void)
        -> (ActiveInlineFormats) -> Void
    {
        let stamped = epoch
        return { [weak self] formats in
            MainActor.assumeIsolated {
                guard let self, self.epoch == stamped else { return }
                deliver(formats)
            }
        }
    }
}
