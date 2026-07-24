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
            "editmd://new?file=A&clipboard&append=true&silent=true&content=hi&x=1")
        XCTAssertEqual(clip?.name, "A")
        XCTAssertEqual(clip?.usesClipboard, true)
        XCTAssertNil(clip?.requestedWorkspace)
    }

    /// `workspace=` names an adopted workspace (Obsidian's `vault=`).
    func testParsesWorkspaceName() {
        XCTAssertEqual(
            clip("editmd://new?file=A&clipboard&workspace=test%20md")?.requestedWorkspace,
            "test md")
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

    /// Every state a launch can be in when `applicationDidFinishLaunching`
    /// runs. Openings are driven through `openUntitled` on purpose: it applies
    /// the very same `.created` override as a clip, but does not route a URL
    /// through `WorkspaceModel.shared`, which runs on `.standard` defaults and
    /// would rewrite the developer's remembered branch from a test.
    @MainActor
    private func makeAppState(
        mode: EditorMode = .source,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (AppState, UserDefaults) {
        let suiteName = "url-scheme-mode-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName), file: file, line: line)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        // Whatever the previous session was left in.
        defaults.set(mode.rawValue, forKey: "editorMode")
        return (AppState(defaults: defaults), defaults)
    }

    /// Nothing claimed the mode: the ordinary cold launch, read-first Preview.
    @MainActor
    func testColdLaunchResetsToPreviewWithoutAClaim() throws {
        let (appState, defaults) = try makeAppState()

        appState.applyColdLaunchEditorMode()

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.preview.rawValue)
    }

    /// A launch caused by `editmd://new` delivers the open BEFORE
    /// `applicationDidFinishLaunching`, so the reset must leave the created
    /// file's write-first Visual mode alone.
    @MainActor
    func testAppliedModeSurvivesColdLaunchReset() throws {
        let (appState, defaults) = try makeAppState()

        appState.openUntitled()
        appState.applyColdLaunchEditorMode()

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.visual.rawValue)
    }

    /// A clip writes on a background task. Until the file exists the mode is
    /// only reserved — `editorMode` is global, so switching it early would drag
    /// the document the user is reading into Visual mid-write.
    @MainActor
    func testReservationDoesNotTouchTheModeUntilTheFileLands() throws {
        let (appState, defaults) = try makeAppState()

        appState.reserveEditorModeForCreate()
        appState.applyColdLaunchEditorMode()
        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.source.rawValue,
                       "a pending create must not change the mode of the open document")

        appState.openUntitled()          // the write landed
        appState.endEditorModeReservation()

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.visual.rawValue)
    }

    /// The write failed: the mode the user was in stays, and a cold launch that
    /// stood aside for the reservation still ends in Preview.
    @MainActor
    func testFailedCreateReplaysTheColdLaunchReset() throws {
        let (appState, defaults) = try makeAppState()

        appState.reserveEditorModeForCreate()
        appState.applyColdLaunchEditorMode()
        appState.endEditorModeReservation()

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.preview.rawValue)
    }

    /// Same failure with the app already running: no cold-launch reset was
    /// deferred, so nothing may be rewritten behind the user's back.
    @MainActor
    func testFailedCreateLeavesARunningSessionAlone() throws {
        let (appState, defaults) = try makeAppState()

        appState.reserveEditorModeForCreate()
        appState.endEditorModeReservation()

        XCTAssertEqual(defaults.string(forKey: "editorMode"), EditorMode.source.rawValue)
    }

    // MARK: - Destination

    private let vault = URL(fileURLWithPath: "/tmp/URLCommandTests/Vault", isDirectory: true)
    private let other = URL(fileURLWithPath: "/tmp/URLCommandTests/Other", isDirectory: true)
    private let inbox = URL(fileURLWithPath: "/tmp/URLCommandTests/Inbox", isDirectory: true)

    /// Every folder in these tests exists unless a case says otherwise.
    private func destination(
        requestedWorkspace: String? = nil,
        mode: ClipDestinationMode = .folder
    ) -> ClipDestination {
        ClipDestination(
            requestedWorkspace: requestedWorkspace,
            mode: mode,
            configuredFolder: inbox,
            workspaces: [
                .init(name: "test md", root: vault),
                .init(name: "Other", root: other),
            ],
            activeWorkspaceRoot: other)
    }

    /// The setting decides when the URL says nothing.
    func testConfiguredModeDecidesWithoutAWorkspaceParam() {
        XCTAssertEqual(
            destination(mode: .folder).resolvedFolder(isExistingFolder: { _ in true }),
            inbox)
        XCTAssertEqual(
            destination(mode: .activeWorkspace).resolvedFolder(isExistingFolder: { _ in true }),
            other)
    }

    /// A named workspace wins over the setting — in both modes.
    func testNamedWorkspaceWinsAndIsCaseInsensitive() {
        for mode in ClipDestinationMode.allCases {
            XCTAssertEqual(
                destination(requestedWorkspace: "test md", mode: mode)
                    .resolvedFolder(isExistingFolder: { _ in true }),
                vault)
            XCTAssertEqual(
                destination(requestedWorkspace: "  TEST MD ", mode: mode)
                    .resolvedFolder(isExistingFolder: { _ in true }),
                vault)
        }
    }

    /// An unknown name must not fail and must not invent a location: the clip
    /// lands in the configured folder.
    func testUnknownWorkspaceNameFallsBackToTheSetting() {
        XCTAssertEqual(
            destination(requestedWorkspace: "Nope").resolvedFolder(isExistingFolder: { _ in true }),
            inbox)
        XCTAssertEqual(
            destination(requestedWorkspace: "").resolvedFolder(isExistingFolder: { _ in true }),
            inbox)
    }

    /// A path is not a name — the parameter can only pick among adopted roots,
    /// so an absolute path from a web page resolves to nothing.
    func testWorkspaceParamCannotCarryAPath() {
        XCTAssertEqual(
            destination(requestedWorkspace: "/etc")
                .resolvedFolder(isExistingFolder: { _ in true }),
            inbox)
        XCTAssertEqual(
            destination(requestedWorkspace: "../Other")
                .resolvedFolder(isExistingFolder: { _ in true }),
            inbox)
    }

    /// A vault that is gone from disk must not be recreated by a clip.
    func testMissingFolderFallsBackToTheConfiguredOne() {
        let exists: (URL) -> Bool = { $0 != self.vault && $0 != self.other }
        XCTAssertEqual(
            destination(requestedWorkspace: "test md").resolvedFolder(isExistingFolder: exists),
            inbox)
        XCTAssertEqual(
            destination(mode: .activeWorkspace).resolvedFolder(isExistingFolder: exists),
            inbox)
    }

    /// Nothing adopted at all: still a valid destination.
    func testNoWorkspacesAtAll() {
        let empty = ClipDestination(
            requestedWorkspace: "test md",
            mode: .activeWorkspace,
            configuredFolder: inbox)
        XCTAssertEqual(empty.resolvedFolder(isExistingFolder: { _ in true }), inbox)
    }

    /// Settings path → folder: empty means the default, `~` is expanded.
    func testConfiguredFolderFromSettingsPath() {
        XCTAssertEqual(
            ClipDestination.configuredFolder(forSettingsPath: "").lastPathComponent,
            "EditMD Clips")
        XCTAssertEqual(
            ClipDestination.configuredFolder(forSettingsPath: "   ").lastPathComponent,
            "EditMD Clips")
        XCTAssertEqual(
            ClipDestination.configuredFolder(forSettingsPath: "~/Notes/Inbox").path,
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Notes/Inbox").standardizedFileURL.path)
        XCTAssertEqual(
            ClipDestination.configuredFolder(forSettingsPath: "/tmp/Clips").path,
            "/tmp/Clips")
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
