import Foundation
import Markdown

// Markdown → HTML for the Preview mode.
//
// swift-markdown's own HTMLFormatter is not used: it does not escape text /
// code content (a code block containing "<div>" would break the page) and it
// drops inline formatting inside headings (plainText). This visitor escapes
// everything except author-written raw HTML blocks/inlines, which are passed
// through — standard markdown behavior.

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func htmlAttributeEscape(_ s: String) -> String {
    htmlEscape(s).replacingOccurrences(of: "\"", with: "&quot;")
}

/// HTML-escapes body text and adds a `<wbr>` soft break after each underscore.
/// Browsers treat `-` as a line-break opportunity but not `_`, so a long
/// `snake_case` identifier is one unbreakable word that widens the line (and,
/// in a table cell, the whole column). `<wbr>` breaks only when needed and is
/// not copied to the clipboard.
func htmlEscapeBreakingUnderscores(_ s: String) -> String {
    htmlEscape(s).replacingOccurrences(of: "_", with: "_<wbr>")
}

/// Options for embedding source-line markers in Preview HTML (`data-ln`).
struct PreviewGutterOptions: Equatable {
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

/// Renders markdown to an HTML body fragment.
/// `imageResolver` may replace an image's `src` (e.g. with a data: URI for
/// local files); returning nil keeps the original source.
func markdownHTMLBody(_ text: String,
                      imageResolver: ((String) -> String?)? = nil,
                      gutter: PreviewGutterOptions = .off) -> String {
    var source = text
    var prefix = ""
    var baseOffset = 0
    var lineBase = 0
    // YAML frontmatter isn't part of the markdown grammar — strip it and render
    // it as an Obsidian-style properties table, so it doesn't mangle into a
    // thematic break + setext heading.
    if let fm = frontmatterRange(in: text) {
        let ns = text as NSString
        let props = parseFrontmatterProperties(ns.substring(with: fm.body))
        if !props.isEmpty {
            let fmLine = 1
            let dirty = gutter.highlightChangedLines && gutter.dirtyLines.contains(fmLine)
            let wantMark = gutter.showLineNumbers
                || (dirty && gutter.showDirtyBulletsWhenNoNumbers)
            var fmAttrs = ""
            if wantMark { fmAttrs += " data-ln=\"\(fmLine)\"" }
            if dirty { fmAttrs += " class=\"ln-dirty\"" }
            let table = frontmatterTableHTML(props)
            // Inject attrs onto the opening <table>
            if table.hasPrefix("<table") {
                let afterTable = table.index(table.startIndex, offsetBy: 6)
                prefix = "<table\(fmAttrs)" + table[afterTable...]
            } else {
                prefix = table
            }
        }
        baseOffset = NSMaxRange(fm.full)
        source = ns.substring(from: baseOffset)
        lineBase = ns.substring(to: baseOffset).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
    let document = Document(parsing: source)
    // LineIndex maps AST SourceRanges → UTF-16 offsets in `source`; baseOffset
    // rebases them into the original document (for Preview toolbar wrap).
    var visitor = HTMLBodyVisitor(imageResolver: imageResolver,
                                  lineIdx: LineIndex(source),
                                  baseOffset: baseOffset,
                                  lineBase: lineBase,
                                  gutter: gutter)
    visitor.visit(document)
    return prefix + visitor.result
}

/// An Obsidian-style properties table for the frontmatter block.
func frontmatterTableHTML(_ props: [FMProperty]) -> String {
    var rows = ""
    for property in props {
        let valueHTML: String
        if property.isList {
            valueHTML = property.items
                .map { "<span class=\"fm-chip\">\(htmlEscape($0))</span>" }
                .joined()
        } else if property.value.isEmpty {
            valueHTML = "<span class=\"fm-empty\">—</span>"
        } else {
            valueHTML = htmlEscapeBreakingUnderscores(property.value)
        }
        rows += "<tr><td class=\"fm-key\">\(htmlEscape(property.key))</td>"
            + "<td class=\"fm-val\">\(valueHTML)</td></tr>\n"
    }
    return "<table class=\"frontmatter\"><tbody>\n\(rows)</tbody></table>\n"
}

/// Colors a `yaml`/`yml` code block: keys / values / comments become spans the
/// preview's CSS tints. Concatenated segment texts reproduce the source, so
/// nothing is lost.
func highlightYAMLToHTML(_ code: String) -> String {
    var out = ""
    for (index, line) in code.components(separatedBy: "\n").enumerated() {
        if index > 0 { out += "\n" }
        for (text, kind) in yamlLineSegments(line) {
            if let cssClass = yamlCSSClass(kind) {
                out += "<span class=\"\(cssClass)\">\(htmlEscape(text))</span>"
            } else {
                out += htmlEscape(text)
            }
        }
    }
    return out
}

private func yamlCSSClass(_ kind: YAMLTokenKind) -> String? {
    switch kind {
    case .key: return "yaml-key"
    case .punctuation: return "yaml-punct"
    case .string: return "yaml-string"
    case .number: return "yaml-number"
    case .bool: return "yaml-bool"
    case .null: return "yaml-null"
    case .comment: return "yaml-comment"
    case .plain: return nil
    }
}

private struct HTMLBodyVisitor: MarkupWalker {
    var result = ""
    let imageResolver: ((String) -> String?)?
    let lineIdx: LineIndex
    /// Added to every AST-derived offset so ranges land in the original
    /// document when frontmatter was stripped before parsing.
    let baseOffset: Int
    /// Newlines before the parsed `source` in the original document.
    let lineBase: Int
    let gutter: PreviewGutterOptions

    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0
    private var inTableHead = false

    init(imageResolver: ((String) -> String?)?,
         lineIdx: LineIndex,
         baseOffset: Int,
         lineBase: Int = 0,
         gutter: PreviewGutterOptions = .off) {
        self.imageResolver = imageResolver
        self.lineIdx = lineIdx
        self.baseOffset = baseOffset
        self.lineBase = lineBase
        self.gutter = gutter
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
        // No data-ln on the wrapper — children (p / nested quote) carry source lines.
        // Otherwise the same line number appears twice (wrapper + first child).
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        openBlock("pre", codeBlock)
        let language = codeBlock.language ?? ""
        if !language.isEmpty {
            result += "<code class=\"language-\(htmlAttributeEscape(language))\">"
        } else {
            result += "<code>"
        }
        let lower = language.lowercased()
        if lower == "yaml" || lower == "yml" {
            result += highlightYAMLToHTML(codeBlock.code)
        } else {
            result += htmlEscape(codeBlock.code)
        }
        result += "</code></pre>\n"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        openBlock("hr", thematicBreak)  // void element: <hr data-ln="…">
        result += "\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML: wrap so the gutter can still mark the starting line.
        openBlock("div", html, classes: ["raw-html"])
        result += html.rawHTML
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
        if let checkbox = listItem.checkbox {
            openBlock("li", listItem, classes: ["task"])
            result += "<input type=\"checkbox\" disabled"
            if checkbox == .checked { result += " checked" }
            result += "> "
        } else {
            openBlock("li", listItem)
        }
        // Unwrap the item's first paragraph (GitHub-style tight rendering) —
        // a block-level <p> would push content below the checkbox/bullet.
        var children = Array(listItem.children)
        if let paragraph = children.first as? Paragraph {
            descendInto(paragraph)
            children.removeFirst()
        }
        for child in children { visit(child) }
        result += "</li>\n"
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
        // Tag runs with source offsets so the Preview toolbar can wrap the
        // real selection (not the first plain-text match in the file).
        let base = mdNSRange(for: text)?.location
        result += Self.inlineDecoratedHTML(s, sourceBase: base)
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
        result += inlineHTML.rawHTML
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) {
        result += "<br>\n"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) {
        result += "\n"
    }
}

// MARK: - Full page for Preview's WKWebView

/// Wraps the rendered body in a standalone page. Colors follow the system
/// appearance via `color-scheme` + CSS system colors, so the WKWebView tracks
/// the app's light/dark toggle without reloading.
///
/// Typography mirrors the editor (FSNotes' getPreviewStyle idea): the body
/// uses the editor's exact font size and page padding matches the editor's
/// `textContainerInset` (`insetH` / `insetV`), so toggling edit↔preview
/// doesn't jump. Top gap under the action strip is controlled by Vertical
/// margin in Settings — not a hardcoded 24px.
func previewHTMLPage(markdown: String,
                     fontSize: CGFloat,
                     insetH: CGFloat = 32,
                     /// Top (and minimum bottom) page padding — Settings ▸ Vertical.
                     insetV: CGFloat = 24,
                     lineHeight: CGFloat = 1.6,
                     /// A centered reading column; `0` disables it (full width,
                     /// left-aligned to `insetH` — matches the editor's inset
                     /// so toggling edit↔preview doesn't shift the text).
                     columnWidth: CGFloat = 0,
                     fontFamily: String = "-apple-system, \"Helvetica Neue\", sans-serif",
                     fontWeight: Int = 400,
                     elements: ElementStyles = ElementStyles(),
                     /// Base text / link color overrides (hex). Nil keeps the
                     /// adaptive system colors (Canvas/CanvasText/LinkText).
                     textColorHex: String? = nil,
                     accentColorHex: String? = nil,
                     gutter: PreviewGutterOptions = .off,
                     imageResolver: ((String) -> String?)? = nil) -> String {
    let body = markdownHTMLBody(markdown, imageResolver: imageResolver, gutter: gutter)
    let maxWidth = columnWidth > 0 ? "\(Int(columnWidth))px" : "none"
    let margin = columnWidth > 0 ? "0 auto" : "0"
    let bodyColor = textColorHex ?? "CanvasText"
    // Bottom keeps a comfortable scroll pad when Vertical is small; top is
    // exactly insetV so the strip→title gap matches Source/Visual.
    let padTop = Int(insetV.rounded())
    let padBottom = Int(max(64, insetV).rounded())
    let padH = Int(insetH.rounded())
    let gutterOn = gutter.isVisible
    // Same digit size as Source/Visual ruler (`GutterTypography.fontSize`).
    let lnFontPx = Int(GutterTypography.fontSize.rounded())
    let lnColPx = max(28, lnFontPx * max(2, String(max(99, gutter.dirtyLines.max() ?? 999)).count) + 10)
    let dirtyColor = gutter.dirtyMarkColorHex.isEmpty ? "#1a8f3c" : gutter.dirtyMarkColorHex
    let bodyGutterClass = gutterOn ? " class=\"\(gutter.modeClass)\"" : ""
    // Extra left padding reserves one shared gutter plus a comfortable gap.
    let lineNumberGapPx = 18
    let padHLeft = gutterOn ? padH + lnColPx + lineNumberGapPx : padH

    // Per-element rules generated from ElementStyles — appended after the base
    // rules so they win. Heading size uses `em` (= the scale), matching how
    // Visual multiplies its base size, so the two modes stay consistent.
    func numstr(_ v: CGFloat) -> String { String(format: "%.4g", v) }
    var elementCSS = ""
    for level in 1...6 {
        let e = elements.heading(level)
        var decl = "font-size: \(numstr(e.sizeScale))em;"
        if let w = e.weight { decl += " font-weight: \(w.cssValue);" }
        if let c = e.colorHex { decl += " color: \(c);" }
        elementCSS += "h\(level) { \(decl) }\n"
    }
    var boldDecl = ""
    if let w = elements.bold.weight { boldDecl += "font-weight: \(w.cssValue);" }
    if let c = elements.bold.colorHex { boldDecl += " color: \(c);" }
    if !boldDecl.isEmpty { elementCSS += "strong, b { \(boldDecl) }\n" }
    if let c = elements.inlineCode.colorHex { elementCSS += "code { color: \(c); }\n" }
    if let c = elements.link.colorHex ?? accentColorHex { elementCSS += "a { color: \(c); }\n" }
    if let c = elements.quote.colorHex { elementCSS += "blockquote { color: \(c); opacity: 1; }\n" }

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
    :root {
        color-scheme: light dark;
        --ln-dirty: \(dirtyColor);
        --ln-col: \(lnColPx)px;
        --ln-size: \(lnFontPx)px;
        --ln-gap: \(lineNumberGapPx)px;
    }
    * { box-sizing: border-box; }
    body {
        font: \(fontWeight) \(Int(fontSize))px/\(numstr(lineHeight)) \(fontFamily);
        background: Canvas; color: \(bodyColor);
        max-width: \(maxWidth); margin: \(margin); padding: \(padTop)px \(padH)px \(padBottom)px \(padHLeft)px;
        word-wrap: break-word;
        position: relative;
    }
    /* Integrated source-line gutter in the left padding. Fixed small mono size
       (not 1em) so headings don't blow up the numbers. */
    [data-ln] { position: relative; }
    [data-ln]::before {
        position: absolute;
        top: 0.2em;
        /* JS below replaces this fallback with a document-global x position.
           Every element has a different local origin (lists, quotes, tables),
           so a percentage/right-based gutter cannot form one visual column. */
        left: var(--ln-left, calc(-1 * (var(--ln-col) + var(--ln-gap))));
        width: var(--ln-col);
        text-align: right;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: var(--ln-size);
        font-weight: 400;
        font-variant-numeric: tabular-nums;
        color: rgba(128,128,128,0.7);
        line-height: 1.2;
        user-select: none;
        pointer-events: none;
        white-space: nowrap;
    }
    /* Headings: pin number to the first text line, not the block center. */
    h1[data-ln]::before, h2[data-ln]::before, h3[data-ln]::before,
    h4[data-ln]::before, h5[data-ln]::before, h6[data-ln]::before {
        top: 0.35em;
        font-size: var(--ln-size);
        font-weight: 400;
    }
    body.gutter-numbers [data-ln]::before { content: attr(data-ln); }
    body.gutter-bullets [data-ln].ln-dirty::before {
        content: "●";
        color: var(--ln-dirty);
        font-size: calc(var(--ln-size) * 0.7);
    }
    body.gutter-bullets [data-ln]:not(.ln-dirty)::before { content: none; }
    [data-ln].ln-dirty::before {
        color: var(--ln-dirty);
        font-weight: 700;
    }
    /* First block must not add extra top margin on top of body padding —
       otherwise Settings ▸ Vertical never reaches zero under the action strip. */
    body > :first-child { margin-top: 0; }
    h1, h2, h3, h4, h5, h6 { font-weight: 600; line-height: 1.25; margin: 1.4em 0 0.5em; }
    h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.25em; }
    h4 { font-size: 1em; } h5 { font-size: 0.875em; } h6 { font-size: 0.85em; opacity: 0.7; }
    h1, h2 { border-bottom: 1px solid rgba(128,128,128,0.3); padding-bottom: 0.3em; }
    p { margin: 0.6em 0; }
    a { color: LinkText; text-decoration: none; }
    a:hover { text-decoration: underline; }
    a.wikilink { cursor: pointer; }
    code {
        font: 0.9em ui-monospace, "SF Mono", Menlo, monospace;
        background: rgba(128,128,128,0.15);
        border-radius: 4px; padding: 0.15em 0.35em;
    }
    pre {
        background: rgba(175,82,222,0.09);
        border: 1px solid rgba(175,82,222,0.28);
        border-radius: 8px; padding: 14px 16px; overflow-x: auto;
    }
    pre code { background: none; padding: 0; font-size: 0.875em; }
    blockquote {
        margin: 0.8em 0; padding: 0.1em 1em;
        border-left: 4px solid rgba(0,122,255,0.68);
        border-radius: 0 7px 7px 0;
        background: rgba(0,122,255,0.07);
        opacity: 0.9;
    }
    ul, ol { padding-left: 1.7em; margin: 0.6em 0; }
    li { margin: 0.2em 0; }
    li > p { margin: 0.2em 0; }
    li.task { list-style: none; margin-left: -1.35em; }
    li.task input { margin-right: 0.4em; vertical-align: -0.1em; }
    hr { border: none; border-top: 2px solid rgba(128,128,128,0.3); margin: 1.6em 0; }
    table { border-collapse: collapse; margin: 1em 0; display: block; overflow-x: auto; }
    th, td { border: 1px solid rgba(128,128,128,0.35); padding: 6px 13px; }
    th { font-weight: 600; }
    tbody tr:nth-child(odd) { background: rgba(128,128,128,0.07); }
    img { max-width: 100%; }
    del { opacity: 0.6; }
    mark {
        background: rgba(255, 212, 0, 0.45);
        color: inherit;
        border-radius: 2px;
        padding: 0 0.12em;
    }
    @media (prefers-color-scheme: dark) {
        mark { background: rgba(255, 196, 0, 0.35); }
        pre {
            background: rgba(191,90,242,0.12);
            border-color: rgba(191,90,242,0.36);
        }
        blockquote {
            background: rgba(10,132,255,0.11);
            border-left-color: rgba(10,132,255,0.78);
        }
    }
    /* Review-mark wash (v37) — open smotr anchors painted over data-md-lo spans.
       Preview is the primary review surface; Source/Visual washes are secondary. */
    [data-md-lo].review-wash {
        border-radius: 2px;
        box-decoration-break: clone;
        -webkit-box-decoration-break: clone;
    }
    [data-md-lo].review-question { background: rgba(0, 122, 255, 0.18); }
    [data-md-lo].review-fix { background: rgba(255, 149, 0, 0.18); }
    [data-md-lo].review-rewrite { background: rgba(175, 82, 222, 0.18); }
    [data-md-lo].review-cut { background: rgba(255, 59, 48, 0.16); }
    [data-md-lo].review-keep { background: rgba(142, 142, 147, 0.18); }
    [data-md-lo].review-comment { background: rgba(255, 204, 0, 0.22); }
    [data-md-lo].review-suggest { background: rgba(52, 199, 89, 0.18); }
    [data-md-lo].review-wash.review-flash {
        outline: 2px solid rgba(0, 122, 255, 0.55);
        outline-offset: 1px;
    }
    /* Obsidian-style frontmatter properties */
    table.frontmatter {
        display: table; width: 100%; border-collapse: collapse;
        margin: 0 0 1.4em; font-size: 0.9em;
        background: rgba(128,128,128,0.05);
        border: 1px solid rgba(128,128,128,0.22); border-radius: 8px; overflow: hidden;
    }
    table.frontmatter td {
        border: none; border-bottom: 1px solid rgba(128,128,128,0.12);
        padding: 6px 12px; vertical-align: top;
    }
    table.frontmatter tr:last-child td { border-bottom: none; }
    table.frontmatter tbody tr { background: none; }
    td.fm-key { color: rgba(128,128,128,0.95); font-weight: 500; width: 1%; white-space: nowrap; }
    td.fm-val { color: inherit; }
    .fm-chip {
        display: inline-block; background: rgba(128,128,128,0.16); border-radius: 4px;
        padding: 1px 8px; margin: 1px 4px 1px 0; font-size: 0.92em;
    }
    .fm-empty { opacity: 0.4; }
    /* D4: copy button on code / quote (hover) */
    .copy-host { position: relative; }
    .copy-block-btn {
        position: absolute;
        top: 6px;
        right: 6px;
        z-index: 2;
        opacity: 0.72;
        pointer-events: auto;
        border: none;
        min-width: 32px;
        min-height: 32px;
        border-radius: 7px;
        padding: 4px 8px;
        font: 17px/1 ui-monospace, Menlo, monospace;
        background: rgba(128,128,128,0.18);
        color: inherit;
        cursor: pointer;
        transition: opacity 0.12s ease;
    }
    .copy-host:hover > .copy-block-btn { opacity: 1; }
    .copy-block-btn:hover { background: rgba(128,128,128,0.32); }
    /* yaml code-block syntax colors */
    .yaml-key { color: #6f42c1; }
    .yaml-string { color: #0a7d33; }
    .yaml-number { color: #0550ae; }
    .yaml-bool, .yaml-null { color: #953800; }
    .yaml-comment { color: #6e7781; font-style: italic; }
    .yaml-punct { color: #57606a; }
    @media (prefers-color-scheme: dark) {
        .yaml-key { color: #d2a8ff; }
        .yaml-string { color: #7ee787; }
        .yaml-number { color: #79c0ff; }
        .yaml-bool, .yaml-null { color: #ffa657; }
        .yaml-comment { color: #8b949e; }
        .yaml-punct { color: #8b949e; }
    }
    \(elementCSS)</style>
    </head>
    <body\(bodyGutterClass)>
    \(body)
    <script>
    // Align every source-line marker to one document-global column. `data-ln`
    // lives on blocks with different local x origins (nested lists/quotes), so
    // pure element-relative CSS produces a ragged gutter. Recompute on resize
    // because a centered reading column moves with the viewport.
    (function () {
        function alignLineNumberGutter() {
            var bodyStyle = getComputedStyle(document.body);
            var contentLeft = document.body.getBoundingClientRect().left
                + parseFloat(bodyStyle.paddingLeft || '0');
            var rootStyle = getComputedStyle(document.documentElement);
            var columnWidth = parseFloat(rootStyle.getPropertyValue('--ln-col')) || 28;
            var gap = parseFloat(rootStyle.getPropertyValue('--ln-gap')) || 18;
            var desiredLeft = contentLeft - gap - columnWidth;
            document.querySelectorAll('[data-ln]').forEach(function (el) {
                var localLeft = desiredLeft - el.getBoundingClientRect().left;
                el.style.setProperty('--ln-left', localLeft + 'px');
            });
        }
        alignLineNumberGutter();
        window.addEventListener('resize', alignLineNumberGutter);
        window.alignLineNumberGutter = alignLineNumberGutter;
    })();
    // Interactive task checkboxes (FSNotes' HandlerCheckbox idea): the body
    // fragment renders them disabled; the live preview re-enables them and
    // reports the clicked index — document order matches the order of
    // taskListMarker spans, which the Swift side uses to edit the source.
    document.querySelectorAll('li.task > input[type=checkbox]').forEach(function (box, i) {
        box.disabled = false;
        box.addEventListener('change', function () {
            var handlers = window.webkit && window.webkit.messageHandlers;
            if (handlers && handlers.taskToggle) { handlers.taskToggle.postMessage(i); }
        });
    });
    // Wiki-link navigation: report a click; the Swift side resolves target →
    // file and opens it. Handler may be absent (no-op) until wired.
    document.querySelectorAll('a.wikilink').forEach(function (el) {
        el.addEventListener('click', function (e) {
            e.preventDefault();
            var handlers = window.webkit && window.webkit.messageHandlers;
            if (handlers && handlers.wikiLinkClick) {
                handlers.wikiLinkClick.postMessage({
                    target: el.dataset.wikiTarget,
                    heading: el.dataset.wikiHeading || null,
                    blockID: el.dataset.wikiBlock || null
                });
            }
        });
    });
    // Local file links ([pdf](/research_pdf/x.pdf)): schemeless hrefs cannot
    // resolve against loadHTMLString's about:blank base, so report the raw
    // href; the Swift side resolves it Obsidian-style (vault-absolute /
    // file-relative) and opens the target. Scheme links keep the default
    // navigation path (decidePolicyFor → system).
    document.querySelectorAll('a[href]').forEach(function (el) {
        if (el.classList.contains('wikilink')) return;
        var href = el.getAttribute('href');
        if (!href || href.charAt(0) === '#' || /^[a-zA-Z][a-zA-Z0-9+.\\-]*:/.test(href)) return;
        el.addEventListener('click', function (e) {
            e.preventDefault();
            var handlers = window.webkit && window.webkit.messageHandlers;
            if (handlers && handlers.localLinkClick) {
                handlers.localLinkClick.postMessage({ href: href });
            }
        });
    });
    // Review marks (v37): paint open anchors on tagged spans and jump by
    // markdown UTF-16 offset. Called from Swift after load / mark changes.
    // marks = [{start, end, type, id}]
    window.applyReviewMarks = function (marks) {
        var types = ['question','fix','rewrite','cut','keep','comment','suggest'];
        document.querySelectorAll('[data-md-lo].review-wash').forEach(function (el) {
            el.classList.remove('review-wash', 'review-flash');
            types.forEach(function (t) { el.classList.remove('review-' + t); });
            el.removeAttribute('data-review-id');
            el.removeAttribute('title');
        });
        if (!marks || !marks.length) return;
        document.querySelectorAll('[data-md-lo]').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            var hi = parseInt(el.getAttribute('data-md-hi'), 10);
            if (isNaN(lo) || isNaN(hi)) return;
            for (var i = 0; i < marks.length; i++) {
                var m = marks[i];
                if (hi > m.start && lo < m.end) {
                    el.classList.add('review-wash', 'review-' + (m.type || 'comment'));
                    el.setAttribute('data-review-id', m.id || '');
                    if (m.tip) el.setAttribute('title', m.tip);
                    break; // first matching mark wins (worklist order)
                }
            }
        });
    };
    // Scroll the span covering `offset` into view; fraction fallback is Swift-side.
    window.scrollToMdOffset = function (offset) {
        // A span CONTAINING the offset always beats the nearest-preceding
        // fallback — a later non-containing span must not override it.
        var contain = null, containLo = -1, near = null, nearLo = -1;
        document.querySelectorAll('[data-md-lo]').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            var hi = parseInt(el.getAttribute('data-md-hi'), 10);
            if (isNaN(lo) || isNaN(hi)) return;
            if (lo <= offset && offset < hi) {
                if (lo > containLo) { contain = el; containLo = lo; }
            } else if (lo <= offset && lo > nearLo) {
                near = el; nearLo = lo;
            }
        });
        var best = contain || near;
        if (best) {
            best.scrollIntoView({ block: 'center', behavior: 'smooth' });
            best.classList.add('review-flash');
            setTimeout(function () { best.classList.remove('review-flash'); }, 1200);
            return true;
        }
        return false;
    };
    // D4: hover copy button on code blocks and blockquotes.
    (function () {
        function copyText(text, btn) {
            function ok() {
                var prev = btn.textContent;
                btn.textContent = '✓';
                setTimeout(function () { btn.textContent = prev; }, 1000);
            }
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(ok).catch(function () {
                    fallbackCopy(text); ok();
                });
            } else {
                fallbackCopy(text); ok();
            }
        }
        function fallbackCopy(text) {
            var ta = document.createElement('textarea');
            ta.value = text;
            ta.style.position = 'fixed';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.select();
            try { document.execCommand('copy'); } catch (e) {}
            document.body.removeChild(ta);
        }
        function attach(el) {
            if (el.querySelector('.copy-block-btn')) return;
            // One button per logical quote tree: a nested blockquote belongs
            // to its outer quote and is copied together with it.
            if (el.tagName === 'BLOCKQUOTE' && el.parentElement.closest('blockquote')) return;
            el.classList.add('copy-host');
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.className = 'copy-block-btn';
            btn.textContent = '⎘';
            btn.title = 'Copy';
            btn.addEventListener('click', function (e) {
                e.preventDefault();
                e.stopPropagation();
                var clone = el.cloneNode(true);
                clone.querySelectorAll('.copy-block-btn').forEach(function (b) { b.remove(); });
                copyText(clone.innerText || '', btn);
            });
            el.appendChild(btn);
        }
        document.querySelectorAll('pre, blockquote').forEach(attach);
    })();
    </script>
    </body>
    </html>
    """
}
