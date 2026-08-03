import XCTest
@testable import EditMD

final class WikiLinkScannerTests: XCTestCase {

    // MARK: parseWikiInner — the four canonical forms

    func testPlainTarget() {
        let p = parseWikiInner("Note")
        XCTAssertEqual(p.target, "Note")
        XCTAssertNil(p.alias)
        XCTAssertNil(p.heading)
        XCTAssertNil(p.blockID)
        XCTAssertEqual(p.originalInner, "Note")
        XCTAssertEqual(p.displayText, "Note")
    }

    func testAlias() {
        let p = parseWikiInner("Note|Display Name")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.alias, "Display Name")
        XCTAssertNil(p.heading)
        XCTAssertEqual(p.displayText, "Display Name")
    }

    func testHeading() {
        let p = parseWikiInner("Note#Section")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.heading, "Section")
        XCTAssertNil(p.alias)
        XCTAssertNil(p.blockID)
    }

    func testBlockID() {
        let p = parseWikiInner("Note#^block-id")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.blockID, "block-id")
        XCTAssertNil(p.heading)
    }

    // MARK: alias AFTER heading (regression)

    func testHeadingThenAlias() {
        // Stripping `#` first loses the alias. Correct parse: pipe first →
        // alias="alias", then `#` → heading="Heading".
        let p = parseWikiInner("Note#Heading|alias")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.heading, "Heading")
        XCTAssertEqual(p.alias, "alias")
        XCTAssertEqual(p.displayText, "alias")
    }

    func testBlockIDThenAlias() {
        let p = parseWikiInner("Note#^b1|see here")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.blockID, "b1")
        XCTAssertEqual(p.alias, "see here")
    }

    // MARK: `\|` escaping inside table cells

    func testEscapedPipeInTableCell() {
        // In a table the alias pipe is escaped so the cell isn't split.
        let p = parseWikiInner("Note\\|Alias")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.alias, "Alias")
        // Round-trip source of truth keeps the backslash verbatim.
        XCTAssertEqual(p.originalInner, "Note\\|Alias")
    }

    // MARK: whitespace trimming

    func testTrimsWhitespace() {
        let p = parseWikiInner(" Note Name #  Heading | alias ")
        XCTAssertEqual(p.target, "Note Name")
        XCTAssertEqual(p.heading, "Heading")
        XCTAssertEqual(p.alias, "alias")
    }

    // MARK: heading text may contain more `#`

    func testFirstHashWins() {
        let p = parseWikiInner("Note#Part 1 # continued")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.heading, "Part 1 # continued")
    }

    func testAliasMayContainHash() {
        let p = parseWikiInner("Note|C# tutorial")
        XCTAssertEqual(p.target, "Note")
        XCTAssertEqual(p.alias, "C# tutorial")
        XCTAssertNil(p.heading)
    }

    // MARK: scanWikiLinks — ranges & multiple matches

    func testScanSingle() {
        let text = "See [[Note]] here."
        let m = scanWikiLinks(in: text)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m[0].range, NSRange(location: 4, length: 8)) // "[[Note]]"
        XCTAssertEqual(m[0].payload.target, "Note")
    }

    func testScanMultiple() {
        let text = "[[A]] and [[B|b]]"
        let m = scanWikiLinks(in: text)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].payload.target, "A")
        XCTAssertEqual(m[1].payload.target, "B")
        XCTAssertEqual(m[1].payload.alias, "b")
        // Second range covers "[[B|b]]"
        let sub = (text as NSString).substring(with: m[1].range)
        XCTAssertEqual(sub, "[[B|b]]")
    }

    func testScanUnicodeOffsets() {
        // Emoji before the link — NSRange is UTF-16, so the range must land on
        // the actual `[[`.
        let text = "😀 [[Цель]]"
        let m = scanWikiLinks(in: text)
        XCTAssertEqual(m.count, 1)
        let sub = (text as NSString).substring(with: m[0].range)
        XCTAssertEqual(sub, "[[Цель]]")
        XCTAssertEqual(m[0].payload.target, "Цель")
    }

    func testEmptyBracketsIgnored() {
        XCTAssertTrue(scanWikiLinks(in: "empty [[]] here").isEmpty)
    }

    func testNewlineAbortsMatch() {
        // A `[[` with no closing `]]` before the line ends is not a wiki-link.
        XCTAssertTrue(scanWikiLinks(in: "[[unclosed\nNote]]").isEmpty)
    }

    func testUnclosedIgnored() {
        XCTAssertTrue(scanWikiLinks(in: "trailing [[Note").isEmpty)
    }

    func testNoBracketsNoMatches() {
        XCTAssertTrue(scanWikiLinks(in: "just some [text](url) here").isEmpty)
    }

    func testAdjacentLinks() {
        let m = scanWikiLinks(in: "[[A]][[B]]")
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m[0].range, NSRange(location: 0, length: 5))
        XCTAssertEqual(m[1].range, NSRange(location: 5, length: 5))
    }

    // MARK: round-trip guarantee — originalInner reproduces the source exactly

    func testOriginalInnerRoundTrips() {
        for inner in ["Note", "Note|alias", "Note#H", "Note#^b", "Note#H|a", "Note\\|a", " x # y | z "] {
            let p = parseWikiInner(inner)
            XCTAssertEqual("[[\(p.originalInner)]]", "[[\(inner)]]")
        }
    }

    // MARK: collectSpans integration (Source highlighting)

    private func wikiPayloads(_ text: String) -> [MDWikiLinkPayload] {
        collectSpans(text).compactMap {
            if case .wikiLink(let p) = $0.kind { return p }
            return nil
        }
    }

    func testSpanInProse() {
        let text = "See [[Note]] for details."
        let spans = collectSpans(text)
        let wiki = spans.compactMap { s -> MDWikiLinkPayload? in
            if case .wikiLink(let p) = s.kind { return p }; return nil
        }
        XCTAssertEqual(wiki.count, 1)
        XCTAssertEqual(wiki[0].target, "Note")
        // Two bracket-syntax spans.
        let syntax = spans.filter { if case .wikiLinkSyntax = $0.kind { return true }; return false }
        XCTAssertEqual(syntax.count, 2)
        // `.wikiLink` covers the inner "Note", brackets are separate.
        let inner = spans.first { if case .wikiLink = $0.kind { return true }; return false }!
        XCTAssertEqual((text as NSString).substring(with: inner.range), "Note")
    }

    func testSpanExcludedInsideInlineCode() {
        // A wiki-link inside inline code must NOT be recognized.
        XCTAssertTrue(wikiPayloads("`[[Note]]` is literal").isEmpty)
    }

    func testSpanExcludedInsideCodeBlock() {
        XCTAssertTrue(wikiPayloads("```\n[[Note]]\n```").isEmpty)
    }

    func testSpanCarriesAlias() {
        let p = wikiPayloads("[[Note|Display]]")
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].target, "Note")
        XCTAssertEqual(p[0].alias, "Display")
    }
}
