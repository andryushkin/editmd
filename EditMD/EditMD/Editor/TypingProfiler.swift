import Foundation
import os

// Per-keystroke performance instrument for the Source and Visual editors.
//
// Typing can drive CPU toward 100% when a per-keystroke phase (synchronous
// highlight, Visual serialization, stats) turns heavy. This mirrors how agterm
// and the rest of EditMD surface diagnostics: Apple unified logging under the
// `andryushkin.EditMD` subsystem plus os_signpost intervals for Instruments — not
// bespoke NSLog or an on-screen HUD.
//
// Two audiences, always on (signposts are near-free until an Instruments trace
// records them; the warning is silent until a keystroke blows the budget):
//   • Instruments — the `typing` signpost track shows one `keystroke` interval
//     per edit with a nested interval per phase.
//   • Console / `log show` — a `.warning` fires only for a slow keystroke,
//     naming the total and the heaviest phases:
//       log show --predicate 'subsystem == "andryushkin.EditMD" && category == "typing"' --last 5m
//
// Tune the threshold without a rebuild:
//   defaults write andryushkin.EditMD EditMDTypingBudgetMs 8

let typingLog = Logger(subsystem: "andryushkin.EditMD", category: "typing")
let typingSignposter = OSSignposter(subsystem: "andryushkin.EditMD", category: "typing")

/// A keystroke costing more than this logs a breakdown. Defaults to one dropped
/// 60 fps frame (16 ms); overridable via the `EditMDTypingBudgetMs` default.
/// Read once at first access — a live `defaults write` needs an app relaunch.
let typingBudget: Duration = .milliseconds(
    typingBudgetMs(from: UserDefaults.standard.object(forKey: "EditMDTypingBudgetMs")))

/// Parses the `EditMDTypingBudgetMs` default into a millisecond budget, falling
/// back to `fallback` for a missing, non-numeric or non-positive value. Accepts
/// both an NSNumber (`defaults write … -int 8`) and a numeric string (the bare
/// `defaults write … 8` form, which stores a string) — a plain `as? Double`
/// bridges neither. Pure, so the parsing is directly testable.
func typingBudgetMs(from raw: Any?, fallback: Double = 16) -> Double {
    let parsed: Double?
    switch raw {
    case let number as NSNumber: parsed = number.doubleValue
    case let string as String:   parsed = Double(string)
    default:                     parsed = nil
    }
    guard let value = parsed, value > 0 else { return fallback }
    return value
}

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
        // defer so the interval always closes even if a future body throws or
        // returns early — the timing entry and signpost stay balanced.
        defer {
            phases.append((name, start.duration(to: clock.now)))
            typingSignposter.endInterval(name, state)
        }
        return body()
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
