import AppKit
import Markdown

// Visual (WYSIWYG) mode foundation — v20.
//
// Model: the attributed string contains NO markdown markers. Each display
// paragraph (text between "\n") carries a `.mdBlock` attribute describing its
// block semantics; inline semantics live in `.mdInline` / `.mdLink` /
// `.mdImage`. Fonts and colors are DERIVED presentation — the serializer
// (AttributedToMarkdown.swift) reads only the semantic attributes.
//
// Constructs the model cannot represent (tables, HTML blocks) become read-only
// "islands": `.raw` paragraphs that serialize back verbatim.
//
// Normalizations (serialize(render(x)) is the normal form; HTML-invariant):
//   setext → ATX headings · reference links → inline · loose lists → tight ·
//   indented code → fenced · _em_/__strong__ → */** · +/* bullets → "-" ·
//   soft breaks → spaces · hard breaks → backslash form · list nesting → 4 spaces

// MARK: - Semantic attributes

struct MDInlineStyle: OptionSet, Hashable {
    let rawValue: Int
    static let bold      = MDInlineStyle(rawValue: 1 << 0)
    static let italic    = MDInlineStyle(rawValue: 1 << 1)
    static let strike    = MDInlineStyle(rawValue: 1 << 2)
    static let code      = MDInlineStyle(rawValue: 1 << 3)
    static let rawHTML   = MDInlineStyle(rawValue: 1 << 4)  // inline HTML: no escaping
    /// Obsidian-style `==highlight==` (display-only markers; not GFM).
    static let highlight = MDInlineStyle(rawValue: 1 << 5)
}

struct MDBlock: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case paragraph
        case heading(Int)
        case codeBlock(language: String)
        case bulletItem(depth: Int)
        case orderedItem(depth: Int, number: Int)
        case taskItem(depth: Int, done: Bool)
        case builtInPluginTaskItem(depth: Int, token: BuiltInPluginTokenPayload)
        /// Extra paragraph of a multi-paragraph list item; indent = content column.
        case listContinuation(indent: Int)
        case thematicBreak
        /// One table cell; alignment: 0 none / 1 left / 2 center / 3 right
        /// (column-level, stored on every cell of the column). Cells of one
        /// table share `group`.
        case tableCell(row: Int, column: Int, columns: Int, alignment: Int)
        /// Read-only island: serialized verbatim from the stored source text.
        case raw(String)

        // A hand-written hash so `.raw`'s payload is NOT walked. This kind is
        // stored as an NSAttributedString attribute value, and NSTextStorage
        // hashes attribute values while fixing/coalescing runs — for a large
        // island (a whole 9000-row table lives in one `.raw`) the synthesized
        // hash would re-walk the entire multi-hundred-KB string on every
        // addAttribute, pegging the CPU. Length is a cheap discriminant;
        // collisions are fine (Hashable only requires equal ⇒ equal-hash, and
        // `==` still compares fully on the rare collision).
        func hash(into hasher: inout Hasher) {
            switch self {
            case .paragraph: hasher.combine(0)
            case .heading(let level): hasher.combine(1); hasher.combine(level)
            case .codeBlock(let language): hasher.combine(2); hasher.combine(language)
            case .bulletItem(let depth): hasher.combine(3); hasher.combine(depth)
            case .orderedItem(let depth, let number):
                hasher.combine(4); hasher.combine(depth); hasher.combine(number)
            case .taskItem(let depth, let done):
                hasher.combine(5); hasher.combine(depth); hasher.combine(done)
            case .builtInPluginTaskItem(let depth, let token):
                hasher.combine(6); hasher.combine(depth); hasher.combine(token)
            case .listContinuation(let indent): hasher.combine(7); hasher.combine(indent)
            case .thematicBreak: hasher.combine(8)
            case .tableCell(let row, let column, let columns, let alignment):
                hasher.combine(9); hasher.combine(row); hasher.combine(column)
                hasher.combine(columns); hasher.combine(alignment)
            case .raw: hasher.combine(10)   // payload-free: docs have very few islands
            }
        }
    }
    var kind: Kind
    var quoteDepth: Int = 0
    /// Identity of the outermost containing blockquote (quote continuity).
    var quoteGroup: Int = -1
    /// Identity of the containing list / code block (grouping on serialize).
    var group: Int = -1
    /// Leading spaces for blocks nested inside a list item.
    var listIndent: Int = 0
}

extension NSAttributedString.Key {
    static let mdBlock  = NSAttributedString.Key("md.block")   // MDBlock
    static let mdInline = NSAttributedString.Key("md.inline")  // Int (MDInlineStyle)
    static let mdLink   = NSAttributedString.Key("md.link")    // String destination
    static let mdImage  = NSAttributedString.Key("md.image")   // [String: String] src/alt/title
    static let mdWikiLink = NSAttributedString.Key("md.wikiLink")  // MDWikiLinkPayload
    static let mdBuiltInPluginToken = NSAttributedString.Key("md.builtInPluginToken")
    /// Math run (`$…$` / `$$…$$`): Int, 0 = inline, 1 = display. The run text
    /// is the VERBATIM source including delimiters; the serializer re-emits it
    /// without markdown escaping (cheap NSNumber value — v29 hash invariant).
    static let mdMath = NSAttributedString.Key("md.math")
}

/// Intra-paragraph hard line break (markdown "  \n" / "\<newline>").
let mdHardBreak = "\u{2028}"
/// Placeholder character for images and thematic breaks.
let mdObjectChar = "\u{FFFC}"

/// True when `html` is only HTML comments (and whitespace) — e.g. `<!-- -->`,
/// used as a list-separator fence. Such blocks serialize via `.raw` but must not
/// paint as monospaced islands in Visual.
func isHTMLCommentOnly(_ html: String) -> Bool {
    var s = html
    while let start = s.range(of: "<!--"),
          let end = s.range(of: "-->", range: start.upperBound..<s.endIndex) {
        s.removeSubrange(start.lowerBound..<end.upperBound)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - Visual style (proportional font — Source stays monospaced)

struct VisualStyle {
    var baseSize: CGFloat = 15
    /// Body font family (empty = system proportional) and its base weight —
    /// from the Visual mode's font settings.
    var bodyFamily: String = ""
    var bodyWeight: NSFont.Weight = .regular
    /// Per-element size/weight config (headings, bold). Colors are applied
    /// separately at draw time.
    var elements = ElementStyles()

    func headingSize(_ level: Int) -> CGFloat {
        baseSize * elements.heading(level).sizeScale
    }

    func font(for styles: MDInlineStyle, blockKind: MDBlock.Kind) -> NSFont {
        if styles.contains(.code) {
            return NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        }
        switch blockKind {
        case .codeBlock, .raw:
            return NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular)
        case .heading(let level):
            let element = elements.heading(level)
            let weight = (element.weight ?? .semibold).nsWeight
            let base = proportional(ofSize: headingSize(level), weight: weight)
            return styles.contains(.italic) ? base.withTraits(.italic) : base
        default:
            var weight = bodyWeight
            if styles.contains(.bold) { weight = (elements.bold.weight ?? .bold).nsWeight }
            let base = proportional(ofSize: baseSize, weight: weight)
            return styles.contains(.italic) ? base.withTraits(.italic) : base
        }
    }

    /// A proportional font honoring `bodyFamily` when set, else the system UI
    /// font at the requested weight.
    private func proportional(ofSize size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if !bodyFamily.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: bodyFamily,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let font = NSFont(descriptor: descriptor, size: size) { return font }
        }
        return .systemFont(ofSize: size, weight: weight)
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        let descriptor = fontDescriptor.withSymbolicTraits(combined)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

// MARK: - Renderer

/// Markdown → attributed string with semantic attributes. Pure of UI state.
func renderMarkdownToAttributed(_ markdown: String,
                                style: VisualStyle = VisualStyle(),
                                pluginSnapshot: BuiltInPluginSnapshot? = nil)
    -> NSAttributedString {
    VisualRenderer(source: markdown, style: style,
                   pluginSnapshot: pluginSnapshot).run()
}

private final class VisualRenderer {
    let style: VisualStyle
    let source: String
    let nsSource: NSString
    let lineIdx: LineIndex
    /// Math spans in the ORIGINAL source; the parse runs on the masked text
    /// (U+E000, layout-preserving) so cmark never reads TeX as markdown — a
    /// `=` line inside `$$…$$` would otherwise make the block a setext H1 and
    /// escape processing would eat `\\`/`\,`.
    private let mathSpans: [MDMathSpan]
    private let pluginSnapshot: BuiltInPluginSnapshot
    private let parseSource: String
    /// Spans that cover whole lines (multiline `$$` blocks) — rendered as one
    /// verbatim block run; per-span "already emitted" bookkeeping.
    private let multilineMath: [Bool]
    private var emittedMath = Set<Int>()
    let out = NSMutableAttributedString()
    private var groupCounter = 0

    init(source: String, style: VisualStyle,
         pluginSnapshot providedPluginSnapshot: BuiltInPluginSnapshot?) {
        self.source = source
        self.style = style
        let ns = source as NSString
        self.nsSource = ns
        let math = scanMathSpans(in: source)
        self.mathSpans = math
        let plugins = providedPluginSnapshot ?? BuiltInPluginRegistry.snapshot(for: source)
        self.pluginSnapshot = plugins
        self.multilineMath = math.map {
            $0.display && ns.range(of: "\n", options: [], range: $0.range).location != NSNotFound
        }
        let (mathMasked, _) = maskMathSpansForParsing(source, spans: math)
        let masked = maskBuiltInPluginTokensForParsing(mathMasked, snapshot: plugins)
        self.parseSource = masked
        // Masked and original have identical UTF-16 layout; the index must be
        // built from what cmark parses (its columns are UTF-8 bytes of that).
        self.lineIdx = LineIndex(masked)
    }

    private func nextGroup() -> Int {
        groupCounter += 1
        return groupCounter
    }

    struct Ctx {
        var quoteDepth = 0
        var quoteGroup = -1
        var listIndent = 0
    }

    func run() -> NSAttributedString {
        let document = Document(parsing: parseSource)
        // YAML frontmatter isn't in the markdown grammar — emit it as a
        // read-only properties island and skip the AST nodes it produced
        // (a thematic break + a setext heading) so it isn't rendered twice.
        let frontmatter = frontmatterRange(in: source)
        if let frontmatter { emitFrontmatterIsland(frontmatter) }
        let skipUntil = frontmatter.map { NSMaxRange($0.full) } ?? 0
        for child in document.children {
            if skipUntil > 0, let range = child.range,
               lineIdx.offset(range.lowerBound.line, range.lowerBound.column) < skipUntil {
                continue
            }
            renderBlock(child, ctx: Ctx())
        }
        return out
    }

    /// The frontmatter as a `.raw` island: the stored value is the verbatim
    /// block (fences included) so it round-trips unchanged, but the DISPLAYED
    /// text is clean "key: value" lines (fences dropped) — cosmetic, since only
    /// the stored `.raw` feeds serialization. Presentation draws a properties
    /// panel and colors the keys (VisualTextView.colorYAMLIsland).
    private func emitFrontmatterIsland(_ frontmatter: FrontmatterRange) {
        let full = nsSource.substring(with: frontmatter.full)
        let bodyText = nsSource.substring(with: frontmatter.body)
        let props = parseFrontmatterProperties(bodyText)
        let display: String
        if props.isEmpty {
            display = bodyText.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: mdHardBreak)
        } else {
            display = props
                .map { $0.value.isEmpty ? "\($0.key):" : "\($0.key): \($0.value)" }
                .joined(separator: mdHardBreak)
        }
        appendParagraph(makeBlock(.raw(full), Ctx())) { b in
            self.appendText(display, block: b, styles: [], link: nil)
        }
    }

    // MARK: Block dispatch

    private func renderBlock(_ block: Markup, ctx: Ctx) {
        // A block fully inside a multiline `$$` span (masked → sentinel
        // paragraphs; blank lines inside TeX split it into several) becomes
        // ONE verbatim math run; the follow-up pieces are dropped silently.
        if let idx = multilineMathIndex(containing: block) {
            if !emittedMath.contains(idx) {
                emittedMath.insert(idx)
                emitDisplayMathBlock(mathSpans[idx], ctx: ctx)
            }
            return
        }
        switch block {
        case let paragraph as Paragraph:
            appendParagraph(makeBlock(.paragraph, ctx)) { b in
                self.renderInlines(paragraph.children, block: b, styles: [], link: nil)
            }
        case let heading as Heading:
            appendParagraph(makeBlock(.heading(heading.level), ctx)) { b in
                self.renderInlines(heading.children, block: b, styles: [], link: nil)
            }
        case let quote as BlockQuote:
            var inner = ctx
            inner.quoteDepth += 1
            if ctx.quoteDepth == 0 { inner.quoteGroup = nextGroup() }
            for child in quote.children { renderBlock(child, ctx: inner) }
        case let code as CodeBlock:
            renderCodeBlock(code, ctx: ctx)
        case is ThematicBreak:
            appendParagraph(makeBlock(.thematicBreak, ctx)) { b in
                self.appendText(mdObjectChar, block: b, styles: [], link: nil)
            }
        case let list as UnorderedList:
            renderList(items: Array(list.listItems), ordered: false, start: 1,
                       depth: currentListDepth(ctx), group: nil, ctx: ctx)
        case let list as OrderedList:
            renderList(items: Array(list.listItems), ordered: true,
                       start: Int(list.startIndex), depth: currentListDepth(ctx),
                       group: nil, ctx: ctx)
        case let table as Markdown.Table where ctx.quoteDepth == 0 && ctx.listIndent == 0:
            // Top-level tables are editable; nested ones stay islands.
            renderTable(table, ctx: ctx)
        default:
            renderIsland(block, ctx: ctx)
        }
    }

    /// Above this many cells a native NSTextTable is rendered as a monospace
    /// island instead. NSTextTable layout is super-linear in cell count — a few
    /// thousand cells peg the CPU indefinitely (TextKit lays out every cell of
    /// the whole document up front, no virtualization). The island is plain
    /// monospace text that lays out fast and round-trips the pipe table
    /// verbatim; FSNotes/Obsidian likewise never use native table widgets for
    /// large tables. Small tables keep the editable grid.
    static let maxNativeTableCells = 400

    private func renderTable(_ table: Markdown.Table, ctx: Ctx) {
        let group = nextGroup()
        let alignments = table.columnAlignments
        let columns = max(1, alignments.count)

        // Count rows with an early-out at the budget (rows is a Sequence, and
        // a giant table would be wasteful to fully materialize just to size it).
        var rowCount = 1  // header row
        for _ in table.body.rows {
            rowCount += 1
            if rowCount * columns > Self.maxNativeTableCells {
                renderTableIsland(table, ctx: ctx)
                return
            }
        }

        func alignmentCode(_ column: Int) -> Int {
            guard column < alignments.count, let alignment = alignments[column] else { return 0 }
            switch alignment {
            case .left: return 1
            case .center: return 2
            case .right: return 3
            }
        }

        func renderCell(_ cell: Markdown.Table.Cell, row: Int, column: Int) {
            let kind = MDBlock.Kind.tableCell(row: row, column: column,
                                              columns: columns,
                                              alignment: alignmentCode(column))
            appendParagraph(makeBlock(kind, ctx, group: group)) { b in
                self.renderInlines(cell.children, block: b, styles: [], link: nil)
            }
        }

        for (column, cell) in table.head.cells.enumerated() where column < columns {
            renderCell(cell, row: 0, column: column)
        }
        for (rowIndex, row) in table.body.rows.enumerated() {
            for (column, cell) in row.cells.enumerated() where column < columns {
                renderCell(cell, row: rowIndex + 1, column: column)
            }
        }
    }

    // MARK: Multiline display math

    private func blockNSRange(_ block: Markup) -> NSRange? {
        guard let r = block.range else { return nil }
        let loc = lineIdx.offset(r.lowerBound.line, r.lowerBound.column)
        let end = lineIdx.offset(r.upperBound.line, r.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    private func multilineMathIndex(containing block: Markup) -> Int? {
        guard mathSpans.contains(where: { $0.display }) else { return nil }
        guard let r = blockNSRange(block) else { return nil }
        for (i, span) in mathSpans.enumerated() where multilineMath[i] {
            if r.location >= span.range.location,
               NSMaxRange(r) <= NSMaxRange(span.range) {
                return i
            }
        }
        return nil
    }

    /// The whole `$$…$$` block as one run: rendered SwiftMath attachment when
    /// the TeX parses (verbatim source in `.mdMathTex`), otherwise raw TeX
    /// with U+2028 line breaks (paragraph model stays intact). `.mdMath`
    /// drives the mono/tint presentation and the no-escape serialization.
    private func emitDisplayMathBlock(_ span: MDMathSpan, ctx: Ctx) {
        let verbatim = nsSource.substring(with: span.range)
        let tex = nsSource.substring(with: span.innerRange)
        appendParagraph(makeBlock(.paragraph, ctx)) { b in
            var attrs = self.baseAttributes(block: b, styles: [], link: nil)
            attrs[.mdMath] = 1
            self.appendMathRun(verbatim: verbatim, tex: tex, display: true,
                               attrs: attrs)
        }
    }

    /// A math run: rendered attachment (`.mdMathTex` = verbatim source for
    /// the serializer) or, when SwiftMath can't parse the TeX, the verbatim
    /// text itself (newlines → U+2028), still serialized via `.mdMath`.
    private func appendMathRun(verbatim: String, tex: String, display: Bool,
                               attrs: [NSAttributedString.Key: Any]) {
        var attrs = attrs
        let fontSize = (attrs[.font] as? NSFont)?.pointSize ?? style.baseSize
        if let attachment = MathRender.attachment(tex: tex, display: display,
                                                  fontSize: fontSize) {
            attrs[.mdMathTex] = verbatim
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttributes(attrs, range: NSRange(location: 0, length: run.length))
            out.append(run)
        } else {
            let text = verbatim.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: mdHardBreak)
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
    }

    /// Depth is carried through listIndent: 4 display-indent spaces per level.
    private func currentListDepth(_ ctx: Ctx) -> Int {
        ctx.listIndent / 4
    }

    private func makeBlock(_ kind: MDBlock.Kind, _ ctx: Ctx, group: Int = -1) -> MDBlock {
        MDBlock(kind: kind, quoteDepth: ctx.quoteDepth, quoteGroup: ctx.quoteGroup,
                group: group,
                listIndent: listIndentForNonItem(kind) ? ctx.listIndent : 0)
    }

    /// List items encode their nesting in `depth`; other blocks nested in an
    /// item carry the raw space indent instead.
    private func listIndentForNonItem(_ kind: MDBlock.Kind) -> Bool {
        switch kind {
        case .bulletItem, .orderedItem, .taskItem, .builtInPluginTaskItem, .listContinuation:
            return false
        default:
            return true
        }
    }

    private func renderCodeBlock(_ code: CodeBlock, ctx: Ctx) {
        let group = nextGroup()
        let language = code.language ?? ""
        var lines = code.code.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        for line in lines {
            appendParagraph(makeBlock(.codeBlock(language: language), ctx, group: group)) { b in
                self.appendText(line, block: b, styles: [], link: nil)
            }
        }
    }

    /// `group` identifies the whole list TREE: nested lists inherit the parent
    /// group, so the serializer can tell "same list" from "adjacent lists".
    private func renderList(items: [ListItem], ordered: Bool, start: Int, depth: Int,
                            group inheritedGroup: Int?, ctx: Ctx) {
        let group = inheritedGroup ?? nextGroup()
        for (index, item) in items.enumerated() {
            let kind: MDBlock.Kind
            let markerLen: Int
            if let checkbox = item.checkbox {
                if let token = pluginListToken(for: item) {
                    kind = .builtInPluginTaskItem(depth: depth, token: token.payload)
                } else {
                    kind = .taskItem(depth: depth, done: checkbox == .checked)
                }
                markerLen = 6  // "- [x] "
            } else if ordered {
                let number = start + index
                kind = .orderedItem(depth: depth, number: number)
                markerLen = "\(number). ".count
            } else {
                kind = .bulletItem(depth: depth)
                markerLen = 2  // "- "
            }
            let contentIndent = depth * 4 + markerLen

            var childCtx = ctx
            childCtx.listIndent = contentIndent

            var emittedHead = false
            for child in item.children {
                if !emittedHead {
                    emittedHead = true
                    if let paragraph = child as? Paragraph {
                        appendParagraph(makeBlock(kind, ctx, group: group)) { b in
                            self.renderInlines(paragraph.children, block: b, styles: [], link: nil)
                        }
                        continue
                    }
                    // Item starts with a non-paragraph child: emit an empty head
                    // so the marker survives, then render the child indented.
                    appendParagraph(makeBlock(kind, ctx, group: group)) { _ in }
                }
                switch child {
                case let paragraph as Paragraph:
                    appendParagraph(makeBlock(.listContinuation(indent: contentIndent), ctx,
                                              group: group)) { b in
                        self.renderInlines(paragraph.children, block: b, styles: [], link: nil)
                    }
                case let list as UnorderedList:
                    renderList(items: Array(list.listItems), ordered: false, start: 1,
                               depth: depth + 1, group: group, ctx: ctx)
                case let list as OrderedList:
                    renderList(items: Array(list.listItems), ordered: true,
                               start: Int(list.startIndex), depth: depth + 1,
                               group: group, ctx: ctx)
                default:
                    renderBlock(child, ctx: childCtx)
                }
            }
            if !emittedHead {
                appendParagraph(makeBlock(kind, ctx, group: group)) { _ in }
            }
        }
    }

    private func pluginListToken(for item: ListItem) -> BuiltInPluginToken? {
        guard let sourceRange = item.range else { return nil }
        let start = lineIdx.offset(sourceRange.lowerBound.line, sourceRange.lowerBound.column)
        let end = lineIdx.offset(sourceRange.upperBound.line, sourceRange.upperBound.column)
        return pluginSnapshot.tokens.first {
            $0.isListMarker && $0.payload.isInteractive
                && $0.range.location >= start && NSMaxRange($0.range) <= end
        }
    }

    // MARK: Islands

    /// A large table stored as a raw island. The `.raw` value is the verbatim
    /// pipe markdown (serializer reads it → round-trips unchanged), but the
    /// DISPLAYED text drops the `| --- |` delimiter line so the grid drawn in
    /// Visual has no empty band under the header. Display is cosmetic; only the
    /// stored `.raw` feeds serialization.
    private func renderTableIsland(_ table: Markdown.Table, ctx: Ctx) {
        let raw: String
        if let srcRange = table.range {
            let loc = lineIdx.lineStart(srcRange.lowerBound.line)
            let end = lineIdx.offset(srcRange.upperBound.line, srcRange.upperBound.column)
            raw = end > loc
                ? nsSource.substring(with: NSRange(location: loc, length: end - loc))
                    .trimmingCharacters(in: CharacterSet.newlines)
                : table.format()
        } else {
            raw = table.format()
        }
        guard !raw.isEmpty else { return }
        var lines = raw.components(separatedBy: "\n")
        if lines.count >= 2 { lines.remove(at: 1) }   // drop delimiter from display only
        let display = lines.joined(separator: mdHardBreak)
        appendParagraph(makeBlock(.raw(raw), ctx)) { b in
            self.appendText(display, block: b, styles: [], link: nil)
        }
    }

    private func renderIsland(_ block: Markup, ctx: Ctx) {
        let raw: String
        if let html = block as? HTMLBlock {
            raw = html.rawHTML.trimmingCharacters(in: CharacterSet.newlines)
        } else if let srcRange = block.range {
            // Slice from the line start so multi-line islands keep the quote/
            // indent prefixes of their intermediate lines consistent.
            let loc = lineIdx.lineStart(srcRange.lowerBound.line)
            let end = lineIdx.offset(srcRange.upperBound.line, srcRange.upperBound.column)
            if end > loc {
                raw = nsSource.substring(with: NSRange(location: loc, length: end - loc))
                    .trimmingCharacters(in: CharacterSet.newlines)
            } else {
                raw = block.format()
            }
        } else {
            raw = block.format()
        }
        guard !raw.isEmpty else { return }
        // HTML comments (incl. the serializer's `<!-- -->` list fence) are kept
        // as `.raw` for round-trip but have no display text — Preview hides them
        // the same way (browser treats `<!--…-->` as a real comment).
        if block is HTMLBlock, isHTMLCommentOnly(raw) {
            appendParagraph(makeBlock(.raw(raw), ctx)) { _ in }
            return
        }
        let display = raw.replacingOccurrences(of: "\n", with: mdHardBreak)
        appendParagraph(makeBlock(.raw(raw), ctx)) { b in
            self.appendText(display, block: b, styles: [], link: nil)
        }
    }

    // MARK: Inlines

    private func renderInlines(_ children: MarkupChildren, block: MDBlock,
                               styles: MDInlineStyle, link: String?) {
        for child in children {
            switch child {
            case let text as Markdown.Text:
                appendTextWithWikiLinks(text, block: block, styles: styles, link: link)
            case let strong as Strong:
                renderInlines(strong.children, block: block, styles: styles.union(.bold), link: link)
            case let emphasis as Emphasis:
                renderInlines(emphasis.children, block: block, styles: styles.union(.italic), link: link)
            case let strike as Strikethrough:
                renderInlines(strike.children, block: block, styles: styles.union(.strike), link: link)
            case let code as InlineCode:
                appendText(code.code, block: block, styles: styles.union(.code), link: link)
            case let mdLink as Markdown.Link:
                renderInlines(mdLink.children, block: block, styles: styles,
                              link: mdLink.destination ?? "")
            case let image as Markdown.Image:
                appendImage(image, block: block, styles: styles, link: link)
            case is SoftBreak:
                appendText(" ", block: block, styles: styles, link: link)
            case is LineBreak:
                appendText(mdHardBreak, block: block, styles: styles, link: link)
            case let html as InlineHTML:
                appendText(html.rawHTML, block: block, styles: styles.union(.rawHTML), link: link)
            default:
                appendText(child.format(), block: block, styles: styles, link: link)
            }
        }
    }

    private func appendImage(_ image: Markdown.Image, block: MDBlock,
                             styles: MDInlineStyle, link: String?) {
        var info: [String: String] = [:]
        info["src"] = image.source ?? ""
        info["alt"] = image.plainText
        if let title = image.title, !title.isEmpty { info["title"] = title }
        var attrs = baseAttributes(block: block, styles: styles, link: link)
        attrs[.mdImage] = info
        out.append(NSAttributedString(string: mdObjectChar, attributes: attrs))
    }

    private func appendText(_ string: String, block: MDBlock,
                            styles: MDInlineStyle, link: String?) {
        guard !string.isEmpty else { return }
        out.append(NSAttributedString(string: string,
                                      attributes: baseAttributes(block: block, styles: styles,
                                                                 link: link)))
    }

    /// A Text node may contain `[[wiki-links]]` and `==highlight==`, which
    /// swift-markdown treats as literal text. We split the run: wiki-links
    /// become marker-free runs with `.mdWikiLink`; highlights become marker-free
    /// runs with `.highlight` style.
    ///
    /// Wiki scan uses the SOURCE slice so escaped `\[` does not match. Highlight
    /// scan (and plain display) use `text.string` — cmark has already resolved
    /// escapes there; feeding source would leave literal backslashes and break
    /// round-trip (`\_` → `\\_`).
    private func appendTextWithWikiLinks(_ text: Markdown.Text, block: MDBlock,
                                         styles: MDInlineStyle, link: String?) {
        // Common path: no wiki-links → highlight on the unescaped string.
        guard let src = text.range else {
            appendTextWithHighlights(text.string, block: block, styles: styles, link: link)
            return
        }
        let loc = lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
        let end = lineIdx.offset(src.upperBound.line, src.upperBound.column)
        guard end > loc, end <= nsSource.length else {
            appendTextWithHighlights(text.string, block: block, styles: styles, link: link)
            return
        }
        let source = nsSource.substring(with: NSRange(location: loc, length: end - loc))
        let wikiMatches = scanWikiLinks(in: source)
        let pluginMatches = pluginSnapshot.textTokens(
            in: NSRange(location: loc, length: end - loc))
            .map { token in
                (range: NSRange(location: token.range.location - loc,
                                length: token.range.length), token: token)
            }
        // Math on the same source slice: `$…$` (and same-line `$$…$$`) become
        // VERBATIM runs carrying `.mdMath` — delimiters stay visible, and the
        // serializer re-emits the text unescaped, so `$\frac{a}{b}$` survives
        // the Visual round-trip. Multiline `$$` blocks span several Text
        // nodes and stay plain text here (Preview still renders them).
        let mathMatches = scanMathSpans(in: source)
        guard !wikiMatches.isEmpty || !mathMatches.isEmpty || !pluginMatches.isEmpty else {
            if text.string.utf16.contains(mathSentinelUnit)
                || text.string.utf16.contains(builtInPluginSentinelUnit) {
                // A sentinel without a local semantic match must never enter
                // NSTextStorage: restore this node's original source slice.
                var attrs = baseAttributes(block: block, styles: styles, link: link)
                if text.string.utf16.contains(mathSentinelUnit) { attrs[.mdMath] = 1 }
                out.append(NSAttributedString(string: source, attributes: attrs))
            } else {
                appendTextWithHighlights(text.string, block: block, styles: styles, link: link)
            }
            return
        }
        // Matches present: split source by match ranges; plain gaps use source
        // substrings (pre-existing wiki path). Highlights still run on gaps.
        // Document order; on overlap ($ inside [[…]] etc.) the earlier wins.
        enum SourcePiece {
            case wiki(WikiLinkMatch)
            case math(MDMathSpan)
            case plugin(BuiltInPluginToken)
        }
        var pieces: [(range: NSRange, piece: SourcePiece)] =
            wikiMatches.map { ($0.range, .wiki($0)) }
            + mathMatches.map { ($0.range, .math($0)) }
            + pluginMatches.map { ($0.range, .plugin($0.token)) }
        pieces.sort { $0.range.location < $1.range.location }
        let ns = source as NSString
        var cursor = 0
        for (range, piece) in pieces {
            guard range.location >= cursor else { continue }
            if range.location > cursor {
                appendTextWithHighlights(
                    ns.substring(with: NSRange(location: cursor,
                                               length: range.location - cursor)),
                    block: block, styles: styles, link: link)
            }
            var attrs = baseAttributes(block: block, styles: styles, link: link)
            switch piece {
            case .wiki(let m):
                attrs[.mdWikiLink] = m.payload
                out.append(NSAttributedString(string: m.payload.displayText,
                                              attributes: attrs))
            case .math(let m):
                attrs[.mdMath] = m.display ? 1 : 0
                appendMathRun(verbatim: ns.substring(with: range),
                              tex: ns.substring(with: m.innerRange),
                              display: m.display, attrs: attrs)
            case .plugin(let token):
                out.append(builtInPluginTokenAttributedString(
                    token.payload,
                    font: attrs[.font] as? NSFont ?? style.font(for: styles,
                                                               blockKind: block.kind),
                    textColor: attrs[.foregroundColor] as? NSColor ?? .labelColor,
                    attributes: attrs))
            }
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length {
            appendTextWithHighlights(
                ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)),
                block: block, styles: styles, link: link)
        }
    }

    /// Splits `==inner==` out of a plain text run (Obsidian highlight). Markers
    /// are dropped from display; inner text carries `.highlight` for yellow mark
    /// styling and for serialize → `==…==`.
    private func appendTextWithHighlights(_ string: String, block: MDBlock,
                                          styles: MDInlineStyle, link: String?) {
        let marks = scanHighlightMarks(in: string)
        guard !marks.isEmpty else {
            appendText(string, block: block, styles: styles, link: link); return
        }
        let ns = string as NSString
        var cursor = 0
        for m in marks {
            if m.range.location > cursor {
                appendText(ns.substring(with: NSRange(location: cursor,
                                                      length: m.range.location - cursor)),
                           block: block, styles: styles, link: link)
            }
            appendText(m.inner, block: block, styles: styles.union(.highlight), link: link)
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length {
            appendText(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)),
                       block: block, styles: styles, link: link)
        }
    }

    private func baseAttributes(block: MDBlock, styles: MDInlineStyle,
                                link: String?) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: style.font(for: styles, blockKind: block.kind),
            .foregroundColor: link != nil ? NSColor.linkColor : NSColor.labelColor,
        ]
        if !styles.isEmpty { attrs[.mdInline] = styles.rawValue }
        if let link { attrs[.mdLink] = link }
        if styles.contains(.strike) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    /// Appends one display paragraph: inline content + "\n", then stamps the
    /// block attribute over the whole range (including the newline, so empty
    /// paragraphs stay identifiable).
    private func appendParagraph(_ block: MDBlock, build: (MDBlock) -> Void) {
        let start = out.length
        build(block)
        out.append(NSAttributedString(string: "\n",
                                      attributes: baseAttributes(block: block, styles: [],
                                                                 link: nil)))
        out.addAttribute(.mdBlock, value: block,
                         range: NSRange(location: start, length: out.length - start))
    }
}

// MARK: - Large-table cell inline rendering (display-only)

/// Renders a GFM table cell's *inline* markdown as an attributed string for
/// virtualized large-table drawing. Markers (`**`, `` ` ``, `[[…]]`, …) are
/// stripped; styles match Visual mode (bold/italic/strike/code/link/wiki-link).
///
/// Display-only — never feeds serialization. The cell source stays raw markdown
/// in the `.raw` island / editor overlay.
func renderTableCellAttributed(_ markdown: String,
                               baseFont: NSFont,
                               textColor: NSColor,
                               linkColor: NSColor,
                               codeColor: NSColor,
                               codeBackground: NSColor = NSColor(white: 0.5, alpha: 0.12),
                               boldColor: NSColor? = nil,
                               pluginSnapshot: BuiltInPluginSnapshot = .empty)
    -> NSAttributedString {
    let out = NSMutableAttributedString()
    guard !markdown.isEmpty else { return out }
    let doc = Document(parsing: markdown)
    let sourceUTF8 = markdown.utf8
    let sourceUTF8Count = sourceUTF8.count

    /// GFM table cells are single-line sources. Slice a Text node directly by
    /// its UTF-8 columns so escape information survives without a per-cell
    /// LineIndex or a second parse.
    func rawSource(for text: Markdown.Text) -> String? {
        guard let range = text.range,
              range.lowerBound.line == 1, range.upperBound.line == 1 else { return nil }
        let lower = range.lowerBound.column - 1
        let upper = range.upperBound.column - 1
        guard lower >= 0, upper >= lower, upper <= sourceUTF8Count else { return nil }
        let start = sourceUTF8.index(sourceUTF8.startIndex, offsetBy: lower)
        let end = sourceUTF8.index(sourceUTF8.startIndex, offsetBy: upper)
        return String(decoding: sourceUTF8[start..<end], as: UTF8.self)
    }

    func font(for styles: MDInlineStyle) -> NSFont {
        if styles.contains(.code) {
            return NSFont.monospacedSystemFont(ofSize: max(9, baseFont.pointSize - 1),
                                               weight: .regular)
        }
        var traits = baseFont.fontDescriptor.symbolicTraits
        if styles.contains(.bold) { traits.insert(.bold) }
        if styles.contains(.italic) { traits.insert(.italic) }
        if traits != baseFont.fontDescriptor.symbolicTraits {
            let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
            if let f = NSFont(descriptor: descriptor, size: baseFont.pointSize) { return f }
        }
        return baseFont
    }

    func append(_ string: String, styles: MDInlineStyle, isLink: Bool) {
        guard !string.isEmpty else { return }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(for: styles),
            .foregroundColor: textColor,
        ]
        if isLink {
            attrs[.foregroundColor] = linkColor
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        } else if styles.contains(.code) {
            attrs[.foregroundColor] = codeColor
            attrs[.backgroundColor] = codeBackground
        } else if styles.contains(.bold), let boldColor {
            attrs[.foregroundColor] = boldColor
        }
        if styles.contains(.strike) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        out.append(NSAttributedString(string: string, attributes: attrs))
    }

    func appendTextWithWikiLinks(_ text: String, source: String,
                                 styles: MDInlineStyle, isLink: Bool) {
        let wikiMatches = scanWikiLinks(in: text)
        let mathMatches = scanMathSpans(in: text)
        let ns = text as NSString
        var pluginMatches: [(range: NSRange, payload: BuiltInPluginTokenPayload)] = []
        if !isLink, !styles.contains(.code) {
            pluginMatches = pluginSnapshot.tokenCandidates(
                in: text, matching: source).compactMap { candidate in
                let protected = wikiMatches.contains {
                    NSIntersectionRange($0.range, candidate.range).length > 0
                } || mathMatches.contains {
                    NSIntersectionRange($0.range, candidate.range).length > 0
                }
                return protected ? nil : (candidate.range, candidate.payload)
            }
        }
        guard !wikiMatches.isEmpty || !pluginMatches.isEmpty else {
            append(text, styles: styles, isLink: isLink)
            return
        }
        enum Piece {
            case wiki(WikiLinkMatch)
            case plugin(BuiltInPluginTokenPayload)
        }
        var pieces: [(range: NSRange, piece: Piece)] = wikiMatches.map { ($0.range, .wiki($0)) }
            + pluginMatches.map { ($0.range, .plugin($0.payload)) }
        pieces.sort { $0.range.location < $1.range.location }
        var cursor = 0
        for (range, piece) in pieces where range.location >= cursor {
            if range.location > cursor {
                append(ns.substring(with: NSRange(location: cursor,
                                                  length: range.location - cursor)),
                       styles: styles, isLink: isLink)
            }
            switch piece {
            case .wiki(let match):
                append(match.payload.displayText, styles: styles, isLink: true)
            case .plugin(let payload):
                var attrs: [NSAttributedString.Key: Any] = [
                    .font: font(for: styles),
                    .foregroundColor: textColor,
                ]
                if styles.contains(.strike) {
                    attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                out.append(builtInPluginTokenAttributedString(
                    payload, font: font(for: styles), textColor: textColor,
                    attributes: attrs))
            }
            cursor = NSMaxRange(range)
        }
        if cursor < ns.length {
            append(ns.substring(with: NSRange(location: cursor, length: ns.length - cursor)),
                   styles: styles, isLink: isLink)
        }
    }

    func walk(_ children: MarkupChildren, styles: MDInlineStyle, isLink: Bool) {
        for child in children {
            switch child {
            case let text as Markdown.Text:
                // Don't scan wiki-links inside code or already-linked text.
                if styles.contains(.code) || isLink {
                    append(text.string, styles: styles, isLink: isLink)
                } else {
                    appendTextWithWikiLinks(text.string,
                                            source: rawSource(for: text) ?? text.string,
                                            styles: styles, isLink: isLink)
                }
            case let strong as Strong:
                walk(strong.children, styles: styles.union(.bold), isLink: isLink)
            case let emphasis as Emphasis:
                walk(emphasis.children, styles: styles.union(.italic), isLink: isLink)
            case let strike as Strikethrough:
                walk(strike.children, styles: styles.union(.strike), isLink: isLink)
            case let code as InlineCode:
                append(code.code, styles: styles.union(.code), isLink: isLink)
            case let link as Markdown.Link:
                walk(link.children, styles: styles, isLink: true)
            case let image as Markdown.Image:
                let alt = image.plainText
                append(alt.isEmpty ? "□" : alt, styles: styles, isLink: isLink)
            case is SoftBreak, is LineBreak:
                append(" ", styles: styles, isLink: isLink)
            case let html as InlineHTML:
                append(html.rawHTML, styles: styles.union(.rawHTML), isLink: isLink)
            default:
                // Unknown inline — fall back to formatted text without markers when possible.
                if !(child is BlockMarkup) {
                    walk(child.children, styles: styles, isLink: isLink)
                }
            }
        }
    }

    for child in doc.children {
        if let paragraph = child as? Paragraph {
            if out.length > 0 { append(" ", styles: [], isLink: false) }
            walk(paragraph.children, styles: [], isLink: false)
        } else if let text = child as? Markdown.Text {
            if out.length > 0 { append(" ", styles: [], isLink: false) }
            appendTextWithWikiLinks(text.string, source: rawSource(for: text) ?? text.string,
                                    styles: [], isLink: false)
        } else {
            // Unexpected block inside a cell — keep plain (no pipe re-introduction).
            let plain = child.format().trimmingCharacters(in: .whitespacesAndNewlines)
            if !plain.isEmpty {
                if out.length > 0 { append(" ", styles: [], isLink: false) }
                append(plain, styles: [], isLink: false)
            }
        }
    }

    // Parser edge case: empty document (e.g. only spaces) — show original trimmed.
    if out.length == 0, !markdown.trimmingCharacters(in: .whitespaces).isEmpty {
        append(markdown, styles: [], isLink: false)
    }
    return out
}
