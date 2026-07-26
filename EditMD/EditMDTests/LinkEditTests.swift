import XCTest
import AppKit
@testable import EditMD

/// Link editor helpers (⌘K) and the no-selection URL paste autolink.
final class LinkEditTests: XCTestCase {

    // MARK: - markdownAutolinkSyntax

    func testAutolinkWrapsBareURL() {
        XCTAssertEqual(markdownAutolinkSyntax(url: "https://example.com"),
                       "<https://example.com>")
    }

    func testAutolinkFallsBackWhenURLHasAngleBrackets() {
        // A `>` in the URL can't sit inside a CommonMark autolink.
        XCTAssertEqual(markdownAutolinkSyntax(url: "https://x.com/a>b"),
                       "[https://x.com/a>b](https://x.com/a>b)")
    }

    // MARK: - normalizedLinkURL

    func testBareHostGetsHTTPS() {
        XCTAssertEqual(normalizedLinkURL("example.com"), "https://example.com")
        XCTAssertEqual(normalizedLinkURL("www.example.com"), "https://www.example.com")
        XCTAssertEqual(normalizedLinkURL("sub.example.co.uk/page?q=1#top"),
                       "https://sub.example.co.uk/page?q=1#top")
        XCTAssertEqual(normalizedLinkURL("сайт.рф"), "https://сайт.рф")
    }

    func testHostWithPortGetsHTTPS() {
        // The colon is a port here, not a scheme.
        XCTAssertEqual(normalizedLinkURL("example.com:8080/x"), "https://example.com:8080/x")
    }

    func testSurroundingSpaceIsTrimmed() {
        XCTAssertEqual(normalizedLinkURL("  example.com  "), "https://example.com")
    }

    func testExistingSchemeIsKept() {
        for url in ["https://example.com", "http://example.com", "mailto:a@b.io",
                    "tel:+1234", "editmd://new?file=x", "obsidian://open"] {
            XCTAssertEqual(normalizedLinkURL(url), url)
        }
    }

    func testLocalDestinationsAreKept() {
        for dest in ["#heading", "/abs/path", "./sibling.md", "../up.md", "notes",
                     "notes.md", "shot.png", "Untitled.markdown", "a b.com"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testRelativePathWithLocalFileIsKept() {
        // A dot inside a path must not turn the first segment into a host.
        XCTAssertEqual(normalizedLinkURL("docs/intro.md"), "docs/intro.md")
    }

    func testBareAddressGetsMailto() {
        XCTAssertEqual(normalizedLinkURL("user@example.com"), "mailto:user@example.com")
        XCTAssertEqual(normalizedLinkURL("user.name+tag@sub.example.co.uk"),
                       "mailto:user.name+tag@sub.example.co.uk")
    }

    func testNonAddressesWithAtAreKept() {
        for dest in ["user@localhost",       // no dotted host
                     "@example.com",         // no local part
                     "a@b@example.com",      // two @
                     "user@example.com/path" // userinfo, not an address
        ] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(normalizedLinkURL(""), "")
        XCTAssertEqual(normalizedLinkURL("   "), "")
    }

    // MARK: - inlineLinkMatch

    func testFindsLinkUnderCaret() {
        let s = "see [Example](https://example.com) now"
        let m = inlineLinkMatch(in: s, at: 20)
        XCTAssertEqual(m?.range, NSRange(location: 4, length: 30))
        XCTAssertEqual(m?.text, "Example")
        XCTAssertEqual(m?.url, "https://example.com")
    }

    func testMatchesAtEitherEdge() {
        let s = "see [Example](https://example.com) now"
        // Just before '[' … and just after ')'.
        XCTAssertNotNil(inlineLinkMatch(in: s, at: 4))
        XCTAssertNotNil(inlineLinkMatch(in: s, at: 34))
    }

    func testNoMatchOffTheLink() {
        let s = "see [Example](https://example.com) now"
        XCTAssertNil(inlineLinkMatch(in: s, at: 0))
        XCTAssertNil(inlineLinkMatch(in: s, at: 38))
    }

    func testAutolinkIsEditable() {
        // ⌘K on `<url>` prefills the URL as both label and destination.
        let m = inlineLinkMatch(in: "go <https://x.io> end", at: 8)
        XCTAssertEqual(m?.url, "https://x.io")
        XCTAssertEqual(m?.text, "https://x.io")
    }

    func testNoLinkInPlainText() {
        XCTAssertNil(inlineLinkMatch(in: "just some words", at: 5))
    }
}

/// End-to-end paste behavior in the real Source text view.
@MainActor
final class SourcePasteURLIntegrationTests: XCTestCase {

    private func makeView(_ text: String, selection: NSRange) -> SourceNSTextView {
        let tv = SourceNSTextView()
        tv.string = text
        tv.setSelectedRange(selection)
        return tv
    }

    private func setClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    func testPasteURLOverSelectionMakesLink() {
        let tv = makeView("hello world", selection: NSRange(location: 0, length: 5))
        setClipboard("https://example.com")
        tv.paste(nil)
        XCTAssertEqual(tv.string, "[hello](https://example.com) world")
    }

    func testPasteURLWithNoSelectionMakesAutolink() {
        let tv = makeView("start ", selection: NSRange(location: 6, length: 0))
        setClipboard("https://example.com")
        tv.paste(nil)
        XCTAssertEqual(tv.string, "start <https://example.com>")
    }

    func testPasteNonURLWithNoSelectionStaysPlain() {
        let tv = makeView("start ", selection: NSRange(location: 6, length: 0))
        setClipboard("just some text")
        tv.paste(nil)
        XCTAssertEqual(tv.string, "start just some text")
    }
}
