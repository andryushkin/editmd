import XCTest
@testable import EditMD

// All tests are synchronous pure-function calls — no AppKit lifecycle, no MainActor needed.

// MARK: - LineIndex Tests

final class LineIndexTests: XCTestCase {

    // MARK: ASCII single-line (no trailing newline)

    func testOffsetASCIISingleLine() {
        let idx = LineIndex("Hello")
        XCTAssertEqual(idx.offset(1, 1), 0)
        XCTAssertEqual(idx.offset(1, 5), 4)
    }

    func testOffsetAfterASCIISingleLine() {
        let idx = LineIndex("Hello")
        XCTAssertEqual(idx.offsetAfter(1, 5), 5)
        XCTAssertEqual(idx.offsetAfter(1, 1), 1)
    }

    func testRangeASCIIFullLine() {
        let idx = LineIndex("Hello")
        XCTAssertEqual(idx.range(1, 1, 1, 5), NSRange(location: 0, length: 5))
    }

    // MARK: 2-byte UTF-8 scalar (é = U+00E9, 1 UTF-16 unit)

    func testOffsetTwoByteScalar() {
        // "café" = c(1) a(1) f(1) é(2 UTF-8) = 5 UTF-8 bytes, 4 UTF-16 units
        let idx = LineIndex("café")
        // byte 4 (first byte of é) → UTF-16 3
        XCTAssertEqual(idx.offset(1, 4), 3)
        // byte 5 (second byte of é) → also UTF-16 3
        XCTAssertEqual(idx.offset(1, 5), 3)
        // offsetAfter(1,5): val=3, next entry sentinel=4 → return 4
        XCTAssertEqual(idx.offsetAfter(1, 5), 4)
    }

    func testRangeTwoByteScalar() {
        // "café": cmark ec=5 (5 UTF-8 bytes), UTF-16 length = 4
        let idx = LineIndex("café")
        XCTAssertEqual(idx.range(1, 1, 1, 5), NSRange(location: 0, length: 4))
    }

    // MARK: 4-byte UTF-8 scalar (🎉 = U+1F389, 2 UTF-16 surrogates)

    func testOffsetFourByteScalar() {
        // "# 🎉" = #(1) space(1) 🎉(4 UTF-8, 2 UTF-16) = 6 UTF-8 bytes, 4 UTF-16 units
        let idx = LineIndex("# 🎉")
        // bytes 2..5 all map to UTF-16 offset 2
        XCTAssertEqual(idx.offset(1, 3), 2)
        XCTAssertEqual(idx.offset(1, 6), 2)
        // offsetAfter(1,6): val=2, sentinel=4 → return 4
        XCTAssertEqual(idx.offsetAfter(1, 6), 4)
    }

    func testRangeFourByteScalar() {
        let idx = LineIndex("# 🎉")
        XCTAssertEqual(idx.range(1, 1, 1, 6), NSRange(location: 0, length: 4))
    }

    // MARK: Multi-line

    func testMultiLineOffsets() {
        // "ab\ncd": line1=ab+\n, line2=cd
        let idx = LineIndex("ab\ncd")
        XCTAssertEqual(idx.lineCount, 2)
        XCTAssertEqual(idx.lineStart(1), 0)
        XCTAssertEqual(idx.lineStart(2), 3)  // UTF-16 offset of 'c'
        XCTAssertEqual(idx.offset(2, 1), 3)
        XCTAssertEqual(idx.offset(2, 2), 4)
    }

    // MARK: Edge cases

    func testEmptyString() {
        let idx = LineIndex("")
        XCTAssertEqual(idx.lineCount, 1)
        // Does not crash; returns sentinel (0)
        XCTAssertEqual(idx.offset(1, 1), 0)
    }

    func testOutOfBoundsLine() {
        let idx = LineIndex("Hello")
        // sentinel = utf8To16.count - 1 = 5
        XCTAssertEqual(idx.offset(0, 1), 5)
        XCTAssertEqual(idx.offset(2, 1), 5)
    }
}

// MARK: - collectSpans Tests

final class CollectSpansTests: XCTestCase {

    // MARK: Empty / plain text

    func testEmptyStringReturnsNoSpans() {
        XCTAssertTrue(collectSpans("").isEmpty)
    }

    func testPlainTextReturnsNoSpans() {
        XCTAssertTrue(collectSpans("Hello world").isEmpty)
    }

    // MARK: Headings

    func testH1() {
        // "# Hello" = 7 ASCII chars
        let spans = collectSpans("# Hello")
        let bodies  = spans.filter { if case .headingBody(1) = $0.kind { return true }; return false }
        let markers = spans.filter { if case .headingMarker  = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count,  1)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 7))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    func testH2() {
        // "## Hello" = 8 ASCII chars, lv=2, markerLen=3
        let spans = collectSpans("## Hello")
        let bodies  = spans.filter { if case .headingBody(2) = $0.kind { return true }; return false }
        let markers = spans.filter { if case .headingMarker  = $0.kind { return true }; return false }
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 8))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 3))
    }

    func testH6() {
        // "###### H6" = 9 ASCII chars, lv=6, markerLen=7
        let spans = collectSpans("###### H6")
        let bodies  = spans.filter { if case .headingBody(6) = $0.kind { return true }; return false }
        let markers = spans.filter { if case .headingMarker  = $0.kind { return true }; return false }
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 9))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 7))
    }

    func testHeadingWithTwoByteContent() {
        // "# café" = # + space + café (5 UTF-8) = 7 UTF-8 bytes, 6 UTF-16 units
        let spans = collectSpans("# café")
        let bodies  = spans.filter { if case .headingBody(1) = $0.kind { return true }; return false }
        let markers = spans.filter { if case .headingMarker  = $0.kind { return true }; return false }
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 6))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    func testHeadingWithEmoji() {
        // "# 🎉" = 6 UTF-8 bytes, 4 UTF-16 units
        let spans = collectSpans("# 🎉")
        let bodies  = spans.filter { if case .headingBody(1) = $0.kind { return true }; return false }
        let markers = spans.filter { if case .headingMarker  = $0.kind { return true }; return false }
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 4))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    // MARK: Bold

    func testBold() {
        // "**bold**" = 8 ASCII chars
        let spans = collectSpans("**bold**")
        let bodies  = spans.filter { if case .boldBody   = $0.kind { return true }; return false }
        let markers = spans.filter { if case .boldMarker = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count,  1)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(bodies[0].range, NSRange(location: 0, length: 8))
        let sorted = markers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(sorted[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(sorted[1].range, NSRange(location: 6, length: 2))
    }

    // MARK: Italic

    func testItalic() {
        // "*italic*" = 8 ASCII chars
        let spans = collectSpans("*italic*")
        let bodies  = spans.filter { if case .italicBody   = $0.kind { return true }; return false }
        let markers = spans.filter { if case .italicMarker = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count,  1)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(bodies[0].range, NSRange(location: 0, length: 8))
        let sorted = markers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(sorted[0].range, NSRange(location: 0, length: 1))
        XCTAssertEqual(sorted[1].range, NSRange(location: 7, length: 1))
    }

    // MARK: Bold + Italic nesting

    func testBoldItalicNesting() {
        // "**bold *italic* bold**" = 22 chars
        // STRONG: NSRange(0,22); EMPH: NSRange(7,8)
        let input = "**bold *italic* bold**"
        let spans = collectSpans(input)

        let boldBodies   = spans.filter { if case .boldBody   = $0.kind { return true }; return false }
        let boldMarkers  = spans.filter { if case .boldMarker = $0.kind { return true }; return false }
        let italicBodies  = spans.filter { if case .italicBody   = $0.kind { return true }; return false }
        let italicMarkers = spans.filter { if case .italicMarker = $0.kind { return true }; return false }

        XCTAssertEqual(boldBodies.count,   1)
        XCTAssertEqual(boldMarkers.count,  2)
        XCTAssertEqual(italicBodies.count,  1)
        XCTAssertEqual(italicMarkers.count, 2)

        XCTAssertEqual(boldBodies[0].range, NSRange(location: 0, length: 22))
        let bm = boldMarkers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(bm[0].range, NSRange(location: 0,  length: 2))
        XCTAssertEqual(bm[1].range, NSRange(location: 20, length: 2))

        XCTAssertEqual(italicBodies[0].range, NSRange(location: 7, length: 8))
        let im = italicMarkers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(im[0].range, NSRange(location: 7,  length: 1))
        XCTAssertEqual(im[1].range, NSRange(location: 14, length: 1))
    }

    // MARK: Inline code

    func testInlineCodeSingleBacktick() {
        // "`code`" = 6 ASCII chars, bt=1
        // cmark content sc=2..ec=5; fullLoc=0, fullEnd=6
        let spans = collectSpans("`code`")
        let codes = spans.filter { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes[0].range, NSRange(location: 0, length: 6))
    }

    func testInlineCodeDoubleBacktick() {
        // "``code``" = 8 ASCII chars, bt=2
        // cmark content sc=3..ec=6; fullLoc=0, fullEnd=8
        let spans = collectSpans("``code``")
        let codes = spans.filter { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes[0].range, NSRange(location: 0, length: 8))
    }

    func testInlineCodeMidSentence() {
        // "Use `foo` here": code "`foo`" starts at offset 4, length 5
        let spans = collectSpans("Use `foo` here")
        let codes = spans.filter { if case .code = $0.kind { return true }; return false }
        XCTAssertEqual(codes.count, 1)
        XCTAssertEqual(codes[0].range, NSRange(location: 4, length: 5))
    }

    // MARK: Link

    func testLink() {
        // "[text](url)" = 11 ASCII chars
        // linkText: NSRange(1,4); linkSyntax: NSRange(0,1) + NSRange(5,6)
        let spans = collectSpans("[text](url)")
        let texts   = spans.filter { if case .linkText   = $0.kind { return true }; return false }
        let syntaxes = spans.filter { if case .linkSyntax = $0.kind { return true }; return false }
        XCTAssertEqual(texts.count,    1)
        XCTAssertEqual(syntaxes.count, 2)
        XCTAssertEqual(texts[0].range, NSRange(location: 1, length: 4))
        let sorted = syntaxes.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(sorted[0].range, NSRange(location: 0, length: 1))
        XCTAssertEqual(sorted[1].range, NSRange(location: 5, length: 6))
    }

    func testLinkWithEmptyText() {
        // "[](url)": no text child → falls to else branch, emits linkSyntax for whole range
        let spans = collectSpans("[](url)")
        let texts   = spans.filter { if case .linkText   = $0.kind { return true }; return false }
        let syntaxes = spans.filter { if case .linkSyntax = $0.kind { return true }; return false }
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(syntaxes.isEmpty)
    }

    // MARK: Blockquote

    func testSingleLineBlockquote() {
        // "> quote" = 7 ASCII chars
        let spans = collectSpans("> quote")
        let bodies  = spans.filter { if case .quoteBody   = $0.kind { return true }; return false }
        let markers = spans.filter { if case .quoteMarker = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count,  1)
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(bodies[0].range,  NSRange(location: 0, length: 7))
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    func testMultiLineBlockquote() {
        // "> line1\n> line2" = 15 ASCII chars
        // quoteMarker on line1 at loc=0, on line2 at loc=8
        let input = "> line1\n> line2"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .quoteMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 2)
        let sorted = markers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(sorted[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(sorted[1].range, NSRange(location: 8, length: 2))
    }

    // MARK: Multi-element document

    func testMultiLineDocument() {
        // "# Title\n**bold**": heading on line1, bold on line2 (offset 8)
        let input = "# Title\n**bold**"
        let spans = collectSpans(input)

        let headingBodies = spans.filter { if case .headingBody(1) = $0.kind { return true }; return false }
        let boldBodies    = spans.filter { if case .boldBody        = $0.kind { return true }; return false }
        let boldMarkers   = spans.filter { if case .boldMarker      = $0.kind { return true }; return false }

        XCTAssertEqual(headingBodies.count, 1)
        XCTAssertEqual(headingBodies[0].range.location, 0)  // exact length depends on cmark newline handling

        XCTAssertEqual(boldBodies.count, 1)
        XCTAssertEqual(boldBodies[0].range, NSRange(location: 8, length: 8))

        XCTAssertEqual(boldMarkers.count, 2)
        let bm = boldMarkers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(bm[0].range, NSRange(location: 8,  length: 2))
        XCTAssertEqual(bm[1].range, NSRange(location: 14, length: 2))
    }

    // MARK: - Fenced Code Blocks

    func testFencedCodeBlock() {
        let input = "```\ncode\n```"
        let spans = collectSpans(input)
        let bodies = spans.filter { if case .codeBlockBody = $0.kind { return true }; return false }
        let fences = spans.filter { if case .codeBlockFence = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        // Body covers the entire block
        XCTAssertEqual(bodies[0].range.location, 0)
        XCTAssertTrue(bodies[0].range.length > 0)
        // Two fences: opening and closing
        XCTAssertEqual(fences.count, 2)
    }

    func testFencedCodeBlockWithLanguage() {
        let input = "```swift\nlet x = 1\n```"
        let spans = collectSpans(input)
        let bodies = spans.filter { if case .codeBlockBody = $0.kind { return true }; return false }
        let fences = spans.filter { if case .codeBlockFence = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(fences.count, 2)
    }

    func testIndentedCodeBlock() {
        // Indented code block: 4 spaces, preceded by blank line
        let input = "paragraph\n\n    code line"
        let spans = collectSpans(input)
        let bodies = spans.filter { if case .codeBlockBody = $0.kind { return true }; return false }
        let fences = spans.filter { if case .codeBlockFence = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        // Indented blocks have no fences
        XCTAssertEqual(fences.count, 0)
    }

    func testFencedCodeBlockTilde() {
        let input = "~~~\ncode\n~~~"
        let spans = collectSpans(input)
        let bodies = spans.filter { if case .codeBlockBody = $0.kind { return true }; return false }
        let fences = spans.filter { if case .codeBlockFence = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(fences.count, 2)
    }

    // MARK: - Thematic Breaks

    func testThematicBreakDashes() {
        // Need blank line or heading before, otherwise "---" becomes setext heading
        let input = "text\n\n---"
        let spans = collectSpans(input)
        let breaks = spans.filter { if case .thematicBreak = $0.kind { return true }; return false }
        XCTAssertEqual(breaks.count, 1)
    }

    func testThematicBreakAsterisks() {
        let input = "text\n\n***"
        let spans = collectSpans(input)
        let breaks = spans.filter { if case .thematicBreak = $0.kind { return true }; return false }
        XCTAssertEqual(breaks.count, 1)
    }

    func testThematicBreakUnderscores() {
        let input = "text\n\n___"
        let spans = collectSpans(input)
        let breaks = spans.filter { if case .thematicBreak = $0.kind { return true }; return false }
        XCTAssertEqual(breaks.count, 1)
    }

    // MARK: - List Items

    func testUnorderedListDash() {
        let input = "- item"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    func testUnorderedListAsterisk() {
        // "* item" — asterisk list
        let input = "* item"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 2))
    }

    func testOrderedListSingle() {
        let input = "1. item"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 3))
    }

    func testOrderedListMultiDigit() {
        let input = "10. item"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 1)
        XCTAssertEqual(markers[0].range, NSRange(location: 0, length: 4))
    }

    func testNestedList() {
        let input = "- outer\n  - inner"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 2)
    }

    // MARK: - Images

    func testImage() {
        // "![alt](url)" = 11 chars
        let spans = collectSpans("![alt](url)")
        let texts   = spans.filter { if case .imageText   = $0.kind { return true }; return false }
        let syntaxes = spans.filter { if case .imageSyntax = $0.kind { return true }; return false }
        XCTAssertEqual(texts.count, 1)
        XCTAssertFalse(syntaxes.isEmpty)
    }

    func testImageEmptyAlt() {
        let spans = collectSpans("![](url)")
        let texts   = spans.filter { if case .imageText   = $0.kind { return true }; return false }
        let syntaxes = spans.filter { if case .imageSyntax = $0.kind { return true }; return false }
        XCTAssertTrue(texts.isEmpty)
        XCTAssertFalse(syntaxes.isEmpty)
    }

    func testImageMidSentence() {
        let input = "See ![pic](img.png) here"
        let spans = collectSpans(input)
        let texts = spans.filter { if case .imageText = $0.kind { return true }; return false }
        XCTAssertEqual(texts.count, 1)
        // "pic" starts at position 6 (after "See ![")
        XCTAssertEqual(texts[0].range.location, 6)
        XCTAssertEqual(texts[0].range.length, 3)
    }

    // MARK: - HTML

    func testHtmlInline() {
        let input = "Text <br> more"
        let spans = collectSpans(input)
        let html = spans.filter { if case .htmlInline = $0.kind { return true }; return false }
        XCTAssertEqual(html.count, 1)
    }

    func testHtmlBlock() {
        // HTML block must be preceded by blank line (or be at start of document)
        let input = "<div>\ncontent\n</div>"
        let spans = collectSpans(input)
        let html = spans.filter { if case .htmlBlock = $0.kind { return true }; return false }
        XCTAssertEqual(html.count, 1)
    }

    // MARK: - Strikethrough (GFM extension)

    func testStrikethrough() {
        let spans = collectSpans("~~text~~")
        let bodies  = spans.filter { if case .strikethroughBody   = $0.kind { return true }; return false }
        let markers = spans.filter { if case .strikethroughMarker = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(bodies[0].range, NSRange(location: 0, length: 8))
        let sorted = markers.sorted { $0.range.location < $1.range.location }
        XCTAssertEqual(sorted[0].range, NSRange(location: 0, length: 2))
        XCTAssertEqual(sorted[1].range, NSRange(location: 6, length: 2))
    }

    func testStrikethroughMidSentence() {
        let input = "Hello ~~world~~ end"
        let spans = collectSpans(input)
        let bodies = spans.filter { if case .strikethroughBody = $0.kind { return true }; return false }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies[0].range, NSRange(location: 6, length: 9))
    }

    func testStrikethroughWithBold() {
        let input = "**~~both~~**"
        let spans = collectSpans(input)
        let boldBodies   = spans.filter { if case .boldBody          = $0.kind { return true }; return false }
        let strikeBodies = spans.filter { if case .strikethroughBody = $0.kind { return true }; return false }
        XCTAssertEqual(boldBodies.count, 1)
        XCTAssertEqual(strikeBodies.count, 1)
    }

    // MARK: - Tables (GFM extension)

    func testSimpleTable() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |"
        let spans = collectSpans(input)
        let headers    = spans.filter { if case .tableHeader    = $0.kind { return true }; return false }
        let delimiters = spans.filter { if case .tableDelimiter = $0.kind { return true }; return false }
        XCTAssertEqual(headers.count, 1)
        XCTAssertTrue(delimiters.count > 0)
    }

    func testTableHeaderRow() {
        let input = "| Name | Age |\n|------|-----|\n| Alice | 30 |"
        let spans = collectSpans(input)
        let headers = spans.filter { if case .tableHeader = $0.kind { return true }; return false }
        XCTAssertEqual(headers.count, 1)
        // Header covers first line
        XCTAssertEqual(headers[0].range.location, 0)
    }

    func testTableDelimiters() {
        let input = "| a | b |\n|---|---|\n| 1 | 2 |"
        let spans = collectSpans(input)
        let delimiters = spans.filter { if case .tableDelimiter = $0.kind { return true }; return false }
        // Count all '|' characters in the input
        let pipeCount = input.filter { $0 == "|" }.count
        XCTAssertEqual(delimiters.count, pipeCount)
    }

    // MARK: - Tasklist (GFM extension — parsed as list items)

    func testTasklistUnchecked() {
        let input = "- [ ] todo"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        // Tasklist items are parsed as list items; the marker is "- "
        XCTAssertEqual(markers.count, 1)
    }

    func testTasklistChecked() {
        let input = "- [x] done"
        let spans = collectSpans(input)
        let markers = spans.filter { if case .listMarker = $0.kind { return true }; return false }
        XCTAssertEqual(markers.count, 1)
    }
}
