import Foundation
import Markdown

// MARK: - Line Index

/// Maps swift-markdown's 1-based (line, UTF-8 column) positions to UTF-16 NSRange offsets.
struct LineIndex {
    /// utf8To16[byteOffset] = UTF-16 unit offset at the start of that byte.
    private let utf8To16: [Int]
    /// 0-indexed: entry n = UTF-8 byte start of line n+1.
    private let lineU8: [Int]
    /// 0-indexed: entry n = UTF-16 offset start of line n+1.
    private let lineU16: [Int]

    init(_ string: String) {
        var u8 = [0], u16 = [0]
        var map = [Int]()
        var c16 = 0
        for scalar in string.unicodeScalars {
            let nb = scalar.utf8.count
            for _ in 0..<nb { map.append(c16) }
            c16 += scalar.utf16.count
            if scalar.value == 0x0A {
                u8.append(map.count)
                u16.append(c16)
            }
        }
        map.append(c16)  // sentinel: one past the end
        self.utf8To16 = map
        self.lineU8 = u8
        self.lineU16 = u16
    }

    var lineCount: Int { lineU8.count }

    /// 1-based line + 1-based UTF-8 byte column → UTF-16 unit offset.
    func offset(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        return b < utf8To16.count ? utf8To16[b] : utf8To16.last ?? 0
    }

    /// UTF-16 offset AFTER the character at (1-based line, 1-based UTF-8 col).
    func offsetAfter(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        guard b < utf8To16.count else { return utf8To16.last ?? 0 }
        let v = utf8To16[b]
        var n = b + 1
        while n < utf8To16.count, utf8To16[n] == v { n += 1 }
        return n < utf8To16.count ? utf8To16[n] : utf8To16.last ?? 0
    }

    /// NSRange for cmark node positions (1-based, endCol inclusive).
    func range(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> NSRange? {
        let loc = offset(sl, sc)
        let end = offsetAfter(el, ec)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    /// UTF-16 start offset of a line (1-based line number).
    func lineStart(_ line: Int) -> Int {
        guard line >= 1, line <= lineU16.count else { return utf8To16.count - 1 }
        return lineU16[line - 1]
    }
}

// MARK: - Highlight Span

struct Span {
    enum Kind: Equatable {
        // Existing
        case headingBody(Int), headingMarker
        case boldBody, boldMarker
        case italicBody, italicMarker
        case code
        case codeMarker
        case linkText(destination: String?), linkSyntax
        case quoteBody, quoteMarker
        // New
        case codeBlockBody(language: String), codeBlockFence
        case thematicBreak
        case listBlock                                // full UnorderedList/OrderedList range
        case listMarker(ordered: Bool, depth: Int)   // depth: nesting level (0 = top)
        case imageText, imageSyntax
        case htmlInline
        case htmlBlock
        case strikethroughBody, strikethroughMarker
        case tableDelimiter
        case tableHeader
        case listItemBody(textStartCol: Int)  // full item range; 1-based col where text begins (after spaces + marker)
        case tableRow                    // alternating body rows, for background
        case taskListMarker(done: Bool)  // the [ ] or [x] part of a task list item
    }
    var range: NSRange
    var kind: Kind
}

// MARK: - SpanCollector

/// MarkupWalker that traverses the swift-markdown AST and collects highlight spans.
private struct SpanCollector: MarkupWalker {
    let nsText: NSString
    let lineIdx: LineIndex
    var spans: [Span] = []

    init(text: String, lineIdx: LineIndex) {
        self.nsText = text as NSString
        self.lineIdx = lineIdx
    }

    // MARK: Helpers

    /// Convert swift-markdown's exclusive SourceRange to NSRange.
    /// swift-markdown: lowerBound inclusive, upperBound exclusive (endColumn = cmark_ec + 1).
    private func nsRange(for srcRange: SourceRange) -> NSRange? {
        let loc = lineIdx.offset(srcRange.lowerBound.line, srcRange.lowerBound.column)
        let end = lineIdx.offset(srcRange.upperBound.line, srcRange.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    // MARK: Block elements

    mutating func visitHeading(_ heading: Heading) {
        guard let src = heading.range, let r = nsRange(for: src) else {
            descendInto(heading); return
        }
        let lv = heading.level
        spans.append(Span(range: r, kind: .headingBody(lv)))
        let isATX = r.location < nsText.length && nsText.character(at: r.location) == 0x23  // '#'
        if isATX {
            let markerLen = min(lv + 1, r.length)
            spans.append(Span(range: NSRange(location: r.location, length: markerLen), kind: .headingMarker))
        } else if src.upperBound.line > src.lowerBound.line {
            // Setext heading: the marker is the ===/--- underline (last line of the range),
            // not a prefix of the title text.
            let underlineStart = lineIdx.lineStart(src.upperBound.line)
            if underlineStart > r.location, underlineStart < NSMaxRange(r) {
                spans.append(Span(range: NSRange(location: underlineStart,
                                                 length: NSMaxRange(r) - underlineStart),
                                  kind: .headingMarker))
            }
        }
        descendInto(heading)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        guard let srcRange = blockQuote.range, let r = nsRange(for: srcRange) else {
            descendInto(blockQuote); return
        }
        spans.append(Span(range: r, kind: .quoteBody))
        let sc = srcRange.lowerBound.column
        let sl = srcRange.lowerBound.line
        let el = srcRange.upperBound.line
        for line in sl...el {
            let markerLoc = lineIdx.offset(line, sc)
            guard markerLoc < NSMaxRange(r), markerLoc < nsText.length else { continue }
            if nsText.substring(with: NSRange(location: markerLoc, length: 1)) == ">" {
                let mLen = min(2, NSMaxRange(r) - markerLoc)
                spans.append(Span(range: NSRange(location: markerLoc, length: mLen), kind: .quoteMarker))
            }
        }
        descendInto(blockQuote)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) {
        guard let srcRange = codeBlock.range, let r = nsRange(for: srcRange) else { return }
        let lang = codeBlock.language ?? ""
        spans.append(Span(range: r, kind: .codeBlockBody(language: lang)))
        // Detect fenced block by looking at the first character (` or ~).
        // swift-markdown maps both indented and fenced-no-lang to language=nil,
        // so we check the source text instead.
        let isFenced = r.location < nsText.length && {
            let ch = nsText.character(at: r.location)
            return ch == 0x60 || ch == 0x7E  // ` or ~
        }()
        if isFenced {
            let sl = srcRange.lowerBound.line
            let el = srcRange.upperBound.line
            // Opening fence: from block start to end of first line
            if sl < lineIdx.lineCount {
                let nextLineStart = lineIdx.lineStart(sl + 1)
                let openLen = nextLineStart - r.location
                if openLen > 0 {
                    spans.append(Span(range: NSRange(location: r.location, length: openLen),
                                      kind: .codeBlockFence))
                }
            }
            // Closing fence: last line of the block
            if el > sl {
                let closeStart = lineIdx.lineStart(el)
                let closeLen = NSMaxRange(r) - closeStart
                if closeLen > 0, closeStart >= r.location {
                    spans.append(Span(range: NSRange(location: closeStart, length: closeLen),
                                      kind: .codeBlockFence))
                }
            }
        }
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) {
        guard let r = thematicBreak.range.flatMap({ nsRange(for: $0) }) else { return }
        spans.append(Span(range: r, kind: .thematicBreak))
    }

    mutating func visitListItem(_ listItem: ListItem) {
        guard let srcRange = listItem.range else { descendInto(listItem); return }
        let sl = srcRange.lowerBound.line
        let sc = srcRange.lowerBound.column
        let markerStart = lineIdx.offset(sl, sc)
        guard markerStart < nsText.length else { descendInto(listItem); return }

        let isOrdered = listItem.parent is OrderedList
        var markerLen = 2  // default: "- " or "* "
        if isOrdered {
            // Scan: digits, then delimiter (. or )), then space
            let maxScan = min(10, nsText.length - markerStart)
            var i = 0
            while i < maxScan {
                let ch = nsText.character(at: markerStart + i)
                guard ch >= 0x30, ch <= 0x39 else { break }  // '0'-'9'
                i += 1
            }
            if i < maxScan { i += 1 }  // delimiter (. or ))
            if i < maxScan { i += 1 }  // space
            markerLen = i
        }

        // Nesting depth: count ancestor ListItem nodes
        var depth = 0
        var ancestor: Markup? = listItem.parent?.parent  // skip immediate containing list
        while let n = ancestor {
            if n is ListItem { depth += 1 }
            ancestor = n.parent
        }

        if markerLen > 0, markerStart + markerLen <= nsText.length {
            spans.append(Span(range: NSRange(location: markerStart, length: markerLen),
                              kind: .listMarker(ordered: isOrdered, depth: depth)))
        }

        // Full item range for paragraph spacing
        if let fullRange = nsRange(for: srcRange) {
            spans.append(Span(range: fullRange, kind: .listItemBody(textStartCol: sc + markerLen)))
        }

        // Task list: swift-markdown parses "[ ]"/"[x]" into ListItem.checkbox.
        // The checkbox occupies 3 chars starting right after the list marker.
        if let checkbox = listItem.checkbox {
            let cbStart = markerStart + markerLen
            if cbStart + 3 <= nsText.length, nsText.character(at: cbStart) == 0x5B {  // '['
                spans.append(Span(range: NSRange(location: cbStart, length: 3),
                                  kind: .taskListMarker(done: checkbox == .checked)))
            }
        }

        descendInto(listItem)
    }

    mutating func visitUnorderedList(_ list: UnorderedList) {
        if let r = list.range.flatMap({ nsRange(for: $0) }) {
            spans.append(Span(range: r, kind: .listBlock))
        }
        descendInto(list)
    }

    mutating func visitOrderedList(_ list: OrderedList) {
        if let r = list.range.flatMap({ nsRange(for: $0) }) {
            spans.append(Span(range: r, kind: .listBlock))
        }
        descendInto(list)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard let r = html.range.flatMap({ nsRange(for: $0) }) else { return }
        spans.append(Span(range: r, kind: .htmlBlock))
    }

    mutating func visitTable(_ table: Table) {
        guard let srcRange = table.range, let r = nsRange(for: srcRange) else {
            descendInto(table); return
        }
        // Header row: first line of the table
        let sl = srcRange.lowerBound.line
        let el = srcRange.upperBound.line
        let headerEnd = sl < lineIdx.lineCount ? lineIdx.lineStart(sl + 1) : NSMaxRange(r)
        let headerLen = min(headerEnd - r.location, r.length)
        if headerLen > 0 {
            spans.append(Span(range: NSRange(location: r.location, length: headerLen),
                              kind: .tableHeader))
        }
        // All '|' delimiters in the table range
        for i in r.location..<NSMaxRange(r) {
            guard i < nsText.length else { break }
            if nsText.character(at: i) == 0x7C {  // '|'
                spans.append(Span(range: NSRange(location: i, length: 1), kind: .tableDelimiter))
            }
        }
        // Alternating body row backgrounds (every other row starting from index 1)
        // Table structure: line sl = header, sl+1 = delimiter (|---|), sl+2+ = body rows
        let bodyCount = max(0, el - sl - 1)  // number of body rows
        for rowIdx in 0..<bodyCount {
            let rowLine = sl + 2 + rowIdx
            let rowStart = max(r.location, lineIdx.lineStart(rowLine))
            let rowEnd   = min(NSMaxRange(r), rowLine < lineIdx.lineCount
                               ? lineIdx.lineStart(rowLine + 1)
                               : NSMaxRange(r))
            let rowLen = rowEnd - rowStart
            guard rowLen > 0 else { continue }
            if rowIdx % 2 == 1 {
                spans.append(Span(range: NSRange(location: rowStart, length: rowLen),
                                  kind: .tableRow))
            }
        }

        // Descend to allow Strong/Emphasis/InlineCode inside cells to be highlighted
        descendInto(table)
    }

    // MARK: Inline elements

    mutating func visitStrong(_ strong: Strong) {
        guard let r = strong.range.flatMap({ nsRange(for: $0) }), r.length >= 4 else {
            descendInto(strong); return
        }
        spans.append(Span(range: r, kind: .boldBody))
        spans.append(Span(range: NSRange(location: r.location, length: 2), kind: .boldMarker))
        spans.append(Span(range: NSRange(location: NSMaxRange(r) - 2, length: 2), kind: .boldMarker))
        descendInto(strong)
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) {
        guard let r = emphasis.range.flatMap({ nsRange(for: $0) }), r.length >= 2 else {
            descendInto(emphasis); return
        }
        spans.append(Span(range: r, kind: .italicBody))
        spans.append(Span(range: NSRange(location: r.location, length: 1), kind: .italicMarker))
        spans.append(Span(range: NSRange(location: NSMaxRange(r) - 1, length: 1), kind: .italicMarker))
        descendInto(emphasis)
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) {
        // swift-markdown adjusts InlineCode.range to include backticks:
        //   start.column = cmark_sc - bt, end.column = cmark_ec + 1 + bt
        // So range covers the full `...` span. code gives only the content.
        guard let r = inlineCode.range.flatMap({ nsRange(for: $0) }) else { return }
        let bt = (r.length - inlineCode.code.utf16.count) / 2
        guard bt > 0 else { return }
        let bodyLen = r.length - 2 * bt
        let openRange  = NSRange(location: r.location, length: bt)
        let bodyRange  = NSRange(location: r.location + bt, length: bodyLen)
        let closeRange = NSRange(location: NSMaxRange(r) - bt, length: bt)
        if openRange.length > 0  { spans.append(Span(range: openRange,  kind: .codeMarker)) }
        if bodyRange.length >= 0 { spans.append(Span(range: bodyRange,  kind: .code)) }
        if closeRange.length > 0 { spans.append(Span(range: closeRange, kind: .codeMarker)) }
    }

    mutating func visitLink(_ link: Link) {
        guard let fullSrc = link.range, let r = nsRange(for: fullSrc) else {
            descendInto(link); return
        }
        let childrenArr = Array(link.children)
        if let firstChild = childrenArr.first, let lastChild = childrenArr.last,
           let firstSrc = firstChild.range, let lastSrc = lastChild.range,
           let textRange = nsRange(for: firstSrc.lowerBound..<lastSrc.upperBound) {
            spans.append(Span(range: textRange, kind: .linkText(destination: link.destination)))
            let beforeLen = textRange.location - r.location
            if beforeLen > 0 {
                spans.append(Span(range: NSRange(location: r.location, length: beforeLen),
                                  kind: .linkSyntax))
            }
            let afterLen = NSMaxRange(r) - NSMaxRange(textRange)
            if afterLen > 0 {
                spans.append(Span(range: NSRange(location: NSMaxRange(textRange), length: afterLen),
                                  kind: .linkSyntax))
            }
        } else {
            spans.append(Span(range: r, kind: .linkSyntax))
        }
        descendInto(link)
    }

    mutating func visitImage(_ image: Image) {
        guard let fullSrc = image.range, let r = nsRange(for: fullSrc) else {
            descendInto(image); return
        }
        let childrenArr = Array(image.children)
        if let firstChild = childrenArr.first, let lastChild = childrenArr.last,
           let firstSrc = firstChild.range, let lastSrc = lastChild.range,
           let textRange = nsRange(for: firstSrc.lowerBound..<lastSrc.upperBound) {
            spans.append(Span(range: textRange, kind: .imageText))
            let beforeLen = textRange.location - r.location
            if beforeLen > 0 {
                spans.append(Span(range: NSRange(location: r.location, length: beforeLen),
                                  kind: .imageSyntax))
            }
            let afterLen = NSMaxRange(r) - NSMaxRange(textRange)
            if afterLen > 0 {
                spans.append(Span(range: NSRange(location: NSMaxRange(textRange), length: afterLen),
                                  kind: .imageSyntax))
            }
        } else {
            spans.append(Span(range: r, kind: .imageSyntax))
        }
        descendInto(image)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) {
        guard let r = inlineHTML.range.flatMap({ nsRange(for: $0) }) else { return }
        spans.append(Span(range: r, kind: .htmlInline))
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) {
        guard let r = strikethrough.range.flatMap({ nsRange(for: $0) }), r.length >= 4 else {
            descendInto(strikethrough); return
        }
        spans.append(Span(range: r, kind: .strikethroughBody))
        spans.append(Span(range: NSRange(location: r.location, length: 2), kind: .strikethroughMarker))
        spans.append(Span(range: NSRange(location: NSMaxRange(r) - 2, length: 2), kind: .strikethroughMarker))
        descendInto(strikethrough)
    }
}

// MARK: - collectSpans

/// Parses the markdown text with swift-markdown and returns highlight spans.
/// Pure function — no dependency on any view or controller.
func collectSpans(_ text: String) -> [Span] {
    guard !text.isEmpty else { return [] }
    let lineIdx = LineIndex(text)
    // Document(parsing:) auto-enables GFM extensions: table, strikethrough, tasklist.
    let document = Document(parsing: text)
    var collector = SpanCollector(text: text, lineIdx: lineIdx)
    collector.visit(document)
    return collector.spans
}
