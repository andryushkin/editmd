import XCTest
@testable import EditMD

/// Formulas sprint: scanner ($…$ / $$…$$) + the length-preserving mask.
final class MathScanTests: XCTestCase {

    private func spans(_ s: String) -> [MDMathSpan] { scanMathSpans(in: s) }

    // MARK: - Inline

    func testInlineSimple() {
        let r = spans("a $x+y$ b")
        XCTAssertEqual(r.count, 1)
        XCTAssertFalse(r[0].display)
        XCTAssertEqual(r[0].range, NSRange(location: 2, length: 5))
        XCTAssertEqual(r[0].innerRange, NSRange(location: 3, length: 3))
    }

    func testInlineTeXWithBackslashes() {
        let text = #"$\frac{a}{b} \cdot \{x\}$"#
        let r = spans(text)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testTwoInlineSpansOnOneLine() {
        let r = spans("$a$ text $b$")
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[1].range, NSRange(location: 9, length: 3))
    }

    func testSpaceRulesRejectLooseDollars() {
        XCTAssertTrue(spans("a $ x$ b").isEmpty)   // opener followed by space
        XCTAssertTrue(spans("a $x $ b").isEmpty)   // closer preceded by space
    }

    func testCurrencyIsNotMath() {
        XCTAssertTrue(spans("за $20 и $30 руб").isEmpty)
        // Closer followed by a digit does not close.
        XCTAssertTrue(spans("цена $10, скидка $5").isEmpty)
    }

    func testEscapedDollarDoesNotOpen() {
        XCTAssertTrue(spans(#"\$x$"#).isEmpty)
        let r = spans(#"\$a$ и $b$"#)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].innerRange.length, 1)  // only $b$
    }

    // MARK: - Display

    func testDisplaySameLine() {
        let r = spans("$$a+b$$")
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].display)
        XCTAssertEqual(r[0].range, NSRange(location: 0, length: 7))
        XCTAssertEqual(r[0].innerRange, NSRange(location: 2, length: 3))
    }

    func testDisplayMultiline() {
        let text = "$$\n\\alpha_i\n$$"
        let r = spans(text)
        XCTAssertEqual(r.count, 1)
        XCTAssertTrue(r[0].display)
        XCTAssertEqual(r[0].range, NSRange(location: 0, length: (text as NSString).length))
    }

    func testDisplayMultilineRequiresLineStart() {
        // Opener mid-line with no same-line closer → not math.
        XCTAssertTrue(spans("text $$\na\n$$").isEmpty)
    }

    func testDisplayMultilineCloserMustEndLine() {
        // Trailing text after the closer breaks the "whole lines" contract.
        XCTAssertTrue(spans("$$\na\n$$ tail").isEmpty)
        // Trailing whitespace is fine.
        XCTAssertEqual(spans("$$\na\n$$   ").count, 1)
    }

    // MARK: - collectSpans uses the masked parse

    func testCollectSpansNoSetextHeadingInsideDisplayMath() {
        // `=` line inside $$…$$ must NOT make the block a giant setext H1.
        let text = "$$\n\\begin{pmatrix} a \\\\ b \\end{pmatrix}\n=\n\\begin{pmatrix} c \\end{pmatrix}\n$$"
        let result = collectSpans(text)
        XCTAssertFalse(result.contains { if case .headingBody = $0.kind { return true }; return false })
        XCTAssertTrue(result.contains { if case .mathBody(display: true) = $0.kind { return true }; return false })
    }

    func testCollectSpansNoEmphasisInsideInlineMath() {
        let result = collectSpans("count $a *b* c$ end")
        XCTAssertFalse(result.contains { if case .italicBody = $0.kind { return true }; return false })
        XCTAssertTrue(result.contains { if case .mathBody(display: false) = $0.kind { return true }; return false })
    }

    func testDisplayInsideBlockquoteRejected() {
        // `>` would be masked away and break the quote — scanner refuses.
        XCTAssertTrue(spans("> $$\n> x\n> $$").isEmpty)
    }

    func testEmptyDisplayIsNotMath() {
        XCTAssertTrue(spans("$$$$").isEmpty)
        XCTAssertTrue(spans("$$").isEmpty)
    }

    // MARK: - Code is skipped

    func testFencedCodeSkipped() {
        XCTAssertTrue(spans("```\n$x$\n```").isEmpty)
        XCTAssertTrue(spans("~~~\n$$a$$\n~~~").isEmpty)
    }

    func testInlineCodeSkipped() {
        XCTAssertTrue(spans("use `$x$` here").isEmpty)
    }

    func testIndentedCodeSkipped() {
        XCTAssertTrue(spans("para\n\n    $x$\n").isEmpty)
    }

    func testMathAfterFenceWorks() {
        let r = spans("```\ncode\n```\n\n$x$")
        XCTAssertEqual(r.count, 1)
    }

    // MARK: - Mask

    func testMaskPreservesUTF16LayoutAndNewlines() {
        let text = "a $x_1$ b\n$$\n\\frac{a}{b}\n$$\n"
        let found = spans(text)
        XCTAssertEqual(found.count, 2)
        let (masked, units) = maskMathSpansForParsing(text, spans: found)
        let nsm = masked as NSString
        let nst = text as NSString
        XCTAssertEqual(nsm.length, nst.length)
        for i in 0..<nst.length where nst.character(at: i) == 0x0A {
            XCTAssertEqual(nsm.character(at: i), 0x0A, "newline moved at \(i)")
        }
        XCTAssertFalse(masked.contains("$"))
        // $x_1$ → 5 masked units; $$…$$ → 2+11+2 (newlines kept).
        XCTAssertEqual(units, [5, 15])
        // Text outside the spans is untouched.
        XCTAssertTrue(masked.hasPrefix("a "))
        XCTAssertEqual(nsm.character(at: 8), nst.character(at: 8))  // "b"
    }

    func testMaskKeepsLeadingIndent() {
        let text = "  $$\n  x + y\n  $$"
        let found = spans(text)
        XCTAssertEqual(found.count, 1)
        let (masked, _) = maskMathSpansForParsing(text, spans: found)
        // Continuation lines keep their leading spaces (list nesting survives).
        XCTAssertTrue(masked.contains("\n  "), masked)
        XCTAssertFalse(masked.contains("$"))
    }

    func testMaskSurvivesAstralCharacters() {
        let text = "$a😀b$"
        let found = spans(text)
        XCTAssertEqual(found.count, 1)
        let (masked, units) = maskMathSpansForParsing(text, spans: found)
        XCTAssertEqual((masked as NSString).length, (text as NSString).length)
        XCTAssertEqual(units, [(text as NSString).length])
    }
}
