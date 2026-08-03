import Foundation

// MARK: - Property field typing (form)

/// Control kind for the Properties inspector. `complex` is always read-only
/// (nested maps, multiline, anchors, unparseable shapes).
enum PropertyFieldKind: Equatable, Sendable {
    case string
    case number
    case bool
    case date
    case tags
    case aliases
    case list
    case complex
}

/// One top-level frontmatter field for the Properties panel, including whether
/// it can be edited line-by-line without a full YAML re-serialize.
struct PropertyField: Equatable, Sendable {
    let key: String
    let kind: PropertyFieldKind
    /// Scalar display text, or list items joined with ", ".
    let displayValue: String
    let items: [String]
    /// False for complex / uneditable shapes (Source only).
    let isEditable: Bool
    /// UTF-16 location of the field's first content line in the full document
    /// (for "Open in Source"). Nil when there is no frontmatter body.
    let utf16Offset: Int?
}

// MARK: - Public edit API

/// Replaces the scalar value of a simple top-level field. Preserves key order,
/// indentation, blank lines, full-line comments, trailing comments on the
/// edited line, CRLF, and unknown neighbouring fields. Returns nil when the
/// field is missing, duplicated, complex, a list, or cannot be written safely.
func replaceFrontmatterScalar(document: String, key: String, newValue: String) -> String? {
    guard !key.isEmpty, isValidFrontmatterKey(key) else { return nil }
    guard let encoded = encodeYAMLScalar(newValue) else { return nil }
    guard let loc = locateFrontmatterField(in: document, key: key),
          loc.isEditableScalar else { return nil }
    return replaceFieldLines(in: document, location: loc, newLines: [
        rebuiltScalarLine(original: loc.lines[0].raw, key: key, encodedValue: encoded)
    ])
}

/// Inserts a scalar field at the end of frontmatter, or creates a frontmatter
/// block when none exists. If the key already exists (any shape), returns nil.
/// Pass `plainLiteral: true` for bare bool/number/date values.
func insertFrontmatterScalar(document: String, key: String, value: String,
                             plainLiteral: Bool = false) -> String? {
    guard !key.isEmpty, isValidFrontmatterKey(key) else { return nil }
    guard let encoded = encodeYAMLScalar(value, plainLiteral: plainLiteral)
    else { return nil }
    if locateFrontmatterField(in: document, key: key) != nil { return nil }
    let line = "\(key): \(encoded)"
    return insertFrontmatterLines(in: document, lines: [line])
}

/// Removes a simple top-level field (scalar, flow list, or block list).
/// Complex fields and duplicates refuse. Removing the last field leaves an
/// empty frontmatter block (`---\n---` / with original line endings).
func removeFrontmatterField(document: String, key: String) -> String? {
    guard !key.isEmpty else { return nil }
    guard let loc = locateFrontmatterField(in: document, key: key),
          loc.isEditable else { return nil }
    return replaceFieldLines(in: document, location: loc, newLines: [])
}

/// Rebuilds exactly the lines of a list field, preserving flow vs block style.
/// An existing simple scalar (including empty `key:`) is upgraded to a flow list.
/// Missing key → nil (use `insertFrontmatterList`). Complex / duplicate → nil.
func replaceFrontmatterList(document: String, key: String, items: [String]) -> String? {
    guard !key.isEmpty, isValidFrontmatterKey(key) else { return nil }
    guard let encodedItems = encodeYAMLListItems(items) else { return nil }
    guard let loc = locateFrontmatterField(in: document, key: key) else { return nil }
    let newLines: [String]
    switch loc.shape {
    case .flowList:
        newLines = [rebuiltFlowListLine(original: loc.lines[0].raw, key: key,
                                        items: encodedItems)]
    case .blockList:
        newLines = rebuiltBlockListLines(key: key, items: encodedItems,
                                         template: loc.lines)
    case .scalar:
        // Upgrade scalar / empty → flow list, preserving trailing comment on the key line.
        newLines = [rebuiltFlowListLine(original: loc.lines[0].raw, key: key,
                                        items: encodedItems)]
    case .complex:
        return nil
    }
    return replaceFieldLines(in: document, location: loc, newLines: newLines)
}

/// Inserts a flow-list field at the end of frontmatter (or creates frontmatter).
/// Fails if the key already exists.
func insertFrontmatterList(document: String, key: String, items: [String]) -> String? {
    guard !key.isEmpty, isValidFrontmatterKey(key) else { return nil }
    guard let encodedItems = encodeYAMLListItems(items) else { return nil }
    if locateFrontmatterField(in: document, key: key) != nil { return nil }
    let joined = encodedItems.joined(separator: ", ")
    let line = "\(key): [\(joined)]"
    return insertFrontmatterLines(in: document, lines: [line])
}

// MARK: - Classification

/// Ordered top-level fields with editability and kind heuristics for the form.
func classifyFrontmatterFields(in document: String) -> [PropertyField] {
    guard let fm = frontmatterRange(in: document) else { return [] }
    let body = (document as NSString).substring(with: fm.body)
    guard !body.isEmpty else { return [] }

    let lines = frontmatterBodyLines(body, bodyUTF16Start: fm.body.location)
    var fields: [PropertyField] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.contentTrimmed
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            i += 1
            continue
        }
        guard line.indent == 0, let colon = keyColonIndex(trimmed) else {
            i += 1
            continue
        }
        let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard let loc = locateFieldStarting(at: i, key: key, lines: lines) else {
            i += 1
            continue
        }
        fields.append(makePropertyField(key: key, location: loc))
        i = loc.endLineIndex
    }
    return fields
}

/// UTF-16 offset of the first line of a field (for Open in Source), if found.
func frontmatterFieldUTF16Offset(in document: String, key: String) -> Int? {
    locateFrontmatterField(in: document, key: key)?.lines.first?.utf16Start
}

// MARK: - YAML scalar encoding

/// Encodes a scalar for a single YAML line. Quotes when the value contains
/// `: `, `#`, leading/trailing whitespace, quotes, or YAML-special tokens.
/// Pass `plainLiteral: true` for bool/number controls so `true` / `42` stay bare.
/// Returns nil when the value cannot be expressed on one line (newlines).
func encodeYAMLScalar(_ value: String, plainLiteral: Bool = false) -> String? {
    if value.contains("\n") || value.contains("\r") { return nil }
    if plainLiteral {
        // Still refuse values that would break the line structure.
        if value.contains("#") || value.contains(": ") { return nil }
        return value
    }
    if needsYAMLQuotes(value) {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
    return value
}

/// Convenience for bool/number form commits.
func replaceFrontmatterPlainScalar(document: String, key: String,
                                   newValue: String) -> String? {
    guard !key.isEmpty, isValidFrontmatterKey(key) else { return nil }
    guard let encoded = encodeYAMLScalar(newValue, plainLiteral: true) else { return nil }
    guard let loc = locateFrontmatterField(in: document, key: key),
          loc.isEditableScalar else { return nil }
    return replaceFieldLines(in: document, location: loc, newLines: [
        rebuiltScalarLine(original: loc.lines[0].raw, key: key, encodedValue: encoded)
    ])
}

// MARK: - Internals: location

private enum FieldShape: Equatable {
    case scalar
    case flowList
    case blockList
    case complex
}

private struct BodyLine {
    /// Full raw line without trailing newline characters.
    let raw: String
    /// UTF-16 start of this line in the full document.
    let utf16Start: Int
    /// Newline sequence that followed this line in the body (`"\n"`, `"\r\n"`,
    /// or `""` for the last line when body has no trailing newline).
    let newline: String
    var indent: Int { leadingWhitespaceCount(raw) }
    var contentTrimmed: String {
        raw.trimmingCharacters(in: .whitespaces)
    }
}

private struct FieldLocation {
    let key: String
    let shape: FieldShape
    /// Inclusive start / exclusive end among `bodyLines` indices for the field.
    let startLineIndex: Int
    let endLineIndex: Int
    let lines: [BodyLine]
    /// Absolute UTF-16 range covering the field lines + their intervening
    /// newlines (and the trailing newline after the last field line when more
    /// body content follows — used only for whole-field replacement).
    let utf16Range: NSRange
    /// Whether a trailing newline after the field was included in `utf16Range`
    /// (true when there is more body after the field).
    let consumesTrailingNewline: Bool

    var isEditableScalar: Bool { shape == .scalar }
    var isEditableList: Bool { shape == .flowList || shape == .blockList }
    var isEditable: Bool { isEditableScalar || isEditableList }
}

private func locateFrontmatterField(in document: String, key: String) -> FieldLocation? {
    guard let fm = frontmatterRange(in: document) else { return nil }
    let body = (document as NSString).substring(with: fm.body)
    let lines = frontmatterBodyLines(body, bodyUTF16Start: fm.body.location)
    var found: FieldLocation?
    var i = 0
    while i < lines.count {
        let line = lines[i]
        let trimmed = line.contentTrimmed
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            i += 1
            continue
        }
        guard line.indent == 0, let colon = keyColonIndex(trimmed) else {
            i += 1
            continue
        }
        let lineKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        guard lineKey == key else {
            // Skip over this field's extent so we don't mis-parse nested lines.
            if let skip = locateFieldStarting(at: i, key: lineKey, lines: lines) {
                i = skip.endLineIndex
            } else {
                i += 1
            }
            continue
        }
        if found != nil {
            // Duplicate top-level key — refuse any edit.
            return nil
        }
        guard let loc = locateFieldStarting(at: i, key: key, lines: lines) else {
            return nil
        }
        found = loc
        i = loc.endLineIndex
    }
    return found
}

private func locateFieldStarting(at start: Int, key: String,
                                 lines: [BodyLine]) -> FieldLocation? {
    guard start < lines.count else { return nil }
    let head = lines[start]
    let trimmed = head.contentTrimmed
    guard head.indent == 0, let colon = keyColonIndex(trimmed) else { return nil }
    let lineKey = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
    guard lineKey == key else { return nil }

    var after = String(trimmed[trimmed.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
    // Strip trailing comment for shape detection only.
    if let cIdx = trailingCommentIndex(after) {
        after = String(after[..<cIdx]).trimmingCharacters(in: .whitespaces)
    }

    // Inline value present.
    if !after.isEmpty {
        if after.hasPrefix("[") {
            // Flow list must be closed on the same line for safe edit.
            if after.hasSuffix("]") {
                return makeLocation(key: key, shape: .flowList,
                                    start: start, end: start + 1, lines: lines)
            }
            return makeLocation(key: key, shape: .complex,
                                start: start, end: start + 1, lines: lines)
        }
        // Anchors / aliases / multiline indicators → complex.
        if after.hasPrefix("&") || after.hasPrefix("*")
            || after.hasPrefix("|") || after.hasPrefix(">") {
            return makeLocation(key: key, shape: .complex,
                                start: start, end: start + 1, lines: lines)
        }
        return makeLocation(key: key, shape: .scalar,
                            start: start, end: start + 1, lines: lines)
    }

    // Empty after colon: consume indented block.
    var j = start + 1
    var sawListItem = false
    var sawMapChild = false
    while j < lines.count {
        let next = lines[j]
        let nextTrim = next.contentTrimmed
        if nextTrim.isEmpty {
            // Blank lines inside a block belong to the field only if more
            // indented content follows; peek ahead.
            var k = j + 1
            while k < lines.count, lines[k].contentTrimmed.isEmpty { k += 1 }
            if k < lines.count, lines[k].indent > 0 {
                j = k
                continue
            }
            break
        }
        if next.indent == 0 { break }
        if nextTrim.hasPrefix("#") {
            j += 1
            continue
        }
        if nextTrim == "-" || nextTrim.hasPrefix("- ") {
            sawListItem = true
            j += 1
            continue
        }
        // Nested mapping under the key.
        if keyColonIndex(nextTrim) != nil {
            sawMapChild = true
            j += 1
            continue
        }
        // Unknown indented content.
        sawMapChild = true
        j += 1
    }

    let shape: FieldShape
    if sawListItem && !sawMapChild {
        shape = .blockList
    } else if sawMapChild || sawListItem {
        shape = .complex
    } else {
        // Empty scalar (`key:` with nothing under it).
        shape = .scalar
    }
    return makeLocation(key: key, shape: shape, start: start, end: j, lines: lines)
}

private func makeLocation(key: String, shape: FieldShape,
                          start: Int, end: Int,
                          lines: [BodyLine]) -> FieldLocation {
    let fieldLines = Array(lines[start..<end])
    let first = fieldLines[0]
    let last = fieldLines[fieldLines.count - 1]
    // Range includes the newline after the last field line when more body
    // follows (removal must not leave a double blank or glue lines); when the
    // field is last, never consume a newline that isn't there.
    let endUTF16: Int
    let consumesTrailing: Bool
    if end < lines.count {
        endUTF16 = lines[end].utf16Start
        consumesTrailing = true
    } else {
        endUTF16 = last.utf16Start + (last.raw as NSString).length
        consumesTrailing = false
    }
    let range = NSRange(location: first.utf16Start,
                        length: max(0, endUTF16 - first.utf16Start))
    return FieldLocation(key: key, shape: shape,
                         startLineIndex: start, endLineIndex: end,
                         lines: fieldLines, utf16Range: range,
                         consumesTrailingNewline: consumesTrailing)
}

// MARK: - Internals: body lines

/// Splits a frontmatter body into lines with absolute UTF-16 starts and the
/// exact newline that followed each line (preserves CRLF documents).
private func frontmatterBodyLines(_ body: String, bodyUTF16Start: Int) -> [BodyLine] {
    let ns = body as NSString
    var result: [BodyLine] = []
    var loc = 0
    let length = ns.length
    while loc < length {
        var lineEnd = loc
        var newline = ""
        while lineEnd < length {
            let ch = ns.character(at: lineEnd)
            if ch == 0x0A { // \n
                newline = "\n"
                break
            }
            if ch == 0x0D { // \r
                if lineEnd + 1 < length, ns.character(at: lineEnd + 1) == 0x0A {
                    newline = "\r\n"
                } else {
                    newline = "\r"
                }
                break
            }
            lineEnd += 1
        }
        let raw = ns.substring(with: NSRange(location: loc, length: lineEnd - loc))
        result.append(BodyLine(raw: raw,
                               utf16Start: bodyUTF16Start + loc,
                               newline: newline))
        if newline.isEmpty {
            break
        }
        loc = lineEnd + (newline as NSString).length
    }
    return result
}

// MARK: - Internals: rebuild / replace

/// Splits a key-line into leading indent, optional trailing comment (including
/// the whitespace that preceded `#`), discarding the old value.
private func splitKeyLineChrome(_ original: String) -> (leading: String, comment: String) {
    let leading = String(original.prefix { $0 == " " || $0 == "\t" })
    let content = String(original.dropFirst(leading.count))
    guard let cIdx = trailingCommentIndex(content) else {
        return (leading, "")
    }
    // Include whitespace between value and `#` so `  # note` stays `  # note`.
    var commentStart = cIdx
    while commentStart > content.startIndex {
        let prev = content.index(before: commentStart)
        if content[prev] == " " || content[prev] == "\t" {
            commentStart = prev
        } else {
            break
        }
    }
    return (leading, String(content[commentStart...]))
}

private func rebuiltScalarLine(original: String, key: String, encodedValue: String) -> String {
    let chrome = splitKeyLineChrome(original)
    return "\(chrome.leading)\(key): \(encodedValue)\(chrome.comment)"
}

private func rebuiltFlowListLine(original: String, key: String,
                                 items: [String]) -> String {
    let chrome = splitKeyLineChrome(original)
    let joined = items.joined(separator: ", ")
    return "\(chrome.leading)\(key): [\(joined)]\(chrome.comment)"
}

private func rebuiltBlockListLines(key: String, items: [String],
                                   template: [BodyLine]) -> [String] {
    // Preserve key line as `key:` and item indent from the first list item.
    let keyLine = template[0]
    let keyLeading = String(keyLine.raw.prefix { $0 == " " || $0 == "\t" })
    var result = ["\(keyLeading)\(key):"]
    let itemIndent: String = {
        if let item = template.dropFirst().first(where: {
            let t = $0.contentTrimmed
            return t == "-" || t.hasPrefix("- ")
        }) {
            return String(item.raw.prefix { $0 == " " || $0 == "\t" })
        }
        return keyLeading + "  "
    }()
    if items.isEmpty {
        // Empty block list: just `key:`.
        return result
    }
    for item in items {
        result.append("\(itemIndent)- \(item)")
    }
    return result
}

private func replaceFieldLines(in document: String, location: FieldLocation,
                               newLines: [String]) -> String? {
    let ns = document as NSString
    guard NSMaxRange(location.utf16Range) <= ns.length else { return nil }

    let nl = location.lines.first(where: { !$0.newline.isEmpty })?.newline
        ?? detectDocumentNewline(document)

    let replacement: String
    if newLines.isEmpty {
        replacement = ""
    } else if location.consumesTrailingNewline {
        replacement = newLines.joined(separator: nl) + nl
    } else {
        replacement = newLines.joined(separator: nl)
    }
    var result = ns.replacingCharacters(in: location.utf16Range, with: replacement)

    // Deleting the last field leaves the separator newline before the closing
    // fence (`---\n\n---`); collapse a whitespace-only body to truly empty.
    if newLines.isEmpty {
        result = collapseWhitespaceOnlyFrontmatterBody(result)
    }
    return result
}

/// If frontmatter body is only whitespace/newlines, replace it with empty so
/// the block is the canonical `---\n---`.
private func collapseWhitespaceOnlyFrontmatterBody(_ document: String) -> String {
    guard let fm = frontmatterRange(in: document) else { return document }
    let ns = document as NSString
    // The span from after the opening fence to the closing fence line may hold
    // whitespace trimmed out of `fm.body`; drop it when whitespace-only.
    let openEnd = fm.body.location
    var lineStart = 0, lineEnd = 0, contentsEnd = 0
    var loc = openEnd
    var closingLineStart = openEnd
    while loc < ns.length {
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: loc, length: 0))
        let trimmed = ns.substring(with: NSRange(location: lineStart,
                                                 length: contentsEnd - lineStart))
            .trimmingCharacters(in: .whitespaces)
        if trimmed == "---" || trimmed == "..." {
            closingLineStart = lineStart
            break
        }
        if lineEnd == loc { break }
        loc = lineEnd
    }
    guard closingLineStart > openEnd else { return document }
    let gap = NSRange(location: openEnd, length: closingLineStart - openEnd)
    let gapText = ns.substring(with: gap)
    guard gapText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return document
    }
    return ns.replacingCharacters(in: gap, with: "")
}

private func insertFrontmatterLines(in document: String, lines: [String]) -> String? {
    let nl = detectDocumentNewline(document)
    let payload = lines.joined(separator: nl)
    if let fm = frontmatterRange(in: document) {
        let ns = document as NSString
        let body = ns.substring(with: fm.body)
        if body.isEmpty {
            // `---\n---` — body sits at the start of the closing fence line.
            // Write payload + newline so the closing `---` stays on its own line.
            return ns.replacingCharacters(in: fm.body, with: payload + nl)
        }
        // Body range has trailing newlines trimmed out (see frontmatterRange),
        // so always insert a separator newline before the new field lines.
        let insertAt = NSRange(location: NSMaxRange(fm.body), length: 0)
        return ns.replacingCharacters(in: insertAt, with: nl + payload)
    }

    // No frontmatter — create a new block at the start.
    let prefix: String
    if document.isEmpty {
        prefix = "---\(nl)\(payload)\(nl)---\(nl)"
        return prefix
    }
    // Preserve a blank line after frontmatter when the document starts with content.
    let spacer = document.hasPrefix("\n") || document.hasPrefix("\r") ? "" : nl
    return "---\(nl)\(payload)\(nl)---\(nl)\(spacer)\(document)"
}

private func detectDocumentNewline(_ document: String) -> String {
    if document.contains("\r\n") { return "\r\n" }
    if document.contains("\r") { return "\r" }
    return "\n"
}

// MARK: - Internals: classification helpers

private func makePropertyField(key: String, location: FieldLocation) -> PropertyField {
    let kind: PropertyFieldKind
    let display: String
    let items: [String]
    let editable: Bool

    switch location.shape {
    case .complex:
        kind = .complex
        display = complexDisplay(location: location)
        items = []
        editable = false
    case .flowList, .blockList:
        items = listItems(from: location)
        display = items.joined(separator: ", ")
        let lower = key.lowercased()
        if lower == "tags" {
            kind = .tags
        } else if lower == "aliases" {
            kind = .aliases
        } else {
            kind = .list
        }
        editable = true
    case .scalar:
        items = []
        let rawValue = scalarRawValue(from: location.lines[0])
        display = unquote(rawValue)
        let lower = key.lowercased()
        if lower == "tags" {
            kind = .tags
            editable = true
        } else if lower == "aliases" {
            kind = .aliases
            editable = true
        } else if isYAMLBool(rawValue) {
            kind = .bool
            editable = true
        } else if isYAMLDate(display) {
            kind = .date
            editable = true
        } else if isYAMLNumber(rawValue) {
            kind = .number
            editable = true
        } else {
            kind = .string
            editable = true
        }
    }

    return PropertyField(key: key, kind: kind, displayValue: display, items: items,
                         isEditable: editable, utf16Offset: location.lines.first?.utf16Start)
}

private func scalarRawValue(from line: BodyLine) -> String {
    let trimmed = line.contentTrimmed
    guard let colon = keyColonIndex(trimmed) else { return "" }
    var after = String(trimmed[trimmed.index(after: colon)...])
        .trimmingCharacters(in: .whitespaces)
    if let cIdx = trailingCommentIndex(after) {
        after = String(after[..<cIdx]).trimmingCharacters(in: .whitespaces)
    }
    return after
}

private func listItems(from location: FieldLocation) -> [String] {
    switch location.shape {
    case .flowList:
        let raw = scalarRawValue(from: location.lines[0])
        guard raw.hasPrefix("["), raw.hasSuffix("]") else { return [] }
        return splitFlowList(String(raw.dropFirst().dropLast()))
    case .blockList:
        var items: [String] = []
        for line in location.lines.dropFirst() {
            let t = line.contentTrimmed
            if t == "-" {
                items.append("")
            } else if t.hasPrefix("- ") {
                var item = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if let cIdx = trailingCommentIndex(item) {
                    item = String(item[..<cIdx]).trimmingCharacters(in: .whitespaces)
                }
                items.append(unquote(item))
            }
        }
        return items
    default:
        return []
    }
}

private func complexDisplay(location: FieldLocation) -> String {
    // Compact read-only summary similar to parseFrontmatterProperties.
    var parts: [String] = []
    for line in location.lines.dropFirst() {
        let t = line.contentTrimmed
        if !t.isEmpty, !t.hasPrefix("#") {
            parts.append(t)
        }
    }
    if parts.isEmpty {
        return scalarRawValue(from: location.lines[0])
    }
    return parts.joined(separator: "; ")
}

private func isYAMLBool(_ s: String) -> Bool {
    switch s.lowercased() {
    case "true", "false", "yes", "no", "on", "off": return true
    default: return false
    }
}

private func isYAMLDate(_ s: String) -> Bool {
    // Strict YYYY-MM-DD.
    guard s.count == 10 else { return false }
    let parts = s.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
          parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
          parts[0].allSatisfy(\.isNumber),
          parts[1].allSatisfy(\.isNumber),
          parts[2].allSatisfy(\.isNumber)
    else { return false }
    let y = Int(parts[0]) ?? 0
    let m = Int(parts[1]) ?? 0
    let d = Int(parts[2]) ?? 0
    return y >= 1000 && m >= 1 && m <= 12 && d >= 1 && d <= 31
}

private func needsYAMLQuotes(_ value: String) -> Bool {
    if value.isEmpty { return true }
    if value.first == " " || value.first == "\t" { return true }
    if value.last == " " || value.last == "\t" { return true }
    if value.contains("#") { return true }
    if value.contains(": ") || value.hasSuffix(":") { return true }
    if value.contains("\"") || value.contains("'") { return true }
    if value.contains("[") || value.contains("]")
        || value.contains("{") || value.contains("}") { return true }
    if value.hasPrefix("&") || value.hasPrefix("*")
        || value.hasPrefix("!") || value.hasPrefix("|")
        || value.hasPrefix(">") || value.hasPrefix("@")
        || value.hasPrefix("`") { return true }
    switch value.lowercased() {
    case "true", "false", "yes", "no", "on", "off", "null", "~":
        return true
    default: break
    }
    if isYAMLNumber(value) { return true }
    return false
}

private func encodeYAMLListItems(_ items: [String]) -> [String]? {
    var result: [String] = []
    result.reserveCapacity(items.count)
    for item in items {
        guard let encoded = encodeYAMLScalar(item) else { return nil }
        result.append(encoded)
    }
    return result
}

private func isValidFrontmatterKey(_ key: String) -> Bool {
    if key.isEmpty { return false }
    if key.contains(":") || key.contains("#") || key.contains("\n")
        || key.contains("\r") { return false }
    if key.contains(" ") || key.contains("\t") { return false }
    return true
}
