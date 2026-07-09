import Foundation

// Pure helpers — no AppKit dependency, easy to unit-test.

/// Returns (words, chars) for the given string.
func wordAndCharCount(in text: String) -> (words: Int, chars: Int) {
    let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    return (words, text.count)
}

/// Wraps `selection` in `marker…marker`, returning the new full string and
/// the new selection range (covers the wrapped text; if original was empty,
/// positions cursor between the markers).
func applyWrap(marker: String, to text: String, selection: NSRange) -> (newText: String, newSelection: NSRange) {
    let nsText = text as NSString
    let selected = nsText.substring(with: selection)
    let wrapped = marker + selected + marker
    let newText = nsText.replacingCharacters(in: selection, with: wrapped)
    let newSelection: NSRange = selection.length == 0
        ? NSRange(location: selection.location + marker.count, length: 0)
        : NSRange(location: selection.location, length: wrapped.count)
    return (newText, newSelection)
}

// MARK: - Task checkbox toggle (Preview click-through)

/// Toggles the `index`-th task-list checkbox (`[ ]` ↔ `[x]`, document order)
/// in the markdown source, or nil when no such checkbox exists. The index
/// matches the DOM order of `li.task` inputs in the rendered preview — both
/// sides enumerate the document tree in order.
func toggleTaskListItem(in markdown: String, index: Int) -> String? {
    guard index >= 0 else { return nil }
    let markers = collectSpans(markdown)
        .compactMap { span -> (range: NSRange, done: Bool)? in
            guard case .taskListMarker(let done) = span.kind else { return nil }
            return (span.range, done)
        }
        .sorted { $0.range.location < $1.range.location }
    guard index < markers.count else { return nil }
    let marker = markers[index]
    let nsText = markdown as NSString
    guard NSMaxRange(marker.range) <= nsText.length else { return nil }
    return nsText.replacingCharacters(in: marker.range,
                                      with: marker.done ? "[ ]" : "[x]")
}

// MARK: - Line-level transforms (Source mode Format menu)

/// A markdown transform applied to whole lines.
enum BlockTransform: Equatable {
    case heading(Int)   // 1...6
    case body           // strip heading / list / quote → plain
    case bullet
    case checklist
    case ordered
    case quote
}

private let headingPrefixPattern = "^(#{1,6})\\s+"
private let checklistPrefixPattern = "^(\\s*)-\\s+\\[[ xX]\\]\\s+"
private let bulletPrefixPattern = "^(\\s*)[-*+]\\s+"
private let orderedPrefixPattern = "^(\\s*)\\d+[.)]\\s+"

private func firstMatch(_ pattern: String, in line: String) -> NSTextCheckingResult? {
    let regex = try! NSRegularExpression(pattern: pattern)
    return regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
}

/// Removes the matched prefix; list patterns capture the leading indent in
/// group 1 and keep it, the heading pattern captures the `#`s and drops them.
private func stripPrefix(_ pattern: String, from line: String) -> String? {
    guard let match = firstMatch(pattern, in: line) else { return nil }
    let nsLine = line as NSString
    let keep = pattern == headingPrefixPattern
        ? "" : nsLine.substring(with: match.range(at: 1))
    return nsLine.replacingCharacters(in: match.range, with: keep)
}

/// Applies `transform` to every line of `lines` (the text of the paragraphs
/// the selection touches, trailing newlines preserved) and returns the
/// replacement text. Toggle semantics: if every non-empty line already has
/// the transform, it is removed instead.
func transformLines(_ transform: BlockTransform, lines: String) -> String {
    var parts = lines.components(separatedBy: "\n")
    // A trailing "\n" yields a final empty component that is not a line.
    let hadTrailingNewline = parts.last == ""
    if hadTrailingNewline { parts.removeLast() }
    let content = parts.enumerated().filter { !$0.element.isEmpty }

    func alreadyApplied(_ line: String) -> Bool {
        switch transform {
        case .heading(let level):
            guard let match = firstMatch(headingPrefixPattern, in: line) else { return false }
            return match.range(at: 1).length == level
        case .body:
            // "Applied" means already plain — never "remove", always strip structure.
            return false
        case .bullet:
            // Checklist is a bullet form; treat pure `- ` (not `- [ ]`) as bullet.
            if firstMatch(checklistPrefixPattern, in: line) != nil { return false }
            return firstMatch(bulletPrefixPattern, in: line) != nil
        case .checklist:
            return firstMatch(checklistPrefixPattern, in: line) != nil
        case .ordered: return firstMatch(orderedPrefixPattern, in: line) != nil
        case .quote:   return line.hasPrefix("> ") || line == ">"
        }
    }
    let removing = transform != .body
        && !content.isEmpty
        && content.allSatisfy { alreadyApplied($0.element) }

    func stripAllStructure(_ line: String) -> String {
        var s = line
        if s.hasPrefix("> ") { s = String(s.dropFirst(2)) }
        else if s == ">" { s = "" }
        s = stripPrefix(headingPrefixPattern, from: s)
            ?? stripPrefix(checklistPrefixPattern, from: s)
            ?? stripPrefix(orderedPrefixPattern, from: s)
            ?? stripPrefix(bulletPrefixPattern, from: s)
            ?? s
        return s
    }

    var ordinal = 0
    let result = parts.map { line -> String in
        if line.isEmpty { return transform == .quote && !removing ? ">" : line }
        switch transform {
        case .heading(let level):
            let stripped = stripPrefix(headingPrefixPattern, from: line) ?? line
            return removing ? stripped : String(repeating: "#", count: level) + " " + stripped
        case .body:
            return stripAllStructure(line)
        case .bullet:
            let stripped = stripPrefix(checklistPrefixPattern, from: line)
                ?? stripPrefix(bulletPrefixPattern, from: line)
                ?? stripPrefix(orderedPrefixPattern, from: line) ?? line
            return removing ? stripped : "- " + stripped
        case .checklist:
            let stripped = stripPrefix(checklistPrefixPattern, from: line)
                ?? stripPrefix(bulletPrefixPattern, from: line)
                ?? stripPrefix(orderedPrefixPattern, from: line) ?? line
            return removing ? stripped : "- [ ] " + stripped
        case .ordered:
            let stripped = stripPrefix(orderedPrefixPattern, from: line)
                ?? stripPrefix(checklistPrefixPattern, from: line)
                ?? stripPrefix(bulletPrefixPattern, from: line) ?? line
            if removing { return stripped }
            ordinal += 1
            return "\(ordinal). " + stripped
        case .quote:
            if removing {
                if line == ">" { return "" }
                return line.hasPrefix("> ") ? String(line.dropFirst(2)) : line
            }
            return "> " + line
        }
    }
    return result.joined(separator: "\n") + (hadTrailingNewline ? "\n" : "")
}

/// Wraps `lines` in ``` fences. The input keeps its trailing newline shape;
/// the fenced replacement always ends the closing fence with the same shape.
func fenceLines(_ lines: String) -> String {
    var body = lines
    let hadTrailingNewline = body.hasSuffix("\n")
    if hadTrailingNewline { body.removeLast() }
    return "```\n" + body + "\n```" + (hadTrailingNewline ? "\n" : "")
}

// MARK: - Preview selection wrap (highlight / strikethrough)

/// Toggles `open…close` around an exact UTF-16 `range` in `markdown`.
/// If the range is already wrapped with those markers, removes them; otherwise
/// inserts the markers. Used by the Preview toolbar once the page reports
/// `data-md-lo`/`data-md-hi` offsets for the selection.
func toggleWrapAtRange(in markdown: String,
                       range: NSRange,
                       open: String,
                       close: String) -> String? {
    guard range.length > 0, !open.isEmpty, !close.isEmpty else { return nil }
    let ns = markdown as NSString
    guard range.location >= 0, NSMaxRange(range) <= ns.length else { return nil }
    let openLen = (open as NSString).length
    let closeLen = (close as NSString).length
    let selected = ns.substring(with: range)

    let beforeStart = range.location - openLen
    let afterStart = NSMaxRange(range)
    let hasOpen = beforeStart >= 0
        && ns.substring(with: NSRange(location: beforeStart, length: openLen)) == open
    let hasClose = afterStart + closeLen <= ns.length
        && ns.substring(with: NSRange(location: afterStart, length: closeLen)) == close

    if hasOpen && hasClose {
        let full = NSRange(location: beforeStart,
                           length: openLen + range.length + closeLen)
        return ns.replacingCharacters(in: full, with: selected)
    }
    return ns.replacingCharacters(in: range, with: open + selected + close)
}

// MARK: - ==highlight== (Obsidian-style; Preview render)

/// One `==inner==` span in a text run. `range` covers the full markers;
/// `inner` is the display text between them.
struct HighlightMarkMatch: Equatable {
    let range: NSRange
    let inner: String
}

/// Scans single-line Obsidian-style highlights (`==text==`). Empty inners and
/// multiline spans are ignored. Non-overlapping, left-to-right.
func scanHighlightMarks(in text: String) -> [HighlightMarkMatch] {
    let ns = text as NSString
    let len = ns.length
    guard len >= 4 else { return [] }
    var matches: [HighlightMarkMatch] = []
    var i = 0
    while i < len - 3 {
        let c0 = ns.character(at: i)
        let c1 = ns.character(at: i + 1)
        if c0 == 0x3D && c1 == 0x3D { // ==
            var j = i + 2
            var found: NSRange?
            while j + 1 < len {
                let cj = ns.character(at: j)
                if cj == 0x0A || cj == 0x0D { break } // single-line only
                if cj == 0x3D && ns.character(at: j + 1) == 0x3D {
                    let innerLen = j - (i + 2)
                    if innerLen > 0 {
                        found = NSRange(location: i, length: (j + 2) - i)
                    }
                    break
                }
                j += 1
            }
            if let found {
                let inner = ns.substring(with: NSRange(location: found.location + 2,
                                                       length: found.length - 4))
                matches.append(HighlightMarkMatch(range: found, inner: inner))
                i = NSMaxRange(found)
                continue
            }
        }
        i += 1
    }
    return matches
}
