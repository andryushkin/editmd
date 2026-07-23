import XCTest
@testable import EditMD

/// The gate drops `ActiveInlineFormats` publishes stamped with a stale epoch —
/// the async tail an outgoing editor (Source/Visual main-queue hop, Preview's
/// WebKit message queue) fires after a mode switch already reset the strip.
@MainActor
final class ActiveFormatsGateTests: XCTestCase {

    private var bold: ActiveInlineFormats {
        var fmt = ActiveInlineFormats()
        fmt.bold = true
        return fmt
    }

    func testSinkDeliversAtCurrentEpoch() {
        let gate = ActiveFormatsGate()
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        sink(bold)
        XCTAssertEqual(received, [bold])
    }

    func testAdvanceRetiresEarlierSinks() {
        let gate = ActiveFormatsGate()
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        gate.advance()
        sink(bold)
        XCTAssertEqual(received, [], "publish queued before the mode switch must be dropped")
    }

    func testSinkCreatedAfterAdvanceDelivers() {
        let gate = ActiveFormatsGate()
        var received: [ActiveInlineFormats] = []
        gate.advance()
        let sink = gate.sink { received.append($0) }
        sink(bold)
        XCTAssertEqual(received, [bold], "the incoming mode's sink carries the new epoch")
    }

    func testRetiredSinkStaysRetiredNextEpoch() {
        // A second advance must not accidentally revalidate a sink from an
        // older epoch (the stamp is compared for equality, not parity).
        let gate = ActiveFormatsGate()
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        gate.advance()
        gate.advance()
        sink(bold)
        XCTAssertEqual(received, [])
    }

    // MARK: noteMode — the render-time funnel

    func testNoteModeFirstObservationKeepsInitialSinks() {
        // First render: noteMode records the initial mode; sinks built later
        // in the same pass must stay valid.
        let gate = ActiveFormatsGate()
        gate.noteMode(.preview)
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        sink(bold)
        XCTAssertEqual(received, [bold])
    }

    func testNoteModeSameModeKeepsSinks() {
        // Re-render without a mode change (resize, unrelated state) must not
        // retire the live editor's sink.
        let gate = ActiveFormatsGate()
        gate.noteMode(.source)
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        gate.noteMode(.source)
        sink(bold)
        XCTAssertEqual(received, [bold])
    }

    func testNoteModeTransitionRetiresSinksWithoutAdvance() {
        // Models the control-socket path: `editmdctl mode …` writes the
        // UserDefaults key directly, so `setEditorMode` never runs — the
        // render pass observing the new mode must retire the old mode's
        // sinks by itself.
        let gate = ActiveFormatsGate()
        gate.noteMode(.preview)
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        gate.noteMode(.source)
        sink(bold)
        XCTAssertEqual(received, [], "Preview's queued WebKit publish must not land in Source")
    }

    func testNoteModeTransitionNewSinkDelivers() {
        let gate = ActiveFormatsGate()
        gate.noteMode(.preview)
        gate.noteMode(.source)
        var received: [ActiveInlineFormats] = []
        let sink = gate.sink { received.append($0) }
        sink(bold)
        XCTAssertEqual(received, [bold])
    }

    func testDeallocatedGateDropsPublishes() {
        // File switch: `.id(url)` recreates ContentView and releases the gate;
        // a coordinator still holding the sink must deliver nothing.
        var gate: ActiveFormatsGate? = ActiveFormatsGate()
        var received: [ActiveInlineFormats] = []
        let sink = gate!.sink { received.append($0) }
        gate = nil
        sink(bold)
        XCTAssertEqual(received, [])
    }
}
