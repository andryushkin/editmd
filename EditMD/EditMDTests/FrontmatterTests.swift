import XCTest
import Testing
@testable import EditMD

final class FrontmatterTests: XCTestCase {

    // MARK: - frontmatterRange

    func testDetectsBasicFrontmatter() {
        let text = "---\ntitle: A\ntags: [x]\n---\n\n# Heading\n"
        guard let fm = frontmatterRange(in: text) else {
            return XCTFail("frontmatter not detected")
        }
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: fm.full), "---\ntitle: A\ntags: [x]\n---")
        XCTAssertEqual(ns.substring(with: fm.body), "title: A\ntags: [x]")
    }

    func testClosingDotsFence() {
        let text = "---\nkey: value\n...\nbody\n"
        guard let fm = frontmatterRange(in: text) else {
            return XCTFail("frontmatter not detected")
        }
        XCTAssertEqual((text as NSString).substring(with: fm.body), "key: value")
    }

    func testEmptyFrontmatter() {
        let text = "---\n---\ncontent"
        guard let fm = frontmatterRange(in: text) else {
            return XCTFail("empty frontmatter not detected")
        }
        XCTAssertEqual(fm.body.length, 0)
        XCTAssertEqual((text as NSString).substring(with: fm.full), "---\n---")
    }

    func testNoFrontmatterWhenNotFirstLine() {
        XCTAssertNil(frontmatterRange(in: "# Title\n\n---\nkey: value\n---\n"))
    }

    func testNoFrontmatterWithoutClosingFence() {
        XCTAssertNil(frontmatterRange(in: "---\nkey: value\nno closing fence\n"))
    }

    func testThematicBreakOnlyIsNotFrontmatter() {
        // A lone "---" as the first line with no closing fence stays a rule.
        XCTAssertNil(frontmatterRange(in: "---\n\njust text\n"))
    }

    // MARK: - parseFrontmatterProperties

    func testScalarProperties() {
        let props = parseFrontmatterProperties("title: Magnesium\npriority: HIGH")
        XCTAssertEqual(props, [
            FMProperty(key: "title", value: "Magnesium", items: []),
            FMProperty(key: "priority", value: "HIGH", items: []),
        ])
    }

    func testFlowList() {
        let props = parseFrontmatterProperties("aliases: [Mg, magnesium]")
        XCTAssertEqual(props.first?.items, ["Mg", "magnesium"])
        XCTAssertTrue(props.first?.isList ?? false)
    }

    func testBlockList() {
        let props = parseFrontmatterProperties("pmids:\n  - 12345678\n  - 23456789\ntitle: X")
        XCTAssertEqual(props.count, 2)
        XCTAssertEqual(props[0].key, "pmids")
        XCTAssertEqual(props[0].items, ["12345678", "23456789"])
        XCTAssertEqual(props[1].key, "title")
    }

    func testCommentsAndBlankLinesSkipped() {
        let props = parseFrontmatterProperties("# a comment\n\ntitle: X\n")
        XCTAssertEqual(props, [FMProperty(key: "title", value: "X", items: [])])
    }

    func testValueWithColon() {
        let props = parseFrontmatterProperties("url: http://example.com/x")
        XCTAssertEqual(props.first, FMProperty(key: "url", value: "http://example.com/x", items: []))
    }

    func testQuotedValueUnquoted() {
        let props = parseFrontmatterProperties("name: \"Hello World\"")
        XCTAssertEqual(props.first?.value, "Hello World")
    }

    // MARK: - HTML rendering

    func testFrontmatterIsNotRenderedInPreview() {
        // The Properties inspector owns frontmatter; the page shows body only.
        let html = markdownHTMLBody("---\ntitle: A\ntags: [a, b]\n---\n\n# H\n")
        XCTAssertFalse(html.contains("frontmatter"), html)
        XCTAssertFalse(html.contains("title: A"), html)
        XCTAssertFalse(html.contains("fm-"), html)
        XCTAssertFalse(html.contains("<hr>"), html)   // opening --- must not render as a rule
        // Heading text is wrapped in a click-to-edit source span (<h1><span
        // data-md-lo…>H</span></h1>) — match structurally, not literally.
        XCTAssertNotNil(html.range(of: #"<h1>(<span[^>]*>)?H(</span>)?</h1>"#,
                                   options: .regularExpression), html)
    }

    func testYAMLCodeBlockGetsSyntaxSpans() {
        let html = markdownHTMLBody("```yaml\nkey: false\n```")
        XCTAssertTrue(html.contains("class=\"language-yaml hljs\""), html)
        XCTAssertTrue(html.contains("hljs-token"), html)
        XCTAssertTrue(html.contains("key:"), html)
        XCTAssertTrue(html.contains("false"), html)
    }

    func testNonYAMLCodeBlockUnchanged() {
        let html = markdownHTMLBody("```swift\nlet x = 1\n```")
        XCTAssertFalse(html.contains("yaml-key"), html)
    }

    // MARK: - Visual round-trip

    func testFrontmatterRoundTripsThroughCompose() {
        // Visual renders body only; the coordinator re-attaches the verbatim
        // block via composeDocumentWithFrontmatter on serialize.
        let markdown = "---\ntitle: A\ntags: [x, y]\n---\n\n# Heading\n"
        let attributed = renderMarkdownToAttributed(markdown)
        XCTAssertFalse(attributed.string.contains("title: A"), attributed.string)
        let body = serializeAttributedToMarkdown(attributed)
        let composed = composeDocumentWithFrontmatter("---\ntitle: A\ntags: [x, y]\n---",
                                                      body: body)
        XCTAssertTrue(composed.hasPrefix("---\ntitle: A\ntags: [x, y]\n---\n\n"), composed)
        XCTAssertTrue(composed.contains("# Heading"), composed)
    }
}

@Suite("Frontmatter hidden from the page")
struct FrontmatterHiddenTests {
    private let markdown = "---\ntitle: A\ntags: [x, y]\n---\n\n# Heading\n"

    @Test func visualDoesNotRenderFrontmatter() {
        let attributed = renderMarkdownToAttributed(markdown)
        #expect(!attributed.string.contains("title: A"))
        #expect(!attributed.string.contains("---"))
        #expect(attributed.string.contains("Heading"))
    }

    @Test func previewShellCarriesNoFrontmatterMachinery() {
        let body = markdownHTMLBody(markdown)
        let page = previewHTMLPageRender(markdown: markdown, fontSize: 14).html

        #expect(!body.contains("class=\"frontmatter\""))
        #expect(!page.contains("hydrateFrontmatterDisclosure"))
        #expect(!page.contains("fm-plugin-state"))
    }

    @Test func composeReattachesFrontmatterByteExactly() {
        let frontmatter = "---\ntitle: A\ntags: [x, y]\n---"
        #expect(composeDocumentWithFrontmatter(frontmatter, body: "# H")
            == "---\ntitle: A\ntags: [x, y]\n---\n\n# H")
        #expect(composeDocumentWithFrontmatter(frontmatter, body: "") == frontmatter)
        #expect(composeDocumentWithFrontmatter(nil, body: "# H") == "# H")
        #expect(composeDocumentWithFrontmatter("", body: "# H") == "# H")
    }

    @Test func emptyFrontmatterStillHiddenAndBodyRenders() {
        let body = markdownHTMLBody("---\n---\n\nBody")

        #expect(!body.contains("class=\"frontmatter\""))
        #expect(body.contains("Body"))
    }
}
