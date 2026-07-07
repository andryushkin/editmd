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
    static let bold    = MDInlineStyle(rawValue: 1 << 0)
    static let italic  = MDInlineStyle(rawValue: 1 << 1)
    static let strike  = MDInlineStyle(rawValue: 1 << 2)
    static let code    = MDInlineStyle(rawValue: 1 << 3)
    static let rawHTML = MDInlineStyle(rawValue: 1 << 4)  // inline HTML: no escaping
}

struct MDBlock: Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case codeBlock(language: String)
        case bulletItem(depth: Int)
        case orderedItem(depth: Int, number: Int)
        case taskItem(depth: Int, done: Bool)
        /// Extra paragraph of a multi-paragraph list item; indent = content column.
        case listContinuation(indent: Int)
        case thematicBreak
        /// One table cell; alignment: 0 none / 1 left / 2 center / 3 right
        /// (column-level, stored on every cell of the column). Cells of one
        /// table share `group`.
        case tableCell(row: Int, column: Int, columns: Int, alignment: Int)
        /// Read-only island: serialized verbatim from the stored source text.
        case raw(String)
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
}

/// Intra-paragraph hard line break (markdown "  \n" / "\<newline>").
let mdHardBreak = "\u{2028}"
/// Placeholder character for images and thematic breaks.
let mdObjectChar = "\u{FFFC}"

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
                                style: VisualStyle = VisualStyle()) -> NSAttributedString {
    VisualRenderer(source: markdown, style: style).run()
}

private final class VisualRenderer {
    let style: VisualStyle
    let source: String
    let nsSource: NSString
    let lineIdx: LineIndex
    let out = NSMutableAttributedString()
    private var groupCounter = 0

    init(source: String, style: VisualStyle) {
        self.source = source
        self.style = style
        self.nsSource = source as NSString
        self.lineIdx = LineIndex(source)
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
        let document = Document(parsing: source)
        for child in document.children {
            renderBlock(child, ctx: Ctx())
        }
        return out
    }

    // MARK: Block dispatch

    private func renderBlock(_ block: Markup, ctx: Ctx) {
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

    private func renderTable(_ table: Markdown.Table, ctx: Ctx) {
        let group = nextGroup()
        let alignments = table.columnAlignments
        let columns = max(1, alignments.count)

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
        case .bulletItem, .orderedItem, .taskItem, .listContinuation:
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
                kind = .taskItem(depth: depth, done: checkbox == .checked)
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

    // MARK: Islands

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
                appendText(text.string, block: block, styles: styles, link: link)
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
