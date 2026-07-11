import XCTest
@testable import EditMD

// MARK: - transformLines / fenceLines (Source-mode Format menu)

final class TransformLinesTests: XCTestCase {

    func testHeadingSet() {
        XCTAssertEqual(transformLines(.heading(2), lines: "Title\n"), "## Title\n")
    }

    func testHeadingReplacesExistingLevel() {
        XCTAssertEqual(transformLines(.heading(3), lines: "# Title\n"), "### Title\n")
    }

    func testHeadingToggleOff() {
        XCTAssertEqual(transformLines(.heading(2), lines: "## Title\n"), "Title\n")
    }

    func testHeadingMultilineSkipsEmpty() {
        XCTAssertEqual(transformLines(.heading(1), lines: "a\n\nb\n"), "# a\n\n# b\n")
    }

    func testBulletSet() {
        XCTAssertEqual(transformLines(.bullet, lines: "one\ntwo\n"), "- one\n- two\n")
    }

    func testBulletToggleOff() {
        XCTAssertEqual(transformLines(.bullet, lines: "- one\n* two\n"), "one\ntwo\n")
    }

    func testBulletKeepsIndent() {
        XCTAssertEqual(transformLines(.bullet, lines: "  - sub\n"), "  sub\n")
    }

    func testBulletFromOrdered() {
        XCTAssertEqual(transformLines(.bullet, lines: "1. one\n2. two\n"), "- one\n- two\n")
    }

    func testOrderedNumbersSequentially() {
        XCTAssertEqual(transformLines(.ordered, lines: "a\nb\nc\n"), "1. a\n2. b\n3. c\n")
    }

    func testOrderedToggleOff() {
        XCTAssertEqual(transformLines(.ordered, lines: "1. a\n2) b\n"), "a\nb\n")
    }

    func testQuoteSetPrefixesEmptyLines() {
        XCTAssertEqual(transformLines(.quote, lines: "a\n\nb\n"), "> a\n>\n> b\n")
    }

    func testQuoteToggleOff() {
        XCTAssertEqual(transformLines(.quote, lines: "> a\n>\n> b\n"), "a\n\nb\n")
    }

    func testNoTrailingNewlinePreserved() {
        XCTAssertEqual(transformLines(.bullet, lines: "one"), "- one")
    }

    func testFenceLines() {
        XCTAssertEqual(fenceLines("code\n"), "```\ncode\n```\n")
    }

    func testFenceLinesNoTrailingNewline() {
        XCTAssertEqual(fenceLines("code"), "```\ncode\n```")
    }
}

// MARK: - toggleTaskListItem (Preview checkbox click-through)

final class ToggleTaskListItemTests: XCTestCase {

    func testTogglesUncheckedToChecked() {
        let md = "- [ ] one\n- [ ] two\n"
        XCTAssertEqual(toggleTaskListItem(in: md, index: 0), "- [x] one\n- [ ] two\n")
    }

    func testTogglesCheckedToUnchecked() {
        let md = "- [ ] one\n- [x] two\n"
        XCTAssertEqual(toggleTaskListItem(in: md, index: 1), "- [ ] one\n- [ ] two\n")
    }

    func testIndexOutOfRangeReturnsNil() {
        XCTAssertNil(toggleTaskListItem(in: "- [ ] one\n", index: 1))
        XCTAssertNil(toggleTaskListItem(in: "- [ ] one\n", index: -1))
        XCTAssertNil(toggleTaskListItem(in: "plain text", index: 0))
    }

    func testDocumentOrderAcrossNestingAndText() {
        let md = "# H\n\n- [x] a\n  - [ ] nested\n\ntext\n\n- [ ] b\n"
        XCTAssertEqual(toggleTaskListItem(in: md, index: 2),
                       "# H\n\n- [x] a\n  - [ ] nested\n\ntext\n\n- [x] b\n")
    }

    func testLinkItemIsNotACheckbox() {
        // "- [Link](url)" is a link, not a task — index 0 must hit the real one.
        let md = "- [Link](https://e.com)\n- [ ] real\n"
        XCTAssertEqual(toggleTaskListItem(in: md, index: 0),
                       "- [Link](https://e.com)\n- [x] real\n")
    }
}

// MARK: - Preview selection wrap + ==highlight== scan

final class PreviewSelectionWrapTests: XCTestCase {

    func testWrapsExactRange() {
        let md = "hello world hello"
        // Second "hello" only — not the first occurrence.
        let r = NSRange(location: 12, length: 5)
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "~~", close: "~~"),
            "hello world ~~hello~~"
        )
    }

    func testUnwrapsWhenAlreadyMarked() {
        let md = "~~hello~~ world"
        let r = NSRange(location: 2, length: 5) // "hello" inside ~~
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "~~", close: "~~"),
            "hello world"
        )
    }

    func testHighlightMarkers() {
        let md = "see ==important== note"
        let r = NSRange(location: 6, length: 9) // "important"
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "==", close: "=="),
            "see important note"
        )
        let plain = "see important note"
        let r2 = (plain as NSString).range(of: "important")
        XCTAssertEqual(
            toggleWrapAtRange(in: plain, range: r2, open: "==", close: "=="),
            "see ==important== note"
        )
    }

    func testEmptyOrOutOfBoundsReturnsNil() {
        XCTAssertNil(toggleWrapAtRange(in: "abc", range: NSRange(location: 0, length: 0),
                                       open: "~~", close: "~~"))
        XCTAssertNil(toggleWrapAtRange(in: "abc", range: NSRange(location: 0, length: 10),
                                       open: "~~", close: "~~"))
    }

    func testScanHighlightMarks() {
        let marks = scanHighlightMarks(in: "a ==b== c ==d==")
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].inner, "b")
        XCTAssertEqual(marks[1].inner, "d")
    }

    func testScanHighlightSkipsEmptyAndMultiline() {
        XCTAssertTrue(scanHighlightMarks(in: "====").isEmpty)
        XCTAssertTrue(scanHighlightMarks(in: "==a\nb==").isEmpty)
    }

    func testHighlightHTML() {
        let html = markdownHTMLBody("x ==hi== y")
        XCTAssertTrue(html.contains("<mark"), html)
        XCTAssertTrue(html.contains(">hi</mark>"), html)
        XCTAssertFalse(html.contains("==hi=="), html)
    }

    func testHighlightVisualRender() {
        let attr = renderMarkdownToAttributed("x ==hi== y")
        var found = false
        attr.enumerateAttribute(.mdInline, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
            if styles.contains(.highlight) {
                found = true
                XCTAssertEqual((attr.string as NSString).substring(with: range), "hi")
            }
        }
        XCTAssertTrue(found, "Visual render should stamp .highlight on ==…== inner text")
        XCTAssertFalse(attr.string.contains("=="), "markers must not appear in display text")
    }

    func testHTMLCommentOnlyHelper() {
        XCTAssertTrue(isHTMLCommentOnly("<!-- -->"))
        XCTAssertTrue(isHTMLCommentOnly("<!-- a -->\n<!-- b -->"))
        XCTAssertTrue(isHTMLCommentOnly("  <!-- x -->  "))
        XCTAssertFalse(isHTMLCommentOnly("<div>x</div>"))
        XCTAssertFalse(isHTMLCommentOnly("<!-- a -->visible"))
    }

    func testHTMLCommentIslandHasNoDisplayText() {
        let attr = renderMarkdownToAttributed("- a\n\n<!-- -->\n\n- b")
        XCTAssertFalse(attr.string.contains("<!--"),
                       "comment fence must not paint as a monospaced island")
        // Still round-trips via .raw on an empty paragraph.
        XCTAssertEqual(serializeAttributedToMarkdown(attr), "- a\n\n<!-- -->\n\n- b")
    }

    func testHTMLTagsSourceOffsets() {
        let html = markdownHTMLBody("hello")
        XCTAssertTrue(html.contains("data-md-lo=\"0\""), html)
        XCTAssertTrue(html.contains("data-md-hi=\"5\""), html)
    }
}

// MARK: - wordAndCharCount

final class WordAndCharCountTests: XCTestCase {

    func testEmpty() {
        let (w, c) = wordAndCharCount(in: "")
        XCTAssertEqual(w, 0)
        XCTAssertEqual(c, 0)
    }

    func testSingleWord() {
        let (w, c) = wordAndCharCount(in: "Hello")
        XCTAssertEqual(w, 1)
        XCTAssertEqual(c, 5)
    }

    func testMultipleWords() {
        let (w, c) = wordAndCharCount(in: "Hello world")
        XCTAssertEqual(w, 2)
        XCTAssertEqual(c, 11)
    }

    func testLeadingTrailingWhitespace() {
        let (w, _) = wordAndCharCount(in: "  hello  ")
        XCTAssertEqual(w, 1)
    }

    func testNewlines() {
        let (w, _) = wordAndCharCount(in: "foo\nbar\nbaz")
        XCTAssertEqual(w, 3)
    }

    func testOnlyWhitespace() {
        let (w, _) = wordAndCharCount(in: "   \n\t  ")
        XCTAssertEqual(w, 0)
    }

    func testUnicodeChars() {
        // "café" = 4 Swift characters
        let (w, c) = wordAndCharCount(in: "café")
        XCTAssertEqual(w, 1)
        XCTAssertEqual(c, 4)
    }
}

// MARK: - stripInlineMarkers (B4)

final class StripInlineMarkersTests: XCTestCase {

    func testBold() {
        XCTAssertEqual(stripInlineMarkers("**hello**"), "hello")
    }

    func testNestedBoldItalic() {
        XCTAssertEqual(stripInlineMarkers("***hello***"), "hello")
        XCTAssertEqual(stripInlineMarkers("**_hello_**"), "hello")
        XCTAssertEqual(stripInlineMarkers("***hello***"), "hello")
    }

    func testCodeInteriorUntouched() {
        // Markers inside a code span must survive; outer backticks unwrap.
        XCTAssertEqual(stripInlineMarkers("`a**b**`"), "a**b**")
        XCTAssertEqual(stripInlineMarkers("x `a**b**` y"), "x a**b** y")
    }

    func testStrikeAndHighlight() {
        XCTAssertEqual(stripInlineMarkers("~~gone~~"), "gone")
        XCTAssertEqual(stripInlineMarkers("==hi=="), "hi")
    }

    func testMixedOutsideCode() {
        XCTAssertEqual(stripInlineMarkers("**a** and *b*"), "a and b")
    }

    func testHeadingMarkersNotTouchedAsStructure() {
        // Only inline delimiters — leading # is not stripped here.
        XCTAssertEqual(stripInlineMarkers("# **Title**"), "# Title")
    }
}

// MARK: - cycleCase (B5)

final class CycleCaseTests: XCTestCase {

    func testLatinCycle() {
        XCTAssertEqual(cycleCase("HELLO"), "hello")
        XCTAssertEqual(cycleCase("hello"), "Hello")
        XCTAssertEqual(cycleCase("Hello"), "HELLO")
    }

    func testCyrillicCycle() {
        XCTAssertEqual(cycleCase("ПРИВЕТ"), "привет")
        XCTAssertEqual(cycleCase("привет"), "Привет")
        XCTAssertEqual(cycleCase("Привет"), "ПРИВЕТ")
    }

    func testMixedGoesUpper() {
        XCTAssertEqual(cycleCase("HeLLo"), "HELLO")
    }

    func testNoLettersUnchanged() {
        XCTAssertEqual(cycleCase("123"), "123")
    }
}

// MARK: - applyWrap

final class ApplyWrapTests: XCTestCase {

    // MARK: Bold (**)

    func testBoldNoSelection() {
        let text = "hello"
        // cursor at position 3, no selection
        let (newText, sel) = applyWrap(marker: "**", to: text, selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(newText, "hel****lo")
        // cursor lands between the markers
        XCTAssertEqual(sel, NSRange(location: 5, length: 0))
    }

    func testBoldWithSelection() {
        let text = "hello world"
        // select "world" (loc=6, len=5)
        let (newText, sel) = applyWrap(marker: "**", to: text, selection: NSRange(location: 6, length: 5))
        XCTAssertEqual(newText, "hello **world**")
        // selection covers the wrapped text including markers
        XCTAssertEqual(sel, NSRange(location: 6, length: 9))  // "**world**"
    }

    func testBoldAtStart() {
        let text = "hi"
        let (newText, sel) = applyWrap(marker: "**", to: text, selection: NSRange(location: 0, length: 2))
        XCTAssertEqual(newText, "**hi**")
        XCTAssertEqual(sel, NSRange(location: 0, length: 6))
    }

    // MARK: Italic (*)

    func testItalicNoSelection() {
        let text = "abc"
        let (newText, sel) = applyWrap(marker: "*", to: text, selection: NSRange(location: 1, length: 0))
        XCTAssertEqual(newText, "a**bc")
        // cursor between the markers: loc 1 + 1 = 2
        XCTAssertEqual(sel, NSRange(location: 2, length: 0))
    }

    func testItalicWithSelection() {
        let text = "abc"
        let (newText, sel) = applyWrap(marker: "*", to: text, selection: NSRange(location: 0, length: 3))
        XCTAssertEqual(newText, "*abc*")
        XCTAssertEqual(sel, NSRange(location: 0, length: 5))
    }

    func testEmptyString() {
        let (newText, sel) = applyWrap(marker: "**", to: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(newText, "****")
        XCTAssertEqual(sel, NSRange(location: 2, length: 0))
    }

    func testUnicodeSelection() {
        // "café" select "é" (Swift char index 3, NSRange location 3 len 1 in UTF-16)
        let text = "café"
        let (newText, sel) = applyWrap(marker: "*", to: text, selection: NSRange(location: 3, length: 1))
        XCTAssertEqual(newText, "caf*é*")
        XCTAssertEqual(sel, NSRange(location: 3, length: 3))
    }
}
