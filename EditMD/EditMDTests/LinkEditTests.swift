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

    func testDottedFolderWithTLDSuffixStaysLocalWhenUnknown() {
        // No probe (unsaved document): a folder whose suffix happens to be a real
        // TLD keeps the benefit of the doubt.
        for dest in ["docs.dev/intro.md", "archive.org/note.md",
                     "notes.io/assets/shot.png", "data.info/table.csv"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testExistingLocalFileDecidesAgainstCompletion() {
        // The file is really there → a path, whatever the first segment reads like.
        for dest in ["docs.dev/intro.md", "archive.org/note.md", "example.com/img.png"] {
            XCTAssertEqual(normalizedLinkURL(dest, localFileExists: { _ in true }), dest)
        }
    }

    func testMissingLocalFileIsCompletedWhenHostIsPlausible() {
        // No such file → the host wins, which is what the TLD says it is.
        XCTAssertEqual(normalizedLinkURL("archive.org/note.md", localFileExists: { _ in false }),
                       "https://archive.org/note.md")
        XCTAssertEqual(normalizedLinkURL("docs.dev/intro.md", localFileExists: { _ in false }),
                       "https://docs.dev/intro.md")
        XCTAssertEqual(normalizedLinkURL("example.com/img.png", localFileExists: { _ in false }),
                       "https://example.com/img.png")
    }

    func testMissingFileStillStaysLocalWithoutAPlausibleHost() {
        // Linking a note before creating it is normal, and `md`/`areas` are not
        // completable TLDs — a missing file must not turn these into URLs.
        for dest in ["notes.md", "2.Areas/note.md", "assets.old/img.png", "v1.x/spec.md"] {
            XCTAssertEqual(normalizedLinkURL(dest, localFileExists: { _ in false }), dest)
        }
    }

    func testProbeIsNotConsultedForUnambiguousInput() {
        // A plain host has no file reading to check, so the answer cannot matter.
        for exists in [true, false] {
            XCTAssertEqual(normalizedLinkURL("example.com", localFileExists: { _ in exists }),
                           "https://example.com")
            XCTAssertEqual(normalizedLinkURL("#top", localFileExists: { _ in exists }), "#top")
        }
    }

    func testWebPathThatIsNotAVaultFileIsCompleted() {
        // Nothing in the vault ends in `.html`, so a page keeps completing.
        XCTAssertEqual(normalizedLinkURL("example.com/index.html"),
                       "https://example.com/index.html")
        XCTAssertEqual(normalizedLinkURL("example.com/docs/intro"),
                       "https://example.com/docs/intro")
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

    func testAtInThePathIsNotAnAddress() {
        // A handle in a path is an ordinary page — the `@` says nothing there.
        XCTAssertEqual(normalizedLinkURL("youtube.com/@mkbhd"), "https://youtube.com/@mkbhd")
        XCTAssertEqual(normalizedLinkURL("medium.com/@author/post"),
                       "https://medium.com/@author/post")
        XCTAssertEqual(normalizedLinkURL("example.com/contact?email=a@b.com"),
                       "https://example.com/contact?email=a@b.com")
        XCTAssertEqual(normalizedLinkURL("example.com#a@b.com"), "https://example.com#a@b.com")
    }

    func testUserinfoAndPathsAreNotAddresses() {
        for dest in ["user:pass@example.com",   // userinfo, not an address
                     "user@example.com/path",   // userinfo with a path
                     "contacts/john@acme.com"   // a file in the vault
        ] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testMalformedHostsAreKept() {
        for dest in ["-example.com", "example-.com", "999.999.999.999",
                     "example.com:0", "1.2.3.4:65536", "[::1]:8080"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testNewlineInTheFieldNeverReachesTheDestination() {
        XCTAssertEqual(linkDestination(typed: "https://a\nb", existing: ""), "https://ab")
        XCTAssertEqual(linkDestination(typed: "example.com\n", existing: ""),
                       "https://example.com")
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

/// The background probe behind the ⌘K dialog's local/web decision.
final class LocalDestinationCacheTests: XCTestCase {

    private func makeVault() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("editmd-linkedit-\(UUID().uuidString)")
        // A folder whose name ends in a real TLD is the whole point of the probe.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("docs.dev"), withIntermediateDirectories: true)
        try "# Intro".write(to: dir.appendingPathComponent("docs.dev/intro.md"),
                           atomically: true, encoding: .utf8)
        try "# Home".write(to: dir.appendingPathComponent("home.md"),
                           atomically: true, encoding: .utf8)
        return dir
    }

    /// The answer lands asynchronously — poll rather than sleep a fixed spell.
    private func awaitAnswer(_ cache: LocalDestinationCache,
                             for destination: String) throws -> Bool {
        for _ in 0..<200 {
            if let answer = cache.answer(for: destination) { return answer }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw XCTSkip("probe did not answer in 2s")
    }

    func testResolvesAnExistingFileInATLDLookingFolder() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          vaultRoot: vault)

        cache.prefetch("docs.dev/intro.md")
        XCTAssertTrue(try awaitAnswer(cache, for: "docs.dev/intro.md"))
        // …and the same destination now decides the normalizer against completing.
        XCTAssertEqual(normalizedLinkURL("docs.dev/intro.md",
                                         localFileExists: { cache.answer(for: $0) }),
                       "docs.dev/intro.md")
    }

    func testReportsAMissingFileAsMissing() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          vaultRoot: vault)

        cache.prefetch("archive.org/note.md")
        XCTAssertFalse(try awaitAnswer(cache, for: "archive.org/note.md"))
        XCTAssertEqual(normalizedLinkURL("archive.org/note.md",
                                         localFileExists: { cache.answer(for: $0) }),
                       "https://archive.org/note.md")
    }

    func testAnchorIsIgnoredWhenResolving() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          vaultRoot: vault)

        cache.prefetch("docs.dev/intro.md#setup")
        XCTAssertTrue(try awaitAnswer(cache, for: "docs.dev/intro.md#setup"))
    }

    func testUnknownUntilAnswered() {
        let cache = LocalDestinationCache(fileURL: nil, vaultRoot: nil)
        cache.prefetch("docs.dev/intro.md")
        // No document to resolve against: the answer stays unknown, and unknown
        // leaves the destination alone.
        XCTAssertNil(cache.answer(for: "docs.dev/intro.md"))
        XCTAssertEqual(normalizedLinkURL("docs.dev/intro.md",
                                         localFileExists: { cache.answer(for: $0) }),
                       "docs.dev/intro.md")
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

/// Name prompts must never let a pasted newline into a path component.
final class OneLineNameTests: XCTestCase {

    func testNewlinesBecomeSpaces() {
        XCTAssertEqual(oneLineName("My\nNote"), "My Note")
        XCTAssertEqual(oneLineName("  spaced \n"), "spaced")
        XCTAssertEqual(oneLineName("a\r\nb"), "a b")
    }

    func testPlainNamePassesThrough() {
        XCTAssertEqual(oneLineName("Untitled.md"), "Untitled.md")
    }
}
