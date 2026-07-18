import XCTest
@testable import EditMD

/// URL-linkify paste door: the bare-URL detector and the link serializer.
final class PasteLinkTests: XCTestCase {

    // MARK: - bareWebURLForPaste

    func testAcceptsPlainHTTPAndHTTPS() {
        XCTAssertEqual(bareWebURLForPaste("https://example.com"), "https://example.com")
        XCTAssertEqual(bareWebURLForPaste("http://example.com/a/b?x=1#f"),
                       "http://example.com/a/b?x=1#f")
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(bareWebURLForPaste("  https://example.com\n"), "https://example.com")
    }

    func testRejectsProseContainingAURL() {
        // A sentence with a URL keeps the plain-text path.
        XCTAssertNil(bareWebURLForPaste("see https://example.com for more"))
    }

    func testRejectsNonWebSchemesAndBareText() {
        XCTAssertNil(bareWebURLForPaste("mailto:a@b.com"))
        XCTAssertNil(bareWebURLForPaste("ftp://host/file"))
        XCTAssertNil(bareWebURLForPaste("example.com"))       // no scheme
        XCTAssertNil(bareWebURLForPaste("just text"))
        XCTAssertNil(bareWebURLForPaste(""))
        XCTAssertNil(bareWebURLForPaste(nil))
        XCTAssertNil(bareWebURLForPaste("https://"))          // no host
    }

    func testRejectsMultilineClipboard() {
        XCTAssertNil(bareWebURLForPaste("https://a.com\nhttps://b.com"))
    }

    // MARK: - selectionUsableAsLinkLabel

    func testMultilineSelectionRefusesLinkLabel() {
        XCTAssertTrue(selectionUsableAsLinkLabel("one line"))
        XCTAssertFalse(selectionUsableAsLinkLabel("two\nlines"))
        XCTAssertFalse(selectionUsableAsLinkLabel("para\n\npara"))
        XCTAssertFalse(selectionUsableAsLinkLabel("crlf\r\nline"))
    }

    // MARK: - markdownLinkSyntax

    func testWrapsSelectionAsLink() {
        XCTAssertEqual(markdownLinkSyntax(text: "Example", url: "https://example.com"),
                       "[Example](https://example.com)")
    }

    func testAngleBracketsDestinationWithParens() {
        // Wikipedia-style URL with parens must not break the link.
        let out = markdownLinkSyntax(text: "Swift",
                                     url: "https://en.wikipedia.org/wiki/Swift_(language)")
        XCTAssertEqual(out, "[Swift](<https://en.wikipedia.org/wiki/Swift_(language)>)")
    }

    func testEscapesBracketsInLabel() {
        XCTAssertEqual(markdownLinkSyntax(text: "a [b] c", url: "https://x.com"),
                       "[a \\[b\\] c](https://x.com)")
    }
}
