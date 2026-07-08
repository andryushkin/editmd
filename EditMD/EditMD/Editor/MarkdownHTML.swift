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

/// Renders markdown to an HTML body fragment.
/// `imageResolver` may replace an image's `src` (e.g. with a data: URI for
/// local files); returning nil keeps the original source.
func markdownHTMLBody(_ text: String,
                      imageResolver: ((String) -> String?)? = nil) -> String {
    var source = text
    var prefix = ""
    // YAML frontmatter isn't part of the markdown grammar — strip it and render
    // it as an Obsidian-style properties table, so it doesn't mangle into a
    // thematic break + setext heading.
    if let fm = frontmatterRange(in: text) {
        let ns = text as NSString
        let props = parseFrontmatterProperties(ns.substring(with: fm.body))
        if !props.isEmpty { prefix = frontmatterTableHTML(props) }
        source = ns.substring(from: NSMaxRange(fm.full))
    }
    let document = Document(parsing: source)
    var visitor = HTMLBodyVisitor(imageResolver: imageResolver)
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

    private var tableColumnAlignments: [Table.ColumnAlignment?]?
    private var currentTableColumn = 0
    private var inTableHead = false

    init(imageResolver: ((String) -> String?)?) {
        self.imageResolver = imageResolver
    }

    // MARK: Block elements

    mutating func visitParagraph(_ paragraph: Paragraph) {
        result += "<p>"
        descendInto(paragraph)
        result += "</p>\n"
    }

    mutating func visitHeading(_ heading: Heading) {
        result += "<h\(heading.level)>"
        descendInto(heading)
        result += "</h\(heading.level)>\n"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        let language = codeBlock.language ?? ""
        if !language.isEmpty {
            result += "<pre><code class=\"language-\(htmlAttributeEscape(language))\">"
        } else {
            result += "<pre><code>"
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
        result += "<hr>\n"
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        result += html.rawHTML
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) {
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
            result += "<li class=\"task\"><input type=\"checkbox\" disabled"
            if checkbox == .checked { result += " checked" }
            result += "> "
        } else {
            result += "<li>"
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
        result += "<table>\n"
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
        let matches = scanWikiLinks(in: s)
        guard !matches.isEmpty else { result += htmlEscapeBreakingUnderscores(s); return }
        let ns = s as NSString
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result += htmlEscapeBreakingUnderscores(
                    ns.substring(with: NSRange(location: cursor,
                                               length: m.range.location - cursor)))
            }
            result += Self.wikiLinkHTML(m.payload)
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            result += htmlEscapeBreakingUnderscores(
                ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)))
        }
    }

    /// A wiki-link as an anchor carrying resolution metadata in data-attributes;
    /// the preview's JS turns a click into a `wikiLinkClick` message (v-next).
    static func wikiLinkHTML(_ p: MDWikiLinkPayload) -> String {
        var a = "<a class=\"wikilink\" data-wiki-target=\"\(htmlAttributeEscape(p.target))\""
        if let h = p.heading { a += " data-wiki-heading=\"\(htmlAttributeEscape(h))\"" }
        if let b = p.blockID { a += " data-wiki-block=\"\(htmlAttributeEscape(b))\"" }
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
        result += "<code>\(htmlEscape(inlineCode.code))</code>"
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
/// uses the editor's exact font size and the page's left inset matches the
/// editor's `textContainerInset`, so toggling edit↔preview doesn't jump.
func previewHTMLPage(markdown: String,
                     fontSize: CGFloat,
                     insetH: CGFloat = 32,
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
                     imageResolver: ((String) -> String?)? = nil) -> String {
    let body = markdownHTMLBody(markdown, imageResolver: imageResolver)
    let maxWidth = columnWidth > 0 ? "\(Int(columnWidth))px" : "none"
    let margin = columnWidth > 0 ? "0 auto" : "0"
    let bodyColor = textColorHex ?? "CanvasText"

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
    :root { color-scheme: light dark; }
    * { box-sizing: border-box; }
    body {
        font: \(fontWeight) \(Int(fontSize))px/\(numstr(lineHeight)) \(fontFamily);
        background: Canvas; color: \(bodyColor);
        max-width: \(maxWidth); margin: \(margin); padding: 24px \(Int(insetH))px 64px;
        word-wrap: break-word;
    }
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
        background: rgba(128,128,128,0.1);
        border-radius: 8px; padding: 14px 16px; overflow-x: auto;
    }
    pre code { background: none; padding: 0; font-size: 0.875em; }
    blockquote {
        margin: 0.8em 0; padding: 0.1em 1em;
        border-left: 3px solid rgba(128,128,128,0.4);
        opacity: 0.75;
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
    <body>
    \(body)
    <script>
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
    </script>
    </body>
    </html>
    """
}
