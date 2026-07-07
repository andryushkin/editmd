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
