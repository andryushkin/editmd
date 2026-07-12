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

    func testHighlightedCodePreservesUnicodeText() {
        let source = "# 🎉\necho \"$HOME\"\n"
        let result = CodeSyntaxHighlighter.shared.highlight(source, language: "bash")
        XCTAssertEqual(result.string, source)
        XCTAssertEqual(result.length, (source as NSString).length)
    }

    func testFenceBodyExcludesFences() {
        let source = "```bash\necho $HOME\n```\n"
        let ns = source as NSString
        let body = CodeSyntaxHighlighter.shared.fencedBodyRange(
            in: ns, blockRange: NSRange(location: 0, length: ns.length))
        XCTAssertEqual(body.map { ns.substring(with: $0) }, "echo $HOME\n")
    }

    func testHTMLIsEscapedAndContainsTokenSpans() {
        let html = CodeSyntaxHighlighter.shared.html("echo '<tag>'", language: "bash")
        XCTAssertTrue(html.contains("hljs-token"), html)
        XCTAssertTrue(html.contains("&lt;tag&gt;"), html)
        XCTAssertFalse(html.contains("<tag>"), html)
    }

    func testLargeBlockFallsBackWithoutChangingText() {
        let source = String(repeating: "echo hello\n", count: 10_000)
        let result = CodeSyntaxHighlighter.shared.highlight(source, language: "bash")
        XCTAssertEqual(result.string, source)
        XCTAssertNil(result.attribute(.foregroundColor, at: 0, effectiveRange: nil))
    }
}
