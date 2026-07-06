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
        XCTAssertTrue(html.contains("<code>a &lt; b</code>"), html)
    }

    func testLinkHrefIsAttributeEscaped() {
        let html = markdownHTMLBody("[t](https://e.com/?a=1&b=2)")
        XCTAssertTrue(html.contains("href=\"https://e.com/?a=1&amp;b=2\""), html)
    }

    // MARK: - Structure

    func testHeadingKeepsInlineFormatting() {
        let html = markdownHTMLBody("## Hello **world**")
        XCTAssertTrue(html.contains("<h2>Hello <strong>world</strong></h2>"), html)
    }

    func testTaskListCheckboxes() {
        let html = markdownHTMLBody("- [x] done\n- [ ] todo")
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled checked> done"), html)
        XCTAssertTrue(html.contains("<li class=\"task\"><input type=\"checkbox\" disabled> todo"), html)
    }

    func testTableAlignmentAndCells() {
        let md = "| a | b |\n|:-:|--:|\n| 1 | 2 |"
        let html = markdownHTMLBody(md)
        XCTAssertTrue(html.contains("<th align=\"center\">a</th>"), html)
        XCTAssertTrue(html.contains("<th align=\"right\">b</th>"), html)
        XCTAssertTrue(html.contains("<td align=\"center\">1</td>"), html)
    }

    func testStrikethrough() {
        let html = markdownHTMLBody("~~gone~~")
        XCTAssertTrue(html.contains("<del>gone</del>"), html)
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
        XCTAssertTrue(page.contains("<h1>Title</h1>"), page)
        XCTAssertTrue(page.contains("color-scheme: light dark"), page)
    }
}
