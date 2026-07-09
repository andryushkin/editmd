import XCTest
@testable import EditMD

final class MarkdownHTMLTests: XCTestCase {

    // MARK: - Escaping

    func testTextIsEscaped() {
        let html = markdownHTMLBody("5 < 6 & 7 > 3")
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 3"), html)
    }

    func testCodeBlockIsEscapedWithLanguageClass() {
        let html = markdownHTMLBody("```html\n<div class=\"x\">\n```")
        XCTAssertTrue(html.contains("<pre><code class=\"language-html\">"), html)
        XCTAssertTrue(html.contains("&lt;div class=\"x\"&gt;"), html)
        XCTAssertFalse(html.contains("<div class=\"x\">"), html)
    }

    func testInlineCodeIsEscaped() {
        let html = markdownHTMLBody("Use `a < b` here")
        XCTAssertTrue(html.contains("a &lt; b"), html)
        XCTAssertTrue(html.contains("<code"), html)
        XCTAssertTrue(html.contains("data-md-code=\"1\""), html)
    }

    func testLinkHrefIsAttributeEscaped() {
        let html = markdownHTMLBody("[t](https://e.com/?a=1&b=2)")
        XCTAssertTrue(html.contains("href=\"https://e.com/?a=1&amp;b=2\""), html)
    }

    // MARK: - Structure

    func testHeadingKeepsInlineFormatting() {
        let html = markdownHTMLBody("## Hello **world**")
        XCTAssertTrue(html.contains("<h2>"), html)
        XCTAssertTrue(html.contains("<strong>"), html)
        XCTAssertTrue(html.contains("world"), html)
        // Text runs carry data-md-lo/hi for Preview toolbar mapping.
        XCTAssertTrue(html.contains("data-md-lo="), html)
    }

    func testTaskListCheckboxes() {
        let html = markdownHTMLBody("- [x] done\n- [ ] todo")
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked>"), html)
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled>"), html)
        XCTAssertTrue(html.contains("done"), html)
        XCTAssertTrue(html.contains("todo"), html)
    }

    func testTableAlignmentAndCells() {
        let md = "| a | b |\n|:-:|--:|\n| 1 | 2 |"
        let html = markdownHTMLBody(md)
        XCTAssertTrue(html.contains("<th align=\"center\">"), html)
        XCTAssertTrue(html.contains("<th align=\"right\">"), html)
        XCTAssertTrue(html.contains("<td align=\"center\">"), html)
        XCTAssertTrue(html.contains(">a<") || html.contains(">a</"), html)
    }

    func testStrikethrough() {
        let html = markdownHTMLBody("~~gone~~")
        XCTAssertTrue(html.contains("<del>"), html)
        XCTAssertTrue(html.contains("gone"), html)
    }

    func testOrderedListStartIndex() {
        let html = markdownHTMLBody("3. three\n4. four")
        XCTAssertTrue(html.contains("<ol start=\"3\">"), html)
    }

    // MARK: - Images

    func testImageResolverRewritesSource() {
        var seen: [String] = []
        let html = markdownHTMLBody("![alt text](assets/pic.png)") { source in
            seen.append(source)
            return "data:image/png;base64,AAA"
        }
        XCTAssertEqual(seen, ["assets/pic.png"])
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,AAA\""), html)
        XCTAssertTrue(html.contains("alt=\"alt text\""), html)
    }

    func testImageResolverNilKeepsOriginalSource() {
        let html = markdownHTMLBody("![a](https://e.com/p.png)") { _ in nil }
        XCTAssertTrue(html.contains("src=\"https://e.com/p.png\""), html)
    }

    // MARK: - Full page

    func testPreviewPageWrapsBody() {
        let page = previewHTMLPage(markdown: "# Title", fontSize: 14)
        XCTAssertTrue(page.contains("<!DOCTYPE html>"), page)
        XCTAssertTrue(page.contains("<h1>"), page)
        XCTAssertTrue(page.contains("Title"), page)
        XCTAssertTrue(page.contains("color-scheme: light dark"), page)
    }

    func testPreviewPageUsesVerticalInsetForTopPadding() {
        let page = previewHTMLPage(markdown: "# Title", fontSize: 14, insetH: 40, insetV: 8)
        // Top padding must track Settings ▸ Vertical (was a hardcoded 24px).
        XCTAssertTrue(page.contains("padding: 8px 40px "), page)
        XCTAssertTrue(page.contains("body > :first-child { margin-top: 0; }"), page)
    }

    func testPreviewPageZeroVerticalInset() {
        let page = previewHTMLPage(markdown: "hi", fontSize: 14, insetH: 12, insetV: 0)
        XCTAssertTrue(page.contains("padding: 0px 12px "), page)
    }

    func testPreviewPageEmbedsFontWeightAndFamily() {
        let page = previewHTMLPage(markdown: "text", fontSize: 16,
                                   fontFamily: "\"Menlo\", monospace", fontWeight: 500)
        XCTAssertTrue(page.contains("font: 500 16px/"), page)
        XCTAssertTrue(page.contains("\"Menlo\", monospace"), page)
    }

    func testPreviewPageEmitsHeadingElementCSS() {
        var elements = ElementStyles()
        elements.h1 = ElementStyle(colorHex: "#FF0000", weight: .black, sizeScale: 2.5)
        let page = previewHTMLPage(markdown: "# H", fontSize: 14, elements: elements)
        XCTAssertTrue(page.contains("h1 { font-size: 2.5em; font-weight: 900; color: #FF0000; }"), page)
    }

    func testPreviewPageAppliesColorOverrides() {
        let page = previewHTMLPage(markdown: "[l](u)", fontSize: 14,
                                   textColorHex: "#112233", accentColorHex: "#445566")
        XCTAssertTrue(page.contains("color: #112233"), page)   // body text
        XCTAssertTrue(page.contains("a { color: #445566; }"), page)
    }

    // MARK: - Wiki-links

    func testWikiLinkRendersAsAnchor() {
        let html = markdownHTMLBody("See [[Note|Shown]] here")
        XCTAssertTrue(html.contains("class=\"wikilink\""), html)
        XCTAssertTrue(html.contains("data-wiki-target=\"Note\""), html)
        XCTAssertTrue(html.contains("Shown"), html)
        XCTAssertFalse(html.contains("[["), html)
    }

    func testWikiLinkHeadingAndBlockData() {
        let html = markdownHTMLBody("[[Note#Sec]] and [[Note#^b1]]")
        XCTAssertTrue(html.contains("data-wiki-target=\"Note\" data-wiki-heading=\"Sec\""), html)
        XCTAssertTrue(html.contains("data-wiki-target=\"Note\" data-wiki-block=\"b1\""), html)
    }

    func testWikiLinkTargetIsAttributeEscaped() {
        let html = markdownHTMLBody("[[A & B]]")
        XCTAssertTrue(html.contains("data-wiki-target=\"A &amp; B\""), html)
    }

    func testWikiLinkNotDetectedInCode() {
        let html = markdownHTMLBody("`[[Note]]`")
        XCTAssertTrue(html.contains("[[Note]]"), html)
        XCTAssertTrue(html.contains("<code"), html)
        XCTAssertFalse(html.contains("wikilink"), html)
    }

    // MARK: - Underscore soft-wrap

    func testUnderscoreGetsSoftBreak() {
        // Long snake_case words widen the line because browsers don't break at
        // `_`; a `<wbr>` after each underscore restores hyphen-like wrapping.
        let html = markdownHTMLBody("uses very_long_snake_case_name here")
        XCTAssertTrue(html.contains("very_<wbr>long_<wbr>snake_<wbr>case_<wbr>name"), html)
    }

    func testUnderscoreBreakNotInInlineCode() {
        let html = markdownHTMLBody("`snake_case_id`")
        XCTAssertTrue(html.contains("snake_case_id"), html)
        XCTAssertTrue(html.contains("<code"), html)
        XCTAssertFalse(html.contains("<wbr>"), html)
    }

    func testUnderscoreBreakInTableCell() {
        let html = markdownHTMLBody("| name |\n| --- |\n| a_b_c |")
        XCTAssertTrue(html.contains("a_<wbr>b_<wbr>c"), html)
    }
}
