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
            // The serializer's <!-- --> list fence is semantically invisible
            // (browser comment + empty raw-html wrapper around it).
            .replacingOccurrences(of: #"<!--[\s\S]*?-->"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"<div class="raw-html">\s*</div>"#, with: "",
                                  options: .regularExpression)
            // Source offsets legitimately shift when a normalizing round-trip
            // changes the text (delimiter padding, inserted list fences) —
            // the fingerprint compares semantics, not positions.
            .replacingOccurrences(of: #" data-md-(lo|hi)="\d+""#, with: "",
                                  options: .regularExpression)
            .replacingOccurrences(of: #" data-ln="\d+""#, with: "",
                                  options: .regularExpression)
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

    func testHighlight() {
        assertStable("see ==important== note")
        assertStable("==Plain ==~~text~~ paragraph")
    }

    func testAdjacentCodeBlocks() {
        assertStable("```swift\nlet x = 1\n```\n\n```\nplain\n```\n\n```\nother\n```")
    }

    func testHTMLCommentListFence() {
        assertStable("- a\n\n<!-- -->\n\n- b")
    }

    func testInlineMathVerbatim() {
        // `.mdMath` runs serialize verbatim — no `\frac` → `\\frac` mangling.
        assertStable(#"Formula $\frac{a}{b}$ in text"#)
        assertStable("Pythagoras: $x^2 + y^2 = z^2$.")
    }

    func testDisplayMathSameLineVerbatim() {
        assertStable("$$E = mc^2$$")
    }

    func testDisplayMathMultilineVerbatim() {
        // The whole block is one verbatim `.mdMath` run in Visual — `\\` and
        // the `=` line survive (no setext H1, no escape mangling).
        assertStable("$$\n\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}\n=\n\\begin{pmatrix} x \\\\ y \\end{pmatrix}\n$$")
        assertStable("before\n\n$$\nE = mc^2\n$$\n\nafter")
    }

    // Inline and same-line display math INSIDE a blockquote are supported.
    func testInlineMathInQuoteVerbatim() { assertStable("> energy $E = mc^2$ here") }
    func testDisplayMathSameLineInQuoteVerbatim() { assertStable("> $$E = mc^2$$") }

    // KNOWN LIMITATION: a MULTILINE `$$…$$` inside a blockquote is not scanned
    // as math — the mask would erase the `>` prefixes and break the quote (see
    // MathScan `matchDisplay`). It degrades gracefully to escaped literal text
    // (content preserved, no data loss) and stays idempotent. This pins that
    // behavior so it can't regress silently while the limitation stands.
    func testMultilineDisplayMathInQuoteDegradesButStays() {
        let out = roundTrip("> $$\n> E = mc^2\n> $$")
        XCTAssertEqual(out, "> \\$\\$ E = mc^2 \\$\\$")
        XCTAssertEqual(roundTrip(out), out, "must stay idempotent")
    }

    func testInlineCode() { assertStable("run `cmd` now") }
    func testInlineCodeWithBacktick() { assertStable("``a`b``") }
    func testNestedBoldItalic() { assertStable("***both***") }

    func testBulletList() { assertStable("- one\n- two\n- three") }
    func testNestedList() { assertStable("- one\n- two\n    - nested\n    - deeper item") }
    func testTaskList() { assertStable("- [ ] todo\n- [x] done") }
    func testOrderedList() { assertStable("1. first\n2. second") }
    func testOrderedListCustomStart() { assertStable("3. third\n4. fourth") }

    // Loose lists (blank line between items) must survive the Visual round-trip
    // instead of silently collapsing to tight — a real file (CLAUDE.md) lost its
    // blank lines this way.
    func testLooseBulletListKeepsBlankLines() { assertStable("- one\n\n- two\n\n- three") }
    func testLooseOrderedListKeepsBlankLines() { assertStable("1. first\n\n2. second") }
    func testLooseTaskListKeepsBlankLines() { assertStable("- [ ] todo\n\n- [x] done") }
    // The blank belongs to the OUTER list: an item ending with a tight nested
    // sublist must still keep the blank before the next outer sibling.
    func testLooseListKeepsBlankAfterNestedSublist() {
        assertStable("- one\n\n- two\n    - b1\n\n- three")
    }
    func testLooseOrderedListKeepsBlankAfterNestedSublist() {
        assertStable("1. first\n    - sub\n\n2. second")
    }
    func testTightListStaysTight() { assertStable("- one\n- two") }
    // A loose top list whose nested sublist is tight: siblings keep their blank,
    // the parent→child step stays tight.
    func testLooseListWithTightNested() {
        assertRoundTrip("- one\n    - a\n    - b\n\n- two")
    }

    func testQuote() { assertStable("> quoted line") }
    func testQuoteTwoParagraphs() { assertStable("> first\n>\n> second") }
    func testNestedQuote() { assertStable("> > deep\n>\n> back") }
    func testCalloutByteStable() {
        assertStable("> [!note] Title\n> body")
        assertStable("> [!Domain-Type] Domain\n>\n> Details")
    }

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

    func testTableStable() {
        assertStable("| a | b |\n| --- | --- |\n| 1 | 2 |")
    }

    func testTableAlignmentsStable() {
        assertStable("| l | c | r |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |")
    }

    func testTableNormalizesDelimiters() {
        XCTAssertEqual(roundTrip("| a | b |\n|---|---|\n| 1 | 2 |"),
                       "| a | b |\n| --- | --- |\n| 1 | 2 |")
        assertRoundTrip("| a | b |\n|---|---|\n| 1 | 2 |")
    }

    func testTableWithStyledCells() {
        assertStable("| **b** | `c` |\n| --- | --- |\n| [l](https://e.com) | x |")
    }

    func testTableCellPipeEscaped() {
        assertRoundTrip("| a \\| b | c |\n| --- | --- |\n| 1 | 2 |")
    }

    func testTableMissingCellsFilledEmpty() {
        assertRoundTrip("| a | b |\n| --- | --- |\n| 1 |")
    }

    func testTableCellAttribute() {
        let attr = renderMarkdownToAttributed("| a | b |\n| --- | --- |\n| 1 | 2 |")
        let block = attr.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock
        XCTAssertEqual(block?.kind, .tableCell(row: 0, column: 0, columns: 2, alignment: 0))
    }

    func testHTMLBlockIsIslandVerbatim() {
        assertStable("<div>\nhello\n</div>")
    }

    // MARK: - Serialization map (cursor continuity)

    func testMarkdownPrefixLengths() {
        XCTAssertEqual(markdownPrefixLength(for: MDBlock(kind: .heading(2))), 3)      // "## "
        XCTAssertEqual(markdownPrefixLength(for: MDBlock(kind: .taskItem(depth: 0, done: true))), 6)
        XCTAssertEqual(markdownPrefixLength(for: MDBlock(kind: .paragraph, quoteDepth: 1)), 2)
        XCTAssertEqual(markdownPrefixLength(for: MDBlock(kind: .bulletItem(depth: 1))), 6)  // 4 spaces + "- "
        XCTAssertEqual(markdownPrefixLength(for: MDBlock(kind: .paragraph)), 0)
    }

    func testParagraphRangesMapCoversAllParagraphs() {
        let attr = renderMarkdownToAttributed("# T\n\nbody\n\n- a\n- b")
        let detailed = serializeAttributedToMarkdownDetailed(attr)
        // display paragraphs: heading, body, item a, item b
        XCTAssertEqual(detailed.paragraphRanges.count, 4)
        let md = detailed.markdown as NSString
        XCTAssertEqual(md.substring(with: detailed.paragraphRanges[0]), "# T")
        XCTAssertEqual(md.substring(with: detailed.paragraphRanges[2]), "- a")
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

    // Loose lists are now PRESERVED (was: normalized to tight). A real file
    // (CLAUDE.md) lost its blank lines under the old normalization.
    func testLooseListPreserved() {
        XCTAssertEqual(roundTrip("- a\n\n- b"), "- a\n\n- b")
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
    // An escaped `\$x\$` must not turn back into a formula on the Visual
    // round-trip (cmark unescapes it, so the serializer must re-escape).
    func testEscapedDollarPairStaysLiteral() { assertStable("literal \\$x\\$ here") }
    // Currency and single dollars are NOT over-escaped.
    func testCurrencyDollarSurvives() { assertStable("it costs $5 today") }
    func testTwoCurrencyDollarsSurvive() { assertStable("$20 and $30 total") }

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

    // MARK: - Wiki-links

    func testWikiLinkStable() {
        assertStable("See [[Note]] for more.")
        assertStable("[[Note|alias]]")
        assertStable("[[Note#Heading]]")
        assertStable("[[Note#^block-id]]")
        assertStable("[[target#Heading|alias]]")
    }

    func testWikiLinkEscapedPipeStable() {
        // A wiki-link inside a table escapes its alias pipe; the verbatim inner
        // must survive so the cell isn't split on re-parse.
        assertStable("Row [[Note\\|Alias]] end")
    }

    func testWikiLinkInBoldStable() {
        assertStable("**[[Note]]**")
    }

    func testWikiLinkIdempotent() {
        assertRoundTrip("Text with [[A]] and [[B|b]] links.")
    }

    func testWikiLinkDisplaysAliasNotMarkers() {
        let attr = renderMarkdownToAttributed("[[Note|Shown]]")
        XCTAssertEqual(attr.string.trimmingCharacters(in: .whitespacesAndNewlines), "Shown")
        XCTAssertFalse(attr.string.contains("["))
        XCTAssertNotNil(attr.attribute(.mdWikiLink, at: 0, effectiveRange: nil) as? MDWikiLinkPayload)
    }
}
