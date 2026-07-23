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

    /// Retire every sink created so far (mode switch).
    func advance() { epoch &+= 1 }

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
