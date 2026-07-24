import XCTest
@testable import EditMD

/// `editmd://` scheme: parsing, name sanitizing, uniquifying, writing.
/// Everything here is pure Foundation — no app, no AppKit.
final class URLCommandTests: XCTestCase {

    private func parse(_ string: String) -> EditMDURLCommand? {
        guard let url = URL(string: string) else {
            XCTFail("not a URL: \(string)")
            return nil
        }
        return EditMDURLCommand.parse(url)
    }

    private func clip(_ string: String) -> EditMDURLCommand.NewClip? {
        guard case .newClip(let clip)? = parse(string) else { return nil }
        return clip
    }

    // MARK: - Parsing

    /// The contract the shipped webtodotmd extension emits.
    func testParsesClipperURL() {
        let clip = clip("editmd://new?file=Test%20Clip&clipboard")
        XCTAssertEqual(clip?.name, "Test Clip")
        XCTAssertEqual(clip?.usesClipboard, true)
    }

    func testParsesAuthoritylessSpellings() {
        XCTAssertEqual(clip("editmd:new?file=A&clipboard")?.name, "A")
        XCTAssertEqual(clip("editmd:///new?file=A&clipboard")?.name, "A")
        XCTAssertEqual(clip("EDITMD://NEW?file=A")?.name, "A")
    }

    func testUnknownCommandAndSchemeAreIgnored() {
        XCTAssertNil(parse("editmd://append?file=A&clipboard"))
        XCTAssertNil(parse("editmd://"))
        XCTAssertNil(parse("obsidian://new?file=A&clipboard"))
        XCTAssertNil(parse("file:///tmp/a.md"))
    }

    /// Reserved parameters may already arrive from a sender; v1 ignores them
    /// instead of failing the whole command.
    func testReservedParametersAreIgnored() {
        let clip = clip(
            "editmd://new?file=A&clipboard&append=true&silent=true&workspace=Vault&content=hi&x=1")
        XCTAssertEqual(clip?.name, "A")
        XCTAssertEqual(clip?.usesClipboard, true)
    }

    /// `content=` is a reserved carrier, not a body source yet — without the
    /// clipboard flag the clip is empty.
    func testContentAloneDoesNotSetClipboardFlag() {
        XCTAssertEqual(clip("editmd://new?file=A&content=%23%20hi")?.usesClipboard, false)
    }

    func testClipboardFlagForms() {
        XCTAssertEqual(clip("editmd://new?file=A&clipboard")?.usesClipboard, true)
        XCTAssertEqual(clip("editmd://new?file=A&clipboard=")?.usesClipboard, true)
        XCTAssertEqual(clip("editmd://new?file=A&clipboard=true")?.usesClipboard, true)
        XCTAssertEqual(clip("editmd://new?file=A&clipboard=1")?.usesClipboard, true)
        XCTAssertEqual(clip("editmd://new?file=A&clipboard=false")?.usesClipboard, false)
        XCTAssertEqual(clip("editmd://new?file=A")?.usesClipboard, false)
    }

    func testMissingOrEmptyFileFallsBackToClip() {
        XCTAssertEqual(clip("editmd://new?clipboard")?.name, "Clip")
        XCTAssertEqual(clip("editmd://new?file=&clipboard")?.name, "Clip")
        XCTAssertEqual(clip("editmd://new?file=%20%20&clipboard")?.name, "Clip")
    }

    // MARK: - Name sanitizing

    func testSanitizerStripsPathSeparators() {
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("../../etc/passwd"), "etcpasswd")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("a/b\\c:d"), "abcd")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName(".."), "Clip")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("/"), "Clip")
    }

    /// A dot-prefixed name would be skipped by every listing in the sidebar.
    func testSanitizerStripsLeadingDots() {
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName(".hidden"), "hidden")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("...hidden"), "hidden")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName(" . .hidden"), "hidden")
    }

    func testSanitizerNormalizesControlCharactersAndWhitespace() {
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("a\nb\tc"), "a b c")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("a\u{0}b"), "a b")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("  spaced   out  "), "spaced out")
    }

    /// Senders are supposed to omit the extension; a sloppy one must not
    /// produce `Note.md.md`.
    func testSanitizerDropsMarkdownExtension() {
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("Note.md"), "Note")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("Note.MARKDOWN"), "Note")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("Note.txt"), "Note.txt")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName("v1.2"), "v1.2")
    }

    func testSanitizerCapsLength() {
        let long = String(repeating: "a", count: 300)
        XCTAssertEqual(
            ClipFileNaming.sanitizedBaseName(long).count,
            ClipFileNaming.maxBaseNameCharacters)
        // Cyrillic is two UTF-8 bytes per character: the byte cap bites first.
        let cyrillic = String(repeating: "я", count: 300)
        let capped = ClipFileNaming.sanitizedBaseName(cyrillic)
        XCTAssertLessThanOrEqual(capped.utf8.count, ClipFileNaming.maxBaseNameBytes)
        XCTAssertEqual(capped.count, ClipFileNaming.maxBaseNameBytes / 2)
        // A truncation must not leave a trailing space or dot behind.
        let padded = String(repeating: "a", count: 99) + " tail"
        XCTAssertFalse(ClipFileNaming.sanitizedBaseName(padded).hasSuffix(" "))
    }

    func testSanitizerKeepsOrdinaryTitles() {
        XCTAssertEqual(
            ClipFileNaming.sanitizedBaseName("Как работает TextKit — заметка"),
            "Как работает TextKit — заметка")
        XCTAssertEqual(ClipFileNaming.sanitizedBaseName(nil), "Clip")
    }

    // MARK: - Uniquifying

    func testCandidateFileNames() {
        XCTAssertEqual(ClipFileNaming.candidateFileName(base: "Note", attempt: 1), "Note.md")
        XCTAssertEqual(ClipFileNaming.candidateFileName(base: "Note", attempt: 2), "Note 2.md")
        XCTAssertEqual(ClipFileNaming.candidateFileName(base: "Note", attempt: 17), "Note 17.md")
    }

    // MARK: - Writing

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("URLCommandTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    func testWriteCreatesFolderAndFileVerbatim() throws {
        let folder = try makeTemporaryFolder()
        let body = "# Clip\n\nтело \u{1F600}\n"
        let url = try ClipFile.write(body, baseName: "Test Clip", in: folder)
        XCTAssertEqual(url.lastPathComponent, "Test Clip.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), body)
    }

    func testWriteUniquifiesAndNeverOverwrites() throws {
        let folder = try makeTemporaryFolder()
        let first = try ClipFile.write("one", baseName: "Note", in: folder)
        let second = try ClipFile.write("two", baseName: "Note", in: folder)
        let third = try ClipFile.write("three", baseName: "Note", in: folder)
        XCTAssertEqual(first.lastPathComponent, "Note.md")
        XCTAssertEqual(second.lastPathComponent, "Note 2.md")
        XCTAssertEqual(third.lastPathComponent, "Note 3.md")
        // The original body survived untouched.
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
    }

    func testWriteAcceptsEmptyBody() throws {
        let folder = try makeTemporaryFolder()
        let url = try ClipFile.write("", baseName: "Empty", in: folder)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "")
    }

    // MARK: - Cold-launch ordering

    /// A launch caused by `editmd://new` delivers the open BEFORE
    /// `applicationDidFinishLaunching`, so the cold-launch reset must leave the
    /// clip's write-first Visual mode alone (it clobbered it back to Preview
    /// until the reset became conditional). This is the whole sequence the
    /// AppDelegate runs, in the order it runs it.
    @MainActor
    func testCreatedOpenSurvivesColdLaunchReset() throws {
        let suiteName = "url-scheme-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(defaults: defaults)
        XCTAssertFalse(appState.didApplyEditorModeOverride)

        // 1. The create arrives first and claims Visual. Driven through
        //    `openUntitled` on purpose: it applies the very same `.created`
        //    override as the clip, but does not route a URL through
        //    `WorkspaceModel.shared`, which runs on `.standard` defaults and
        //    would rewrite the developer's remembered branch from a test.
        appState.openUntitled()
        XCTAssertTrue(appState.didApplyEditorModeOverride)
        // 2. applicationDidFinishLaunching runs afterwards and must not reset.
        resetEditorModeForColdLaunch(
            defaults, modeAlreadyChosen: appState.didApplyEditorModeOverride)

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.visual.rawValue)
    }

    /// Without an open first, the same launch sequence still lands on Preview —
    /// the gate must not disable the reset outright.
    @MainActor
    func testColdLaunchResetStillAppliesWithoutAnOpen() throws {
        let suiteName = "url-scheme-mode-plain-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(EditorMode.source.rawValue, forKey: "editorMode")

        resetEditorModeForColdLaunch(defaults, modeAlreadyChosen: false)

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.preview.rawValue)
    }

    // MARK: - Destination fallback

    /// The active workspace root wins only while it is a real folder — a
    /// vault that vanished from disk must not be recreated by a clip.
    @MainActor
    func testDestinationFallsBackWhenWorkspaceRootIsGone() throws {
        let suiteName = "clips-dest-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        let existing = try makeTemporaryFolder()
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

        XCTAssertEqual(
            AppState.clipDestinationFolder(
                activeWorkspaceRoot: existing, defaults: defaults).path,
            existing.standardizedFileURL.path)
        XCTAssertEqual(
            AppState.clipDestinationFolder(
                activeWorkspaceRoot: existing.appendingPathComponent("gone"),
                defaults: defaults
            ).lastPathComponent,
            "EditMD Clips")
        XCTAssertEqual(
            AppState.clipDestinationFolder(
                activeWorkspaceRoot: nil, defaults: defaults).lastPathComponent,
            "EditMD Clips")
    }

    /// With no workspace adopted a clip lands in `~/Documents/EditMD Clips`,
    /// or wherever `clips.folder` points.
    @MainActor
    func testClipsFallbackFolder() throws {
        let suiteName = "clips-folder-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            AppState.clipsFallbackFolder(defaults: defaults).lastPathComponent,
            "EditMD Clips")

        defaults.set("~/Notes/Inbox", forKey: "clips.folder")
        XCTAssertEqual(
            AppState.clipsFallbackFolder(defaults: defaults).path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Notes/Inbox").standardizedFileURL.path)

        // A blank override is not a location — fall back to the default.
        defaults.set("   ", forKey: "clips.folder")
        XCTAssertEqual(
            AppState.clipsFallbackFolder(defaults: defaults).lastPathComponent,
            "EditMD Clips")
    }

    // MARK: - Body cap

    func testBodyCapTruncatesOnCharacterBoundary() {
        XCTAssertEqual(ClipFile.cappedBody("abc", maxBytes: 10), "abc")
        // "я" is two bytes: an odd cap must not split it.
        let cyrillic = String(repeating: "я", count: 10)
        let capped = ClipFile.cappedBody(cyrillic, maxBytes: 5)
        XCTAssertEqual(capped, "яя")
        XCTAssertEqual(ClipFile.cappedBody(cyrillic, maxBytes: 20), cyrillic)
    }
}
