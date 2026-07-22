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

// MARK: - Preview selection wrap + ==highlight== scan

final class PreviewSelectionWrapTests: XCTestCase {

    func testWrapsExactRange() {
        let md = "hello world hello"
        // Second "hello" only — not the first occurrence.
        let r = NSRange(location: 12, length: 5)
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "~~", close: "~~"),
            "hello world ~~hello~~"
        )
    }

    func testUnwrapsWhenAlreadyMarked() {
        let md = "~~hello~~ world"
        let r = NSRange(location: 2, length: 5) // "hello" inside ~~
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "~~", close: "~~"),
            "hello world"
        )
    }

    func testUnwrapsWhenSelectionIncludesMarkers() {
        let md = "before ~~paragraph~~ after"
        let r = (md as NSString).range(of: "~~paragraph~~")
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "~~", close: "~~"),
            "before paragraph after"
        )
    }

    func testPartialSelectionRemovesStyleOnlyFromFragment() {
        let md = "~~paragraph~~"
        XCTAssertEqual(toggleWrapAtRange(
            in: md, range: NSRange(location: 2, length: 4), open: "~~", close: "~~"),
            "para~~graph~~")
        XCTAssertEqual(toggleWrapAtRange(
            in: md, range: NSRange(location: 6, length: 5), open: "~~", close: "~~"),
            "~~para~~graph")
    }

    func testPlainTextBetweenStyledRunsIsWrappedNotUnwrapped() {
        let md = "~~a~~ plain ~~b~~"
        let range = (md as NSString).range(of: "plain")
        XCTAssertEqual(toggleWrapAtRange(in: md, range: range, open: "~~", close: "~~"),
                       "~~a~~ ~~plain~~ ~~b~~")
    }

    func testHighlightMarkers() {
        let md = "see ==important== note"
        let r = NSRange(location: 6, length: 9) // "important"
        XCTAssertEqual(
            toggleWrapAtRange(in: md, range: r, open: "==", close: "=="),
            "see important note"
        )
        let plain = "see important note"
        let r2 = (plain as NSString).range(of: "important")
        XCTAssertEqual(
            toggleWrapAtRange(in: plain, range: r2, open: "==", close: "=="),
            "see ==important== note"
        )
    }

    func testEmptyOrOutOfBoundsReturnsNil() {
        XCTAssertNil(toggleWrapAtRange(in: "abc", range: NSRange(location: 0, length: 0),
                                       open: "~~", close: "~~"))
        XCTAssertNil(toggleWrapAtRange(in: "abc", range: NSRange(location: 0, length: 10),
                                       open: "~~", close: "~~"))
    }

    func testScanHighlightMarks() {
        let marks = scanHighlightMarks(in: "a ==b== c ==d==")
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks[0].inner, "b")
        XCTAssertEqual(marks[1].inner, "d")
    }

    func testScanHighlightSkipsEmptyAndMultiline() {
        XCTAssertTrue(scanHighlightMarks(in: "====").isEmpty)
        XCTAssertTrue(scanHighlightMarks(in: "==a\nb==").isEmpty)
    }

    func testHighlightHTML() {
        let html = markdownHTMLBody("x ==hi== y")
        XCTAssertTrue(html.contains("<mark"), html)
        XCTAssertTrue(html.contains(">hi</mark>"), html)
        XCTAssertFalse(html.contains("==hi=="), html)
    }

    func testHighlightVisualRender() {
        let attr = renderMarkdownToAttributed("x ==hi== y")
        var found = false
        attr.enumerateAttribute(.mdInline, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
            if styles.contains(.highlight) {
                found = true
                XCTAssertEqual((attr.string as NSString).substring(with: range), "hi")
            }
        }
        XCTAssertTrue(found, "Visual render should stamp .highlight on ==…== inner text")
        XCTAssertFalse(attr.string.contains("=="), "markers must not appear in display text")
    }

    func testHTMLCommentOnlyHelper() {
        XCTAssertTrue(isHTMLCommentOnly("<!-- -->"))
        XCTAssertTrue(isHTMLCommentOnly("<!-- a -->\n<!-- b -->"))
        XCTAssertTrue(isHTMLCommentOnly("  <!-- x -->  "))
        XCTAssertFalse(isHTMLCommentOnly("<div>x</div>"))
        XCTAssertFalse(isHTMLCommentOnly("<!-- a -->visible"))
    }

    func testHTMLCommentIslandHasNoDisplayText() {
        let attr = renderMarkdownToAttributed("- a\n\n<!-- -->\n\n- b")
        XCTAssertFalse(attr.string.contains("<!--"),
                       "comment fence must not paint as a monospaced island")
        // Still round-trips via .raw on an empty paragraph.
        XCTAssertEqual(serializeAttributedToMarkdown(attr), "- a\n\n<!-- -->\n\n- b")
    }

    func testHTMLTagsSourceOffsets() {
        let html = markdownHTMLBody("hello")
        XCTAssertTrue(html.contains("data-md-lo=\"0\""), html)
        XCTAssertTrue(html.contains("data-md-hi=\"5\""), html)
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

// MARK: - stripInlineMarkers (B4)

final class StripInlineMarkersTests: XCTestCase {

    func testBold() {
        XCTAssertEqual(stripInlineMarkers("**hello**"), "hello")
    }

    func testNestedBoldItalic() {
        XCTAssertEqual(stripInlineMarkers("***hello***"), "hello")
        XCTAssertEqual(stripInlineMarkers("**_hello_**"), "hello")
        XCTAssertEqual(stripInlineMarkers("***hello***"), "hello")
    }

    func testCodeInteriorUntouched() {
        // Markers inside a code span must survive; outer backticks unwrap.
        XCTAssertEqual(stripInlineMarkers("`a**b**`"), "a**b**")
        XCTAssertEqual(stripInlineMarkers("x `a**b**` y"), "x a**b** y")
    }

    func testStrikeAndHighlight() {
        XCTAssertEqual(stripInlineMarkers("~~gone~~"), "gone")
        XCTAssertEqual(stripInlineMarkers("==hi=="), "hi")
    }

    func testMixedOutsideCode() {
        XCTAssertEqual(stripInlineMarkers("**a** and *b*"), "a and b")
    }

    func testHeadingMarkersNotTouchedAsStructure() {
        // Only inline delimiters — leading # is not stripped here.
        XCTAssertEqual(stripInlineMarkers("# **Title**"), "# Title")
    }

    func testIntrawordUnderscoreSurvives() {
        // CommonMark: intraword `_` is not emphasis.
        XCTAssertEqual(stripInlineMarkers("my_var_name"), "my_var_name")
        XCTAssertEqual(stripInlineMarkers("a_b_c and _real_"), "a_b_c and real")
    }

    func testWhitespaceFlankedStarsSurvive() {
        XCTAssertEqual(stripInlineMarkers("2 * 3 * 4"), "2 * 3 * 4")
        XCTAssertEqual(stripInlineMarkers("2 * 3 and *real*"), "2 * 3 and real")
    }

    func testRejectedCloserCanOpenLaterPair() {
        XCTAssertEqual(stripInlineMarkers("a_ _b_ c"), "a_ b c")
    }
}

// MARK: - cycleCase (B5)

final class CycleCaseTests: XCTestCase {

    func testLatinCycle() {
        XCTAssertEqual(cycleCase("HELLO"), "hello")
        XCTAssertEqual(cycleCase("hello"), "Hello")
        XCTAssertEqual(cycleCase("Hello"), "HELLO")
    }

    func testCyrillicCycle() {
        XCTAssertEqual(cycleCase("ПРИВЕТ"), "привет")
        XCTAssertEqual(cycleCase("привет"), "Привет")
        XCTAssertEqual(cycleCase("Привет"), "ПРИВЕТ")
    }

    func testMixedGoesUpper() {
        XCTAssertEqual(cycleCase("HeLLo"), "HELLO")
    }

    func testNoLettersUnchanged() {
        XCTAssertEqual(cycleCase("123"), "123")
    }
}

// MARK: - dividerSnippet (B3)

final class DividerSnippetTests: XCTestCase {

    private func insert(_ text: String, at loc: Int) -> String {
        let ns = text as NSString
        let range = NSRange(location: loc, length: 0)
        return ns.replacingCharacters(in: range,
                                      with: dividerSnippet(in: ns, replacing: range))
    }

    func testEmptyDocument() {
        XCTAssertEqual(insert("", at: 0), "---\n")
    }

    func testAfterParagraphWithoutTrailingNewline() {
        XCTAssertEqual(insert("text", at: 4), "text\n\n---\n")
    }

    func testBetweenExistingBlankLines() {
        // "para\n\n" + caret + "\nnext" — no extra blank growth.
        XCTAssertEqual(insert("para\n\n\nnext", at: 6), "para\n\n---\n\nnext")
    }

    func testMidLineBreaksOutToOwnBlock() {
        XCTAssertEqual(insert("ab", at: 1), "a\n\n---\n\nb")
    }

    func testAtLineStartAfterSingleNewline() {
        XCTAssertEqual(insert("para\nnext", at: 5), "para\n\n---\n\nnext")
    }

    /// The generalized `blockSnippet` gives a multi-line body (table template,
    /// `$$…$$`) the same one-blank-line separation as the divider.
    func testBlockSnippetSeparatesMultiLineBody() {
        let ns = "para\nnext" as NSString
        let range = NSRange(location: 5, length: 0)
        let body = "| a |\n| --- |"
        XCTAssertEqual(ns.replacingCharacters(
                           in: range,
                           with: blockSnippet(body, in: ns, replacing: range)),
                       "para\n\n| a |\n| --- |\n\nnext")
    }
}

// MARK: - Source block states (strip toggles)

final class SourceLineBlockTests: XCTestCase {

    func testClassifiesPrefixes() {
        XCTAssertEqual(classifyMarkdownLine("## Title").headingLevel, 2)
        XCTAssertNil(classifyMarkdownLine("#NoSpace").headingLevel)
        XCTAssertNil(classifyMarkdownLine("####### seven").headingLevel)
        XCTAssertTrue(classifyMarkdownLine("- item").bullet)
        XCTAssertTrue(classifyMarkdownLine("  * indented").bullet)
        XCTAssertFalse(classifyMarkdownLine("-no space").bullet)
        XCTAssertTrue(classifyMarkdownLine("- [x] done").checklist)
        XCTAssertFalse(classifyMarkdownLine("- [x] done").bullet,
                       "Task lines are checklists, not bullets")
        XCTAssertTrue(classifyMarkdownLine("3. third").numbered)
        XCTAssertTrue(classifyMarkdownLine("12) twelfth").numbered)
        XCTAssertFalse(classifyMarkdownLine("3.14 pi").numbered)
        XCTAssertTrue(classifyMarkdownLine("> quoted").quote)
    }

    /// Review P1: the checkmark must recognize EXACTLY what the toggle press
    /// recognizes (`transformLines` grammar) — no lenient extras.
    func testClassifierMatchesTransformLinesGrammar() {
        // A heading nested in a quote is quote-only: the heading toggle would
        // prepend another "# " rather than remove the existing one.
        let nested = classifyMarkdownLine("> # Quoted title")
        XCTAssertTrue(nested.quote)
        XCTAssertNil(nested.headingLevel)
        XCTAssertFalse(classifyMarkdownLine("> - listed").bullet)
        // The checklist toggle only knows "- [ ]": a star task is a bullet.
        let starTask = classifyMarkdownLine("* [x] done")
        XCTAssertFalse(starTask.checklist)
        XCTAssertTrue(starTask.bullet)
        // Quote is the literal "> " / ">" prefix, headings sit at column 0.
        XCTAssertFalse(classifyMarkdownLine(">tight").quote)
        XCTAssertTrue(classifyMarkdownLine(">").quote)
        XCTAssertNil(classifyMarkdownLine("  # indented").headingLevel)
    }

    /// Review P1: paragraph ranges carry the line terminator, transformLines'
    /// lines never do — the classifier must normalize to the logical line.
    func testClassifierNormalizesTrailingNewline() {
        XCTAssertTrue(classifyMarkdownLine(">\n").quote)
        XCTAssertNil(classifyMarkdownLine("#\n").headingLevel,
                     "The heading \\s+ must not be satisfied by the terminator")
        XCTAssertNil(classifyMarkdownLine("-\n").headingLevel)
        XCTAssertFalse(classifyMarkdownLine("-\n").bullet)
        XCTAssertFalse(classifyMarkdownLine("1.\n").numbered)
        XCTAssertTrue(classifyMarkdownLine("- item\n").bullet)
        XCTAssertEqual(classifyMarkdownLine("# Title\r\n").headingLevel, 1)
    }

    /// Anchoring at the covering span: the underline must close the SAME
    /// heading span, and every line of a multi-line Setext title lights.
    func testSetextHeadingLevelAgainstRealSpans() {
        func levels(of text: String) -> [Int?] {
            let spans = collectSpans(text)
            let ns = text as NSString
            var result: [Int?] = []
            var location = 0
            while location < ns.length {
                let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
                result.append(setextHeadingLevel(spans: spans, paragraph: paragraph,
                                                 text: ns))
                if NSMaxRange(paragraph) == location { break }
                location = NSMaxRange(paragraph)
            }
            return result
        }
        // Canonical Setext: both the title and the underline light.
        XCTAssertEqual(levels(of: "Title\n==="), [1, 1])
        // Bare "#" + thematic break: an empty ATX heading and a separate
        // construct — the next-line peek used to glue them into a fake H1.
        XCTAssertEqual(levels(of: "#\n---"), [nil, nil])
        // Multi-line Setext title: every line reports the level, so the
        // uniform merge over a full-heading selection stays on.
        XCTAssertEqual(levels(of: "Foo *bar\nbaz*\n===="), [1, 1, 1])
        // ATX heading is not a Setext: prefix grammar owns it.
        XCTAssertEqual(levels(of: "# ATX\nbody"), [nil, nil])
        // Setext H2 via dashes.
        XCTAssertEqual(levels(of: "Sub\n---"), [2, 2])
    }

    /// Review P1: the Setext fallback must demand the literal underline —
    /// cmark also calls `  # indented` a heading, the toggle grammar doesn't.
    func testSetextUnderlineShape() {
        XCTAssertTrue(isSetextUnderline("==="))
        XCTAssertTrue(isSetextUnderline("-"))
        XCTAssertTrue(isSetextUnderline("  ==  "))
        XCTAssertTrue(isSetextUnderline("===\n"))
        XCTAssertFalse(isSetextUnderline("    ==="), "4 spaces = code block")
        XCTAssertFalse(isSetextUnderline("=-="))
        XCTAssertFalse(isSetextUnderline("== =="))
        XCTAssertFalse(isSetextUnderline(""))
        XCTAssertFalse(isSetextUnderline("text"))
    }

    func testUniformStatesRequireEveryLine() {
        // H1 + plain paragraph — the caret-probe bug lit H1 here.
        let mixed = uniformBlockStates(["# Title", "plain text"])
        XCTAssertNil(mixed.headingLevel)
        XCTAssertFalse(mixed.quote)

        let allBullets = uniformBlockStates(["- a", "- b"])
        XCTAssertTrue(allBullets.bullet)

        let sameLevel = uniformBlockStates(["## a", "## b"])
        XCTAssertEqual(sameLevel.headingLevel, 2)
        XCTAssertNil(uniformBlockStates(["## a", "# b"]).headingLevel)
        XCTAssertEqual(uniformBlockStates([String]()), SourceLineBlock())
    }
}

// MARK: - cycleCaseAttributed (B5, Visual)

final class CycleCaseAttributedTests: XCTestCase {

    private let marker = NSAttributedString.Key("test.marker")

    /// "**bold** plain" as two runs; UPPER must not smear the bold attribute.
    func testMixedRunsKeepTheirAttributes() {
        let src = NSMutableAttributedString()
        src.append(NSAttributedString(string: "bold", attributes: [marker: 1]))
        src.append(NSAttributedString(string: " plain"))
        let out = cycleCaseAttributed(src)  // lower → capitalized? "bold plain" is lower → Capitalized
        XCTAssertEqual(out.string, "Bold Plain")
        XCTAssertEqual(out.attribute(marker, at: 0, effectiveRange: nil) as? Int, 1)
        XCTAssertEqual(out.attribute(marker, at: 3, effectiveRange: nil) as? Int, 1)
        XCTAssertNil(out.attribute(marker, at: 4, effectiveRange: nil))
    }

    /// A word split across runs ("H" bold + "ello" plain) stays ONE word when
    /// capitalizing — the second run must not get an extra capital.
    func testCapitalizationCarriesWordStateAcrossRuns() {
        let src = NSMutableAttributedString()
        src.append(NSAttributedString(string: "h", attributes: [marker: 1]))
        src.append(NSAttributedString(string: "ello world"))
        let out = cycleCaseAttributed(src)  // all lower → Capitalized
        XCTAssertEqual(out.string, "Hello World")
        XCTAssertEqual(out.attribute(marker, at: 0, effectiveRange: nil) as? Int, 1)
    }

    func testUpperAndLowerPerRun() {
        let src = NSMutableAttributedString()
        src.append(NSAttributedString(string: "ПРИВЕТ", attributes: [marker: 1]))
        src.append(NSAttributedString(string: " МИР"))
        let out = cycleCaseAttributed(src)  // upper → lower
        XCTAssertEqual(out.string, "привет мир")
        XCTAssertEqual(out.attribute(marker, at: 2, effectiveRange: nil) as? Int, 1)
        XCTAssertNil(out.attribute(marker, at: 7, effectiveRange: nil))
    }

    func testNoLettersUntouched() {
        let src = NSAttributedString(string: "12 34")
        XCTAssertEqual(cycleCaseAttributed(src).string, "12 34")
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
