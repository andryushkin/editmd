import Foundation
import Markdown

// Markdown → HTML for the Preview mode.
//
// swift-markdown's own HTMLFormatter is not used: it does not escape text /
// code content (a code block containing "<div>" would break the page) and it
// drops inline formatting inside headings (plainText). This visitor escapes
// everything except author-written raw HTML blocks/inlines, which are passed
// through except executable script tags. Preview is a document viewer, not a
// script host; this also keeps first load and later innerHTML updates consistent.

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func htmlAttributeEscape(_ s: String) -> String {
    htmlEscape(s).replacingOccurrences(of: "\"", with: "&quot;")
}

/// Preserve ordinary Markdown raw HTML while making `<script>` text inert.
/// `innerHTML` does not execute newly inserted scripts, but the initial full
/// page would; neutralizing at the shared renderer gives both paths one rule.
func previewSafeRawHTML(_ raw: String) -> String {
    raw.replacingOccurrences(of: "(?i)<\\s*script\\b", with: "&lt;script",
                             options: .regularExpression)
        .replacingOccurrences(of: "(?i)</\\s*script\\s*>", with: "&lt;/script&gt;",
                              options: .regularExpression)
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

/// Geometry of the Preview line-number rail. It lives in the body's left
/// padding (not in a ruler view like Source/Visual), so the action strip has
/// to add it to reach the text — same numbers as the CSS below.
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

/// A math span prepared for the HTML visitor: full-document range, verbatim
/// TeX, and the number of sentinel units its mask produced (the visitor
/// consumes sentinel runs against this count — a multiline `$$` block is
/// split across several Text nodes by softbreaks).
struct HTMLMathSpan {
    let range: NSRange
    let tex: String
    let display: Bool
    let units: Int
}

/// Body fragment + whether the document contains math (`previewHTMLPage`
/// embeds the KaTeX assets only when it does).
func markdownHTMLRender(_ text: String,
                        imageResolver: ((String) -> String?)? = nil,
                        gutter: PreviewGutterOptions = .off,
                        syntaxHighlighting: Bool = true)
    -> (body: String, hasMath: Bool) {
    let pluginSnapshot = BuiltInPluginRegistry.snapshot(for: text)
    let pluginDiagnostics = BuiltInPluginRegistry.configurationDiagnostics(in: text)
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
        let fmLine = 1
        let dirty = gutter.highlightChangedLines && gutter.dirtyLines.contains(fmLine)
        let wantMark = gutter.showLineNumbers
            || (dirty && gutter.showDirtyBulletsWhenNoNumbers)
        let fmAttributes = wantMark ? " data-ln=\"\(fmLine)\"" : ""
        let fmClasses = dirty ? " ln-dirty" : ""
        if !props.isEmpty || !pluginSnapshot.activations.isEmpty || !pluginDiagnostics.isEmpty {
            prefix = frontmatterPropertiesHTML(
                props, pluginSnapshot: pluginSnapshot,
                pluginDiagnostics: pluginDiagnostics,
                additionalClasses: fmClasses, attributes: fmAttributes)
        }
        baseOffset = NSMaxRange(fm.full)
        source = ns.substring(from: baseOffset)
        lineBase = ns.substring(to: baseOffset).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }
    // Math is extracted BEFORE parsing: cmark would mangle TeX (`\{`/`\\`
    // escapes, `_`/`*` emphasis). The mask is UTF-16-length-preserving, so
    // every offset from the masked parse is valid in the original document.
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
    // LineIndex maps AST SourceRanges → UTF-16 offsets in the parsed string;
    // it MUST be built from `parseSource` (cmark columns are UTF-8 bytes of
    // what it parsed; the sentinel is 3 bytes vs the original chars). The
    // resulting UTF-16 offsets are valid in the original document. baseOffset
    // rebases them past stripped frontmatter (for Preview toolbar wrap).
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
    return (prefix + visitor.result, !mathSpans.isEmpty)
}

/// An Obsidian-inspired properties panel for the frontmatter block. It is
/// deliberately not a bordered table: lengthy values and tag collections need
/// room to breathe, while the source YAML remains untouched in Source mode.
func frontmatterPropertiesHTML(_ props: [FMProperty],
                               pluginSnapshot: BuiltInPluginSnapshot = .empty,
                               pluginDiagnostics: [BuiltInPluginConfigurationDiagnostic] = [],
                               additionalClasses: String = "",
                               attributes: String = "") -> String {
    var rows = ""
    let visibleProperties = pluginSnapshot.activations.isEmpty && pluginDiagnostics.isEmpty
        ? props
        : props.filter { $0.key.lowercased() != "editmd" }
    for property in visibleProperties {
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
        rows += "<div class=\"fm-row\">\(frontmatterIconHTML(for: property))"
            + "<div class=\"fm-key\">\(htmlEscape(property.key))</div>"
            + "<div class=\"fm-val\">\(valueHTML)</div></div>\n"
    }
    let pluginHTML = builtInPluginConfigurationHTML(pluginSnapshot)
        + builtInPluginDiagnosticHTML(pluginDiagnostics)
    let listHTML = rows.isEmpty ? "" : "<div class=\"fm-list\">\n\(rows)</div>"
    return "<section class=\"frontmatter\(additionalClasses)\"\(attributes)>"
        + "<button type=\"button\" class=\"fm-title\" aria-expanded=\"true\">"
        + "<span class=\"fm-disclosure\" aria-hidden=\"true\"><svg viewBox=\"0 0 20 20\"><path d=\"m5 7 5 5 5-5\"/></svg></span>"
        + "<span>" + htmlEscape(frontmatterDisplayTitle) + "</span></button>"
        + "<div class=\"fm-content\">" + listHTML + pluginHTML + "</div>"
        + "</section>\n"
}

private func builtInPluginDiagnosticHTML(
    _ diagnostics: [BuiltInPluginConfigurationDiagnostic]) -> String {
    diagnostics.map { diagnostic in
        """
        <section class="fm-plugin-editor fm-plugin-invalid" data-plugin-id="\(htmlAttributeEscape(diagnostic.descriptor.id))">
          <div class="fm-plugin-heading"><div><h3>\(htmlEscape(diagnostic.descriptor.name))</h3><p>\(htmlEscape(diagnostic.descriptor.summary))</p></div><span class="fm-plugin-error-badge">Needs attention</span></div>
          <p class="fm-plugin-error" role="alert">\(htmlEscape(diagnostic.message))</p>
          <p class="fm-plugin-help">Fix this plugin block in Source mode.</p>
        </section>
        """
    }.joined(separator: "\n")
}

private func builtInPluginConfigurationHTML(_ snapshot: BuiltInPluginSnapshot) -> String {
    snapshot.activations.compactMap { activation -> String? in
        guard let payload = activation.initialChecklistPayload else { return nil }
        let pluginID = htmlAttributeEscape(activation.descriptor.id)
        let states = payload.states.enumerated().map { index, state in
            let marker = (state.source as NSString).substring(
                with: NSRange(location: 1, length: max(0, (state.source as NSString).length - 2)))
            let iconKind: String
            let iconValue: String
            let iconPreview: String
            var iconWarning = ""
            switch state.icon {
            case .sfSymbol(let name):
                iconKind = "sf"
                iconValue = name
                if let uri = sfSymbolPNGDataURI(name: name, label: state.label) {
                    iconPreview = "<img src=\"\(uri)\" alt=\"\">"
                } else {
                    iconPreview = "<span aria-hidden=\"true\">\(htmlEscape(state.source))</span>"
                    iconWarning = "Unknown SF Symbol: \(name)"
                }
            case .emoji(let value):
                iconKind = "emoji"
                iconValue = value
                iconPreview = "<span aria-hidden=\"true\">\(htmlEscape(value))</span>"
            case .text(let value):
                iconKind = "text"
                iconValue = value
                iconPreview = "<span aria-hidden=\"true\">\(htmlEscape(value))</span>"
            }
            let select = ["emoji", "sf", "text"].map { kind in
                let selected = kind == iconKind ? " selected" : ""
                let title = kind == "sf" ? "SF Symbol" : kind.capitalized
                return "<option value=\"\(kind)\"\(selected)>\(title)</option>"
            }.joined()
            let strike = state.strikethrough ? " checked" : ""
            let inputID = "fm-plugin-\(pluginID)-icon-\(index)"
            return """
            <div class="fm-plugin-state" data-plugin-id="\(pluginID)" data-state-index="\(index)" data-state-source="\(htmlAttributeEscape(state.source))" data-icon-kind="\(iconKind)">
              <div class="fm-plugin-icon-preview" aria-hidden="true">\(iconPreview)</div>
              <label class="fm-plugin-field fm-plugin-marker-field"><span>Marker</span><input class="fm-plugin-marker" data-plugin-control="marker" type="text" maxlength="1" value="\(htmlAttributeEscape(marker))"></label>
              <label class="fm-plugin-field fm-plugin-label-field"><span>Name</span><input class="fm-plugin-label" data-plugin-control="label" type="text" value="\(htmlAttributeEscape(state.label))"></label>
              <label class="fm-plugin-field fm-plugin-icon-field"><span>Icon</span><span class="fm-plugin-icon-control"><select class="fm-plugin-icon-kind" data-plugin-control="icon-kind">\(select)</select><input id="\(inputID)" class="fm-plugin-icon-value" data-plugin-control="icon-value" type="text" value="\(htmlAttributeEscape(iconValue))"><button type="button" class="fm-plugin-emoji-picker" title="Open Emoji &amp; Symbols" aria-label="Open Emoji &amp; Symbols">☺︎</button></span></label>
              <label class="fm-plugin-strike"><input data-plugin-control="strikethrough" type="checkbox"\(strike)> Strike</label>
              <p class="fm-plugin-validation" role="status" data-icon-warning="\(htmlAttributeEscape(iconWarning))">\(htmlEscape(iconWarning))</p>
            </div>
            """
        }.joined(separator: "\n")
        return """
        <section class="fm-plugin-editor" data-plugin-id="\(pluginID)">
          <div class="fm-plugin-heading"><div><h3>\(htmlEscape(activation.descriptor.name))</h3><p>\(htmlEscape(activation.descriptor.summary))</p></div><span class="fm-plugin-enabled">Enabled</span></div>
          <div class="fm-plugin-states">\(states)</div>
          <button type="button" class="fm-plugin-add-state" data-plugin-id="\(pluginID)">+ Add state</button>
          <p class="fm-plugin-help">Changes are saved to frontmatter. State order defines the click cycle.</p>
        </section>
        """
    }.joined(separator: "\n")
}

/// Small inline SVGs keep the Preview independent of system font glyphs while
/// matching the Properties inspector heuristics (`frontmatterFieldIconKind`).
private func frontmatterIconHTML(for property: FMProperty) -> String {
    let svg: String
    switch frontmatterFieldIconKind(key: property.key, value: property.value) {
    case .tags:
        svg = #"<svg viewBox="0 0 24 24"><path d="M20 13.5 13.5 20a2.1 2.1 0 0 1-3 0L3 12.5V4h8.5L20 10.5a2.1 2.1 0 0 1 0 3Z"/><circle cx="7.5" cy="8.5" r="1"/></svg>"#
    case .date:
        svg = #"<svg viewBox="0 0 24 24"><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4m8-4v4"/></svg>"#
    case .file:
        svg = #"<svg viewBox="0 0 24 24"><path d="M6 3h8l4 4v14H6zM14 3v5h5M9 13h6m-6 4h6"/></svg>"#
    case .graph:
        svg = #"<svg viewBox="0 0 24 24"><circle cx="6" cy="6" r="2"/><circle cx="18" cy="7" r="2"/><circle cx="12" cy="18" r="2"/><path d="m7.7 7.1 2.8 9M16.2 8.4l-2.8 8M8 6.3l8 .5"/></svg>"#
    case .number:
        svg = #"<svg viewBox="0 0 24 24"><path d="M9 3 7 21M17 3l-2 18M4 9h16M3 15h16"/></svg>"#
    case .text:
        svg = #"<svg viewBox="0 0 24 24"><path d="M5 6h14M5 12h14M5 18h14"/></svg>"#
    }
    return "<span class=\"fm-icon\" aria-hidden=\"true\">\(svg)</span>"
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
    /// Added to every AST-derived offset so ranges land in the original
    /// document when frontmatter was stripped before parsing.
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

    /// SOURCE range of each RENDERED code line, in document order.
    ///
    /// Taken from the source text, not from `codeBlock.code`: an indented
    /// block's code has had its indent stripped, so the two disagree on where a
    /// line ends. A fenced block's first source line is the opening fence, which
    /// the DOM never shows; an indented block starts with code straight away.
    /// Counting lines cannot tell them apart (a source range may include a
    /// trailing blank line), so read the opening line and look for a fence.
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
        // No data-ln on the wrapper — children (p / nested quote) carry source lines.
        // Otherwise the same line number appears twice (wrapper + first child).
        result += "<blockquote>\n"
        descendInto(blockQuote)
        result += "</blockquote>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        // Every rendered code LINE gets its own `data-md-lo/hi` span: without
        // anchors inside the block, split-scroll sync has nothing to interpolate
        // between and the follow stalls until the block ends.
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
            // Keep language-* first for existing integrations that match the
            // literal class prefix, then add the highlighter marker.
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
        // Tag runs with source offsets so the Preview toolbar can wrap the
        // real selection (not the first plain-text match in the file).
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
                    // No AST source range and no remaining semantic token: keep
                    // the failure visible without leaking the private-use mask.
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

    /// Sentinel-run accounting: the FIRST run of a span emits its HTML; the
    /// remaining runs (continuation lines of a `$$` block, split by
    /// softbreaks/paragraphs) are consumed silently against `units`.
    private mutating func consumeSentinelRun(_ count: Int) {
        var remaining = count
        while remaining > 0 {
            if pendingMathUnits > 0 {
                let take = min(pendingMathUnits, remaining)
                pendingMathUnits -= take
                remaining -= take
                continue
            }
            // Orphan sentinels (a document that itself contains U+E000) —
            // nothing sane to emit.
            guard mathCursor < mathSpans.count else { return }
            let span = mathSpans[mathCursor]
            mathCursor += 1
            emitMath(span)
            pendingMathUnits = span.units
        }
    }

    /// `data-md-lo/hi` keep scroll/review-wash working; `data-md-code` marks
    /// the KaTeX DOM as a selection island (rendered text ≠ source offsets),
    /// same as rendered code. The page script replaces the escaped TeX content
    /// with KaTeX output (`katex.render` on textContent).
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

// MARK: - Full page for Preview's WKWebView

/// A rendered Preview page plus the one capability of its shell that outlives
/// the load: whether the KaTeX assets are actually embedded in it.
///
/// The live `innerHTML` path needs that bit to decide when a document that
/// grew its first formula requires a new shell. It MUST come from here rather
/// than a second scan of the markdown: `markdownHTMLRender` strips YAML
/// frontmatter before it looks for math, so `$…$` inside frontmatter would
/// otherwise claim assets the page never received — and every later formula in
/// the body would sit there as raw TeX, because no reload was ever triggered.
struct PreviewPageRender {
    let html: String
    let hasMathAssets: Bool
}

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
                     insetV: CGFloat = 24,
                     lineHeight: CGFloat = 1.6,
                     columnWidth: CGFloat = 0,
                     fontFamily: String = "-apple-system, \"Helvetica Neue\", sans-serif",
                     fontWeight: Int = 400,
                     elements: ElementStyles = ElementStyles(),
                     textColorHex: String? = nil,
                     accentColorHex: String? = nil,
                     gutter: PreviewGutterOptions = .off,
                     syntaxHighlighting: Bool = true,
                     imageResolver: ((String) -> String?)? = nil) -> String {
    previewHTMLPageRender(
        markdown: markdown, fontSize: fontSize, insetH: insetH, insetV: insetV,
        lineHeight: lineHeight, columnWidth: columnWidth, fontFamily: fontFamily,
        fontWeight: fontWeight, elements: elements, textColorHex: textColorHex,
        accentColorHex: accentColorHex, gutter: gutter,
        syntaxHighlighting: syntaxHighlighting, imageResolver: imageResolver).html
}

/// `previewHTMLPage` plus the shell's KaTeX capability bit (see `PreviewPageRender`).
func previewHTMLPageRender(markdown: String,
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
                           syntaxHighlighting: Bool = true,
                           imageResolver: ((String) -> String?)? = nil) -> PreviewPageRender {
    let (body, hasMath) = markdownHTMLRender(markdown, imageResolver: imageResolver,
                                             gutter: gutter,
                                             syntaxHighlighting: syntaxHighlighting)
    // KaTeX is ~640 KB inline (JS + CSS with data-URI fonts) — embedded only
    // when the document actually contains math. Without the assets the page
    // shows raw TeX (`.math` spans keep their escaped source text).
    let mathAssets = hasMath && KaTeXResources.isAvailable
    let mathHead = mathAssets ? "<style>\n\(KaTeXResources.css)\n</style>" : ""
    // Preview is a document viewer, not a script host — and a markdown file is
    // untrusted input (a vault syncs, a repo is cloned). A nonce'd script-src
    // is what actually enforces that: the shell's own scripts carry the nonce,
    // while raw-HTML `<script>` AND inline event handlers (`<img onerror=…>`,
    // the vector `previewSafeRawHTML` alone cannot reach) have none and never
    // run. Verified against WebKit: WKUserScript (the selection bridge) and
    // evaluateJavaScript/callAsyncJavaScript are host-privileged and bypass CSP,
    // and `el.onclick = fn` from our own script keeps working — only handlers
    // parsed out of markup are blocked. Styles stay 'unsafe-inline': the page
    // bakes its CSS inline and hljs tokens carry `style="--tl:…"`.
    let scriptNonce = UUID().uuidString
    let csp = "default-src 'none'; "
        + "img-src data: https: http:; media-src data: https: http:; "
        + "style-src 'unsafe-inline'; font-src data:; "
        + "script-src 'nonce-\(scriptNonce)'"
    // The library stays outside #preview-content so live innerHTML replacement
    // cannot remove it. Rendering newly inserted math is handled by the shared
    // hydrate function below rather than a one-shot page-load script.
    let mathScripts = mathAssets ? """
    <script nonce="\(scriptNonce)">
    \(KaTeXResources.js)
    </script>
    """ : ""
    let maxWidth = columnWidth > 0 ? "\(Int(columnWidth))px" : "none"
    let margin = columnWidth > 0 ? "0 auto" : "0"
    let bodyColor = textColorHex ?? "CanvasText"
    let accentColor = accentColorHex ?? "LinkText"
    // Bottom keeps a comfortable scroll pad when Vertical is small; top is
    // exactly insetV so the strip→title gap matches Source/Visual.
    let padTop = Int(insetV.rounded())
    let padBottom = Int(max(64, insetV).rounded())
    let padH = Int(insetH.rounded())
    let gutterOn = gutter.isVisible
    // Same digit size as Source/Visual ruler (`GutterTypography.fontSize`).
    let lnFontPx = Int(GutterTypography.fontSize.rounded())
    let lnColPx = Int(PreviewGutterMetrics.columnPx(for: gutter))
    let dirtyColor = gutter.dirtyMarkColorHex.isEmpty ? "#1a8f3c" : gutter.dirtyMarkColorHex
    let bodyGutterClass = gutterOn ? " class=\"\(gutter.modeClass)\"" : ""
    // Extra left padding reserves one shared gutter plus a comfortable gap.
    let lineNumberGapPx = Int(PreviewGutterMetrics.gapPx)
    let padHLeft = padH + Int(PreviewGutterMetrics.railPx(for: gutter))

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

    let html = """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(csp)">
    <style>
    :root {
        color-scheme: light dark;
        --ln-dirty: \(dirtyColor);
        --ln-col: \(lnColPx)px;
        --ln-size: \(lnFontPx)px;
        --ln-gap: \(lineNumberGapPx)px;
        --accent: \(accentColor);
    }
    * { box-sizing: border-box; }
    /* WebKit's native scroll anchoring races our split-view restoration after
       innerHTML replacement and produces a visible up/down twitch. The Preview
       owns anchoring explicitly below. */
    html, body, #preview-content { overflow-anchor: none; }
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
    #preview-content > :first-child { margin-top: 0; }
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
        border-radius: 8px; padding: 14px 16px;
        /* NOT overflow-x here: that clips the gutter number, which is an
           absolutely-positioned ::before sitting left of the block. The code
           itself scrolls instead. */
        overflow: visible;
    }
    pre code {
        background: none; padding: 0; font-size: 0.875em;
        display: block; overflow-x: auto;
    }
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
    .multi-checkbox {
        appearance: none; border: 0; background: transparent; color: var(--accent);
        font: inherit; line-height: 1; padding: 0 0.18em; margin: 0 0.18em 0 0;
        cursor: pointer; vertical-align: -0.08em;
    }
    .multi-checkbox:not(:disabled):hover { background: rgba(128,128,128,0.13); border-radius: 4px; }
    .multi-checkbox:disabled { cursor: default; }
    .multi-checkbox:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .multi-checkbox-sf { width: 1em; height: 1em; object-fit: contain; vertical-align: -0.12em; }
    li.multi-task-strike { text-decoration: line-through; opacity: 0.68; }
    li.multi-task-strike > .multi-checkbox { text-decoration: none; opacity: 1; }
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
    /* Obsidian-inspired frontmatter properties. This is a definition-list
       grid rather than a table: no boxed rows, clearer scanning and proper
       wrapping for long paper titles. */
    .frontmatter {
        margin: 0 0 2.1em;
        max-width: none;
    }
    .frontmatter.is-collapsed { margin-bottom: 1.1em; }
    .fm-title {
        display: flex;
        align-items: center;
        gap: 0.38em;
        width: 100%;
        margin: 0 0 1.05em;
        padding: 0;
        border: none;
        border-radius: 4px;
        appearance: none;
        background: transparent;
        color: inherit;
        cursor: pointer;
        font-family: inherit;
        font-size: 1.45em;
        font-weight: 650;
        line-height: 1.2;
        text-align: left;
    }
    .fm-title:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
    .frontmatter.is-collapsed .fm-title { margin-bottom: 0; }
    .fm-disclosure {
        display: inline-flex;
        flex: 0 0 auto;
        width: 0.82em;
        height: 0.82em;
        transition: transform 120ms ease;
    }
    .fm-disclosure svg { width: 100%; height: 100%; overflow: visible; }
    .fm-disclosure path {
        fill: none;
        stroke: currentColor;
        stroke-width: 2;
        stroke-linecap: round;
        stroke-linejoin: round;
    }
    .frontmatter.is-collapsed .fm-disclosure { transform: rotate(-90deg); }
    .fm-content[hidden] { display: none !important; }
    .fm-list { margin: 0; }
    .fm-row {
        display: grid;
        grid-template-columns: 20px minmax(0, 120px) minmax(0, 1fr);
        column-gap: 0;
        align-items: start;
        margin: 0 0 0.82em;
    }
    .fm-row:last-child { margin-bottom: 0; }
    .fm-key {
        grid-column: 2;
        margin: 0;
        min-width: 0;
        color: rgba(128,128,128,0.96);
        font-size: 0.94em;
        font-weight: 500;
        line-height: 1.5;
        overflow-wrap: anywhere;
    }
    .fm-icon {
        grid-column: 1;
        display: flex;
        width: 20px;
        height: 1.5em;
        color: rgba(128,128,128,0.82);
        align-items: center;
        padding: 0;
    }
    .fm-icon svg {
        display: block;
        width: 18px;
        height: 18px;
        fill: none;
        stroke: currentColor;
        stroke-width: 1.8;
        stroke-linecap: round;
        stroke-linejoin: round;
    }
    .fm-val {
        grid-column: 3;
        margin: 0;
        min-width: 0;
        overflow-wrap: anywhere;
    }
    .fm-chip {
        display: inline-block;
        border: 1px solid rgba(128,128,128,0.28);
        border-radius: 999px;
        padding: 0.08em 0.62em;
        margin: 0.05em 0.32em 0.18em 0;
        font-size: 0.9em;
        line-height: 1.35;
    }
    .fm-empty { opacity: 0.4; }
    .fm-plugin-editor {
        margin-top: 1.25em;
        padding: 1em 1.05em;
        border: 1px solid rgba(128,128,128,0.24);
        border-radius: 10px;
        background: rgba(128,128,128,0.055);
    }
    .fm-plugin-heading {
        display: flex;
        align-items: flex-start;
        justify-content: space-between;
        gap: 1em;
        margin-bottom: 0.9em;
    }
    .fm-plugin-heading h3 { margin: 0; font-size: 1em; line-height: 1.35; }
    .fm-plugin-heading p, .fm-plugin-help {
        margin: 0.18em 0 0;
        color: rgba(128,128,128,0.96);
        font-size: 0.82em;
        line-height: 1.4;
    }
    .fm-plugin-enabled {
        flex: 0 0 auto;
        border-radius: 999px;
        padding: 0.12em 0.55em;
        color: #17823b;
        background: rgba(52,199,89,0.14);
        font-size: 0.78em;
        font-weight: 600;
    }
    .fm-plugin-error-badge {
        flex: 0 0 auto;
        border-radius: 999px;
        padding: 0.12em 0.55em;
        color: #b12b24;
        background: rgba(217,74,63,0.14);
        font-size: 0.78em;
        font-weight: 600;
    }
    .fm-plugin-error { margin: 0; color: #b12b24; font-size: 0.86em; }
    .fm-plugin-states { display: grid; gap: 0.55em; }
    .fm-plugin-state {
        display: grid;
        grid-template-columns: 28px minmax(62px, 0.55fr) minmax(120px, 1.15fr) minmax(170px, 1.5fr) auto;
        gap: 0.55em;
        align-items: end;
    }
    .fm-plugin-icon-preview {
        display: flex;
        align-items: center;
        justify-content: center;
        height: 28px;
        padding-bottom: 2px;
        font-size: 1.05em;
    }
    .fm-plugin-icon-preview img { width: 18px; height: 18px; object-fit: contain; }
    .fm-plugin-field { display: grid; gap: 0.18em; min-width: 0; }
    .fm-plugin-field > span:first-child, .fm-plugin-strike {
        color: rgba(128,128,128,0.96);
        font-size: 0.72em;
        font-weight: 500;
    }
    .fm-plugin-field input, .fm-plugin-field select {
        width: 100%;
        min-width: 0;
        height: 28px;
        border: 1px solid rgba(128,128,128,0.3);
        border-radius: 6px;
        padding: 0 0.5em;
        color: inherit;
        background: rgba(255,255,255,0.45);
        font: inherit;
        font-size: 0.82em;
    }
    .fm-plugin-icon-control { display: grid; grid-template-columns: 86px minmax(60px, 1fr) 28px; gap: 0.35em; }
    .fm-plugin-emoji-picker {
        display: none;
        width: 28px;
        height: 28px;
        border: 1px solid rgba(128,128,128,0.3);
        border-radius: 6px;
        color: inherit;
        background: rgba(128,128,128,0.1);
        font: inherit;
        cursor: pointer;
    }
    .fm-plugin-state[data-icon-kind="emoji"] .fm-plugin-emoji-picker { display: block; }
    .fm-plugin-strike {
        display: flex;
        align-items: center;
        gap: 0.32em;
        min-height: 28px;
        white-space: nowrap;
    }
    .fm-plugin-help { margin-top: 0.8em; }
    .fm-plugin-add-state {
        margin-top: 0.75em;
        border: 1px solid rgba(128,128,128,0.3);
        border-radius: 6px;
        padding: 0.28em 0.7em;
        color: inherit;
        background: rgba(128,128,128,0.08);
        font: inherit;
        font-size: 0.8em;
        cursor: pointer;
    }
    .fm-plugin-add-state:hover { background: rgba(128,128,128,0.16); }
    .fm-plugin-validation {
        grid-column: 2 / -1;
        min-height: 1.2em;
        margin: -0.2em 0 0;
        color: #c33b32;
        font-size: 0.75em;
        line-height: 1.2;
    }
    .fm-plugin-state:not(.is-invalid) .fm-plugin-validation:empty { display: none; }
    .fm-plugin-state.is-invalid .fm-plugin-marker { border-color: #d94a3f; }
    @media (prefers-color-scheme: dark) {
        .fm-plugin-field input, .fm-plugin-field select { background: rgba(0,0,0,0.18); }
        .fm-plugin-enabled { color: #62d482; }
        .fm-plugin-error-badge, .fm-plugin-error { color: #ff8178; }
    }
    @media (max-width: 620px) {
        .fm-row { grid-template-columns: 20px 1fr; row-gap: 0.22em; margin-bottom: 0.95em; }
        .fm-key { font-size: 0.88em; }
        .fm-val { grid-column: 2; }
        .fm-plugin-state { grid-template-columns: 28px 65px minmax(0, 1fr); align-items: end; }
        .fm-plugin-icon-field { grid-column: 2 / -1; }
        .fm-plugin-strike { grid-column: 2 / -1; }
    }
    /* Math ($…$ / $$…$$): KaTeX replaces the span content when its assets are
       embedded; before/without that the span shows the raw TeX source.
       Display blocks are LEFT-aligned with an indent (not centered) — and
       KaTeX's own .katex-display centering is overridden to match. */
    .math-display {
        display: block;
        text-align: left;
        padding-left: 2em;
        /* Bigger than the 0.6em paragraph margin it collapses with, so a
           display block gets real air instead of reading as one more line. */
        margin: 1.1em 0;
        overflow-x: auto;
        overflow-y: hidden;
    }
    .math-display .katex-display {
        text-align: left;
        /* overflow-x above makes .math-display a BFC — this margin would add
           to the outer one instead of collapsing into it. */
        margin: 0;
    }
    .math-display .katex-display > .katex {
        text-align: left;
    }
    .math-error {
        color: #cb2431;
        font-family: ui-monospace, "SF Mono", Menlo, monospace;
        font-size: 0.9em;
    }
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
    /* Code tokens carry both palettes (--tl / --td); the page picks one, so a
       Dark Mode switch needs no re-render. */
    \(CodeSyntaxHighlighter.tokenCSS)
    \(elementCSS)</style>
    \(mathHead)
    </head>
    <body\(bodyGutterClass)>
    <main id="preview-content">\(body)</main>
    \(mathScripts)
    <script nonce="\(scriptNonce)">
    window.editMDPreviewRevision = 0;
    // Align every source-line marker to one document-global column. `data-ln`
    // lives on blocks with different local x origins (nested lists/quotes), so
    // pure element-relative CSS produces a ragged gutter. Recompute on resize
    // because a centered reading column moves with the viewport.
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
    window.addEventListener('resize', alignLineNumberGutter);
    window.alignLineNumberGutter = alignLineNumberGutter;
    // Interactive task checkboxes (FSNotes' HandlerCheckbox idea): the body
    // fragment renders them disabled; the live preview re-enables them and
    // reports the clicked index — document order matches the order of
    // taskListMarker spans, which the Swift side uses to edit the source.
    function hydrateTaskCheckboxes() {
        document.querySelectorAll('li.task > input[type=checkbox]').forEach(function (box, i) {
            box.disabled = false;
            // Property assignment is deliberately idempotent: hydrate can run
            // after every fragment replacement without accumulating listeners.
            box.onchange = function () {
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.taskToggle) { handlers.taskToggle.postMessage(i); }
            };
        });
    }
    // Built-in plugins use source offsets rather than document-order indexes:
    // a delayed click is rejected safely if the token moved meanwhile.
    function hydrateBuiltInPluginTokens() {
        document.querySelectorAll('button.multi-checkbox:not(:disabled)').forEach(function (button) {
            button.onclick = function (event) {
                event.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                var offset = Number(button.dataset.pluginOffset);
                if (handlers && handlers.builtInPluginToggle && Number.isFinite(offset)) {
                    handlers.builtInPluginToggle.postMessage(offset);
                }
            };
        });
    }
    function captureBuiltInPluginEditorFocus(root) {
        var active = document.activeElement;
        if (!active || !root.contains(active)) return null;
        var row = active.closest('.fm-plugin-state');
        var control = active.dataset && active.dataset.pluginControl;
        if (!row || !control) return null;
        return {
            pluginID: row.dataset.pluginId,
            stateIndex: Number(row.dataset.stateIndex),
            control: control,
            selectionStart: typeof active.selectionStart === 'number'
                ? active.selectionStart : null,
            selectionEnd: typeof active.selectionEnd === 'number'
                ? active.selectionEnd : null
        };
    }
    function restoreBuiltInPluginEditorFocus(snapshot) {
        if (!snapshot || !Number.isInteger(snapshot.stateIndex)) return false;
        var row = Array.from(document.querySelectorAll('.fm-plugin-state')).find(function (candidate) {
            return candidate.dataset.pluginId === snapshot.pluginID
                && Number(candidate.dataset.stateIndex) === snapshot.stateIndex;
        });
        if (!row) return false;
        var control = Array.from(row.querySelectorAll('[data-plugin-control]')).find(function (candidate) {
            return candidate.dataset.pluginControl === snapshot.control;
        });
        if (!control) return false;
        control.focus({preventScroll: true});
        if (snapshot.selectionStart !== null
            && typeof control.setSelectionRange === 'function') {
            var length = typeof control.value === 'string' ? control.value.length : 0;
            var start = Math.min(snapshot.selectionStart, length);
            var end = Math.min(snapshot.selectionEnd, length);
            try { control.setSelectionRange(start, end); } catch (_) {}
        }
        return document.activeElement === control;
    }
    function hydrateBuiltInPluginConfiguration() {
        function handler() {
            var handlers = window.webkit && window.webkit.messageHandlers;
            return handlers && handlers.builtInPluginConfiguration;
        }
        function context(el) {
            var row = el.closest('.fm-plugin-state');
            return row ? {
                pluginID: row.dataset.pluginId,
                stateIndex: Number(row.dataset.stateIndex),
                expectedSource: row.dataset.stateSource
            } : null;
        }
        function postEdit(el, field, value) {
            var bridge = handler(), ctx = context(el);
            if (!bridge || !ctx || !Number.isInteger(ctx.stateIndex)) return;
            bridge.postMessage({
                action: 'edit', pluginID: ctx.pluginID,
                stateIndex: ctx.stateIndex, expectedSource: ctx.expectedSource,
                field: field, value: value
            });
        }
        document.querySelectorAll('.fm-plugin-state').forEach(function (row) {
            var marker = row.querySelector('.fm-plugin-marker');
            var label = row.querySelector('.fm-plugin-label');
            var kind = row.querySelector('.fm-plugin-icon-kind');
            var icon = row.querySelector('.fm-plugin-icon-value');
            var picker = row.querySelector('.fm-plugin-emoji-picker');
            var strike = row.querySelector('.fm-plugin-strike input');
            var validation = row.querySelector('.fm-plugin-validation');
            var emojiTimer = null;
            row.onfocusin = function () {
                var bridge = handler();
                if (bridge) bridge.postMessage({action: 'focusChanged', focused: true});
            };
            row.onfocusout = function () {
                setTimeout(function () {
                    var active = document.activeElement;
                    if (active && active.closest('.fm-plugin-editor')) return;
                    var bridge = handler();
                    if (bridge) bridge.postMessage({action: 'focusChanged', focused: false});
                }, 0);
            };
            row.querySelectorAll('input, select').forEach(function (control) {
                control.onkeydown = function (event) {
                    if (event.key === 'Enter') control.blur();
                };
            });
            function markerIssue() {
                var duplicate = Array.from(document.querySelectorAll('.fm-plugin-marker'))
                    .some(function (other) { return other !== marker && other.value === marker.value; });
                if (marker.value.length !== 1) return 'Marker must be exactly one UTF-16 character.';
                if (marker.value === '[' || marker.value === ']') return 'Square brackets cannot be markers.';
                if (duplicate) return 'This marker is already used by another state.';
                return '';
            }
            function validateMarker() {
                var issue = markerIssue();
                marker.setCustomValidity(issue);
                row.classList.toggle('is-invalid', !!issue);
                validation.textContent = issue || validation.dataset.iconWarning || '';
                return !issue;
            }
            marker.oninput = validateMarker;
            marker.onchange = function () {
                if (!validateMarker()) return;
                marker.setCustomValidity('');
                postEdit(marker, 'marker', marker.value);
            };
            label.onchange = function () { postEdit(label, 'label', label.value); };
            function iconSource() {
                if (kind.value === 'sf') return 'sf:' + icon.value;
                if (kind.value === 'emoji') return 'emoji:' + icon.value;
                return icon.value;
            }
            kind.onchange = function () {
                if (kind.value === 'sf') icon.value = 'circle';
                if (kind.value === 'emoji') icon.value = '🙂';
                if (kind.value === 'text') icon.value = marker.value;
                postEdit(kind, 'icon', iconSource());
            };
            icon.onchange = function () { postEdit(icon, 'icon', iconSource()); };
            icon.oninput = function () {
                if (kind.value !== 'emoji' || !icon.value) return;
                clearTimeout(emojiTimer);
                emojiTimer = setTimeout(function () {
                    postEdit(icon, 'icon', iconSource());
                }, 160);
            };
            picker.onclick = function () {
                icon.focus();
                icon.select();
                var bridge = handler(), ctx = context(picker);
                if (bridge && ctx) {
                    bridge.postMessage({
                        action: 'openEmojiPicker', pluginID: ctx.pluginID,
                        stateIndex: ctx.stateIndex
                    });
                }
            };
            strike.onchange = function () {
                postEdit(strike, 'strikethrough', strike.checked ? 'true' : 'false');
            };
        });
        document.querySelectorAll('.fm-plugin-add-state').forEach(function (button) {
            button.onclick = function () {
                var bridge = handler();
                if (bridge) {
                    bridge.postMessage({
                        action: 'addState', pluginID: button.dataset.pluginId
                    });
                }
            };
        });
    }
    // Wiki-link navigation: report a click; the Swift side resolves target →
    // file and opens it. Handler may be absent (no-op) until wired.
    function hydrateWikiLinks() {
        document.querySelectorAll('a.wikilink').forEach(function (el) {
            el.onclick = function (e) {
                e.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.wikiLinkClick) {
                    handlers.wikiLinkClick.postMessage({
                        target: el.dataset.wikiTarget,
                        heading: el.dataset.wikiHeading || null,
                        blockID: el.dataset.wikiBlock || null
                    });
                }
            };
        });
    }
    // Local file links ([pdf](/research_pdf/x.pdf)): schemeless hrefs cannot
    // resolve against loadHTMLString's about:blank base, so report the raw
    // href; the Swift side resolves it Obsidian-style (vault-absolute /
    // file-relative) and opens the target. Scheme links keep the default
    // navigation path (decidePolicyFor → system).
    function hydrateLocalLinks() {
        document.querySelectorAll('a[href]').forEach(function (el) {
            if (el.classList.contains('wikilink')) return;
            var href = el.getAttribute('href');
            if (!href || href.charAt(0) === '#' || /^[a-zA-Z][a-zA-Z0-9+.\\-]*:/.test(href)) return;
            el.onclick = function (e) {
                e.preventDefault();
                var handlers = window.webkit && window.webkit.messageHandlers;
                if (handlers && handlers.localLinkClick) {
                    handlers.localLinkClick.postMessage({ href: href });
                }
            };
        });
    }
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
        // `pre` carries data-md-lo for scroll sync only. Washing it would paint
        // the whole code block for a mark that touches one line of it, so the
        // wash stays on the inline spans, as before code blocks were tagged.
        document.querySelectorAll('[data-md-lo]:not(pre)').forEach(function (el) {
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
    // Split-mode follow. Navigation jumps (scrollToMdOffset) center + flash on
    // purpose; continuous synchronization instead aligns the matching rendered
    // run with the viewport BOTTOM and never animates.
    //
    // Both directions read one cached anchor table. Re-querying the DOM and
    // calling getBoundingClientRect per element ran on every frame of a scroll
    // gesture — with syntax highlighting that is a walk over every token span.
    // The table stores DOCUMENT-space geometry, so scrolling never stales it;
    // anything that can change layout drops it.
    var mdAnchorTable = null;
    function mdAnchors() {
        if (mdAnchorTable) return mdAnchorTable;
        var list = [];
        var scrollY = window.scrollY;
        document.querySelectorAll('[data-md-lo]').forEach(function (el) {
            var lo = parseInt(el.getAttribute('data-md-lo'), 10);
            if (isNaN(lo)) return;
            var rect = el.getBoundingClientRect();
            if (rect.width <= 0 && rect.height <= 0) return;  // not laid out
            list.push({ lo: lo, top: rect.top + scrollY, bottom: rect.bottom + scrollY });
        });
        list.sort(function (a, b) { return a.lo - b.lo; });
        // Keep the table monotonic in Y: an anchor can only ever be at or below
        // its predecessor, and the interpolation below relies on that.
        for (var i = 1; i < list.length; i++) {
            if (list[i].top < list[i - 1].top) list[i].top = list[i - 1].top;
        }
        mdAnchorTable = list;
        return list;
    }
    function invalidateMdAnchors() { mdAnchorTable = null; }
    window.addEventListener('resize', invalidateMdAnchors);
    window.addEventListener('load', invalidateMdAnchors);
    // Images and KaTeX resize blocks after first layout.
    document.addEventListener('load', invalidateMdAnchors, true);
    window.invalidateMdAnchors = invalidateMdAnchors;

    // Y (document space) for a FRACTIONAL markdown offset, by interpolating
    // between the two anchors around it. Both scales are monotonic, so the
    // result is monotonic: the follow can neither stall nor run backwards.
    //
    // Anchoring to a rendered LINE (an earlier cut) could do both, because a
    // source line and a rendered line are different objects — the two panes
    // wrap at different widths.
    function mdYForPosition(position) {
        var anchors = mdAnchors();
        if (!anchors.length) return null;
        var lo = 0, hi = anchors.length - 1;
        if (position <= anchors[0].lo) return anchors[0].top;
        if (position >= anchors[hi].lo) {
            var last = anchors[hi];
            return last.bottom > last.top ? last.bottom : last.top;
        }
        while (lo + 1 < hi) {                     // binary search: last anchor <= position
            var mid = (lo + hi) >> 1;
            if (anchors[mid].lo <= position) lo = mid; else hi = mid;
        }
        var a = anchors[lo], b = anchors[lo + 1];
        var span = b.lo - a.lo;
        if (span <= 0) return a.top;
        var t = Math.max(0, Math.min(1, (position - a.lo) / span));
        return a.top + (b.top - a.top) * t;
    }

    // The inverse: the fractional markdown offset at a document-space Y.
    function mdPositionForY(y) {
        var anchors = mdAnchors();
        if (!anchors.length) return null;
        if (y <= anchors[0].top) return anchors[0].lo;
        var last = anchors[anchors.length - 1];
        if (y >= last.top) return last.lo;
        var lo = 0, hi = anchors.length - 1;
        while (lo + 1 < hi) {
            var mid = (lo + hi) >> 1;
            if (anchors[mid].top <= y) lo = mid; else hi = mid;
        }
        var a = anchors[lo], b = anchors[lo + 1];
        var span = b.top - a.top;
        if (span <= 0) return b.lo;
        var t = Math.max(0, Math.min(1, (y - a.top) / span));
        return a.lo + (b.lo - a.lo) * t;
    }
    window.editMDCurrentScrollPosition = function () {
        return mdPositionForY(window.scrollY + 8);
    };

    // Set by any scroll the user drives, cleared by each fragment swap: a late
    // settle pass consults it before touching the viewport (see settlePreviewLayout).
    var userScrolledSinceSettle = false;

    // Programmatic scrolls must not be reported back as user scrolls; the flag
    // clears on the next frame, by which time WebKit has fired the event.
    var suppressScrollReport = 0;
    function beginScrollReportSuppression() {
        suppressScrollReport++;
    }
    function endScrollReportSuppressionAfterFrame() {
        requestAnimationFrame(function () {
            suppressScrollReport = Math.max(0, suppressScrollReport - 1);
        });
    }
    function programmaticScroll(y) {
        var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        beginScrollReportSuppression();
        window.scrollTo(0, Math.max(0, Math.min(y, maxY)));
        endScrollReportSuppressionAfterFrame();
    }
    window.programmaticScroll = programmaticScroll;

    // The editor reports the position at ITS TOP edge, so put the matching point
    // at ours. Aligning bottom edges instead pinned Preview to zero for the
    // whole first screenful (the target Y minus a viewport height is negative).
    // No easing: the position is already continuous, and smoothing only adds lag
    // behind the gesture.
    window.syncScrollToMdPosition = function (position) {
        var y = mdYForPosition(position);
        if (y === null) return false;
        programmaticScroll(y - 8);
        return true;
    };
    window.syncScrollToEdge = function (edge) {
        programmaticScroll(edge === 'top' ? 0 : document.documentElement.scrollHeight);
    };

    // PUSH the position on every frame of a user scroll. Polling it from Swift
    // per wheel event meant one round trip in flight at a time and the rest of
    // the gesture's frames dropped — the editor moved in visible jerks.
    var scrollReportQueued = false;
    function reportScroll() {
        var maxY = Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
        if (maxY <= 0.5) return;      // nothing to scroll — no position to share
        var payload;
        if (window.scrollY <= 0.5) {
            payload = { edge: 'top' };
        } else if (window.scrollY >= maxY - 0.5) {
            payload = { edge: 'bottom' };
        } else {
            var position = mdPositionForY(window.scrollY + 8);   // our TOP edge
            if (position === null) return;
            payload = { position: position };
        }
        try {
            window.webkit.messageHandlers.previewScroll.postMessage(payload);
        } catch (e) {}
    }
    window.addEventListener('scroll', function () {
        if (suppressScrollReport > 0) return;   // our own restore, not the user
        // The user has taken the viewport: a late settle pass (an image or the
        // KaTeX webfonts landing seconds after the edit) must not yank them back
        // to the anchor captured when the fragment was swapped in.
        userScrolledSinceSettle = true;
        if (scrollReportQueued) return;
        scrollReportQueued = true;
        requestAnimationFrame(function () {
            scrollReportQueued = false;
            reportScroll();
        });
    }, { passive: true });

    // D4: hover copy button on code blocks and blockquotes.
    function copyPreviewText(text, btn) {
        function ok() {
            var prev = btn.textContent;
            btn.textContent = '✓';
            setTimeout(function () { btn.textContent = prev; }, 1000);
        }
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(ok).catch(function () {
                fallbackPreviewCopy(text); ok();
            });
        } else {
            fallbackPreviewCopy(text); ok();
        }
    }
    function fallbackPreviewCopy(text) {
        var ta = document.createElement('textarea');
        ta.value = text;
        ta.style.position = 'fixed';
        ta.style.left = '-9999px';
        document.body.appendChild(ta);
        ta.select();
        try { document.execCommand('copy'); } catch (e) {}
        document.body.removeChild(ta);
    }
    function attachPreviewCopyButton(el) {
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
        btn.onclick = function (e) {
            e.preventDefault();
            e.stopPropagation();
            var clone = el.cloneNode(true);
            clone.querySelectorAll('.copy-block-btn').forEach(function (b) { b.remove(); });
            copyPreviewText(clone.innerText || '', btn);
        };
        el.appendChild(btn);
    }
    function hydratePreviewCopyButtons() {
        document.querySelectorAll('pre, blockquote').forEach(attachPreviewCopyButton);
    }

    // The shell owns this state, not the replaceable fragment. Consequently a
    // live Preview innerHTML update keeps the user's disclosure choice.
    // Default collapsed: Properties inspector owns frontmatter editing (plan 04).
    // Disclosure state lives in this persistent shell across fragment updates.
    var frontmatterCollapsed = true;
    function applyFrontmatterDisclosure(section) {
        var title = section.querySelector('.fm-title');
        var content = section.querySelector('.fm-content');
        if (!title || !content) return;
        section.classList.toggle('is-collapsed', frontmatterCollapsed);
        title.setAttribute('aria-expanded', frontmatterCollapsed ? 'false' : 'true');
        content.hidden = frontmatterCollapsed;
    }
    function hydrateFrontmatterDisclosure() {
        document.querySelectorAll('.frontmatter').forEach(function (section) {
            var title = section.querySelector('.fm-title');
            if (!title) return;
            title.onclick = function (event) {
                event.preventDefault();
                event.stopPropagation();
                frontmatterCollapsed = !frontmatterCollapsed;
                document.querySelectorAll('.frontmatter').forEach(applyFrontmatterDisclosure);
                invalidateMdAnchors();
                alignLineNumberGutter();
            };
            applyFrontmatterDisclosure(section);
        });
    }

    function hydratePreviewMath() {
        if (typeof katex === 'undefined') return;
        document.querySelectorAll('.math:not(.math-rendered)').forEach(function (el) {
            var tex = el.textContent;
            try {
                katex.render(tex, el, {
                    displayMode: el.classList.contains('math-display'),
                    throwOnError: false
                });
                el.classList.add('math-rendered');
                el.classList.remove('math-error');
            } catch (e) {
                el.classList.add('math-error');
                el.textContent = tex;
            }
        });
    }

    // Make the DOM live again. Deliberately cheap: no geometry is read here,
    // because hydrate runs BEFORE the new content has been laid out. Everything
    // that depends on final geometry belongs in settlePreviewLayout.
    window.editMDHydratePreviewContent = function () {
        hydrateTaskCheckboxes();
        hydrateBuiltInPluginTokens();
        hydrateBuiltInPluginConfiguration();
        hydrateWikiLinks();
        hydrateLocalLinks();
        hydratePreviewCopyButtons();
        hydrateFrontmatterDisclosure();
        hydratePreviewMath();
        invalidateMdAnchors();
    };

    // One settle pass over final geometry: drop the anchor cache, re-place the
    // line-number gutter, and (optionally) restore the scroll anchor. Both the
    // gutter walk and the anchor table read getBoundingClientRect for every
    // tagged element, so this must run ONCE per layout — not once in hydrate
    // (pre-layout, therefore wrong) and again afterwards.
    function settlePreviewLayout(position, pixelY) {
        invalidateMdAnchors();
        alignLineNumberGutter();
        if (userScrolledSinceSettle) return;   // the user owns the viewport now
        if (position !== null && position !== undefined) {
            window.syncScrollToMdPosition(position);
        } else if (pixelY !== null && pixelY !== undefined) {
            programmaticScroll(pixelY);
        }
    }

    // Images and the KaTeX webfonts land after first layout and change block
    // heights, which moves every anchor below them. Replay the settle when they
    // do — on the first page load as well as after a fragment swap; before, only
    // the fragment path did this and a freshly opened math document kept a stale
    // anchor table (split-scroll sync drifted until the next resize).
    function replayPreviewSettle(root, position) {
        root.querySelectorAll('img').forEach(function (image) {
            if (image.complete) return;
            image.addEventListener('load', function () {
                settlePreviewLayout(position, null);
            }, { once: true });
        });
        // A resolved FontFaceSet promise would replay immediately on every edit
        // and defeat the pixel-stable first settle. Replay only while this DOM
        // actually has fonts still landing.
        if (document.fonts && document.fonts.status === 'loading') {
            document.fonts.ready.then(function () { settlePreviewLayout(position, null); });
        }
    }

    // SYNCHRONOUS on purpose. This function is the Swift side's continuation:
    // whatever it waits on, the render task waits on too. It used to await two
    // requestAnimationFrames "for layout" — and a WKWebView that is not
    // producing frames (occluded, off-screen, a suspended rendering update)
    // never fires them, so the promise never settled, the awaiting task never
    // released the render slot, and Preview froze on the first edit for the rest
    // of the session. Nothing here needs a frame: reading geometry in
    // settlePreviewLayout forces a synchronous layout, which is exactly the
    // "after layout" state we wanted. Late shifts (images, webfonts) are picked
    // up by replayPreviewSettle, which is fire-and-forget — if frames never
    // come, we lose a scroll-anchor touch-up, never the content update.
    window.editMDReplacePreview = function (payload) {
        if (!payload || payload.revision < window.editMDPreviewRevision) return false;
        var root = document.getElementById('preview-content');
        if (!root) return false;
        var position = payload.position;
        var pixelY = null;
        var replayPosition = position;
        if (position === null || position === undefined) {
            // Typing is a content update, not a scroll gesture. Preserve the
            // exact viewport instead of re-interpreting its old markdown offset
            // in the new DOM (which visibly nudged the first edit after a click).
            pixelY = window.scrollY;
            // Late image/font layout needs the semantic point that occupied the
            // viewport before the swap; replaying pixelY after heights change
            // would show different content.
            replayPosition = window.editMDCurrentScrollPosition();
        }
        // Replacing a long document with a shorter one can make WebKit clamp
        // scrollY before our explicit restore. That implicit scroll belongs to
        // this update transaction and must never be reported back to Source.
        beginScrollReportSuppression();
        try {
            var pluginEditorFocus = captureBuiltInPluginEditorFocus(root);
            root.innerHTML = payload.html;
            window.editMDPreviewRevision = payload.revision;
            window.editMDHydratePreviewContent();
            restoreBuiltInPluginEditorFocus(pluginEditorFocus);
            userScrolledSinceSettle = false;
            settlePreviewLayout(position, pixelY);
            replayPreviewSettle(root, replayPosition);
            return true;
        } finally {
            endScrollReportSuppressionAfterFrame();
        }
    };

    window.editMDHydratePreviewContent();
    settlePreviewLayout(null, null);
    replayPreviewSettle(document.getElementById('preview-content'), null);
    </script>
    </body>
    </html>
    """
    return PreviewPageRender(html: html, hasMathAssets: mathAssets)
}
