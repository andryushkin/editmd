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

// MARK: - Clear inline markers (Source)

/// Removes markdown inline markers from a selection, leaving block structure
/// alone. Code-span *interiors* keep their characters (so `a**b**` stays
/// `a**b**` after unwrap); outer `` ` `` / `**` / `*` / `~~` / `==` wrappers
/// are stripped. (B4)
func stripInlineMarkers(_ text: String) -> String {
    // Split into code spans and everything else. Single-backtick spans only
    // (`` multi-tick is rare in casual selection; leave multi-tick alone).
    var result = ""
    var i = text.startIndex
    while i < text.endIndex {
        if text[i] == "`" {
            // Find matching closing backtick on the same line.
            let afterOpen = text.index(after: i)
            if let close = text[afterOpen...].firstIndex(of: "`"),
               !text[afterOpen..<close].contains(where: { $0 == "\n" || $0 == "\r" }) {
                // Unwrap: emit interior only (do not strip markers inside).
                result += text[afterOpen..<close]
                i = text.index(after: close)
                continue
            }
            // Unmatched ` — keep as-is and continue.
            result.append(text[i])
            i = text.index(after: i)
            continue
        }
        // Non-code run until next ` or end.
        let runEnd = text[i...].firstIndex(of: "`") ?? text.endIndex
        result += stripNonCodeInlineMarkers(String(text[i..<runEnd]))
        i = runEnd
    }
    return result
}

/// Strip bold / italic / strike / highlight markers outside code spans.
private func stripNonCodeInlineMarkers(_ text: String) -> String {
    var s = text
    // Order: longer delimiters first so ** is not eaten as two *'s.
    let pairs = ["**", "~~", "==", "*", "_"]
    var changed = true
    while changed {
        changed = false
        for d in pairs {
            let next = stripDelimiterPairs(d, in: s)
            if next != s {
                s = next
                changed = true
            }
        }
    }
    return s
}

/// Removes all non-overlapping `delim…delim` pairs (non-greedy, single-line).
private func stripDelimiterPairs(_ delim: String, in text: String) -> String {
    guard !delim.isEmpty else { return text }
    let d = delim
    let dLen = d.count
    var out = ""
    var i = text.startIndex
    while i < text.endIndex {
        // Find next opening delimiter.
        guard let open = text[i...].range(of: d)?.lowerBound else {
            out += text[i...]
            break
        }
        out += text[i..<open]
        let afterOpen = text.index(open, offsetBy: dLen)
        guard afterOpen < text.endIndex,
              let closeRel = text[afterOpen...].range(of: d) else {
            out += text[open...]
            break
        }
        let close = closeRel.lowerBound
        let inner = text[afterOpen..<close]
        // Empty or multiline → keep markers (not valid emphasis).
        if inner.isEmpty || inner.contains(where: { $0 == "\n" || $0 == "\r" }) {
            out += text[open..<text.index(close, offsetBy: dLen)]
            i = text.index(close, offsetBy: dLen)
            continue
        }
        out += inner
        i = text.index(close, offsetBy: dLen)
        // Continue scanning after this pair (changed for outer while).
    }
    return out
}

// MARK: - Case cycle (B5)

/// Cycles selection case: UPPER → lower → Capitalized → UPPER.
/// Detection uses letter-bearing content; non-letters pass through.
func cycleCase(_ text: String) -> String {
    let letters = text.filter(\.isLetter)
    guard !letters.isEmpty else { return text }
    if text == text.uppercased() {
        return text.lowercased()
    }
    if text == text.lowercased() {
        return text.capitalized
    }
    if text == text.capitalized {
        return text.uppercased()
    }
    // Mixed → normalize to UPPER (next full cycle step).
    return text.uppercased()
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

    // Source mode often selects the visible syntax as well as its body
    // (`~~text~~`). Treat that as the same toggle-off gesture as Preview's
    // body-only selection; otherwise it becomes `~~~~text~~~~`.
    let selectedLength = (selected as NSString).length
    if selectedLength >= openLen + closeLen,
       selected.hasPrefix(open), selected.hasSuffix(close) {
        let innerRange = NSRange(location: openLen,
                                 length: selectedLength - openLen - closeLen)
        let inner = (selected as NSString).substring(with: innerRange)
        return ns.replacingCharacters(in: range, with: inner)
    }

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
    // Partial selection inside one uniformly formatted run: remove formatting
    // only from the selected fragment and preserve it on both sides.
    // Example: `~~paragraph~~`, selecting `para` → `para~~graph~~`.
    if open == close {
        var tokens: [NSRange] = []
        var search = NSRange(location: 0, length: ns.length)
        while search.length > 0 {
            let token = ns.range(of: open, options: [.literal], range: search)
            guard token.location != NSNotFound else { break }
            tokens.append(token)
            let next = NSMaxRange(token)
            search = NSRange(location: next, length: ns.length - next)
        }
        let before = tokens.filter { NSMaxRange($0) <= range.location }
        if before.count % 2 == 1, let opener = before.last,
           let closer = tokens.first(where: { $0.location >= NSMaxRange(range) }) {
            let bodyStart = NSMaxRange(opener)
            let bodyEnd = closer.location
            if range.location >= bodyStart, NSMaxRange(range) <= bodyEnd {
                let left = ns.substring(with: NSRange(location: bodyStart,
                                                       length: range.location - bodyStart))
                let right = ns.substring(with: NSRange(location: NSMaxRange(range),
                                                        length: bodyEnd - NSMaxRange(range)))
                let replacement = (left.isEmpty ? "" : open + left + close)
                    + selected
                    + (right.isEmpty ? "" : open + right + close)
                let full = NSRange(location: opener.location,
                                   length: NSMaxRange(closer) - opener.location)
                return ns.replacingCharacters(in: full, with: replacement)
            }
        }
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
