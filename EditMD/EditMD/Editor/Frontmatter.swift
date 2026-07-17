import Foundation

// YAML frontmatter (the `---\n…\n---` metadata block at the top of a markdown
// file): range detection plus a pragmatic line-based property reader, used by
// the Properties inspector, Tags sidebar and wiki completion. Source mode is
// intentionally left untouched.
//
// swift-markdown does not model frontmatter: the opening `---` parses as a
// thematic break and the closing `---` after the body as a *setext heading*,
// which blows the whole block up into a big heading. Callers detect the block
// here and treat it as properties instead.
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

/// Visual's serialization normal form for documents with frontmatter. The
/// block is not rendered in Visual (the Properties inspector owns it), so the
/// serializer output has no island carrying it — this re-attaches the verbatim
/// block exactly the way the serializer used to join the old `.raw` island
/// with the first body block (a blank line).
func composeDocumentWithFrontmatter(_ frontmatter: String?, body: String) -> String {
    guard let frontmatter, !frontmatter.isEmpty else { return body }
    guard !body.isEmpty else { return frontmatter }
    return frontmatter + "\n\n" + body
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

// MARK: - Property field icon (Preview SVG / Properties SF Symbol)

/// Shared heuristic for the decorative glyph next to a frontmatter key.
/// Used by Preview (`frontmatterIconHTML`) and the Properties inspector.
enum FrontmatterFieldIconKind: Equatable, Sendable {
    case tags
    case date
    case file
    case graph
    case number
    case text
}

func frontmatterFieldIconKind(key: String, value: String = "") -> FrontmatterFieldIconKind {
    let k = key.lowercased()
    if k == "tags" || k == "tag" || k == "aliases" { return .tags }
    if k.contains("date") || k == "created" || k == "updated" { return .date }
    if k == "pdf" || k.contains("file") || k == "doi" || k == "pmid" { return .file }
    if k.contains("graph") || k.contains("node") { return .graph }
    if k.contains("year") || k.contains("level") || k.contains("count")
        || k.hasSuffix("_n")
        || (!value.isEmpty && value.allSatisfy(\.isNumber)) {
        return .number
    }
    return .text
}

/// SF Symbol for the Properties inspector (native AppKit/SwiftUI).
func frontmatterFieldSystemImage(key: String, value: String = "") -> String {
    switch frontmatterFieldIconKind(key: key, value: value) {
    case .tags: return "tag"
    case .date: return "calendar"
    case .file: return "doc"
    case .graph: return "circle.grid.cross"
    case .number: return "number"
    case .text: return "text.alignleft"
    }
}

// MARK: - Small helpers

func leadingWhitespaceCount(_ s: String) -> Int {
    s.prefix(while: { $0 == " " || $0 == "\t" }).count
}

/// First `:` that separates a mapping key from its value: outside quotes and
/// followed by a space or end-of-line (so `url: http://x` splits after `url`).
func keyColonIndex(_ s: String) -> String.Index? {
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
func trailingCommentIndex(_ s: String) -> String.Index? {
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

func splitFlowList(_ inner: String) -> [String] {
    inner.split(separator: ",")
        .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
        .filter { !$0.isEmpty }
}

func unquote(_ s: String) -> String {
    guard s.count >= 2 else { return s }
    if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
        return String(s.dropFirst().dropLast())
    }
    return s
}

func isYAMLNumber(_ s: String) -> Bool {
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
