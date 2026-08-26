import Foundation
import Markdown

// Markdown → HTML for Preview. swift-markdown's HTMLFormatter is unused: it
// does not escape text/code content and drops inline formatting in headings.
// This visitor escapes everything except author raw HTML, passed through minus
// executable script tags — one rule for first load and innerHTML updates.

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func htmlAttributeEscape(_ s: String) -> String {
    htmlEscape(s).replacingOccurrences(of: "\"", with: "&quot;")
}

/// Keeps ordinary raw HTML while making `<script>` text inert. `innerHTML`
/// doesn't execute inserted scripts, but the initial full page would —
/// neutralizing in the shared renderer gives both paths one rule.
func previewSafeRawHTML(_ raw: String) -> String {
    raw.replacingOccurrences(of: "(?i)<\\s*script\\b", with: "&lt;script",
                             options: .regularExpression)
        .replacingOccurrences(of: "(?i)</\\s*script\\s*>", with: "&lt;/script&gt;",
                              options: .regularExpression)
}

/// Escapes + `<wbr>` after each underscore: browsers break on `-` but not `_`,
/// so `snake_case` widens the line (and table column). `<wbr>` is not copied.
func htmlEscapeBreakingUnderscores(_ s: String) -> String {
    htmlEscape(s).replacingOccurrences(of: "_", with: "_<wbr>")
}

/// Options for embedding source-line markers in Preview HTML (`data-ln`).
struct PreviewGutterOptions: Equatable, Sendable {
    var showLineNumbers: Bool = false
    var highlightChangedLines: Bool = false
    var showDirtyBulletsWhenNoNumbers: Bool = false
    var dirtyLines: Set<Int> = []
    /// Hex color for dirty marks (e.g. `#1a8f3c`); empty → CSS default green.
    var dirtyMarkColorHex: String = ""

    var isVisible: Bool {
        showLineNumbers || (highlightChangedLines && showDirtyBulletsWhenNoNumbers)
    }

    /// Numbers for every marked block vs bullets only on dirty lines.
    var modeClass: String {
        if showLineNumbers { return "gutter-numbers" }
        if highlightChangedLines && showDirtyBulletsWhenNoNumbers { return "gutter-bullets" }
        return ""
    }

    static let off = PreviewGutterOptions()
}

/// Preview line-number rail geometry — lives in the body's left padding (not a
/// ruler view), so the action strip must add it to reach the text; numbers
/// match the page CSS.
enum PreviewGutterMetrics {
    /// Gap between the numbers column and the text.
    static let gapPx: CGFloat = 18

    static func columnPx(for gutter: PreviewGutterOptions) -> CGFloat {
        let font = GutterTypography.fontSize.rounded()
        let digits = max(2, String(max(99, gutter.dirtyLines.max() ?? 999)).count)
        return max(28, font * CGFloat(digits) + 10)
    }

    /// Left offset the rail adds to the text. RESERVED even with numbers off:
    /// they appear in the margin instead of pushing the text sideways.
    static func railPx(for gutter: PreviewGutterOptions) -> CGFloat {
        columnPx(for: gutter) + gapPx
    }
}

/// Renders markdown to an HTML body fragment.
/// `imageResolver` may replace an image's `src` (e.g. with a data: URI for
/// local files); returning nil keeps the original source.
func markdownHTMLBody(_ text: String,
                      imageResolver: ((String) -> String?)? = nil,
                      gutter: PreviewGutterOptions = .off,
                      syntaxHighlighting: Bool = true) -> String {
    markdownHTMLRender(text, imageResolver: imageResolver, gutter: gutter,
                       syntaxHighlighting: syntaxHighlighting).body
}

/// Math span for the HTML visitor: full-document range, verbatim TeX, and how
/// many sentinel units its mask produced (a multiline `$$` block splits across
/// Text nodes; runs are consumed against `units`).
struct HTMLMathSpan {
    let range: NSRange
    let tex: String
    let display: Bool
    let units: Int
}

/// Body fragment + whether the document contains math (`previewHTMLPageRender`
/// embeds the KaTeX assets only when it does).
func markdownHTMLRender(_ text: String,
                        imageResolver: ((String) -> String?)? = nil,
                        gutter: PreviewGutterOptions = .off,
                        syntaxHighlighting: Bool = true)
    -> (body: String, hasMath: Bool) {
    let pluginSnapshot = BuiltInPluginRegistry.snapshot(for: text)
    var source = text
    var baseOffset = 0
    var lineBase = 0
    // Frontmatter is not markdown grammar — strip before parsing (else it
    // parses as thematic break + setext heading). Never rendered: the
    // Properties inspector owns it.
    if let fm = frontmatterRange(in: text) {
        let ns = text as NSString
        baseOffset = NSMaxRange(fm.full)
        source = ns.substring(from: baseOffset)
        lineBase = ns.substring(to: baseOffset).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
    // Math extracted BEFORE parsing: cmark would mangle TeX. The mask preserves
    // UTF-16 length, so masked-parse offsets are valid in the original.
    let mathSpans = scanMathSpans(in: source)
    let (mathMaskedSource, sentinelUnits) = maskMathSpansForParsing(source, spans: mathSpans)
    let parseSource = maskBuiltInPluginTokensForParsing(
        mathMaskedSource, snapshot: pluginSnapshot, sourceOffset: baseOffset)
    let sourceNS = source as NSString
    let renderMath = mathSpans.enumerated().map { idx, span in
        HTMLMathSpan(
            range: NSRange(location: span.range.location + baseOffset,
                           length: span.range.length),
            tex: sourceNS.substring(with: span.innerRange),
            display: span.display,
            units: sentinelUnits[idx])
    }
    let document = Document(parsing: parseSource)
    // LineIndex MUST be built from `parseSource`: cmark columns are UTF-8 bytes
    // of what it parsed (sentinel = 3 bytes vs the original chars). Resulting
    // UTF-16 offsets are valid in the original; baseOffset rebases past
    // stripped frontmatter.
    var visitor = HTMLBodyVisitor(imageResolver: imageResolver,
                                  lineIdx: LineIndex(parseSource),
                                  parsedSource: parseSource as NSString,
                                  originalSource: text as NSString,
                                  baseOffset: baseOffset,
                                  lineBase: lineBase,
                                  gutter: gutter,
                                  syntaxHighlighting: syntaxHighlighting,
                                  mathSpans: renderMath,
                                  pluginTokens: pluginSnapshot.tokens)
    visitor.visit(document)
    return (visitor.result, !mathSpans.isEmpty)
}

private struct HTMLBodyVisitor: MarkupWalker {
    var result = ""
    let imageResolver: ((String) -> String?)?
    let lineIdx: LineIndex
    /// The text cmark parsed (masked, frontmatter stripped) — read for the few
    /// decisions the AST doesn't carry, e.g. is this code block fenced?
    let parsedSource: NSString
    /// Full, unmasked document for fail-safe restoration if a sentinel cannot
    /// be matched to the token at the exact expected source offset.
    let originalSource: NSString
    /// Rebases AST offsets into the original document past stripped frontmatter.
    let baseOffset: Int
    /// Newlines before the parsed `source` in the original document.
    let lineBase: Int
    let gutter: PreviewGutterOptions
    let syntaxHighlighting: Bool
    /// Document-order math spans; Text nodes carry U+E000 sentinel runs that
    /// are consumed against these (first run of a span emits its HTML).
    let mathSpans: [HTMLMathSpan]
    /// Global UTF-16 ranges. List tokens are normalized to GFM task markers;
    /// inline tokens are represented by U+E001 runs in Text nodes.
    let pluginTokens: [BuiltInPluginToken]
    private var mathCursor = 0
    private var pendingMathUnits = 0
    private var pluginSentinelCursor: BuiltInPluginSentinelCursor

    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0
    private var inTableHead = false

    init(imageResolver: ((String) -> String?)?,
         lineIdx: LineIndex,
         parsedSource: NSString,
         originalSource: NSString,
         baseOffset: Int,
         lineBase: Int = 0,
         gutter: PreviewGutterOptions = .off,
         syntaxHighlighting: Bool = true,
         mathSpans: [HTMLMathSpan] = [],
         pluginTokens: [BuiltInPluginToken] = []) {
        self.imageResolver = imageResolver
        self.lineIdx = lineIdx
        self.parsedSource = parsedSource
        self.originalSource = originalSource
        self.baseOffset = baseOffset
        self.lineBase = lineBase
        self.gutter = gutter
        self.syntaxHighlighting = syntaxHighlighting
        self.mathSpans = mathSpans
        self.pluginTokens = pluginTokens
        self.pluginSentinelCursor = BuiltInPluginSentinelCursor(tokens: pluginTokens)
    }

    /// UTF-16 NSRange in the original markdown for a markup node's SourceRange.
    private func mdNSRange(for markup: some Markup) -> NSRange? {
        guard let src = markup.range else { return nil }
        let loc = lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
        let end = lineIdx.offset(src.upperBound.line, src.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc + baseOffset, length: end - loc)
    }

    /// 1-based line in the **original** markdown (frontmatter-aware).
    private func sourceLine(of markup: some Markup) -> Int? {
        guard let src = markup.range else { return nil }
        return lineBase + src.lowerBound.line
    }

    /// SOURCE range of each RENDERED code line, in document order. Read from
    /// source text, not `codeBlock.code` (indented blocks strip the indent). A
    /// fenced block's first source line is the fence, never shown; line counts
    /// cannot tell fenced from indented (trailing blank lines), so the opening
    /// line is inspected for a fence.
    private func codeLineRanges(_ codeBlock: CodeBlock) -> [NSRange]? {
        guard let src = codeBlock.range else { return nil }
        var lines = codeBlock.code.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return nil }

        let firstLine = src.lowerBound.line
        let opening = lineText(firstLine).trimmingCharacters(in: .whitespaces)
        let isFenced = opening.hasPrefix("```") || opening.hasPrefix("~~~")
        let start = isFenced ? firstLine + 1 : firstLine

        return (0..<lines.count).map { index in
            let lineStart = lineIdx.lineStart(start + index)
            let body = lineText(start + index)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
            return NSRange(location: lineStart + baseOffset,
                           length: (body as NSString).length)
        }
    }

    /// One line of the parsed source, newline included (1-based, as cmark).
    private func lineText(_ line: Int) -> String {
        let start = lineIdx.lineStart(line)
        guard start < parsedSource.length else { return "" }
        let range = parsedSource.lineRange(for: NSRange(location: start, length: 0))
        return parsedSource.substring(with: range)
    }

    /// Opens a block tag with optional `data-ln` / `ln-dirty` for the Preview gutter.
    private mutating func openBlock(_ tag: String, _ markup: some Markup,
                                    classes: [String] = [],
                                    extraAttrs: String = "") {
        var cls = classes
        var attrs = extraAttrs
        if let line = sourceLine(of: markup) {
            let isDirty = gutter.highlightChangedLines && gutter.dirtyLines.contains(line)
            let wantMark = gutter.showLineNumbers
                || (isDirty && gutter.showDirtyBulletsWhenNoNumbers)
            if wantMark {
                attrs += " data-ln=\"\(line)\""
            }
            if isDirty {
                cls.append("ln-dirty")
            }
        }
        let classAttr = cls.isEmpty ? "" : " class=\"\(cls.joined(separator: " "))\""
        result += "<\(tag)\(classAttr)\(attrs)>"
    }

    // MARK: Block elements

    mutating func visitParagraph(_ paragraph: Paragraph) {
        openBlock("p", paragraph)
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        openBlock("h\(heading.level)", heading)
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        // No data-ln on the wrapper — children carry source lines; otherwise the
        // same number appears twice.
        let callout = mdNSRange(for: blockQuote).flatMap {
            markdownCallout(in: originalSource as String, quoteRange: $0)
        }
        if let callout {
            result += "<blockquote class=\"callout callout-\(callout.style.rawValue)\""
                + " data-callout=\"\(htmlAttributeEscape(callout.type))\">\n"
                + "<span class=\"callout-icon\" aria-hidden=\"true\">"
                + htmlEscape(callout.iconText) + "</span>\n"
        } else {
            result += "<blockquote>\n"
        }
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        // Each rendered code LINE gets data-md-lo/hi: without in-block anchors
        // split-scroll sync stalls until the block ends.
        let lineRanges = codeLineRanges(codeBlock)
        let sourceAttrs: String
        if let range = mdNSRange(for: codeBlock) {
            sourceAttrs = " data-md-lo=\"\(range.location)\""
                + " data-md-hi=\"\(NSMaxRange(range))\" data-md-code=\"1\""
        } else {
            sourceAttrs = " data-md-code=\"1\""
        }
        openBlock("pre", codeBlock, extraAttrs: sourceAttrs)
        let language = codeBlock.language ?? ""
        if !language.isEmpty {
            // language-* first for integrations matching the literal prefix.
            result += "<code class=\"language-\(htmlAttributeEscape(language)) hljs\">"
        } else {
            result += "<code>"
        }
        result += syntaxHighlighting
            ? CodeSyntaxHighlighter.shared.html(codeBlock.code, language: language,
                                                lineRanges: lineRanges)
            : Self.plainCodeHTML(codeBlock.code, lineRanges: lineRanges)
        result += "</code></pre>\n"
    }

    /// Same per-line spans as the highlighter emits, for `syntaxHighlighting`
    /// off — scroll sync must not depend on a display setting.
    private static func plainCodeHTML(_ code: String, lineRanges: [NSRange]?) -> String {
        guard let lineRanges else { return htmlEscape(code) }
        let lines = code.components(separatedBy: "\n")
        var out = ""
        for (index, line) in lines.enumerated() {
            if index < lineRanges.count {
                let range = lineRanges[index]
                out += "<span class=\"cl\" data-md-lo=\"\(range.location)\""
                    + " data-md-hi=\"\(NSMaxRange(range))\">"
                    + htmlEscape(line) + "</span>"
            } else {
                out += htmlEscape(line)
            }
            if index < lines.count - 1 { out += "\n" }
        }
        return out
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        openBlock("hr", thematicBreak)  // void element: <hr data-ln="…">
        result += "\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML: wrap so the gutter can still mark the starting line.
        openBlock("div", html, classes: ["raw-html"])
        result += previewSafeRawHTML(html.rawHTML)
        result += "</div>\n"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
        // data-ln only on <li>, not the list wrapper (avoids duplicate numbers).
        result += "<ul>\n"
        descendInto(unorderedList)
        result += "</ul>\n"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) {
        if orderedList.startIndex != 1 {
            result += "<ol start=\"\(orderedList.startIndex)\">\n"
        } else {
            result += "<ol>\n"
        }
        descendInto(orderedList)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ listItem: ListItem) {
        if let token = pluginListToken(in: listItem) {
            var classes = ["task", "multi-task"]
            if token.payload.state.strikethrough { classes.append("multi-task-strike") }
            openBlock("li", listItem, classes: classes)
            result += builtInPluginTokenHTML(token.payload,
                                             sourceOffset: token.range.location) + " "
        } else if let checkbox = listItem.checkbox {
            openBlock("li", listItem, classes: ["task"])
            result += "<input type=\"checkbox\" disabled"
            if checkbox == .checked { result += " checked" }
            result += "> "
        } else {
            openBlock("li", listItem)
        }
        // Unwrap the first paragraph (tight rendering) — a block <p> would push
        // content below the checkbox/bullet.
        var children = Array(listItem.children)
        if let paragraph = children.first as? Paragraph {
            descendInto(paragraph)
            children.removeFirst()
        }
        for child in children { visit(child) }
        result += "</li>\n"
    }

    private func pluginListToken(in listItem: ListItem) -> BuiltInPluginToken? {
        guard let range = mdNSRange(for: listItem) else { return nil }
        return pluginTokens.first {
            $0.isListMarker && $0.payload.isInteractive
                && $0.range.location >= range.location
                && NSMaxRange($0.range) <= NSMaxRange(range)
        }
    }

    // MARK: Tables

    mutating func visitTable(_ table: Table) {
        openBlock("table", table)
        result += "\n"
        tableColumnAlignments = table.columnAlignments
        descendInto(table)
        tableColumnAlignments = nil
        result += "</table>\n"
    }

    mutating func visitTableHead(_ tableHead: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        currentTableColumn = 0
        descendInto(tableHead)
        inTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ tableBody: Table.Body) {
        guard !tableBody.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(tableBody)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        result += "<tr>\n"
        currentTableColumn = 0
        descendInto(tableRow)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ tableCell: Table.Cell) {
        guard let alignments = tableColumnAlignments,
              currentTableColumn < alignments.count,
              tableCell.colspan > 0, tableCell.rowspan > 0 else { return }

        let element = inTableHead ? "th" : "td"
        result += "<\(element)"
        if let alignment = alignments[currentTableColumn] {
            result += " align=\"\(alignment)\""
        }
        currentTableColumn += 1
        if tableCell.rowspan > 1 { result += " rowspan=\"\(tableCell.rowspan)\"" }
        if tableCell.colspan > 1 { result += " colspan=\"\(tableCell.colspan)\"" }
        result += ">"
        descendInto(tableCell)
        result += "</\(element)>\n"
    }

    // MARK: Inline elements

    mutating func visitText(_ text: Text) {
        let s = text.string
        // Tag runs with source offsets so the Preview toolbar wraps the real
        // selection, not the first plain-text match.
        let base = mdNSRange(for: text)?.location
        let hasMath = s.utf16.contains(mathSentinelUnit)
        let hasPlugin = s.utf16.contains(builtInPluginSentinelUnit)
        guard hasMath || hasPlugin else {
            result += Self.inlineDecoratedHTML(s, sourceBase: base)
            return
        }
        // Masked math: split the run into plain segments and sentinel runs.
        let ns = s as NSString
        var i = 0
        while i < ns.length {
            if ns.character(at: i) == mathSentinelUnit {
                var j = i
                while j < ns.length, ns.character(at: j) == mathSentinelUnit { j += 1 }
                consumeSentinelRun(j - i)
                i = j
            } else if ns.character(at: i) == builtInPluginSentinelUnit {
                var j = i
                while j < ns.length,
                      ns.character(at: j) == builtInPluginSentinelUnit { j += 1 }
                consumePluginSentinelRun(j - i, sourceOffset: base.map { $0 + i })
                i = j
            } else {
                var j = i
                while j < ns.length,
                      ns.character(at: j) != mathSentinelUnit,
                      ns.character(at: j) != builtInPluginSentinelUnit { j += 1 }
                let sub = ns.substring(with: NSRange(location: i, length: j - i))
                result += Self.inlineDecoratedHTML(sub, sourceBase: base.map { $0 + i })
                i = j
            }
        }
    }

    private mutating func consumePluginSentinelRun(_ count: Int, sourceOffset: Int?) {
        var remaining = count
        var offset = sourceOffset
        while remaining > 0 {
            guard let token = pluginSentinelCursor.next(
                startingAt: offset, maxLength: remaining)
            else {
                if let offset, offset >= 0, offset + remaining <= originalSource.length {
                    let original = originalSource.substring(
                        with: NSRange(location: offset, length: remaining))
                    result += Self.inlineDecoratedHTML(original, sourceBase: offset)
                } else {
                    // No AST range, no token left: keep the failure visible
                    // without leaking the private-use mask.
                    result += String(repeating: "□", count: max(1, (remaining + 2) / 3))
                }
                return
            }
            result += builtInPluginTokenHTML(token.payload,
                                             sourceOffset: token.range.location)
            remaining -= token.range.length
            offset = offset.map { $0 + token.range.length }
        }
    }

    /// FIRST run of a span emits its HTML; remaining runs (continuation lines
    /// of `$$`, split by softbreaks) are consumed silently against `units`.
    private mutating func consumeSentinelRun(_ count: Int) {
        var remaining = count
        while remaining > 0 {
            if pendingMathUnits > 0 {
                let take = min(pendingMathUnits, remaining)
                pendingMathUnits -= take
                remaining -= take
                continue
            }
            // Orphan sentinels (document itself contains U+E000): emit nothing.
            guard mathCursor < mathSpans.count else { return }
            let span = mathSpans[mathCursor]
            mathCursor += 1
            emitMath(span)
            pendingMathUnits = span.units
        }
    }

    /// data-md-lo/hi keep scroll/review-wash working; data-md-code marks the
    /// KaTeX DOM a selection island (rendered text ≠ source offsets), same as
    /// rendered code. Page script replaces the escaped TeX with KaTeX output.
    private mutating func emitMath(_ span: HTMLMathSpan) {
        let cls = span.display ? "math math-display" : "math math-inline"
        result += "<span class=\"\(cls)\" data-md-lo=\"\(span.range.location)\""
            + " data-md-hi=\"\(NSMaxRange(span.range))\" data-md-code=\"1\">"
            + htmlEscape(span.tex) + "</span>"
    }

    /// Wiki-links first, then `==highlight==` in the remaining plain segments.
    /// When `sourceBase` is set, each run is wrapped in a `data-md-lo/hi` span
    /// (UTF-16 offsets into the original markdown).
    static func inlineDecoratedHTML(_ s: String, sourceBase: Int?) -> String {
        let wiki = scanWikiLinks(in: s)
        guard !wiki.isEmpty else { return highlightDecoratedHTML(s, sourceBase: sourceBase) }
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in wiki {
            if m.range.location > cursor {
                let sub = ns.substring(with: NSRange(location: cursor,
                                                     length: m.range.location - cursor))
                let base = sourceBase.map { $0 + cursor }
                out += highlightDecoratedHTML(sub, sourceBase: base)
            }
            let wBase = sourceBase.map { $0 + m.range.location }
            out += wikiLinkHTML(m.payload, sourceBase: wBase, utf16Length: m.range.length)
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            let sub = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            let base = sourceBase.map { $0 + cursor }
            out += highlightDecoratedHTML(sub, sourceBase: base)
        }
        return out
    }

    /// Renders `==inner==` as `<mark>`; plain runs stay escaped. Tagged when
    /// `sourceBase` is known (inner of a mark uses the content range, not the
    /// `==` fences — so toggle-unwrap finds the surrounding markers).
    static func highlightDecoratedHTML(_ s: String, sourceBase: Int?) -> String {
        let marks = scanHighlightMarks(in: s)
        let ns = s as NSString
        guard !marks.isEmpty else {
            return mdTagged(htmlEscapeBreakingUnderscores(s),
                            lo: sourceBase, length: ns.length)
        }
        var out = ""
        var cursor = 0
        for m in marks {
            if m.range.location > cursor {
                let len = m.range.location - cursor
                out += mdTagged(
                    htmlEscapeBreakingUnderscores(
                        ns.substring(with: NSRange(location: cursor, length: len))),
                    lo: sourceBase.map { $0 + cursor },
                    length: len)
            }
            // Inner content only (between == … ==).
            let innerLo = m.range.location + 2
            let innerLen = (m.inner as NSString).length
            out += mdTagged(htmlEscapeBreakingUnderscores(m.inner),
                            lo: sourceBase.map { $0 + innerLo },
                            length: innerLen,
                            tag: "mark")
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            let len = ns.length - cursor
            out += mdTagged(
                htmlEscapeBreakingUnderscores(
                    ns.substring(with: NSRange(location: cursor, length: len))),
                lo: sourceBase.map { $0 + cursor },
                length: len)
        }
        return out
    }

    /// Wraps already-escaped HTML in a source-offset tag when `lo` is known.
    static func mdTagged(_ escapedHTML: String, lo: Int?, length: Int,
                         tag: String = "span") -> String {
        guard let lo, length > 0, !escapedHTML.isEmpty else { return escapedHTML }
        let hi = lo + length
        return "<\(tag) data-md-lo=\"\(lo)\" data-md-hi=\"\(hi)\">\(escapedHTML)</\(tag)>"
    }

    /// A wiki-link as an anchor carrying resolution metadata in data-attributes;
    /// the preview's JS turns a click into a `wikiLinkClick` message.
    static func wikiLinkHTML(_ p: MDWikiLinkPayload,
                             sourceBase: Int? = nil,
                             utf16Length: Int = 0) -> String {
        var a = "<a class=\"wikilink\" data-wiki-target=\"\(htmlAttributeEscape(p.target))\""
        if let h = p.heading { a += " data-wiki-heading=\"\(htmlAttributeEscape(h))\"" }
        if let b = p.blockID { a += " data-wiki-block=\"\(htmlAttributeEscape(b))\"" }
        if let sourceBase, utf16Length > 0 {
            a += " data-md-lo=\"\(sourceBase)\" data-md-hi=\"\(sourceBase + utf16Length)\""
        }
        a += ">\(htmlEscapeBreakingUnderscores(p.displayText))</a>"
        return a
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        result += "<em>"
        descendInto(emphasis)
        result += "</em>"
    }

    mutating func visitStrong(_ strong: Strong) {
        result += "<strong>"
        descendInto(strong)
        result += "</strong>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        result += "<del>"
        descendInto(strikethrough)
        result += "</del>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        // data-md-code: toolbar wrap refuses selections inside code spans.
        result += "<code data-md-code=\"1\">\(htmlEscape(inlineCode.code))</code>"
    }

    mutating func visitLink(_ link: Link) {
        result += "<a"
        if let destination = link.destination {
            result += " href=\"\(htmlAttributeEscape(destination))\""
        }
        result += ">"
        descendInto(link)
        result += "</a>"
    }

    mutating func visitImage(_ image: Image) {
        result += "<img"
        if let source = image.source, !source.isEmpty {
            let resolved = imageResolver?(source) ?? source
            result += " src=\"\(htmlAttributeEscape(resolved))\""
        }
        let alt = image.plainText
        if !alt.isEmpty { result += " alt=\"\(htmlAttributeEscape(alt))\"" }
        if let title = image.title, !title.isEmpty {
            result += " title=\"\(htmlAttributeEscape(title))\""
        }
        result += ">"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        result += previewSafeRawHTML(inlineHTML.rawHTML)
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }
}
