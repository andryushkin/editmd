import XCTest
@testable import EditMD

/// v20 quality gate: `serialize(render(x))` must be idempotent and preserve
/// semantics (same HTML fingerprint via markdownHTMLBody).
final class RoundTripTests: XCTestCase {

    private func roundTrip(_ md: String) -> String {
        serializeAttributedToMarkdown(renderMarkdownToAttributed(md))
    }

    private func normalizedHTML(_ md: String) -> String {
        markdownHTMLBody(md)
            // The serializer's <!-- --> list fence is semantically invisible.
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Fixture already in normal form: serialization must reproduce it exactly.
    private func assertStable(_ md: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(roundTrip(md), md, file: file, line: line)
    }

    /// Arbitrary input: one pass normalizes, second pass must be identity,
    /// and the HTML fingerprint must survive.
    private func assertRoundTrip(_ md: String, file: StaticString = #filePath, line: UInt = #line) {
        let once = roundTrip(md)
        XCTAssertEqual(roundTrip(once), once, "not idempotent", file: file, line: line)
        XCTAssertEqual(normalizedHTML(once), normalizedHTML(md),
                       "semantics changed:\n---once---\n\(once)", file: file, line: line)
    }

    // MARK: - Stable fixtures (normal form)

    func testHeading() { assertStable("# Title") }
    func testAllHeadingLevels() { assertStable("# H1\n\n## H2\n\n### H3\n\n#### H4") }

    func testInlineStyles() {
        assertStable("Body with **bold** and *italic* and ~~strike~~.")
    }

    func testInlineCode() { assertStable("run `cmd` now") }
    func testInlineCodeWithBacktick() { assertStable("``a`b``") }
    func testNestedBoldItalic() { assertStable("***both***") }

    func testBulletList() { assertStable("- one\n- two\n- three") }
    func testNestedList() { assertStable("- one\n- two\n    - nested\n    - deeper item") }
    func testTaskList() { assertStable("- [ ] todo\n- [x] done") }
    func testOrderedList() { assertStable("1. first\n2. second") }
    func testOrderedListCustomStart() { assertStable("3. third\n4. fourth") }

    func testQuote() { assertStable("> quoted line") }
    func testQuoteTwoParagraphs() { assertStable("> first\n>\n> second") }
    func testNestedQuote() { assertStable("> > deep\n>\n> back") }

    func testCodeBlock() { assertStable("```swift\nlet x = 1\n```") }
    func testCodeBlockNoLanguage() { assertStable("```\nplain\n```") }
    func testCodeBlockPreservesMarkers() { assertStable("```\n**not bold** # not heading\n```") }

    func testThematicBreak() { assertStable("---") }

    func testLink() { assertStable("[text](https://example.com)") }
    func testAutolink() { assertStable("visit https://example.com today") }
    func testImage() { assertStable("![alt](img.png)") }
    func testImageWithTitle() { assertStable("![alt](img.png \"a title\")") }
    func testBoldAroundLink() { assertStable("**a [b](https://e.com) c**") }
    func testStylesInsideLink() { assertStable("[**bold** text](https://e.com)") }
    func testImageInsideLink() { assertStable("[![alt](i.png)](https://e.com)") }

    func testHardBreak() { assertStable("line one\\\nline two") }

    func testTableIsIslandVerbatim() {
        assertStable("| a | b |\n|---|---|\n| 1 | 2 |")
    }

    func testHTMLBlockIsIslandVerbatim() {
        assertStable("<div>\nhello\n</div>")
    }

    func testMixedDocument() {
        assertStable("""
        # Title

        Paragraph with **bold**.

        - one
        - [x] two

        > quote

        ```swift
        let x = 1
        ```

        ---

        [link](https://example.com)
        """)
    }

    // MARK: - Normalization (semantic equality + idempotence)

    func testSetextBecomesATX() {
        XCTAssertEqual(roundTrip("Title\n=====\n\nBody"), "# Title\n\nBody")
    }

    func testUnderscoreEmphasisNormalized() {
        XCTAssertEqual(roundTrip("__bold__ and _italic_"), "**bold** and *italic*")
    }

    func testStarBulletsNormalized() {
        XCTAssertEqual(roundTrip("* a\n* b"), "- a\n- b")
    }

    func testIndentedCodeBecomesFenced() {
        XCTAssertEqual(roundTrip("    let x = 1"), "```\nlet x = 1\n```")
    }

    func testReferenceLinkInlined() {
        XCTAssertEqual(roundTrip("[a][b]\n\n[b]: https://e.com"), "[a](https://e.com)")
    }

    func testLooseListBecomesTight() {
        XCTAssertEqual(roundTrip("- a\n\n- b"), "- a\n- b")
    }

    func testSoftBreakBecomesSpace() {
        XCTAssertEqual(roundTrip("one\ntwo"), "one two")
    }

    func testAdjacentListsKeepCommentFence() {
        XCTAssertEqual(roundTrip("- a\n\n* b"), "- a\n\n<!-- -->\n\n- b")
        assertRoundTrip("- a\n\n* b")
    }

    // MARK: - Escaping survives

    func testEscapedStarsSurvive() { assertRoundTrip("\\*not emphasis\\*") }
    func testBareStarsSurvive() { assertRoundTrip("2 * 3 * 4 = 24") }
    func testUnderscoreInWordSurvives() { assertRoundTrip("snake_case_name here") }
    func testLeadingHashEscaped() { assertRoundTrip("\\#not a heading") }
    func testLiteralBrackets() { assertRoundTrip("see \\[citation\\] here") }

    // MARK: - Semantic round-trips on tricky inputs

    func testTwoQuotesStayTwoQuotes() { assertRoundTrip("> one\n\n> two") }
    func testQuotedList() { assertRoundTrip("> - a\n> - b") }
    func testQuoteWithHeading() { assertRoundTrip("> # Title\n>\n> body") }
    func testMultiParagraphListItem() { assertRoundTrip("- first\n\n  continuation\n\n- second") }
    func testCodeBlockInListItem() { assertRoundTrip("- item\n\n  ```swift\n  let x = 1\n  ```") }
    func testMixedNesting() { assertRoundTrip("1. a\n    - b\n    - c\n2. d") }
    func testHTMLInline() { assertRoundTrip("text with <b>html</b> inside") }

    // MARK: - Corpus

    func testCorpusRoundTrip() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // EditMDTests
            .deletingLastPathComponent()   // EditMD (project)
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("test-all-elements.md")
        let corpus = try String(contentsOf: url, encoding: .utf8)
        assertRoundTrip(corpus)
    }

    // MARK: - Model structure

    func testHeadingAttribute() {
        let attr = renderMarkdownToAttributed("## Head")
        let block = attr.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock
        XCTAssertEqual(block?.kind, .heading(2))
    }

    func testTaskItemAttribute() {
        let attr = renderMarkdownToAttributed("- [x] done")
        let block = attr.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock
        XCTAssertEqual(block?.kind, .taskItem(depth: 0, done: true))
    }

    func testLinkAttribute() {
        let attr = renderMarkdownToAttributed("[a](https://e.com)")
        XCTAssertEqual(attr.attribute(.mdLink, at: 0, effectiveRange: nil) as? String,
                       "https://e.com")
    }

    func testNoMarkersInDisplayText() {
        let attr = renderMarkdownToAttributed("# H\n\n**b** *i* `c` [l](u)")
        XCTAssertFalse(attr.string.contains("#"))
        XCTAssertFalse(attr.string.contains("*"))
        XCTAssertFalse(attr.string.contains("["))
    }

    func testEmptyDocument() {
        XCTAssertEqual(roundTrip(""), "")
        XCTAssertEqual(renderMarkdownToAttributed("").length, 0)
    }
}
