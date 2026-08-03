import XCTest
import WebKit
import SwiftUI
@testable import EditMD

final class MarkdownHTMLTests: XCTestCase {

    // MARK: - Escaping

    func testTextIsEscaped() {
        let html = markdownHTMLBody("5 < 6 & 7 > 3")
        XCTAssertTrue(html.contains("5 &lt; 6 &amp; 7 &gt; 3"), html)
    }

    func testRawHTMLScriptsStayInertOnFullAndFragmentRenders() {
        let html = markdownHTMLBody("<script>alert('no')</script>")
        XCTAssertTrue(html.contains("&lt;script>alert('no')&lt;/script&gt;"), html)
        XCTAssertFalse(html.contains("<script>alert('no')</script>"), html)
    }

    /// The token spans must concatenate back to the code verbatim — that
    /// invariant is what lets Source/Visual paint the same runs over untouched
    /// storage, so assert it structurally instead of grepping for fragments.
    private func codeText(in html: String) -> String {
        guard let openTag = html.range(of: "<code"),
              let contentStart = html.range(of: ">", range: openTag.upperBound..<html.endIndex),
              let close = html.range(of: "</code>", range: contentStart.upperBound..<html.endIndex)
        else { return "" }
        let inner = String(html[contentStart.upperBound..<close.lowerBound])
        return inner
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    func testCodeBlockIsEscapedWithLanguageClass() {
        let html = markdownHTMLBody("```html\n<div class=\"x\">\n```")
        XCTAssertTrue(html.contains("<pre data-md-lo=\"0\""), html)
        XCTAssertTrue(html.contains("data-md-hi="), html)
        XCTAssertTrue(html.contains("data-md-code=\"1\""), html)
        XCTAssertTrue(html.contains("<code class=\"language-html hljs\">"), html)
        XCTAssertFalse(html.contains("<div class=\"x\">"), html)
        XCTAssertEqual(codeText(in: html), "<div class=\"x\">\n", html)
    }

    /// Sync needs a real DOM box per code line, so each line is its own anchor
    /// — token runs get cut at the line boundaries they cross, and the code text
    /// still concatenates back verbatim (`codeText`).
    func testCodeLinesAreIndividuallyAnchored() {
        let markdown = "```swift\nlet a = 1\nlet b = 2\n```"
        let html = markdownHTMLBody(markdown)
        let first = (markdown as NSString).range(of: "let a = 1")
        let second = (markdown as NSString).range(of: "let b = 2")
        XCTAssertTrue(html.contains(
            "<span class=\"cl\" data-md-lo=\"\(first.location)\" "
                + "data-md-hi=\"\(NSMaxRange(first))\">"), html)
        XCTAssertTrue(html.contains(
            "<span class=\"cl\" data-md-lo=\"\(second.location)\" "
                + "data-md-hi=\"\(NSMaxRange(second))\">"), html)
        XCTAssertEqual(codeText(in: html), "let a = 1\nlet b = 2\n", html)
    }

    /// Scroll sync must not depend on a display setting: line anchors exist with
    /// highlighting off too.
    func testCodeLinesAreAnchoredWithoutSyntaxHighlighting() {
        let markdown = "```swift\nlet a = 1\n```"
        let html = markdownHTMLBody(markdown, syntaxHighlighting: false)
        let line = (markdown as NSString).range(of: "let a = 1")
        XCTAssertTrue(html.contains(
            "<span class=\"cl\" data-md-lo=\"\(line.location)\" "
                + "data-md-hi=\"\(NSMaxRange(line))\">let a = 1</span>"), html)
        XCTAssertFalse(html.contains("hljs-token"), html)
    }

    /// The page pushes its anchor per frame instead of Swift polling it per
    /// wheel event (one round trip in flight dropped most of the gesture).
    func testPreviewPagePushesScrollAnchorAndFlagsProgrammaticScrolls() {
        let page = previewHTMLPage(markdown: "# One\n\nTwo", fontSize: 14)
        XCTAssertTrue(page.contains("messageHandlers.previewScroll.postMessage"), page)
        XCTAssertTrue(page.contains("if (suppressScrollReport > 0) return;"), page)
        XCTAssertTrue(page.contains("userScrolledSinceSettle = true;"), page)
        XCTAssertTrue(page.contains("function programmaticScroll(y)"), page)
        XCTAssertTrue(page.contains("function beginScrollReportSuppression()"), page)
        XCTAssertTrue(page.contains("function endScrollReportSuppressionAfterFrame()"), page)
    }

    /// A fenced block's opening fence is not a rendered line; an indented
    /// block's first line IS code. Anchors must line up with what's on screen.
    func testIndentedCodeBlockCountsItsFirstLineAsCode() {
        let markdown = "text\n\n    one\n    two\n"
        let html = markdownHTMLBody(markdown)
        let first = (markdown as NSString).range(of: "    one")
        XCTAssertTrue(html.contains(
            "<span class=\"cl\" data-md-lo=\"\(first.location)\" "
                + "data-md-hi=\"\(NSMaxRange(first))\">"), html)
    }

    func testCodeBlockUsesSyntaxHighlighterForBash() {
        let html = markdownHTMLBody("```bash\necho '<tag>' && exit 0\n```")
        XCTAssertTrue(html.contains("class=\"language-bash hljs\""), html)
        XCTAssertTrue(html.contains("hljs-token"), html)
        XCTAssertTrue(html.contains("&lt;tag&gt;"), html)
        XCTAssertEqual(codeText(in: html), "echo '<tag>' && exit 0\n", html)
    }

    /// Both palettes ride along on every token, so the page flips with
    /// `prefers-color-scheme` instead of baking the light theme onto a dark page.
    func testCodeTokensCarryLightAndDarkColors() {
        let html = markdownHTMLBody("```swift\nlet x = 1\n```")
        XCTAssertTrue(html.contains("--tl:#"), html)
        XCTAssertTrue(html.contains("--td:#"), html)
        let page = previewHTMLPage(markdown: "```swift\nlet x = 1\n```", fontSize: 14)
        XCTAssertTrue(page.contains(".hljs-token { color: var(--tl); }"), "token CSS missing")
        XCTAssertTrue(page.contains(".hljs-token { color: var(--td); }"), "dark token CSS missing")
    }

    func testCodeHighlightingCanBeDisabledInPreviewHTML() {
        let html = markdownHTMLBody("```bash\necho hello\n```", syntaxHighlighting: false)
        XCTAssertFalse(html.contains("hljs-token"), html)
        XCTAssertTrue(html.contains("echo hello"), html)
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
        XCTAssertTrue(page.contains("<main id=\"preview-content\"><h1>"), page)
        XCTAssertTrue(page.contains("<h1>"), page)
        XCTAssertTrue(page.contains("Title"), page)
        XCTAssertTrue(page.contains("color-scheme: light dark"), page)
    }

    func testPreviewPageIncludesPersistentLiveFragmentBridge() {
        let page = previewHTMLPage(markdown: "- [ ] Task", fontSize: 14)
        XCTAssertTrue(page.contains("window.editMDPreviewRevision = 0"), page)
        XCTAssertTrue(page.contains("window.editMDHydratePreviewContent = function ()"), page)
        // SYNCHRONOUS: the bridge is the Swift render task's continuation, so it
        // must never wait on a frame the web view may not produce (an awaited
        // requestAnimationFrame froze Preview on the first edit — see
        // testTypingIntoTheDocumentUpdatesTheLivePreview).
        XCTAssertTrue(page.contains("window.editMDReplacePreview = function (payload)"), page)
        XCTAssertFalse(page.contains("editMDReplacePreview = async"), page)
        XCTAssertFalse(page.contains("requestAnimationFrame(resolve)"), page)
        XCTAssertTrue(page.contains("root.innerHTML = payload.html"), page)
        XCTAssertTrue(page.contains("box.onchange = function ()"), page)
        XCTAssertTrue(page.contains("btn.onclick = function (e)"), page)
        XCTAssertTrue(page.contains("window.editMDCurrentScrollPosition = function ()"), page)
        // Scripts are siblings after the persistent content root, not children
        // that the first live replacement would destroy.
        let rootEnd = page.range(of: "</main>")!.upperBound
        let bridge = page.range(of: "window.editMDReplacePreview")!.lowerBound
        XCTAssertLessThan(rootEnd, bridge)
    }

    func testPreviewPageIncludesFindLayer() {
        let page = previewHTMLPage(markdown: "# Title\n\nfind me", fontSize: 14)
        XCTAssertTrue(page.contains("window.editMDFind = function (query)"), page)
        XCTAssertTrue(page.contains("window.editMDFindStep = function (delta)"), page)
        XCTAssertTrue(page.contains("window.editMDFindClear = function ()"), page)
        // Highlight classes the Swift side never names but the CSS must style.
        XCTAssertTrue(page.contains(".editmd-find"), page)
        XCTAssertTrue(page.contains(".editmd-find-current"), page)
        // A fragment swap discards the old spans; the references must be dropped
        // so a later step/clear can't touch dead nodes.
        let swap = page.range(of: "root.innerHTML = payload.html")!.upperBound
        let reset = page.range(of: "findMatches = [];", range: swap..<page.endIndex)
        XCTAssertNotNil(reset, "editMDReplacePreview must reset find state after innerHTML swap")
    }

    /// Geometry is read ONCE per layout. `alignLineNumberGutter` walks every
    /// `[data-ln]` element with getBoundingClientRect, so calling it from
    /// hydrate (pre-layout, therefore wrong anyway) *and* from the settle pass
    /// meant two forced full-document layouts per fragment, every ~90 ms.
    func testHydrateReadsNoGeometryAndSettleOwnsTheGutter() {
        let page = previewHTMLPage(markdown: "# Title\n\ntext", fontSize: 14)
        let hydrate = page.range(of: "window.editMDHydratePreviewContent = function () {")!
        let hydrateBody = String(page[hydrate.upperBound...].prefix(
            while: { $0 != "}" }))
        XCTAssertFalse(hydrateBody.contains("alignLineNumberGutter"), hydrateBody)
        XCTAssertTrue(page.contains("function settlePreviewLayout(position, pixelY) {"), page)
        XCTAssertTrue(page.contains("if (userScrolledSinceSettle) return;"), page)
        XCTAssertTrue(page.contains("html, body, #preview-content { overflow-anchor: none; }"), page)
        // The first full load replays the settle too — a freshly opened math
        // document used to keep the anchor table it built before the KaTeX
        // webfonts landed, and split-scroll drifted until the next resize.
        XCTAssertTrue(page.contains("replayPreviewSettle(document.getElementById('preview-content'), null)"),
                      page)
        XCTAssertTrue(page.contains("settlePreviewLayout(position, null);"), page)
        XCTAssertTrue(page.contains("document.fonts.status === 'loading'"), page)
    }

    /// Ordinary typing keeps the exact pixel immediately, while resources that
    /// land later restore the semantic point captured from the old DOM.
    func testFragmentSettleSeparatesImmediatePixelFromLateSemanticReplay() {
        let page = previewHTMLPage(markdown: "# Title\n\ntext", fontSize: 14)
        XCTAssertTrue(page.contains("pixelY = window.scrollY;"), page)
        XCTAssertTrue(page.contains(
            "replayPosition = window.editMDCurrentScrollPosition();"), page)
        XCTAssertTrue(page.contains("settlePreviewLayout(position, pixelY);"), page)
        XCTAssertTrue(page.contains("replayPreviewSettle(root, replayPosition);"), page)

        let capture = page.range(of: "replayPosition = window.editMDCurrentScrollPosition();")!
        let swap = page.range(of: "root.innerHTML = payload.html;")!
        XCTAssertLessThan(capture.lowerBound, swap.lowerBound,
                          "the semantic point must be read from the old DOM")
    }

    /// The fragment swap itself is programmatic: WebKit may clamp scrollY while
    /// innerHTML is changing, before the explicit settle has a chance to run.
    func testFragmentSwapSuppressesClampFeedbackForWholeDOMTransaction() {
        let page = previewHTMLPage(markdown: "# Title\n\ntext", fontSize: 14)
        let begin = page.range(of: "beginScrollReportSuppression();", options: [],
                               range: page.range(of: "window.editMDReplacePreview")!.lowerBound..<page.endIndex)!
        let swap = page.range(of: "root.innerHTML = payload.html;")!
        let end = page.range(of: "endScrollReportSuppressionAfterFrame();", options: .backwards)!
        XCTAssertLessThan(begin.lowerBound, swap.lowerBound)
        XCTAssertLessThan(swap.lowerBound, end.lowerBound)
        let transaction = String(page[begin.lowerBound..<end.upperBound])
        XCTAssertTrue(transaction.contains("try {"), transaction)
        XCTAssertTrue(transaction.contains("} finally {"), transaction)
    }

    /// The follow interpolates a FRACTIONAL markdown offset between anchors, in
    /// both directions. Anchoring to a rendered line instead makes the follow
    /// stall or run backwards, because the two panes wrap at different widths.
    func testPreviewPageIncludesImmediateSplitScrollBridge() {
        let page = previewHTMLPage(markdown: "# One\n\nTwo", fontSize: 14)
        XCTAssertTrue(page.contains("window.syncScrollToMdPosition = function (position)"), page)
        XCTAssertTrue(page.contains("function mdYForPosition(position)"), page)
        XCTAssertTrue(page.contains("function mdPositionForY(y)"), page)
        // TOP edges are what the two panes share: aligning bottom edges pins
        // Preview to zero for a whole screenful when the panes differ in height.
        XCTAssertTrue(page.contains("programmaticScroll(y - 8)"), page)
        XCTAssertTrue(page.contains("mdPositionForY(window.scrollY + 8)"), page)
    }

    /// The anchor table is what keeps a scroll gesture off a per-frame DOM walk
    /// (with highlighting that walk covers every token span). Scrolling must not
    /// stale it — hence document-space coords — but layout changes must.
    func testSplitScrollBridgeCachesAnchorsAndInvalidatesOnLayoutChange() {
        let page = previewHTMLPage(markdown: "# One\n\nTwo", fontSize: 14)
        XCTAssertTrue(page.contains("if (mdAnchorTable) return mdAnchorTable"), page)
        XCTAssertTrue(page.contains("top: rect.top + scrollY"), page)
        XCTAssertTrue(page.contains("window.addEventListener('resize', invalidateMdAnchors)"), page)
        XCTAssertTrue(page.contains("document.addEventListener('load', invalidateMdAnchors, true)"), page)
    }

    /// `pre` is tagged for scroll sync only: washing it would paint a whole
    /// code block for a mark that touches one line.
    func testReviewWashSkipsCodeBlockWrapper() {
        let page = previewHTMLPage(markdown: "```swift\nlet a = 1\n```", fontSize: 14)
        XCTAssertTrue(page.contains("querySelectorAll('[data-md-lo]:not(pre)')"), page)
    }

    func testPreviewPageUsesVerticalInsetForTopPadding() {
        let page = previewHTMLPage(markdown: "# Title", fontSize: 14, insetH: 40, insetV: 8)
        // Top padding must track Settings ▸ Vertical, not a hardcoded value.
        XCTAssertTrue(page.contains("padding: 8px 40px "), page)
        XCTAssertTrue(page.contains("#preview-content > :first-child { margin-top: 0; }"), page)
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
        XCTAssertTrue(page.contains("copyPreviewText(clone.innerText || '', btn)"), page)
    }

    func testCalloutPreviewUsesKnownStyleAndPreservesUnknownType() {
        let warning = markdownHTMLBody("> [!warning] Careful")
        XCTAssertTrue(warning.contains("class=\"callout callout-warning\""), warning)
        XCTAssertTrue(warning.contains("data-callout=\"warning\""), warning)
        XCTAssertTrue(warning.contains("class=\"callout-icon\""), warning)

        let custom = markdownHTMLBody("> [!custom] Domain")
        XCTAssertTrue(custom.contains("class=\"callout callout-note\""), custom)
        XCTAssertTrue(custom.contains("data-callout=\"custom\""), custom)
    }

    func testPreviewLineNumbersUseOneGlobalColumnAndLargerGap() {
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let page = previewHTMLPage(markdown: "# H\n\n- item\n\n> quote",
                                   fontSize: 14, insetH: 32, gutter: gutter)
        XCTAssertTrue(page.contains("--ln-gap: 18px"), page)
        XCTAssertTrue(page.contains("function alignLineNumberGutter()"), page)
        XCTAssertTrue(page.contains("desiredLeft - el.getBoundingClientRect().left"), page)
        XCTAssertFalse(page.contains("li[data-ln]::before"), page)
        // 32 content inset + gutter column + 18px text gap.
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

    // MARK: - Preview line numbers

    func testPreviewLineNumbersMatchSourceLines() {
        let md = "# Title\n\nParagraph text.\n\n## Second\n\n- item\n"
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let html = markdownHTMLBody(md, gutter: gutter)
        XCTAssertTrue(html.contains("data-ln=\"1\""), html)
        XCTAssertTrue(html.contains("data-ln=\"3\""), html)
        XCTAssertTrue(html.contains("data-ln=\"5\""), html)
        XCTAssertTrue(html.contains("data-ln=\"7\""), html)
    }

    func testPreviewLineNumbersWithFrontmatterOffset() {
        let md = "---\ntitle: x\n---\n\n# Hello\n"
        let gutter = PreviewGutterOptions(showLineNumbers: true)
        let html = markdownHTMLBody(md, gutter: gutter)
        // "# Hello" is line 5 in the original file
        XCTAssertTrue(html.contains("<h1") && html.contains("data-ln=\"5\""), html)
    }

    // MARK: - Math

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
        let with = previewHTMLPageRender(markdown: "$x$", fontSize: 15)
        let without = previewHTMLPageRender(markdown: "plain text", fontSize: 15)
        // The reusable hydrate bridge mentions katex.render even without the
        // library, so "assets embedded" is reported by the page itself.
        XCTAssertFalse(without.hasMathAssets)
        XCTAssertTrue(with.html.contains("class=\"math math-inline\""))
        XCTAssertEqual(with.hasMathAssets, KaTeXResources.isAvailable)
    }

    /// The live shell's KaTeX bit must be the one the page acted on. Scanning
    /// the RAW markdown instead sees `$…$` inside YAML frontmatter — which the
    /// renderer strips before it looks for math — and would claim assets the
    /// page never got, leaving every later formula in the body as raw TeX
    /// because no shell reload was ever triggered.
    func testFrontmatterMathDoesNotClaimKaTeXAssets() {
        let md = "---\nformula: $x^2$\n---\n\nPlain body, no math.\n"
        XCTAssertFalse(markdownHTMLRender(md).hasMath)
        XCTAssertFalse(previewHTMLPageRender(markdown: md, fontSize: 15).hasMathAssets)

        // …and once the body really has math, the page does embed them.
        let withBodyMath = md + "\nNow $E=mc^2$ lands.\n"
        XCTAssertTrue(markdownHTMLRender(withBodyMath).hasMath)
        XCTAssertEqual(previewHTMLPageRender(markdown: withBodyMath, fontSize: 15).hasMathAssets,
                       KaTeXResources.isAvailable)
    }

    /// Preview renders untrusted markdown (a synced vault, a cloned repo). A
    /// nonce'd script-src is what makes it a viewer rather than a script host:
    /// it blocks raw-HTML `<script>` AND inline event handlers, which no amount
    /// of tag-escaping reaches. Host-side JS (WKUserScript, evaluateJavaScript)
    /// bypasses CSP, so the selection bridge and the fragment bridge keep working.
    func testPreviewPageLocksDownScriptExecutionWithNoncedCSP() throws {
        let page = previewHTMLPage(markdown: "$x$\n\n<img src=x onerror=\"alert(1)\">",
                                   fontSize: 15)
        let meta = try XCTUnwrap(page.range(of: "<meta http-equiv=\"Content-Security-Policy\""))
        let header = String(page[meta.lowerBound...].prefix(400))
        XCTAssertTrue(header.contains("default-src 'none'"), header)

        // script-src carries a nonce and NOT 'unsafe-inline' — with a nonce
        // present, browsers ignore 'unsafe-inline', and inline event handlers
        // (`onerror=`) have no way to carry a nonce, so they never run.
        let scriptSrc = try XCTUnwrap(header.components(separatedBy: "script-src ")
            .last?.components(separatedBy: "\"").first)
        XCTAssertTrue(scriptSrc.hasPrefix("'nonce-"), scriptSrc)
        XCTAssertFalse(scriptSrc.contains("unsafe-inline"), scriptSrc)

        // Every script the page ships must carry the nonce, or the shell itself
        // would be blocked by its own policy.
        let nonce = try XCTUnwrap(scriptSrc.dropFirst("'nonce-".count)
            .components(separatedBy: "'").first)
        XCTAssertFalse(nonce.isEmpty)
        let scriptTags = page.components(separatedBy: "<script").dropFirst()
        XCTAssertFalse(scriptTags.isEmpty)
        for tag in scriptTags {
            XCTAssertTrue(tag.hasPrefix(" nonce=\"\(nonce)\""),
                          "script tag without the page nonce: \(tag.prefix(60))")
        }
    }
}

/// The CSP is only worth anything if it holds in a real WebKit page: the shell's
/// own bridge must survive it while injected markup does not. Asserting on the
/// HTML string cannot tell those apart — so load the page the app actually ships.
@MainActor
final class PreviewPageCSPWebKitTests: XCTestCase {

    func testShellScriptsRunUnderCSPWhileInjectedMarkupDoesNot() throws {
        let controller = WKUserContentController()
        // Stands in for the real selection bridge (a WKUserScript, like the one
        // MarkdownPreviewView installs): host-injected scripts must bypass CSP.
        controller.addUserScript(WKUserScript(
            source: "window.__userScriptRan = true;",
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800),
                                configuration: configuration)

        // Raw HTML an untrusted document could carry: a script tag and — the
        // vector escaping cannot reach — an inline error handler.
        let markdown = """
        # Title

        <img src="does-not-exist.png" onerror="window.__inlineHandlerRan = true;">

        <script>window.__injectedScriptRan = true;</script>

        Body with $x^2$ math.
        """
        let page = previewHTMLPage(markdown: markdown, fontSize: 14)

        let loaded = expectation(description: "page loaded")
        let delegate = LoadWaiter { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(page, baseURL: nil)
        wait(for: [loaded], timeout: 20)

        let probe = """
        JSON.stringify({
          userScript: !!window.__userScriptRan,
          injectedScript: !!window.__injectedScriptRan,
          inlineHandler: !!window.__inlineHandlerRan,
          bridge: typeof window.editMDReplacePreview === 'function',
          hydrate: typeof window.editMDHydratePreviewContent === 'function',
          mathRendered: !!document.querySelector('.math-rendered')
        })
        """
        let answered = expectation(description: "probe answered")
        var result: [String: Bool] = [:]
        webView.evaluateJavaScript(probe) { value, _ in
            if let json = value as? String,
               let data = json.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Bool] {
                result = parsed
            }
            answered.fulfill()
        }
        wait(for: [answered], timeout: 20)

        XCTAssertEqual(result["userScript"], true, "WKUserScript must bypass CSP")
        XCTAssertEqual(result["bridge"], true, "the shell's nonce'd bridge must run")
        XCTAssertEqual(result["hydrate"], true)
        XCTAssertEqual(result["injectedScript"], false, "raw <script> must not execute")
        XCTAssertEqual(result["inlineHandler"], false, "inline onerror must not execute")
        if KaTeXResources.isAvailable {
            XCTAssertEqual(result["mathRendered"], true, "KaTeX must still render under CSP")
        }
    }

    /// The live fragment path end to end, exactly as `applyFragment` drives it:
    /// callAsyncJavaScript → editMDReplacePreview → #preview-content. If this
    /// breaks, editing in the split silently stops updating Preview.
    func testFragmentReplacementSwapsTheContentRoot() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        let loaded = expectation(description: "page loaded")
        let delegate = LoadWaiter { loaded.fulfill() }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(previewHTMLPage(markdown: "# Before", fontSize: 14),
                               baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)

        // didFinish stamps the shell's revision; the fragment must be newer.
        _ = try await webView.evaluateJavaScript("window.editMDPreviewRevision = 1")

        let applied = try await webView.callAsyncJavaScript(
            "return window.editMDReplacePreview({html: html, revision: revision, position: position});",
            arguments: [
                "html": markdownHTMLBody("# After"),
                "revision": NSNumber(value: UInt64(2)),
                // No editor scroll to follow — ordinary typing preserves the
                // Preview's exact pixel viewport.
                "position": NSNull(),
            ],
            in: nil,
            contentWorld: .page
        )
        XCTAssertEqual(applied as? Bool, true, "editMDReplacePreview must report success")

        let html = try await webView.evaluateJavaScript(
            "document.getElementById('preview-content').innerHTML") as? String ?? ""
        XCTAssertTrue(html.contains("After"), html)
        XCTAssertFalse(html.contains("Before"), html)
    }

    /// Re-interpreting the old viewport as a markdown offset in the new DOM
    /// nudged Preview on the first character after placing the caret. Content
    /// replacement without a fresh editor-scroll instruction must be pixel-stable.
    func testFragmentReplacementPreservesExactPixelScrollWhileTyping() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        let loaded = expectation(description: "page loaded")
        let delegate = LoadWaiter { loaded.fulfill() }
        webView.navigationDelegate = delegate
        let markdown = (0..<120).map { "Paragraph \($0) with enough text to scroll." }
            .joined(separator: "\n\n")
        webView.loadHTMLString(previewHTMLPage(markdown: markdown, fontSize: 14),
                               baseURL: nil)
        await fulfillment(of: [loaded], timeout: 20)
        _ = try await webView.evaluateJavaScript("window.editMDPreviewRevision = 1")

        let beforeValue = try await webView.evaluateJavaScript(
            "window.scrollTo(0, 600); window.scrollY")
        let before = try XCTUnwrap(beforeValue as? NSNumber).doubleValue
        XCTAssertGreaterThan(before, 100, "test page did not become scrollable")

        let applied = try await webView.callAsyncJavaScript(
            "return window.editMDReplacePreview({html: html, revision: revision, position: null});",
            arguments: [
                "html": markdownHTMLBody("# Changed\n\n" + markdown),
                "revision": NSNumber(value: UInt64(2)),
            ],
            in: nil,
            contentWorld: .page
        )
        XCTAssertEqual(applied as? Bool, true)

        let afterValue = try await webView.evaluateJavaScript("window.scrollY")
        let after = try XCTUnwrap(afterValue as? NSNumber).doubleValue
        XCTAssertEqual(after, before, accuracy: 0.5,
                       "typing must not semantically re-anchor the Preview viewport")
    }

    /// `didFinish` attributes the load by WKNavigation identity, and a shell that
    /// is never marked ready freezes every later fragment render. That guard is
    /// only sound if WebKit hands back the very object `loadHTMLString` returned.
    func testLoadHTMLStringNavigationIsTheOneDidFinishReports() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let finished = expectation(description: "navigation finished")
        nonisolated(unsafe) var reported: WKNavigation?
        let delegate = LoadWaiter(onFinishNavigation: { navigation in
            reported = navigation
            finished.fulfill()
        })
        webView.navigationDelegate = delegate
        let started = webView.loadHTMLString(previewHTMLPage(markdown: "# Title", fontSize: 14),
                                             baseURL: nil)
        await fulfillment(of: [finished], timeout: 20)

        let issued = try XCTUnwrap(started, "loadHTMLString returned no navigation")
        XCTAssertTrue(issued === reported,
                      "didFinish must report the navigation loadHTMLString returned")
    }

    /// The whole split path, in a real window: SwiftUI observes the document,
    /// updateNSView schedules, the fragment renders off-main and lands in the DOM.
    /// This is the loop the user drives by typing — if it stalls, Preview freezes
    /// on the first render and never catches up.
    func testTypingIntoTheDocumentUpdatesTheLivePreview() throws {
        let document = MarkdownDocument()
        document.content = "# Before\n"

        struct Host: View {
            @ObservedObject var document: MarkdownDocument
            var body: some View {
                MarkdownPreviewView(document: document, fileURL: nil)
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(document: document))
        window.makeKeyAndOrderFront(nil)
        defer {
            // Tear the hosted tree down deterministically and let the runloop
            // drain: dropping a live WKWebView + SwiftUI host on the floor and
            // moving on took the whole test host down several suites later.
            window.orderOut(nil)
            window.contentView = nil
            pump(0.3)
        }

        let webView = try XCTUnwrap(findWebView(in: window), "no WKWebView was hosted")
        XCTAssertTrue(waitForPreviewText("Before", in: webView),
                      "the first full page never rendered")

        // What typing does, minus the keyboard: Source writes the buffer.
        document.content = "# After\n"
        XCTAssertTrue(waitForPreviewText("After", in: webView),
                      "Preview never picked up the edit — the live update path is stalled")
    }

    /// The production edit originates inside an AppKit text delegate. Preview
    /// must not rely exclusively on an ancestor SwiftUI view noticing that
    /// publish and calling updateNSView: coalescing the ancestor invalidation
    /// used to leave the real split frozen while the @ObservedObject host test
    /// above stayed green.
    func testPreviewObservesDocumentWithoutObservedObjectAncestor() throws {
        let document = MarkdownDocument()
        document.content = "# Before\n"

        struct Host: View {
            let document: MarkdownDocument
            var body: some View {
                MarkdownPreviewView(document: document, fileURL: nil)
            }
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Host(document: document))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            pump(0.3)
        }

        let webView = try XCTUnwrap(findWebView(in: window), "no WKWebView was hosted")
        XCTAssertTrue(waitForPreviewText("Before", in: webView),
                      "the first full page never rendered")

        document.content = "# After\n"
        XCTAssertTrue(waitForPreviewText("After", in: webView),
                      "Preview must observe the document at its coordinator boundary")
    }

    /// The test runs on the main thread, so nothing else pumps it: WebKit
    /// callbacks, SwiftUI's updateNSView and main-actor Tasks only advance while
    /// the runloop spins. Awaiting instead of pumping hangs the whole harness.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func findWebView(in window: NSWindow) -> WKWebView? {
        func find(_ view: NSView) -> WKWebView? {
            if let webView = view as? WKWebView { return webView }
            for sub in view.subviews {
                if let hit = find(sub) { return hit }
            }
            return nil
        }
        for _ in 0..<50 {
            if let root = window.contentView, let webView = find(root) { return webView }
            pump(0.1)
        }
        return nil
    }

    private func waitForPreviewText(_ needle: String, in webView: WKWebView) -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            var html: String?
            var answered = false
            webView.evaluateJavaScript(
                "var r = document.getElementById('preview-content'); r ? r.innerHTML : ''"
            ) { value, _ in
                html = value as? String
                answered = true
            }
            while !answered, Date() < deadline { pump(0.02) }
            if let html, html.contains(needle) { return true }
            pump(0.05)
        }
        return false
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private let onFinish: (WKNavigation?) -> Void

        init(onFinish: @escaping () -> Void) {
            self.onFinish = { _ in onFinish() }
        }

        init(onFinishNavigation: @escaping (WKNavigation?) -> Void) {
            self.onFinish = onFinishNavigation
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish(navigation)
        }
    }
}

final class PreviewRenderSchedulerTests: XCTestCase {

    func testFirstRequestStartsImmediatelyAndDuplicateIsIgnored() {
        var scheduler = PreviewRenderScheduler()
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(scheduler.request("one"), 1)
        XCTAssertNil(scheduler.request("one"))
        XCTAssertEqual(scheduler.delay(heavy: false, now: now), 0)
        XCTAssertEqual(scheduler.startLatest(now: now),
                       .init(revision: 1, content: "one"))
    }

    func testTypingWhileRenderingKeepsOnlyLatestRequest() {
        var scheduler = PreviewRenderScheduler()
        let now = Date(timeIntervalSince1970: 1_000)
        _ = scheduler.request("one")
        let first = scheduler.startLatest(now: now)!
        _ = scheduler.request("two")
        _ = scheduler.request("three")

        XCTAssertTrue(scheduler.markApplied(first))
        XCTAssertTrue(scheduler.hasPendingRequest)
        XCTAssertEqual(scheduler.startLatest(now: now.addingTimeInterval(1)),
                       .init(revision: 3, content: "three"))
    }

    func testAppliedRevisionNeverMovesBackwards() {
        var scheduler = PreviewRenderScheduler()
        _ = scheduler.request("old")
        let old = scheduler.startLatest()!
        _ = scheduler.request("new")
        let new = scheduler.startLatest()!
        XCTAssertTrue(scheduler.markApplied(new))
        XCTAssertFalse(scheduler.markApplied(old))
        XCTAssertEqual(scheduler.appliedRevision, new.revision)
        // Strictly forward: the same revision cannot land twice (the shell's
        // didFinish and a fragment completion must not both claim it).
        XCTAssertFalse(scheduler.markApplied(new))
    }

    func testHeavyDocumentsUseLongerThrottleButKeepPendingRevision() {
        var scheduler = PreviewRenderScheduler()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = scheduler.request("one")
        _ = scheduler.startLatest(now: start)
        _ = scheduler.request("two")
        let soon = start.addingTimeInterval(0.02)

        XCTAssertEqual(scheduler.delay(heavy: false, now: soon), 0.07, accuracy: 0.001)
        XCTAssertEqual(scheduler.delay(heavy: true, now: soon), 0.23, accuracy: 0.001)
        XCTAssertTrue(scheduler.hasPendingRequest)
    }

    func testOnlyFirstMathActivationRequiresNewShell() {
        XCTAssertTrue(PreviewShellUpdatePolicy.requiresFullReload(
            hasMath: true, shellHasMathAssets: false))
        XCTAssertFalse(PreviewShellUpdatePolicy.requiresFullReload(
            hasMath: false, shellHasMathAssets: false))
        XCTAssertFalse(PreviewShellUpdatePolicy.requiresFullReload(
            hasMath: true, shellHasMathAssets: true))
    }
}
