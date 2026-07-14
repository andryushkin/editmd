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

    // MARK: - yamlLineSegments

    func testSegmentsReconstructLine() {
        let line = "  key: false  # note"
        let joined = yamlLineSegments(line).map(\.text).joined()
        XCTAssertEqual(joined, line)
    }

    func testKeyValueClassification() {
        let segs = yamlLineSegments("priority: 42")
        XCTAssertEqual(segs.first(where: { $0.text == "priority" })?.kind, .key)
        XCTAssertEqual(segs.first(where: { $0.text == "42" })?.kind, .number)
    }

    func testBooleanValue() {
        let segs = yamlLineSegments("draft: false")
        XCTAssertEqual(segs.first(where: { $0.text == "false" })?.kind, .bool)
    }

    func testFullLineComment() {
        let segs = yamlLineSegments("# just a comment")
        XCTAssertEqual(segs.map(\.kind), [.comment])
    }

    func testPlainScalarNotOvercolored() {
        // An unquoted, non-typed scalar stays plain (default text color).
        let segs = yamlLineSegments("title: Some Long Title")
        XCTAssertEqual(segs.first(where: { $0.text == "Some Long Title" })?.kind, .plain)
    }

    // MARK: - HTML rendering

    func testFrontmatterRendersAsPropertiesPanel() {
        let html = markdownHTMLBody("---\ntitle: A\n---\n\n# H\n")
        XCTAssertTrue(html.contains("section class=\"frontmatter\""), html)
        XCTAssertTrue(html.contains(
            "<button type=\"button\" class=\"fm-title\" aria-expanded=\"true\">"), html)
        XCTAssertTrue(html.contains("class=\"fm-disclosure\""), html)
        XCTAssertTrue(html.contains("<span>Свойства</span></button>"), html)
        XCTAssertTrue(html.contains("<div class=\"fm-content\">"), html)
        XCTAssertTrue(html.contains("<span class=\"fm-icon\""), html)
        XCTAssertTrue(html.contains("<div class=\"fm-key\">title</div>"), html)
        XCTAssertFalse(html.contains("<hr>"), html)   // opening --- must not render as a rule
        // Heading text is wrapped in a click-to-edit source span (<h1><span
        // data-md-lo…>H</span></h1>) — match structurally, not literally.
        XCTAssertNotNil(html.range(of: #"<h1>(<span[^>]*>)?H(</span>)?</h1>"#,
                                   options: .regularExpression), html)
    }

    func testFrontmatterListRendersChips() {
        let html = markdownHTMLBody("---\ntags: [a, b]\n---\n")
        XCTAssertTrue(html.contains("<circle cx=\"7.5\" cy=\"8.5\" r=\"1\"/>"), html)
        XCTAssertTrue(html.contains("<span class=\"fm-chip\">a</span>"), html)
        XCTAssertTrue(html.contains("<span class=\"fm-chip\">b</span>"), html)
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

    func testFrontmatterRoundTripsVerbatim() {
        let markdown = "---\ntitle: A\ntags: [x, y]\n---\n\n# Heading\n"
        let attributed = renderMarkdownToAttributed(markdown)
        let serialized = serializeAttributedToMarkdown(attributed)
        XCTAssertTrue(serialized.hasPrefix("---\ntitle: A\ntags: [x, y]\n---"), serialized)
        XCTAssertTrue(serialized.contains("# Heading"), serialized)
    }
}

@Suite("Frontmatter disclosure presentation")
struct FrontmatterDisclosureTests {
    private let markdown = "---\ntitle: A\ntags: [x, y]\n---\n\n# Heading\n"

    @Test func visualDisclosureChangesOnlyDisplayAndKeepsRawYAML() throws {
        let expanded = renderMarkdownToAttributed(markdown)
        let collapsed = renderMarkdownToAttributed(markdown, frontmatterCollapsed: true)
        let titleRange = (expanded.string as NSString).range(of: frontmatterDisplayTitle)

        #expect(titleRange.location != NSNotFound)
        #expect(expanded.attribute(.mdFrontmatterToggle,
                                   at: titleRange.location,
                                   effectiveRange: nil) != nil)
        #expect(expanded.string.contains("title: A"))
        #expect(collapsed.string.contains(frontmatterDisplayTitle))
        #expect(!collapsed.string.contains("title: A"))
        #expect(serializeAttributedToMarkdown(expanded)
            == serializeAttributedToMarkdown(collapsed))
        #expect(serializeAttributedToMarkdown(collapsed).hasPrefix(
            "---\ntitle: A\ntags: [x, y]\n---"))
    }

    @Test func previewDisclosureIsHydratedFromPersistentShellState() {
        let body = markdownHTMLBody(markdown)
        let page = previewHTMLPage(markdown: markdown, fontSize: 14)

        #expect(body.contains(
            "<button type=\"button\" class=\"fm-title\" aria-expanded=\"true\">"))
        #expect(body.contains("class=\"fm-disclosure\""))
        #expect(body.contains("<span>Свойства</span></button>"))
        #expect(body.contains("<div class=\"fm-content\">"))
        #expect(page.contains("var frontmatterCollapsed = false;"))
        #expect(page.contains("function hydrateFrontmatterDisclosure()"))
        #expect(page.contains("hydrateFrontmatterDisclosure();"))
        #expect(page.contains("content.hidden = frontmatterCollapsed;"))
    }

    @Test func emptyFrontmatterStillGetsTheSharedDisclosureTitle() {
        let body = markdownHTMLBody("---\n---\n\nBody")

        #expect(body.contains("class=\"frontmatter\""))
        #expect(body.contains("<span>Свойства</span></button>"))
    }
}
