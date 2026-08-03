import Foundation
import os

// Per-keystroke performance instrument for Source and Visual. Unified logging
// (subsystem `andryushkin.EditMD`) + os_signpost intervals — not NSLog or a HUD.
// Always on: signposts are near-free until an Instruments trace records them;
// the `.warning` fires only when a keystroke blows the budget.
//   log show --predicate 'subsystem == "andryushkin.EditMD" && category == "typing"' --last 5m
// Tune without a rebuild: defaults write andryushkin.EditMD EditMDTypingBudgetMs 8

let typingLog = Logger(subsystem: "andryushkin.EditMD", category: "typing")
let typingSignposter = OSSignposter(subsystem: "andryushkin.EditMD", category: "typing")

/// A keystroke costing more than this logs a breakdown. Defaults to one dropped
/// 60 fps frame (16 ms); overridable via the `EditMDTypingBudgetMs` default.
/// Read once at first access — a live `defaults write` needs an app relaunch.
let typingBudget: Duration = .milliseconds(
    typingBudgetMs(from: UserDefaults.standard.object(forKey: "EditMDTypingBudgetMs")))

/// Parses `EditMDTypingBudgetMs`; `fallback` for missing/non-numeric/≤0.
/// Accepts NSNumber (`-int 8`) and numeric string (bare `defaults write` stores
/// a string) — a plain `as? Double` bridges neither. Pure, testable.
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
        // defer: interval always closes even if a future body throws/returns
        // early — timing entry and signpost stay balanced.
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

/// Heaviest phases as `name=1.2ms`, largest first (top `limit`). Pure, testable.
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
