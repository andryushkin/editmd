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

    func testMissingFileAndMissingFolderIsCompleted() {
        // Neither the file nor its folder is here → the host wins, which is what
        // the TLD says it is.
        XCTAssertEqual(normalizedLinkURL("archive.org/note.md", localFileExists: { _ in false }),
                       "https://archive.org/note.md")
        XCTAssertEqual(normalizedLinkURL("docs.dev/intro.md", localFileExists: { _ in false }),
                       "https://docs.dev/intro.md")
        XCTAssertEqual(normalizedLinkURL("example.com/img.png", localFileExists: { _ in false }),
                       "https://example.com/img.png")
    }

    func testForwardLinkIntoAnExistingFolderStaysLocal() {
        // The everyday vault move: write the link, create the note after. The
        // folder is here, the note is not — and that must not become a URL.
        let folderOnly: (String) -> Bool? = { $0 == "projects.dev" }
        XCTAssertEqual(normalizedLinkURL("projects.dev/plan.md", localFileExists: folderOnly),
                       "projects.dev/plan.md")
        XCTAssertEqual(normalizedLinkURL("projects.dev/2026/plan.md",
                                         localFileExists: { $0 == "projects.dev/2026" }),
                       "projects.dev/2026/plan.md")
    }

    func testABareNoteNameNeverNeedsAFolder() {
        // No folder to check: a plain name is local whatever the probe says.
        for answer: Bool? in [true, false, nil] {
            XCTAssertEqual(normalizedLinkURL("plan.md", localFileExists: { _ in answer }),
                           "plan.md")
        }
    }

    func testAFileNamedLikeAnAddressWinsOverMailto() {
        XCTAssertEqual(normalizedLinkURL("user@example.com", localFileExists: { _ in true }),
                       "user@example.com")
        XCTAssertEqual(normalizedLinkURL("user@example.com", localFileExists: { _ in false }),
                       "mailto:user@example.com")
    }

    func testMissingFileStillStaysLocalWithoutAPlausibleHost() {
        // Linking a note before creating it is normal, and `md`/`areas` are not
        // completable TLDs — a missing file must not turn these into URLs.
        for dest in ["notes.md", "2.Areas/note.md", "assets.old/img.png", "v1.x/spec.md"] {
            XCTAssertEqual(normalizedLinkURL(dest, localFileExists: { _ in false }), dest)
        }
    }

    func testEvenABareHostYieldsToAFileOfThatName() {
        // `example.com` on disk is a path; without it, the host reading stands.
        XCTAssertEqual(normalizedLinkURL("example.com", localFileExists: { _ in true }),
                       "example.com")
        XCTAssertEqual(normalizedLinkURL("example.com", localFileExists: { _ in false }),
                       "https://example.com")
        XCTAssertEqual(normalizedLinkURL("example.com", localFileExists: { _ in nil }),
                       "https://example.com")
    }

    func testAnchorsAreNeverArbitrated() {
        for exists in [true, false] {
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

    // MARK: - localProbeKey

    func testProbeIsSkippedWhereNothingIsArbitrated() {
        // Nothing here has a local reading, so no key — and therefore no probe,
        // no detached task, and no stat while the user types.
        for dest in ["https://example.com/a/b", "http://example.com/x.md",
                     "mailto:a@b.io", "user@example.com/path", "#top", "/abs/path",
                     "./sibling.md", "../up.md", "notes", "docs.dev?next=/guide",
                     "192.168.1.5:8080", "localhost:3000"] {
            XCTAssertNil(localProbeKey(for: dest), dest)
        }
    }

    func testDottedBareNameIsAskedAbout() {
        // `Makefile.am` and `example.com` are the same shape; only the file
        // system tells them apart, so both get a key.
        XCTAssertEqual(localProbeKey(for: "Makefile.am"), "Makefile.am")
        XCTAssertEqual(localProbeKey(for: "example.com"), "example.com")
    }

    func testFileWhoseExtensionIsATLDStaysLocalWhenItExists() {
        for dest in ["Makefile.am", "main.cc", "logo.ai", "settings.pro", "Notes.app"] {
            XCTAssertEqual(normalizedLinkURL(dest, localFileExists: { _ in true }), dest)
        }
    }

    func testExtensionsThatCollideWithTLDsAreNotCompletedBlind() {
        // Even with no answer at all, the ones a repo is full of stay local
        // because their extension is not a completable TLD.
        for dest in ["Makefile.am", "main.cc", "config.h.in", "settings.pro"] {
            XCTAssertEqual(normalizedLinkURL(dest, localFileExists: { _ in nil }), dest)
        }
    }

    func testProbeKeyIsThePathAlone() {
        XCTAssertEqual(localProbeKey(for: "docs.dev/intro.md#setup"), "docs.dev/intro.md")
        XCTAssertEqual(localProbeKey(for: "docs.dev/intro.md?plain=1"), "docs.dev/intro.md")
        XCTAssertEqual(localProbeKey(for: " notes.md\n"), "notes.md")
        XCTAssertEqual(localProbeKey(for: "docs.io/guide"), "docs.io/guide")
    }

    func testSlashInsideAQueryIsNotAPath() {
        // A `/` in the query must not make this a local path: with `docs.dev`
        // itself on disk, an arbitration keyed on the path alone would answer
        // "exists" and leave the page unlinked.
        XCTAssertEqual(normalizedLinkURL("docs.dev?next=/guide", localFileExists: { _ in true }),
                       "https://docs.dev?next=/guide")
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
                     "example.com:0", "1.2.3.4:65536", "[::1]:8080",
                     "example:+80", "host:0080"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testAddressAtAMalformedHostIsKept() {
        // The address branch owes the same host test as the web branch.
        for dest in ["user@-example.com", "user@example-.com", "user@exam_ple.com"] {
            XCTAssertEqual(normalizedLinkURL(dest), dest)
        }
    }

    func testControlCharactersNeverReachTheDestination() {
        XCTAssertEqual(linkDestination(typed: "https://a\nb", existing: ""), "https://ab")
        XCTAssertEqual(linkDestination(typed: "https://x.com/a\tb", existing: ""),
                       "https://x.com/ab")
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

    func testRawLabelKeepsItsMarkers() {
        // What the dialog shows is the rendered text; what goes back when the
        // user does not touch it is the source.
        let m = inlineLinkMatch(in: "see [**bold** and `code`](notes.md) now", at: 10)
        // `plainText` drops emphasis markers but keeps the code span's backticks —
        // whatever it renders, the label put back is the source.
        XCTAssertEqual(m?.text, "bold and `code`")
        XCTAssertEqual(m?.rawLabel, "**bold** and `code`")
        XCTAssertEqual(markdownLinkSyntax(rawLabel: m!.rawLabel, url: "notes.md"),
                       "[**bold** and `code`](notes.md)")
    }

    func testRawLabelOfAPlainLinkIsItsText() {
        let m = inlineLinkMatch(in: "[Example](https://example.com)", at: 3)
        XCTAssertEqual(m?.rawLabel, "Example")
    }

    func testRawLabelIsNotEscapedTwice() {
        // The label came from the source, so its escapes are already right.
        let m = inlineLinkMatch(in: #"[a\[b](x.md)"#, at: 3)
        XCTAssertEqual(m?.rawLabel, #"a\[b"#)
        XCTAssertEqual(markdownLinkSyntax(rawLabel: m!.rawLabel, url: "x.md"), #"[a\[b](x.md)"#)
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
    /// A probe that never answers is a failure, not a skip: an unanswered probe
    /// is exactly the regression these tests exist to catch.
    private func awaitAnswer(_ cache: LocalDestinationCache,
                             for destination: String) throws -> Bool {
        for _ in 0..<500 {
            if let answer = cache.answer(for: destination) { return answer }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("the probe never answered for \(destination)")
        return false
    }

    func testResolvesAnExistingFileInATLDLookingFolder() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          adoptedRoot: vault)

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
                                          adoptedRoot: vault)

        cache.prefetch("archive.org/note.md")
        XCTAssertFalse(try awaitAnswer(cache, for: "archive.org/note.md"))
        XCTAssertEqual(normalizedLinkURL("archive.org/note.md",
                                         localFileExists: { cache.answer(for: $0) }),
                       "https://archive.org/note.md")
    }

    func testQueryIsIgnoredWhenResolving() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          adoptedRoot: vault)

        cache.prefetch("docs.dev/intro.md?plain=1")
        XCTAssertTrue(try awaitAnswer(cache, for: "docs.dev/intro.md?plain=1"))
        XCTAssertEqual(normalizedLinkURL("docs.dev/intro.md?plain=1",
                                         localFileExists: { cache.answer(for: $0) }),
                       "docs.dev/intro.md?plain=1")
    }

    func testExtensionlessPathIsResolvedToo() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        try FileManager.default.createDirectory(
            at: vault.appendingPathComponent("docs.io/guide"), withIntermediateDirectories: true)
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          adoptedRoot: vault)

        cache.prefetch("docs.io/guide")
        XCTAssertTrue(try awaitAnswer(cache, for: "docs.io/guide"))
        // An Obsidian-style extensionless link must survive the completer.
        XCTAssertEqual(normalizedLinkURL("docs.io/guide",
                                         localFileExists: { cache.answer(for: $0) }),
                       "docs.io/guide")
        // …while the same shape with nothing on disk is a web page.
        XCTAssertEqual(normalizedLinkURL("docs.io/guide", localFileExists: { _ in false }),
                       "https://docs.io/guide")
    }

    func testUnansweredProbeDoesNotBlockAnOrdinaryWebLink() {
        // Unknown protects a vault-file tail, not every path: a plain page must
        // still complete while the probe is still thinking.
        XCTAssertEqual(normalizedLinkURL("example.com/docs/guide", localFileExists: { _ in nil }),
                       "https://example.com/docs/guide")
    }

    func testAnchorIsIgnoredWhenResolving() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          adoptedRoot: vault)

        cache.prefetch("docs.dev/intro.md#setup")
        XCTAssertTrue(try awaitAnswer(cache, for: "docs.dev/intro.md#setup"))
    }

    func testAFullTableEvictsTheOldestAndKeepsTheNewest() throws {
        let vault = try makeVault()
        defer { try? FileManager.default.removeItem(at: vault) }
        let cache = LocalDestinationCache(fileURL: vault.appendingPathComponent("home.md"),
                                          adoptedRoot: vault)

        // Awaited one at a time, so arrival order — and therefore what is evicted
        // — is decided by the test rather than by which detached probe finishes
        // first. 70 arrivals past a table of 64.
        for i in 0..<70 {
            cache.prefetch("docs.dev/note-\(i).md")
            XCTAssertFalse(try awaitAnswer(cache, for: "docs.dev/note-\(i).md"))
        }
        // The newest answer is the one a dialog is about to read, and it survives
        // the arrivals before it — which a wipe-on-full table would have dropped.
        XCTAssertNotNil(cache.answer(for: "docs.dev/note-69.md"))
        // The oldest is gone — evicted one at a time, never wiped as a table.
        XCTAssertNil(cache.answer(for: "docs.dev/note-0.md"))
    }

    func testUnknownUntilAnswered() {
        let cache = LocalDestinationCache(fileURL: nil, adoptedRoot: nil)
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
