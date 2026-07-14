import Foundation

/// Shared presentation title for the metadata card in Visual and Preview.
/// Source mode intentionally keeps the YAML fences and keys as written.
let frontmatterDisplayTitle = "Свойства"

// YAML frontmatter (the `---\n…\n---` metadata block at the top of a markdown
// file) plus a lightweight YAML tokenizer, shared by Visual (a read-only
// "properties" island) and Preview (a properties table + `yaml` code-block
// coloring). Source mode is intentionally left untouched.
//
// swift-markdown does not model frontmatter: the opening `---` parses as a
// thematic break and the closing `---` after the body as a *setext heading*,
// which blows the whole block up into a big heading. Both renderers detect the
// block here and render it as an Obsidian-style properties block instead.
//
// Everything in this file is a pure function — no view / controller state.

// MARK: - Frontmatter range

struct FrontmatterRange {
    /// The whole block INCLUDING both `---` fences, no trailing newline.
    let full: NSRange
    /// The YAML body between the fences (may be empty), no trailing newline.
    let body: NSRange
}

/// Detects a YAML frontmatter block: the FIRST line is exactly `---` and a
/// later line is exactly `---` or `...` (the closing fence). Returns nil when
/// there is no well-formed block — the legacy (mangled) behavior then applies.
/// This matches the universal convention (Jekyll/Hugo/Obsidian/pandoc): a `---`
/// on line 1 opens frontmatter.
func frontmatterRange(in text: String) -> FrontmatterRange? {
    let ns = text as NSString
    let length = ns.length
    guard length >= 3 else { return nil }

    // First line must be exactly "---" (allowing trailing whitespace).
    var lineStart = 0, lineEnd = 0, contentsEnd = 0
    ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                    for: NSRange(location: 0, length: 0))
    let firstLine = ns.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
    guard firstLine.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
    guard lineEnd < length else { return nil }  // nothing after the opening fence

    let bodyStart = lineEnd
    var loc = lineEnd
    while loc < length {
        var ls = 0, le = 0, ce = 0
        ns.getLineStart(&ls, end: &le, contentsEnd: &ce, for: NSRange(location: loc, length: 0))
        let trimmed = ns.substring(with: NSRange(location: ls, length: ce - ls))
            .trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == "..." {
            let full = NSRange(location: 0, length: ce)   // through closing-fence content, no trailing \n
            var bodyLen = max(0, ls - bodyStart)          // up to the start of the closing line
            // Trim the single trailing newline before the closing fence.
            while bodyLen > 0,
                  ns.character(at: bodyStart + bodyLen - 1) == 0x0A
                  || ns.character(at: bodyStart + bodyLen - 1) == 0x0D {
                bodyLen -= 1
            }
            return FrontmatterRange(full: full,
                                    body: NSRange(location: bodyStart, length: bodyLen))
        }
        if le == loc { break }
        loc = le
    }
    return nil
}

// MARK: - Properties

/// One frontmatter property, ready for the properties table / card.
struct FMProperty: Equatable {
    let key: String
    /// Display value — scalar text, or list items joined with ", ".
    let value: String
    /// Individual list items (empty for scalars) — for chip rendering.
    let items: [String]
    var isList: Bool { !items.isEmpty }
}

/// Parses the frontmatter body into ordered top-level properties. A pragmatic
/// line-based reader — not a full YAML parser — sufficient for the flat
/// `key: value`, flow-list (`[a, b]`) and block-list (`- a`) shapes real
/// frontmatter uses. Comments and blank lines are skipped.
func parseFrontmatterProperties(_ body: String) -> [FMProperty] {
    let lines = body.components(separatedBy: "\n")
    var props: [FMProperty] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        i += 1
        let indent = leadingWhitespaceCount(line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
        guard indent == 0, let colon = keyColonIndex(trimmed) else { continue }

        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        var after = String(trimmed[trimmed.index(after: colon)...])
            .trimmingCharacters(in: .whitespaces)
        // Drop a trailing `# comment` (outside quotes) so it doesn't leak into
        // the displayed value.
        if let commentIdx = trailingCommentIndex(after) {
            after = String(after[..<commentIdx]).trimmingCharacters(in: .whitespaces)
        }

        if !after.isEmpty {
            if after.hasPrefix("[") && after.hasSuffix("]") {
                let items = splitFlowList(String(after.dropFirst().dropLast()))
                props.append(FMProperty(key: key, value: items.joined(separator: ", "), items: items))
            } else {
                props.append(FMProperty(key: key, value: unquote(after), items: []))
            }
            continue
        }

        // Empty scalar: consume the following indented block (list or map).
        var items: [String] = []
        var subLines: [String] = []
        while i < lines.count {
            let next = lines[i]
            let nextTrim = next.trimmingCharacters(in: .whitespaces)
            if nextTrim.isEmpty { i += 1; continue }
            if leadingWhitespaceCount(next) == 0 { break }   // next top-level key
            i += 1
            if nextTrim == "-" {
                items.append("")
            } else if nextTrim.hasPrefix("- ") {
                items.append(unquote(String(nextTrim.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            } else {
                subLines.append(nextTrim)
            }
        }
        if !items.isEmpty {
            props.append(FMProperty(key: key, value: items.joined(separator: ", "), items: items))
        } else if !subLines.isEmpty {
            props.append(FMProperty(key: key, value: subLines.joined(separator: "; "), items: []))
        } else {
            props.append(FMProperty(key: key, value: "", items: []))
        }
    }
    return props
}

// MARK: - YAML line tokenizer (display coloring)

enum YAMLTokenKind: Equatable {
    case key, punctuation, string, number, bool, null, comment, plain
}

/// Splits one YAML line into colored segments. Concatenating the segment texts
/// reproduces the line exactly (offsets stay valid for NSTextStorage coloring).
/// Plain (unquoted, non-typed) scalars stay `.plain` so long text values aren't
/// over-colored — only quoted strings, numbers, booleans, null, keys, comments
/// and punctuation get a distinct kind.
func yamlLineSegments(_ line: String) -> [(text: String, kind: YAMLTokenKind)] {
    var segments: [(String, YAMLTokenKind)] = []

    let indentCount = leadingWhitespaceCount(line)
    if indentCount > 0 {
        segments.append((String(line.prefix(indentCount)), .plain))
    }
    var rest = String(line.dropFirst(indentCount))

    if rest.hasPrefix("#") {
        segments.append((rest, .comment))
        return segments
    }

    var trailingComment: String?
    if let cIdx = trailingCommentIndex(rest) {
        trailingComment = String(rest[cIdx...])
        rest = String(rest[..<cIdx])
    }

    appendContentSegments(rest, into: &segments)
    if let trailingComment { segments.append((trailingComment, .comment)) }
    return segments
}

private func appendContentSegments(_ content: String,
                                   into segments: inout [(String, YAMLTokenKind)]) {
    var s = content
    if s == "-" {
        segments.append(("-", .punctuation))
        return
    }
    if s.hasPrefix("- ") {
        segments.append(("- ", .punctuation))
        s = String(s.dropFirst(2))
    }
    if let colon = keyColonIndex(s) {
        segments.append((String(s[..<colon]), .key))
        segments.append((":", .punctuation))
        appendValueSegments(String(s[s.index(after: colon)...]), into: &segments)
    } else {
        appendValueSegments(s, into: &segments)
    }
}

private func appendValueSegments(_ value: String,
                                 into segments: inout [(String, YAMLTokenKind)]) {
    let leadCount = leadingWhitespaceCount(value)
    if leadCount > 0 { segments.append((String(value.prefix(leadCount)), .plain)) }
    var core = String(value.dropFirst(leadCount))
    guard !core.isEmpty else { return }

    var trailing = ""
    while let last = core.last, last == " " || last == "\t" {
        trailing = String(last) + trailing
        core.removeLast()
    }
    guard !core.isEmpty else {
        segments.append((trailing, .plain)); return
    }

    if core.hasPrefix("[") && core.hasSuffix("]") && core.count >= 2 {
        segments.append(("[", .punctuation))
        let inner = String(core.dropFirst().dropLast())
        var first = true
        for element in inner.split(separator: ",", omittingEmptySubsequences: false) {
            if !first { segments.append((",", .punctuation)) }
            first = false
            appendValueSegments(String(element), into: &segments)
        }
        segments.append(("]", .punctuation))
    } else {
        segments.append((core, classifyScalar(core)))
    }
    if !trailing.isEmpty { segments.append((trailing, .plain)) }
}

private func classifyScalar(_ s: String) -> YAMLTokenKind {
    if (s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2)
        || (s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2) { return .string }
    switch s.lowercased() {
    case "true", "false", "yes", "no", "on", "off": return .bool
    case "null", "~": return .null
    default: break
    }
    return isYAMLNumber(s) ? .number : .plain
}

// MARK: - Small helpers

private func leadingWhitespaceCount(_ s: String) -> Int {
    s.prefix(while: { $0 == " " || $0 == "\t" }).count
}

/// First `:` that separates a mapping key from its value: outside quotes and
/// followed by a space or end-of-line (so `url: http://x` splits after `url`).
private func keyColonIndex(_ s: String) -> String.Index? {
    let chars = Array(s)
    var inSingle = false, inDouble = false
    for k in 0..<chars.count {
        let c = chars[k]
        if c == "\"" && !inSingle { inDouble.toggle() }
        else if c == "'" && !inDouble { inSingle.toggle() }
        else if c == ":" && !inSingle && !inDouble {
            if k + 1 == chars.count || chars[k + 1] == " " || chars[k + 1] == "\t" {
                return s.index(s.startIndex, offsetBy: k)
            }
        }
    }
    return nil
}

/// Index of a trailing `#` comment: a `#` at line start or preceded by
/// whitespace, outside quotes.
private func trailingCommentIndex(_ s: String) -> String.Index? {
    let chars = Array(s)
    var inSingle = false, inDouble = false
    for k in 0..<chars.count {
        let c = chars[k]
        if c == "\"" && !inSingle { inDouble.toggle() }
        else if c == "'" && !inDouble { inSingle.toggle() }
        else if c == "#" && !inSingle && !inDouble {
            if k == 0 || chars[k - 1] == " " || chars[k - 1] == "\t" {
                return s.index(s.startIndex, offsetBy: k)
            }
        }
    }
    return nil
}

private func splitFlowList(_ inner: String) -> [String] {
    inner.split(separator: ",")
        .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}

private func unquote(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
        return String(s.dropFirst().dropLast())
    }
    return s
}

private func isYAMLNumber(_ s: String) -> Bool {
    var idx = s.startIndex
    if s.hasPrefix("-") { idx = s.index(after: idx) }
    guard idx < s.endIndex else { return false }
    var seenDot = false, seenDigit = false
    while idx < s.endIndex {
        let c = s[idx]
        if c == "." {
            if seenDot { return false }
            seenDot = true
        } else if c.isNumber {
            seenDigit = true
        } else {
            return false
        }
        idx = s.index(after: idx)
    }
    return seenDigit
}
