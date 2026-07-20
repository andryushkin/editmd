import Foundation
import os

// Per-keystroke performance instrument for the Source and Visual editors.
//
// Typing can drive CPU toward 100% when a per-keystroke phase (synchronous
// highlight, Visual serialization, stats) turns heavy. This mirrors how agterm
// and the rest of EditMD surface diagnostics: Apple unified logging under the
// `com.editmd.app` subsystem plus os_signpost intervals for Instruments — not
// bespoke NSLog or an on-screen HUD.
//
// Two audiences, always on (signposts are near-free until an Instruments trace
// records them; the warning is silent until a keystroke blows the budget):
//   • Instruments — the `typing` signpost track shows one `keystroke` interval
//     per edit with a nested interval per phase.
//   • Console / `log show` — a `.warning` fires only for a slow keystroke,
//     naming the total and the heaviest phases:
//       log show --predicate 'subsystem == "com.editmd.app" && category == "typing"' --last 5m
//
// Tune the threshold without a rebuild:
//   defaults write com.editmd.app EditMDTypingBudgetMs 8

let typingLog = Logger(subsystem: "com.editmd.app", category: "typing")
let typingSignposter = OSSignposter(subsystem: "com.editmd.app", category: "typing")

/// A keystroke costing more than this logs a breakdown. Defaults to one dropped
/// 60 fps frame (16 ms); overridable via the `EditMDTypingBudgetMs` default.
let typingBudget: Duration = {
    let override = UserDefaults.standard.object(forKey: "EditMDTypingBudgetMs") as? Double
    return .milliseconds(override ?? 16)
}()

/// Measures one keystroke cycle: wrap each phase in `phase(_:_:)`, then call
/// `finish()`. Value type — create a fresh one per edit.
struct KeystrokeProfiler {
    enum Mode: String { case source, visual }

    private let mode: Mode
    private let clock = ContinuousClock()
    private let started: ContinuousClock.Instant
    private let keystrokeID: OSSignpostID
    private let keystrokeState: OSSignpostIntervalState
    private var phases: [(name: StaticString, duration: Duration)] = []

    init(_ mode: Mode) {
        self.mode = mode
        started = clock.now
        keystrokeID = typingSignposter.makeSignpostID()
        keystrokeState = typingSignposter.beginInterval(
            "keystroke", id: keystrokeID, "\(mode.rawValue, privacy: .public)")
    }

    /// Runs `body` as one named phase — its own signpost interval and a timing
    /// entry in the slow-keystroke breakdown. Returns whatever `body` returns.
    @discardableResult
    mutating func phase<T>(_ name: StaticString, _ body: () -> T) -> T {
        let state = typingSignposter.beginInterval(name, id: keystrokeID)
        let start = clock.now
        let result = body()
        phases.append((name, start.duration(to: clock.now)))
        typingSignposter.endInterval(name, state)
        return result
    }

    /// Closes the keystroke interval; warns (with a phase breakdown) when the
    /// total exceeded the budget.
    func finish() {
        let total = started.duration(to: clock.now)
        typingSignposter.endInterval("keystroke", keystrokeState)
        guard total >= typingBudget else { return }
        typingLog.warning("""
            slow \(mode.rawValue, privacy: .public) keystroke \
            \(total.milliseconds, privacy: .public) ms — \
            \(slowKeystrokeBreakdown(phases), privacy: .public)
            """)
    }
}

/// Formats the heaviest phases as `name=1.2ms`, largest first (top `limit`).
/// Pure and side-effect-free so it is directly testable.
func slowKeystrokeBreakdown(_ phases: [(name: StaticString, duration: Duration)],
                            limit: Int = 4) -> String {
    phases
        .sorted { $0.duration > $1.duration }
        .prefix(limit)
        .map { "\($0.name)=\(String(format: "%.1f", $0.duration.milliseconds))ms" }
        .joined(separator: " ")
}

extension Duration {
    /// Whole duration in milliseconds (seconds + attoseconds folded together).
    var milliseconds: Double {
        let parts = components
        return Double(parts.seconds) * 1_000
            + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
