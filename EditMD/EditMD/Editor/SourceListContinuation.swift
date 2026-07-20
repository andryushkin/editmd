import Foundation

// Auto-continuation of Markdown lists / checkboxes when Return is pressed in
// Source mode (also the Source pane of the split). Pure functions here decide
// what a Return keystroke should do given the caret's line; SourceNSTextView
// applies the edit. Kept AppKit-free so it is directly unit-testable.

/// What pressing Return on a list / checkbox line should do.
enum ListReturnAction: Equatable {
    /// Continue the list: insert a newline followed by this fresh marker at the
    /// caret (e.g. `"- "`, `"  1. "`, `"- [ ] "`).
    case insertMarker(String)
    /// The item was empty (marker only) — end the list by clearing the marker.
    /// The range is relative to the start of the caret's line.
    case clearMarker(NSRange)
}

// Ordered so that a checklist (a bullet carrying a `[ ]` box) is recognised
// before the plain-bullet pattern it is a superset of.
private let listReturnPatterns: [(pattern: String, kind: ListMarkerKind)] = [
    ("^([ \\t]*)([-*+])[ \\t]+\\[[ xX]\\][ \\t]+", .checklist),
    ("^([ \\t]*)([-*+])[ \\t]+", .bullet),
    ("^([ \\t]*)(\\d+)([.)])[ \\t]+", .ordered),
]

private enum ListMarkerKind { case bullet, checklist, ordered }

private func firstListMatch(_ pattern: String, in line: NSString) -> NSTextCheckingResult? {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.firstMatch(in: line as String,
                            range: NSRange(location: 0, length: line.length))
}

/// Given the text of the line the caret sits on (no trailing newline) and the
/// caret's column within it, returns the auto-continuation action for Return,
/// or nil when the line is not a list item (caller falls back to a plain
/// newline). The caret must be at or past the marker prefix; a caret inside the
/// indentation or marker yields nil so structural edits there behave normally.
func listReturnAction(line: String, caretColumn: Int) -> ListReturnAction? {
    let ns = line as NSString
    for (pattern, kind) in listReturnPatterns {
        guard let match = firstListMatch(pattern, in: ns) else { continue }
        let prefixLength = match.range.length
        guard caretColumn >= prefixLength else { return nil }
        let indent = ns.substring(with: match.range(at: 1))
        let content = ns.substring(from: prefixLength)
        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item → terminate the list, clearing the whole marker prefix.
            return .clearMarker(NSRange(location: 0, length: prefixLength))
        }
        switch kind {
        case .bullet:
            let bullet = ns.substring(with: match.range(at: 2))
            return .insertMarker("\(indent)\(bullet) ")
        case .checklist:
            // A continued checklist item always starts unchecked.
            let bullet = ns.substring(with: match.range(at: 2))
            return .insertMarker("\(indent)\(bullet) [ ] ")
        case .ordered:
            let number = Int(ns.substring(with: match.range(at: 2))) ?? 0
            let delimiter = ns.substring(with: match.range(at: 3))
            return .insertMarker("\(indent)\(number + 1)\(delimiter) ")
        }
    }
    return nil
}

/// An empty GFM table row with `columns` blank cells, e.g. 3 → `"|  |  |  |"`.
/// Unaligned on purpose — the Source highlighter re-pads pipes via `.kern`.
func emptyPipeRow(columns: Int) -> String {
    guard columns > 0 else { return "|  |" }
    return "|" + String(repeating: "  |", count: columns)
}

/// True when a pipe-table row line carries no cell content (only pipes and
/// whitespace) — the signal to end the table on Return.
func pipeRowIsEmpty(_ line: String) -> Bool {
    guard line.contains("|") else { return false }
    return line.allSatisfy { $0 == "|" || $0 == " " || $0 == "\t" }
}
