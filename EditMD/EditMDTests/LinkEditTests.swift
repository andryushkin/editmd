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

    func testLocalFileKeepsAnchorAndQuery() {
        // The file check must not depend on the name being the whole string.
        XCTAssertEqual(normalizedLinkURL("notes.md#heading"), "notes.md#heading")
        XCTAssertEqual(normalizedLinkURL("notes.md?plain=1"), "notes.md?plain=1")
        XCTAssertEqual(normalizedLinkURL("assets/shot.png#fig"), "assets/shot.png#fig")
    }

    func testUnknownExtensionsStayLocal() {
        // Not a curated TLD → a file in the vault, not a host to complete.
        for dest in ["build.sh", "schema.sql", "report.docx", "data.xlsx",
                     "main.swift", "lib.rs", "script.pl"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testDottedFolderInPathStaysLocal() {
        // PARA / versioned vault folders: the first segment has a dot but is
        // not a host.
        for dest in ["2.Areas/note.md", "assets.old/img.png", "v1.x/spec.md"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testServerWithPortGetsHTTP() {
        // A port with no domain is a server on this network, and those speak
        // http far more often than https.
        XCTAssertEqual(normalizedLinkURL("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(normalizedLinkURL("localhost:8080/preview"),
                       "http://localhost:8080/preview")
        XCTAssertEqual(normalizedLinkURL("192.168.1.5:8080"), "http://192.168.1.5:8080")
    }

    func testColonThatIsNotAPortOrSchemeIsKept() {
        for dest in ["C:\\notes", "foo:bar", "https:example.com"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    // MARK: - linkDestination

    func testUntouchedDestinationIsStoredVerbatim() {
        // Opening ⌘K on an existing link and confirming must not rewrite it,
        // however odd the destination looks to the normalizer.
        for existing in ["notes.md", "2.Areas/note.md", "build.sh", "example.com"] {
            XCTAssertEqual(linkDestination(typed: existing, existing: existing), existing)
        }
    }

    func testEditedDestinationIsNormalized() {
        XCTAssertEqual(linkDestination(typed: "example.com", existing: "notes.md"),
                       "https://example.com")
        XCTAssertEqual(linkDestination(typed: "  example.com  ", existing: ""),
                       "https://example.com")
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
