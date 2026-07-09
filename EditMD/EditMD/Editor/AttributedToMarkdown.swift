import AppKit

// Attributed string (Visual model) → markdown. Reads ONLY the semantic
// attributes (.mdBlock/.mdInline/.mdLink/.mdImage) — fonts and colors are
// presentation and never consulted. Counterpart to MarkdownToAttributed.swift;
// `serialize(render(x))` is the document's normal form.

/// Serialization result plus a display-paragraph → markdown-range map, used
/// to carry the cursor across mode switches.
struct MarkdownSerialization {
    let markdown: String
    /// For each display paragraph (index = paragraph order in the attributed
    /// string) the UTF-16 range of its emitted piece in `markdown`.
    let paragraphRanges: [NSRange]
}

func serializeAttributedToMarkdown(_ attr: NSAttributedString) -> String {
    serializeAttributedToMarkdownDetailed(attr).markdown
}

func serializeAttributedToMarkdownDetailed(_ attr: NSAttributedString) -> MarkdownSerialization {
    let nsText = attr.string as NSString
    guard nsText.length > 0 else { return MarkdownSerialization(markdown: "", paragraphRanges: []) }

    // Split into display paragraphs; each carries MDBlock (stamped through \n).
    var paragraphs: [(range: NSRange, block: MDBlock)] = []
    var location = 0
    while location < nsText.length {
        let rest = NSRange(location: location, length: nsText.length - location)
        let newline = nsText.range(of: "\n", options: [], range: rest)
        let end = newline.location == NSNotFound ? nsText.length : newline.location
        let range = NSRange(location: location, length: end - location)
        let attrIndex = min(range.length > 0 ? range.location : end, nsText.length - 1)
        let block = attr.attribute(.mdBlock, at: attrIndex, effectiveRange: nil) as? MDBlock
            ?? MDBlock(kind: .paragraph)
        paragraphs.append((range, block))
        if newline.location == NSNotFound { break }
        location = end + 1
    }

    // Emit pieces; code-block and table paragraphs group into single pieces.
    var pieces: [(text: String, block: MDBlock, paraIndexes: Range<Int>)] = []
    var i = 0
    while i < paragraphs.count {
        let (range, block) = paragraphs[i]
        switch block.kind {
        case .codeBlock(let language):
            var lines: [String] = [nsText.substring(with: range)]
            var j = i + 1
            while j < paragraphs.count,
                  case .codeBlock = paragraphs[j].block.kind,
                  paragraphs[j].block.group == block.group {
                lines.append(nsText.substring(with: paragraphs[j].range))
                j += 1
            }
            let prefix = linePrefix(block)
            var text = prefix + "```" + language
            for line in lines { text += "\n" + prefix + line }
            text += "\n" + prefix + "```"
            pieces.append((text, block, i..<j))
            i = j
        case .tableCell:
            var cells: [(row: Int, column: Int, text: String, alignment: Int)] = []
            var columns = 1
            var j = i
            while j < paragraphs.count,
                  case .tableCell(let row, let column, let cols, let alignment)
                    = paragraphs[j].block.kind,
                  paragraphs[j].block.group == block.group {
                columns = cols
                let text = serializeInlines(attr, in: paragraphs[j].range,
                                            block: paragraphs[j].block)
                cells.append((row, column, text, alignment))
                j += 1
            }
            pieces.append((tableMarkdown(cells: cells, columns: columns), block, i..<j))
            i = j
        case .raw(let raw):
            pieces.append((raw, block, i..<(i + 1)))
            i += 1
        case .thematicBreak:
            pieces.append((linePrefix(block) + "---", block, i..<(i + 1)))
            i += 1
        default:
            let prefix = linePrefix(block) + kindPrefix(block.kind)
            let inline = serializeInlines(attr, in: range, block: block)
            pieces.append((prefix + escapeLeading(inline, kind: block.kind), block, i..<(i + 1)))
            i += 1
        }
    }

    guard !pieces.isEmpty else { return MarkdownSerialization(markdown: "", paragraphRanges: []) }
    var result = ""
    var ranges = [NSRange](repeating: NSRange(location: 0, length: 0), count: paragraphs.count)
    for (index, piece) in pieces.enumerated() {
        if index > 0 {
            result += separator(pieces[index - 1].block, piece.block)
        }
        let pieceRange = NSRange(location: (result as NSString).length,
                                 length: (piece.text as NSString).length)
        for paragraphIndex in piece.paraIndexes {
            ranges[paragraphIndex] = pieceRange
        }
        result += piece.text
    }
    return MarkdownSerialization(markdown: result, paragraphRanges: ranges)
}

/// GFM table from collected cells. Missing cells render empty.
private func tableMarkdown(cells: [(row: Int, column: Int, text: String, alignment: Int)],
                           columns: Int) -> String {
    var grid: [Int: [Int: String]] = [:]
    var alignments = [Int](repeating: 0, count: columns)
    var rowCount = 1
    for cell in cells {
        grid[cell.row, default: [:]][cell.column] = cell.text
        if cell.column < columns { alignments[cell.column] = cell.alignment }
        rowCount = max(rowCount, cell.row + 1)
    }
    func line(_ values: [String]) -> String {
        "| " + values.joined(separator: " | ") + " |"
    }
    func delimiter(_ alignment: Int) -> String {
        switch alignment {
        case 1: return ":--"
        case 2: return ":-:"
        case 3: return "--:"
        default: return "---"
        }
    }
    var lines: [String] = []
    lines.append(line((0..<columns).map { grid[0]?[$0] ?? "" }))
    lines.append(line((0..<columns).map { delimiter(alignments[$0]) }))
    for row in 1..<rowCount {
        lines.append(line((0..<columns).map { grid[row]?[$0] ?? "" }))
    }
    return lines.joined(separator: "\n")
}

// MARK: - Prefixes & separators

/// UTF-16 length of the markdown prefix emitted before a paragraph's display
/// text ("# ", "- [x] ", "> "…). Used for cursor mapping across modes.
func markdownPrefixLength(for block: MDBlock) -> Int {
    ((linePrefix(block) + kindPrefix(block.kind)) as NSString).length
}

private func linePrefix(_ block: MDBlock) -> String {
    String(repeating: " ", count: block.listIndent)
        + String(repeating: "> ", count: block.quoteDepth)
}

private func kindPrefix(_ kind: MDBlock.Kind) -> String {
    switch kind {
    case .paragraph, .codeBlock, .thematicBreak, .raw, .tableCell:
        return ""
    case .heading(let level):
        return String(repeating: "#", count: level) + " "
    case .bulletItem(let depth):
        return String(repeating: " ", count: depth * 4) + "- "
    case .orderedItem(let depth, let number):
        return String(repeating: " ", count: depth * 4) + "\(number). "
    case .taskItem(let depth, let done):
        return String(repeating: " ", count: depth * 4) + (done ? "- [x] " : "- [ ] ")
    case .listContinuation(let indent):
        return String(repeating: " ", count: indent)
    }
}

private func isListItem(_ kind: MDBlock.Kind) -> Bool {
    switch kind {
    case .bulletItem, .orderedItem, .taskItem:
        return true
    default:
        return false
    }
}

private func bulletFamily(_ kind: MDBlock.Kind) -> Bool {
    switch kind {
    case .bulletItem, .taskItem:
        return true
    default:
        return false
    }
}

private func separator(_ a: MDBlock, _ b: MDBlock) -> String {
    // Adjacent list items stay tight (loose lists normalize to tight).
    // Same quoteGroup required: items of lists living in two *different*
    // blockquotes must not glue those quotes together.
    if isListItem(a.kind) && isListItem(b.kind) && a.quoteGroup == b.quoteGroup {
        if a.group == b.group || a.quoteDepth > 0 { return "\n" }
        // Different list trees. A blank line cannot separate two lists whose
        // markers normalize to the same char — use an HTML-comment fence
        // (Prettier's trick). Different families split on the marker alone.
        return bulletFamily(a.kind) == bulletFamily(b.kind) ? "\n\n<!-- -->\n\n" : "\n\n"
    }
    // Blocks of the same blockquote need a quoted blank line, otherwise a
    // plain blank line would split them into two quotes.
    if a.quoteDepth > 0, b.quoteDepth > 0, a.quoteGroup == b.quoteGroup {
        let depth = min(a.quoteDepth, b.quoteDepth)
        let blank = String(repeating: "> ", count: depth)
            .trimmingCharacters(in: .whitespaces)
        return "\n" + blank + "\n"
    }
    return "\n\n"
}

/// Escapes a leading character that would turn the paragraph into another
/// block type on reparse (heading, quote, list, thematic break).
private func escapeLeading(_ text: String, kind: MDBlock.Kind) -> String {
    switch kind {
    // Item text starting with "-", "1." etc. would nest a new block on reparse.
    case .paragraph, .listContinuation, .bulletItem, .orderedItem, .taskItem:
        break
    default:
        return text
    }
    guard let first = text.first else { return text }
    if "#>+-".contains(first) { return "\\" + text }
    // "1. " / "1) " would become an ordered list.
    let digits = text.prefix(while: { $0.isNumber })
    if !digits.isEmpty, digits.count < text.count {
        let next = text[text.index(text.startIndex, offsetBy: digits.count)]
        if next == "." || next == ")" { return "\\" + text }
    }
    return text
}

// MARK: - Inline serialization

private enum OpenMarker: Equatable {
    case bold, italic, strike, highlight
    case link(String)

    var opener: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strike: return "~~"
        case .highlight: return "=="
        case .link: return "["
        }
    }

    var closer: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strike: return "~~"
        case .highlight: return "=="
        case .link(let dest): return "](\(formatDestination(dest)))"
        }
    }
}

private struct InlineRun {
    var text: String
    var styles: MDInlineStyle
    var link: String?
    var image: [String: String]?
    var wikiLink: MDWikiLinkPayload?
}

private func serializeInlines(_ attr: NSAttributedString, in range: NSRange,
                              block: MDBlock) -> String {
    guard range.length > 0 else { return "" }
    let nsText = attr.string as NSString

    var runs: [InlineRun] = []
    attr.enumerateAttributes(in: range, options: []) { attrs, r, _ in
        runs.append(InlineRun(
            text: nsText.substring(with: r),
            styles: MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0),
            link: attrs[.mdLink] as? String,
            image: attrs[.mdImage] as? [String: String],
            wikiLink: attrs[.mdWikiLink] as? MDWikiLinkPayload))
    }

    // Autolink: a whole-paragraph unstyled link whose text equals its
    // destination serializes as the bare URL.
    if runs.count == 1, let run = runs.first, run.image == nil,
       run.styles.isEmpty, let dest = run.link,
       dest == run.text || dest == "mailto:" + run.text {
        return run.text
    }

    let continuationPrefix = linePrefix(block)
    // Inside table cells a literal "|" would split the cell.
    var escapePipes = false
    if case .tableCell = block.kind { escapePipes = true }
    var result = ""
    var stack: [OpenMarker] = []

    func desiredMarkers(_ run: InlineRun) -> [OpenMarker] {
        var markers: [OpenMarker] = []
        if let link = run.link { markers.append(.link(link)) }
        // Highlight is outermost among pure style markers so reparse sees
        // `==…==` as one text run (bold/italic inside stay literal in the
        // mark; `**==x==**` re-renders both bold and highlight).
        if run.styles.contains(.highlight) { markers.append(.highlight) }
        if run.styles.contains(.bold) { markers.append(.bold) }
        if run.styles.contains(.italic) { markers.append(.italic) }
        if run.styles.contains(.strike) { markers.append(.strike) }
        return markers
    }

    for run in runs {
        let desired = desiredMarkers(run)

        // Close markers no longer wanted (LIFO, reopening survivors).
        var reopen: [OpenMarker] = []
        while let top = stack.last, !desired.contains(top) || !stackIsPrefixValid(stack, desired) {
            stack.removeLast()
            result += top.closer
            if desired.contains(top) { reopen.insert(top, at: 0) }
            if stack.allSatisfy({ desired.contains($0) }) { break }
        }
        // Reopen survivors, then open new markers.
        for marker in reopen where !stack.contains(marker) {
            openMarker(marker, into: &result, stack: &stack)
        }
        for marker in desired where !stack.contains(marker) {
            openMarker(marker, into: &result, stack: &stack)
        }

        if let wiki = run.wikiLink {
            // Round-trip source of truth: re-emit the verbatim inner text, never
            // reconstruct from parsed fields. After marker management so bold/
            // italic around a wiki-link keep their wrappers.
            result += "[[\(wiki.originalInner)]]"
        } else if let image = run.image {
            // Emitted after marker management so an image inside a link keeps
            // its enclosing [..](..) wrapper.
            result += imageMarkdown(image)
        } else if run.styles.contains(.code) {
            result += codeSpan(run.text)
        } else if run.styles.contains(.rawHTML) {
            result += run.text
        } else {
            result += escapeInline(run.text, continuationPrefix: continuationPrefix,
                                   escapePipes: escapePipes)
        }
    }
    for marker in stack.reversed() { result += marker.closer }
    return result
}

/// True when every marker currently on the stack is still desired — used to
/// stop the closing loop early.
private func stackIsPrefixValid(_ stack: [OpenMarker], _ desired: [OpenMarker]) -> Bool {
    stack.allSatisfy { desired.contains($0) }
}

private func openMarker(_ marker: OpenMarker, into result: inout String,
                        stack: inout [OpenMarker]) {
    if case .link = marker, result.hasSuffix("!") {
        // "!" directly before "[" would parse as an image.
        result.removeLast()
        result += "\\!"
    }
    result += marker.opener
    stack.append(marker)
}

private func imageMarkdown(_ info: [String: String]) -> String {
    let alt = (info["alt"] ?? "").replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
    var inside = formatDestination(info["src"] ?? "")
    if let title = info["title"], !title.isEmpty {
        inside += " \"\(title)\""
    }
    return "![\(alt)](\(inside))"
}

private func formatDestination(_ dest: String) -> String {
    if dest.contains(" ") || dest.contains("(") || dest.contains(")") {
        return "<" + dest + ">"
    }
    return dest
}

private func codeSpan(_ text: String) -> String {
    var maxRun = 0, current = 0
    for ch in text {
        current = ch == "`" ? current + 1 : 0
        maxRun = max(maxRun, current)
    }
    let fence = String(repeating: "`", count: maxRun + 1)
    let needsPad = text.hasPrefix("`") || text.hasSuffix("`")
        || (text.hasPrefix(" ") && text.hasSuffix(" ") && !text.trimmingCharacters(in: .whitespaces).isEmpty)
    let pad = needsPad ? " " : ""
    return fence + pad + text + pad + fence
}

/// Escapes markdown-significant characters in plain text. U+2028 (hard break)
/// becomes the backslash form, re-applying the quote/indent prefix.
private func escapeInline(_ text: String, continuationPrefix: String,
                          escapePipes: Bool = false) -> String {
    var out = ""
    for ch in text {
        switch ch {
        case "\\", "`", "*", "_", "[", "]", "<", "~":
            out.append("\\")
            out.append(ch)
        case "|" where escapePipes:
            out += "\\|"
        case Character(mdHardBreak) where escapePipes:
            out.append(" ")  // table cells are single-line
        case Character(mdHardBreak):
            out += "\\\n" + continuationPrefix
        default:
            out.append(ch)
        }
    }
    return out
}
