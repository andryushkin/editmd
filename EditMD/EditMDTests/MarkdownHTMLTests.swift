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

    func testPreviewPageStylesQuoteAndCodeWithCopyButtons() {
        let page = previewHTMLPage(markdown: "> quote\n\n```swift\nlet x = 1\n```",
                                   fontSize: 14)
        XCTAssertTrue(page.contains("border-left: 4px solid rgba(0,122,255"), page)
        XCTAssertTrue(page.contains("border: 1px solid rgba(175,82,222"), page)
        XCTAssertTrue(page.contains("document.querySelectorAll('pre, blockquote')"), page)
        XCTAssertTrue(page.contains("clone.querySelectorAll('.copy-block-btn')"), page)
        XCTAssertTrue(page.contains("opacity: 0.72"), page)
        XCTAssertTrue(page.contains("min-width: 32px"), page)
        XCTAssertTrue(page.contains("min-height: 32px"), page)
        XCTAssertTrue(page.contains("font: 17px/1"), page)
        XCTAssertTrue(page.contains("el.parentElement.closest('blockquote')"), page)
    }

    func testNestedQuoteRendersAsOneCopyableTree() {
        let md = "> This is a blockquote.\n>\n> > It can span multiple lines."
        let page = previewHTMLPage(markdown: md, fontSize: 14)
        XCTAssertTrue(page.contains("<blockquote>"), page)
        // Runtime attachment deliberately skips nested blockquotes, while the
        // outer clone retains their text for one whole-tree copy operation.
        XCTAssertTrue(page.contains("el.tagName === 'BLOCKQUOTE'"), page)
        XCTAssertTrue(page.contains("copyText(clone.innerText || '', btn)"), page)
    }

    func testPreviewLineNumbersUseOneGlobalColumnAndLargerGap() {
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let page = previewHTMLPage(markdown: "# H\n\n- item\n\n> quote",
                                   fontSize: 14, insetH: 32, gutter: gutter)
        XCTAssertTrue(page.contains("--ln-gap: 18px"), page)
        XCTAssertTrue(page.contains("function alignLineNumberGutter()"), page)
        XCTAssertTrue(page.contains("desiredLeft - el.getBoundingClientRect().left"), page)
        XCTAssertFalse(page.contains("li[data-ln]::before"), page)
        // 32 content inset + gutter column + the new 18px text gap.
        XCTAssertTrue(page.contains("padding: 24px 32px 64px 93px"), page)
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

    // MARK: - Preview line numbers (C1)

    func testPreviewLineNumbersMatchSourceLines() {
        let md = "# Title\n\nParagraph text.\n\n## Second\n\n- item\n"
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let html = markdownHTMLBody(md, gutter: gutter)
        // Line 1: # Title
        XCTAssertTrue(html.contains("data-ln=\"1\""), html)
        // Line 3: paragraph
        XCTAssertTrue(html.contains("data-ln=\"3\""), html)
        // Line 5: ## Second
        XCTAssertTrue(html.contains("data-ln=\"5\""), html)
        // Line 7: list item
        XCTAssertTrue(html.contains("data-ln=\"7\""), html)
    }

    func testPreviewLineNumbersWithFrontmatterOffset() {
        let md = "---\ntitle: x\n---\n\n# Hello\n"
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let html = markdownHTMLBody(md, gutter: gutter)
        // "# Hello" is line 5 in the original file
        XCTAssertTrue(html.contains("<h1") && html.contains("data-ln=\"5\""), html)
    }

    // MARK: - Math (formulas sprint)

    func testInlineMathKeepsVerbatimTeX() {
        // `_` and `\f` would be mangled by a plain cmark parse — the masked
        // parse must deliver the TeX untouched.
        let (html, hasMath) = markdownHTMLRender("Формула $a_i + \\frac{x}{y}$ в тексте")
        XCTAssertTrue(hasMath)
        XCTAssertTrue(html.contains("class=\"math math-inline\""), html)
        XCTAssertTrue(html.contains("a_i + \\frac{x}{y}"), html)
        XCTAssertFalse(html.contains("<em>"), html)
        XCTAssertFalse(html.contains("\u{E000}"), html)
    }

    func testMathSpanCarriesSourceOffsetsAndIslandFlag() {
        let (html, _) = markdownHTMLRender("ab $x$ cd")
        XCTAssertTrue(html.contains("data-md-lo=\"3\""), html)
        XCTAssertTrue(html.contains("data-md-hi=\"6\""), html)
        XCTAssertTrue(html.contains("data-md-code=\"1\""), html)
        // Trailing text keeps its own source offset after the masked span.
        XCTAssertTrue(html.contains("data-md-lo=\"6\""), html)
    }

    func testDisplayMathBlock() {
        let (html, hasMath) = markdownHTMLRender("$$\nE = mc^2\n$$")
        XCTAssertTrue(hasMath)
        XCTAssertTrue(html.contains("class=\"math math-display\""), html)
        XCTAssertTrue(html.contains("E = mc^2"), html)
        XCTAssertFalse(html.contains("\u{E000}"), html)
    }

    func testCurrencyDollarsAreNotMath() {
        let (html, hasMath) = markdownHTMLRender("цены $20 и $30 за штуку")
        XCTAssertFalse(hasMath)
        XCTAssertFalse(html.contains("class=\"math"), html)
        XCTAssertTrue(html.contains("$20 и $30"), html)
    }

    func testMathInsideCodeStaysLiteral() {
        let (html, hasMath) = markdownHTMLRender("```\n$x+y$\n```")
        XCTAssertFalse(hasMath)
        XCTAssertTrue(html.contains("$x+y$"), html)
    }

    func testMathTeXContentIsHTMLEscaped() {
        let (html, _) = markdownHTMLRender("$a < b$")
        XCTAssertTrue(html.contains("a &lt; b"), html)
        XCTAssertFalse(html.contains("<b$"), html)
    }

    func testMathAfterFrontmatterKeepsOffsets() {
        let md = "---\ntitle: x\n---\n$a$"
        let (html, hasMath) = markdownHTMLRender(md)
        XCTAssertTrue(hasMath)
        let loc = (md as NSString).range(of: "$a$").location
        XCTAssertTrue(html.contains("data-md-lo=\"\(loc)\""), html)
    }

    func testPreviewPageEmbedsKaTeXOnlyForMath() {
        let with = previewHTMLPage(markdown: "$x$", fontSize: 15)
        let without = previewHTMLPage(markdown: "plain text", fontSize: 15)
        // The base CSS mentions .katex-display (left-align override), so the
        // marker for "assets embedded" is the render call, not "katex".
        XCTAssertFalse(without.contains("katex.render"), "KaTeX embedded without math")
        XCTAssertTrue(with.contains("class=\"math math-inline\""))
        if KaTeXResources.isAvailable {
            XCTAssertTrue(with.contains("katex.render"))
        }
    }
}
