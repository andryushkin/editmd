import AppKit
import XCTest
@testable import EditMD

final class CodeSyntaxHighlighterTests: XCTestCase {
    func testLanguageAliasesAndInfoStringParameters() {
        XCTAssertEqual(CodeLanguageRegistry.language(from: " sh "), "bash")
        XCTAssertEqual(CodeLanguageRegistry.language(from: "swift title=\"App.swift\""), "swift")
        XCTAssertEqual(CodeLanguageRegistry.language(from: "yml"), "yaml")
        XCTAssertNil(CodeLanguageRegistry.language(from: "nohighlight"))
        XCTAssertNil(CodeLanguageRegistry.language(from: nil))
    }

    /// Runs must map onto the ORIGINAL text: callers paint them over their own
    /// storage, so a shifted offset would smear colors across the code.
    func testTokenRunsStayInsideTheSourceText() throws {
        let source = "# 🎉\necho \"$HOME\"\n"
        let runs = try XCTUnwrap(
            CodeSyntaxHighlighter.shared.tokenRuns(for: source, language: "bash", blocking: true))
        XCTAssertFalse(runs.isEmpty)
        let length = (source as NSString).length
        for run in runs {
            XCTAssertGreaterThanOrEqual(run.range.location, 0)
            XCTAssertLessThanOrEqual(NSMaxRange(run.range), length)
        }
    }

    /// One pass, two palettes: the token color resolves per drawing appearance,
    /// so the ☀/🌙 override and a system Dark Mode switch both land without
    /// re-running the highlighter.
    func testTokenColorFollowsTheDrawingAppearance() throws {
        let runs = try XCTUnwrap(
            CodeSyntaxHighlighter.shared.tokenRuns(for: "let x = 1\n", language: "swift",
                                                   blocking: true))
        let run = try XCTUnwrap(runs.first)
        let aqua = try XCTUnwrap(NSAppearance(named: .aqua))
        let darkAqua = try XCTUnwrap(NSAppearance(named: .darkAqua))
        XCTAssertEqual(run.color.hexString(for: aqua), run.lightHex)
        XCTAssertEqual(run.color.hexString(for: darkAqua), run.darkHex)
        XCTAssertNotEqual(run.lightHex, run.darkHex)
    }

    func testFenceBodyExcludesFences() {
        let source = "```bash\necho $HOME\n```\n"
        let ns = source as NSString
        let body = CodeSyntaxHighlighter.shared.fencedBodyRange(
            in: ns, blockRange: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(body.map { ns.substring(with: $0) }, "echo $HOME\n")
    }

    func testHTMLIsEscapedAndCarriesBothPalettes() {
        let html = CodeSyntaxHighlighter.shared.html("echo '<tag>'", language: "bash")
        XCTAssertTrue(html.contains("hljs-token"), html)
        XCTAssertTrue(html.contains("--tl:#"), html)
        XCTAssertTrue(html.contains("--td:#"), html)
        XCTAssertTrue(html.contains("&lt;tag&gt;"), html)
        XCTAssertFalse(html.contains("<tag>"), html)
    }

    /// The span text, tags stripped, is the code: nothing dropped, nothing
    /// reordered, whitespace intact.
    func testHTMLSpansReproduceTheCodeVerbatim() {
        let source = "if a && b {\n    print(\"x < y\")\n}\n"
        let html = CodeSyntaxHighlighter.shared.html(source, language: "swift")
        XCTAssertEqual(unescapedText(of: html), source)
    }

    /// Plain text and oversized blocks answer with an empty run list — a
    /// definitive "nothing to paint", not a pending one, so no caller spins.
    func testPlainTextAndOversizedBlocksAreDefinitivelyEmpty() {
        XCTAssertEqual(CodeSyntaxHighlighter.shared.tokenRuns(for: "x", language: "text")?.count, 0)
        let huge = String(repeating: "echo hello\n", count: 10_000)
        XCTAssertGreaterThan((huge as NSString).length, CodeSyntaxHighlighter.maximumCodeLength)
        XCTAssertEqual(CodeSyntaxHighlighter.shared.tokenRuns(for: huge, language: "bash")?.count, 0)
        XCTAssertFalse(CodeSyntaxHighlighter.shared.html(huge, language: "bash").contains("hljs-token"))
    }

    /// A block too big to highlight inside a keystroke returns nil (the caller
    /// leaves it plain), warms off main and posts a repaint — typing never waits
    /// on JavaScriptCore.
    func testBigBlockWarmsOffMainAndNotifies() {
        let source = "// \(UUID().uuidString)\n" + String(repeating: "let value = 1\n", count: 500)
        XCTAssertGreaterThan((source as NSString).length, CodeSyntaxHighlighter.inlineLimit)

        let warmed = XCTNSNotificationExpectation(name: .codeHighlightingDidWarm)
        XCTAssertNil(CodeSyntaxHighlighter.shared.tokenRuns(for: source, language: "swift"),
                     "an oversized block must not run Highlight.js on the caller's thread")
        wait(for: [warmed], timeout: 10)

        let runs = CodeSyntaxHighlighter.shared.tokenRuns(for: source, language: "swift")
        XCTAssertFalse(runs?.isEmpty ?? true, "the warmed cache must serve the next pass")
    }

    private func unescapedText(of html: String) -> String {
        html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
