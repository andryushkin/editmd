import XCTest
import Testing
@testable import EditMD

/// Folder scan filtering, hide/unhide, per-path persistence, pinning,
/// and loose-file bookkeeping. Persistence uses an injected UserDefaults suite
/// so tests stay isolated from the real store.
@MainActor
final class WorkspaceModelTests: XCTestCase {

    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a.md, b.md, note.txt (excluded), sub.textbundle (a package = included)
        try "a".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "t".write(to: dir.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("sub.textbundle"), withIntermediateDirectories: true)

        suiteName = "wstest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    /// Parent folders on disk, no file written — nothing below reads content.
    private func makeFilePath(_ relativePath: String) throws -> URL {
        let file = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return file.standardizedFileURL
    }

    func testScanFiltersToMarkdownAndSorts() {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.primeFolderListing(dir)   // listings fill async in the app
        XCTAssertEqual(names(model.visibleFiles(model.workspaces[0])),
                       ["a.md", "b.md", "sub.textbundle"])   // note.txt excluded, sorted
    }

    func testScanListsPDFsAlongsideMarkdown() throws {
        try Data("%PDF-1.4".utf8).write(to: dir.appendingPathComponent("paper.pdf"))
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.primeFolderListing(dir)
        XCTAssertEqual(names(model.visibleFiles(model.workspaces[0])),
                       ["a.md", "b.md", "paper.pdf", "sub.textbundle"])
    }

    func testScanListsSupportedImagesAlongsideMarkdown() throws {
        try Data().write(to: dir.appendingPathComponent("cover.SVG"))
        try Data().write(to: dir.appendingPathComponent("photo.jpg"))
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.primeFolderListing(dir)
        XCTAssertEqual(names(model.visibleFiles(model.workspaces[0])),
                       ["a.md", "b.md", "cover.SVG", "photo.jpg", "sub.textbundle"])
    }

    func testHideUnhide() {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.primeFolderListing(dir)
        let ws = model.workspaces[0]
        let a = dir.appendingPathComponent("a.md")

        model.hide(a, in: ws)
        XCTAssertEqual(names(model.visibleFiles(ws)), ["b.md", "sub.textbundle"])
        XCTAssertEqual(names(model.hiddenFilesList(ws)), ["a.md"])
        XCTAssertEqual(model.totalHiddenCount, 1)
        XCTAssertEqual(model.hiddenFiles[ws.folderPath], ["a.md"])

        model.unhide(a, in: ws)
        XCTAssertEqual(names(model.visibleFiles(ws)), ["a.md", "b.md", "sub.textbundle"])
        XCTAssertEqual(model.totalHiddenCount, 0)
    }

    func testHideNestedRelativePath() throws {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let deep = nested.appendingPathComponent("deep.md")
        try "x".write(to: deep, atomically: true, encoding: .utf8)
        model.primeFolderListing(nested)

        XCTAssertEqual(model.relativePath(of: deep, in: model.workspaces[0]), "nested/deep.md")
        model.hide(deep)
        XCTAssertTrue(model.isHidden(deep))
        XCTAssertEqual(names(model.visibleMarkdown(in: nested)), [])
        XCTAssertEqual(names(model.hiddenMarkdown(in: nested)), ["deep.md"])
        XCTAssertEqual(model.hiddenFiles[model.workspaces[0].folderPath], ["nested/deep.md"])
        XCTAssertEqual(model.totalHiddenCount, 1)

        model.unhide(deep)
        XCTAssertFalse(model.isHidden(deep))
        XCTAssertEqual(names(model.visibleMarkdown(in: nested)), ["deep.md"])
    }

    func testWorkspaceOwningLongestPrefix() throws {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        let nested = dir.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let deep = nested.appendingPathComponent("deep.md")
        try "x".write(to: deep, atomically: true, encoding: .utf8)

        XCTAssertEqual(model.workspaceOwning(deep)?.folderPath, dir.standardizedFileURL.path)
        // File only in parent-of-workspace is not owned.
        XCTAssertNil(model.workspaceOwning(dir.deletingLastPathComponent()))
    }

    func testHiddenPersistsAcrossInstances() {
        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.hide(dir.appendingPathComponent("a.md"), in: m1.workspaces[0])

        let m2 = WorkspaceModel(defaults: defaults)   // reloads from the same suite
        m2.primeFolderListing(dir)
        XCTAssertEqual(m2.workspaces.map(\.folderPath), [dir.standardizedFileURL.path])
        XCTAssertEqual(m2.hiddenFiles[dir.standardizedFileURL.path], ["a.md"])
        XCTAssertEqual(names(m2.visibleFiles(m2.workspaces[0])), ["b.md", "sub.textbundle"])
    }

    func testPinnedLooseFilesPersistAndOrderFirst() {
        let m1 = WorkspaceModel(defaults: defaults)
        let spec = URL(fileURLWithPath: "/tmp/spec.md")
        let draft = URL(fileURLWithPath: "/tmp/draft.md")
        m1.noteOpened(draft)   // session loose
        m1.pin(spec)           // pinned (persisted)

        XCTAssertTrue(m1.isPinned(spec))
        // Pinned first, then session loose.
        XCTAssertEqual(names(m1.looseFilesToShow), ["spec.md", "draft.md"])

        let m2 = WorkspaceModel(defaults: defaults)
        XCTAssertTrue(m2.isPinned(spec))          // pin persisted
        XCTAssertFalse(m2.looseFilesToShow.contains(draft))  // session file did not
    }

    func testWorkspaceFavoritesPersistAndMissingClickRemoves() throws {
        let favorite = dir.appendingPathComponent("a.md")
        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.addFavorite(favorite)

        let m2 = WorkspaceModel(defaults: defaults)
        XCTAssertEqual(m2.favoriteFiles, [favorite.standardizedFileURL])
        XCTAssertTrue(m2.isFavorite(favorite))

        try FileManager.default.removeItem(at: favorite)
        XCTAssertNil(m2.favoriteOpenTarget(favorite))
        XCTAssertFalse(m2.isFavorite(favorite))
        XCTAssertTrue(m2.favoriteFiles.isEmpty)
    }

    func testWorkspaceFavoritesAreLimitedToFiftyPerRoot() throws {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        for index in 0..<51 {
            model.addFavorite(dir.appendingPathComponent("\(index).md"))
        }
        XCTAssertEqual(model.favoriteFiles.count, 50)
    }

    func testSubfoldersListsChildDirsSkippingHidden() throws {
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let model = WorkspaceModel(defaults: defaults)
        let subs = names(model.subfolders(in: dir))
        XCTAssertTrue(subs.contains("notes"))
        XCTAssertFalse(subs.contains(".git"))   // hidden folder skipped
    }

    func testExpandedFoldersAreSessionStateNotPersisted() {
        let child = dir.appendingPathComponent("notes")
        let m1 = WorkspaceModel(defaults: defaults)
        XCTAssertFalse(m1.isExpanded(child))
        m1.toggleExpanded(child)
        XCTAssertTrue(m1.isExpanded(child))

        // A launch rebuilds the open branch from `lastActivePath` — restoring
        // every expanded folder is what left several roots open and empty.
        let m2 = WorkspaceModel(defaults: defaults)
        XCTAssertFalse(m2.isExpanded(child))
    }

    // MARK: - Startup tree (one branch open, the rest collapsed)

    func testStartupExpandsOnlyTheBranchOfTheLastActiveFile() throws {
        let nested = dir.appendingPathComponent("notes/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("note.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let other = dir.deletingLastPathComponent()
            .appendingPathComponent("editmd-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.addWorkspace(other)
        m1.noteActive(file)

        let m2 = WorkspaceModel(defaults: defaults)   // relaunch
        let owner = try XCTUnwrap(m2.workspaces.first { $0.folderPath == dir.standardizedFileURL.path })
        let stranger = try XCTUnwrap(m2.workspaces.first { $0.folderPath == other.standardizedFileURL.path })
        XCTAssertFalse(owner.collapsed)          // branch of the last active file
        XCTAssertTrue(stranger.collapsed)        // every other root starts closed
        XCTAssertTrue(m2.isExpanded(dir.appendingPathComponent("notes")))
        XCTAssertTrue(m2.isExpanded(nested))     // path down to the file, not the file
        XCTAssertEqual(m2.expandedFolders.count, 2)
    }

    func testStartupExpandsTheLastActiveFolderItself() throws {
        let notes = dir.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)

        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.noteActive(notes)                     // a folder, not a file

        let m2 = WorkspaceModel(defaults: defaults)
        XCTAssertTrue(m2.isExpanded(notes))      // the folder opens, not just its parent
    }

    func testStartupWithoutLastActiveOpensFirstRootOnly() throws {
        let other = dir.deletingLastPathComponent()
            .appendingPathComponent("editmd-other-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }

        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.addWorkspace(other)

        let m2 = WorkspaceModel(defaults: defaults)
        XCTAssertFalse(m2.workspaces[0].collapsed)
        XCTAssertTrue(m2.workspaces[1].collapsed)
        XCTAssertTrue(m2.expandedFolders.isEmpty)
    }

    // MARK: - Startup snapshot (first frame comes from disk)

    func testSnapshotServesListingBeforeTheScanLands() async throws {
        let snapshotURL = dir.appendingPathComponent("snapshot.json")
        let m1 = WorkspaceModel(defaults: defaults, snapshotURL: snapshotURL)
        m1.addWorkspace(dir)
        // A real background scan fills the caches, which feed the snapshot.
        _ = m1.markdownFiles(in: dir)
        try await Task.sleep(for: .milliseconds(300))
        m1.snapshot.flushSync()

        // Relaunch: caches are empty, so without the snapshot this is [].
        let m2 = WorkspaceModel(defaults: defaults, snapshotURL: snapshotURL)
        XCTAssertEqual(names(m2.markdownFiles(in: dir)), ["a.md", "b.md", "sub.textbundle"])
    }

    func testNoteOpenedSkipsFilesInsideAWorkspace() {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.noteOpened(dir.appendingPathComponent("a.md"))   // inside workspace
        XCTAssertTrue(model.looseFilesToShow.isEmpty)

        model.noteOpened(URL(fileURLWithPath: "/tmp/outside.md")) // not in a workspace
        XCTAssertEqual(names(model.looseFilesToShow), ["outside.md"])
    }

    /// "Add the Folder Containing This File…" seeds the picker with the folder
    /// the loose row already shows.
    func testFolderPickerStartsAtTheFilesOwnFolder() throws {
        let file = try makeFilePath("topics/steps/note.md")
        XCTAssertEqual(WorkspaceModel.folderPickerStart(containing: file),
                       file.deletingLastPathComponent())
    }

    /// A package is a document, not a folder to open a workspace at, so the
    /// walk steps over it to the folder that holds it.
    func testFolderPickerSkipsAPackage() throws {
        let file = dir.appendingPathComponent("sub.textbundle/text.md")
        XCTAssertEqual(WorkspaceModel.folderPickerStart(containing: file),
                       dir.standardizedFileURL)
    }

    /// A pinned loose row outlives the folder it names; the panel then opens at
    /// the nearest ancestor that is still there instead of nowhere.
    func testFolderPickerWalksUpPastAMissingFolder() {
        let file = dir.appendingPathComponent("gone/deeper/note.md")
        XCTAssertEqual(WorkspaceModel.folderPickerStart(containing: file),
                       dir.standardizedFileURL)
    }

    /// The point of the panel: the adopted root is usually an ancestor of the
    /// file's own folder, and the row must still leave Open Files.
    func testAdoptingAnAncestorEndsLooseStatusAtAnyDepth() throws {
        let file = try makeFilePath("topics/steps/note.md")
        let model = WorkspaceModel(defaults: defaults)
        model.noteOpened(file)
        model.noteActive(file)
        XCTAssertEqual(names(model.looseFilesToShow), ["note.md"])

        model.addWorkspace(dir)   // two levels above the file

        XCTAssertTrue(model.looseFilesToShow.isEmpty)
        XCTAssertNotNil(model.workspaceOwning(file))
        // Adoption is sidebar bookkeeping only — the open document stays put.
        XCTAssertEqual(model.lastActivePath, file.standardizedFileURL.path)
    }

    /// A pin only holds a file in Open Files; under a root the tree shows it,
    /// so adoption must drop the pin as well as the session entry.
    func testAdoptingAnAncestorClearsAPinnedLooseRow() throws {
        let file = try makeFilePath("topics/spec.md")
        let model = WorkspaceModel(defaults: defaults)
        model.pin(file)
        XCTAssertEqual(names(model.looseFilesToShow), ["spec.md"])

        model.addWorkspace(dir)

        XCTAssertFalse(model.isPinned(file))
        XCTAssertTrue(model.looseFilesToShow.isEmpty)
        // And the pin does not come back on the next launch.
        let relaunched = WorkspaceModel(defaults: defaults)
        XCTAssertTrue(relaunched.looseFilesToShow.isEmpty)
    }

    /// `/` has no extra separator before descendants. The shared containment
    /// predicate must still make a root workspace own and hide every loose row.
    func testAdoptingFilesystemRootHidesDescendantLooseRows() {
        let file = dir.appendingPathComponent("a.md").standardizedFileURL
        let model = WorkspaceModel(defaults: defaults)
        model.noteOpened(file)

        model.addWorkspace(URL(fileURLWithPath: "/", isDirectory: true))

        XCTAssertTrue(model.looseFilesToShow.isEmpty)
        XCTAssertEqual(model.workspaceOwning(file)?.folderPath, "/")
    }

    /// A root does not own a sibling whose name merely starts with its own.
    /// This case already worked; repairing the `/` and trailing-slash corners
    /// must not lose it. (A trailing-slash root is unreachable from here —
    /// `Workspace` stores `standardizedFileURL.path` — so `PathScopeTests`
    /// covers that corner.)
    func testARootDoesNotOwnASiblingWithASharedPrefix() throws {
        let vault = try makeFilePath("vault/note.md")
        let sibling = try makeFilePath("vaultx/note.md")
        let model = WorkspaceModel(defaults: defaults)
        model.noteOpened(sibling)

        model.addWorkspace(vault.deletingLastPathComponent())

        XCTAssertNotNil(model.workspaceOwning(vault))
        XCTAssertNil(model.workspaceOwning(sibling))
        XCTAssertEqual(names(model.looseFilesToShow), ["note.md"])
    }

    /// The ancestor walk reaches `/` once and terminates there for an absolute
    /// stale path whose other ancestors do not exist.
    func testFolderPickerFallsBackToFilesystemRoot() {
        let missing = URL(fileURLWithPath: "/editmd-missing-\(UUID().uuidString)/note.md")
        XCTAssertEqual(WorkspaceModel.folderPickerStart(containing: missing)?.path, "/")
    }

    // MARK: - Frontmatter tags

    func testFrontmatterTagsFlowList() {
        let md = "---\ntags: [demo, markup]\n---\n\n# Hi\n"
        XCTAssertEqual(frontmatterTags(in: md), ["demo", "markup"])
    }

    func testFrontmatterTagsBlockList() {
        let md = "---\ntags:\n  - alpha\n  - beta\n---\n"
        XCTAssertEqual(frontmatterTags(in: md), ["alpha", "beta"])
    }

    func testFrontmatterTagsAbsent() {
        XCTAssertTrue(frontmatterTags(in: "# no fm\n").isEmpty)
        XCTAssertTrue(frontmatterTags(in: "---\ntitle: x\n---\n").isEmpty)
    }

    func testScanWorkspaceTags() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-tags-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = root.appendingPathComponent("a.md")
        let b = root.appendingPathComponent("b.md")
        try "---\ntags: [shared, only-a]\n---\n".write(to: a, atomically: true, encoding: .utf8)
        try "---\ntags: [shared]\n---\n".write(to: b, atomically: true, encoding: .utf8)
        let index = scanWorkspaceTags(roots: [root])
        XCTAssertEqual(Set(index["shared"]?.map(\.lastPathComponent) ?? []), ["a.md", "b.md"])
        XCTAssertEqual(index["only-a"]?.map(\.lastPathComponent), ["a.md"])
    }

    func testTagIndexRefreshesWhenWorkspaceRootsChange() async throws {
        try "---\ntags: [first-root]\n---\n".write(
            to: dir.appendingPathComponent("first-tagged.md"), atomically: true, encoding: .utf8)
        let second = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-tags-second-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: second) }
        try "---\ntags: [second-root]\n---\n".write(
            to: second.appendingPathComponent("tagged.md"), atomically: true, encoding: .utf8)

        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.ensureTagIndex()
        await waitForTagIndex(model) { $0["first-root"]?.count == 1 }

        model.addWorkspace(second)
        model.ensureTagIndex()
        await waitForTagIndex(model) { $0["second-root"]?.count == 1 }
        XCTAssertEqual(model.tagIndex["second-root"]?.first?.lastPathComponent, "tagged.md")
    }

    private func waitForTagIndex(
        _ model: WorkspaceModel,
        timeoutIterations: Int = 100,
        until predicate: ([String: [URL]]) -> Bool
    ) async {
        for _ in 0..<timeoutIterations {
            if predicate(model.tagIndex) { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for tag index refresh")
    }
}

@Suite("Workspace move transaction regressions")
@MainActor
struct WorkspaceMoveTransactionRegressionTests {

    @Test("An orphan destination review sidecar is always a collision")
    func orphanDestinationSidecarIsRejected() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.source.appendingPathComponent("note.md")
        let destination = fixture.destination.appendingPathComponent("note.md")
        let orphanSidecar = ReviewSidecar.url(for: destination)
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "unrelated review".write(
            to: orphanSidecar, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.source)
        model.addWorkspace(fixture.destination)

        do {
            _ = try await model.moveFileOnDisk(source, to: fixture.destination)
            Issue.record("Expected the orphan sidecar collision")
        } catch {
            #expect(error as? FileMoveError == .alreadyExists(
                orphanSidecar.lastPathComponent))
        }

        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try String(contentsOf: orphanSidecar, encoding: .utf8)
                == "unrelated review")
    }

    @Test("Renaming a parent root relocates nested adopted roots and hidden keys")
    func parentRenameRelocatesNestedWorkspaceState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let child = fixture.source.appendingPathComponent("Child", isDirectory: true)
        try FileManager.default.createDirectory(
            at: child, withIntermediateDirectories: false)

        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.source)
        model.addWorkspace(child)
        model.setDisplayName("Nested notes", for: try #require(model.workspaces.last))
        model.hiddenFiles[fixture.source.path] = ["root.md"]
        model.hiddenFiles[child.path] = ["nested.md"]

        let root = try #require(model.workspaces.first)
        let renamed = try await model.renameFolderOnDisk(
            root, to: "Archive", openDocumentURLs: [])
        let renamedChild = renamed.appendingPathComponent("Child", isDirectory: true)

        #expect(model.workspaces.map(\.folderPath) == [
            renamed.path, renamedChild.path
        ])
        #expect(model.workspaces.last?.displayName == "Nested notes")
        #expect(model.hiddenFiles[renamed.path] == ["root.md"])
        #expect(model.hiddenFiles[renamedChild.path] == ["nested.md"])
        #expect(model.hiddenFiles[fixture.source.path] == nil)
        #expect(model.hiddenFiles[child.path] == nil)
    }

    @Test("A missing source never adopts an unrelated destination folder")
    func missingSourceDoesNotMigrateToUnrelatedDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.source)
        let root = try #require(model.workspaces.first)

        try FileManager.default.removeItem(at: fixture.source)
        let unrelated = fixture.parent.appendingPathComponent(
            "Archive", isDirectory: true)
        try FileManager.default.createDirectory(
            at: unrelated, withIntermediateDirectories: false)
        let marker = unrelated.appendingPathComponent("unrelated.txt")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)

        do {
            _ = try await model.renameFolderOnDisk(
                root, to: "Archive", openDocumentURLs: [])
            Issue.record("Expected the missing source to abort before rename")
        } catch {
            #expect(error as? FolderRenameError == .folderNoLongerExists)
        }

        #expect(model.workspaces.first?.folderPath == fixture.source.path)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test("Case-only folder rename changes the spelling on disk")
    func caseOnlyFolderRename() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.source)
        let root = try #require(model.workspaces.first)

        let renamed = try await model.renameFolderOnDisk(
            root, to: "notes", openDocumentURLs: [])
        let siblingNames = try FileManager.default.contentsOfDirectory(
            at: fixture.parent,
            includingPropertiesForKeys: nil).map(\.lastPathComponent)

        #expect(renamed.lastPathComponent == "notes")
        #expect(siblingNames.contains("notes"))
        #expect(!siblingNames.contains("Notes"))
        #expect(model.workspaces.first?.folderPath == renamed.path)
    }

    @Test("Failed case-only recovery reports the temporary survivor")
    func caseOnlyRollbackReportsTemporarySurvivor() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let destination = fixture.parent.appendingPathComponent(
            "notes", isDirectory: true)
        let mover = FailingMovePrimitive(failingInvocations: [2, 3])

        do {
            try WorkspaceModel.moveFolderThroughTemporary(
                from: fixture.source,
                to: destination,
                moveItem: { source, destination in
                    try mover.move(from: source, to: destination)
                })
            Issue.record("Expected the final move and rollback to fail")
        } catch let FolderRenameError.diskFailure(survivor) {
            let survivor = try #require(survivor)
            #expect(survivor.lastPathComponent.hasPrefix(".editmd-rename-"))
            #expect(FileManager.default.fileExists(atPath: survivor.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.source.path))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Failed batch rollback reports and reconciles the surviving destination")
    func failedRollbackReconcilesSurvivingDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = fixture.source.appendingPathComponent("first.md")
        let second = fixture.source.appendingPathComponent("second.md")
        let movedFirst = fixture.destination.appendingPathComponent("first.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.source)
        model.addWorkspace(fixture.destination)
        model.hide(first)
        model.noteActive(first)
        let mover = FailingMovePrimitive(failingInvocations: [2, 3])

        do {
            _ = try await model.moveFilesOnDisk(
                [first, second],
                to: fixture.destination,
                moveItem: { source, destination in
                    try mover.move(from: source, to: destination)
                })
            Issue.record("Expected a rollback failure")
        } catch let FileMoveError.rollbackFailed(states) {
            let state = try #require(states.first)
            #expect(states.count == 1)
            #expect(state.move == FileMoveResult(
                source: first, destination: movedFirst))
            #expect(!state.fileAtSource)
            #expect(state.fileAtDestination)
            #expect(state.fileRemainsAtDestination)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: movedFirst.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(model.hiddenFiles[fixture.source.path] == nil)
        #expect(model.hiddenFiles[fixture.destination.path] == ["first.md"])
        #expect(model.lastActivePath == movedFirst.path)
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "editmd-workspace-transaction-\(UUID().uuidString)",
                isDirectory: true)
        let source = parent.appendingPathComponent("Notes", isDirectory: true)
        let destination = parent.appendingPathComponent(
            "Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination, withIntermediateDirectories: true)
        let suiteName = "workspace-transaction-\(UUID().uuidString)"
        return Fixture(
            parent: parent,
            source: source,
            destination: destination,
            suiteName: suiteName,
            defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private struct Fixture {
        let parent: URL
        let source: URL
        let destination: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

private final class FailingMovePrimitive: @unchecked Sendable {
    private enum InjectedFailure: Error { case move }

    private let lock = NSLock()
    private let failingInvocations: Set<Int>
    private var invocation = 0

    init(failingInvocations: Set<Int>) {
        self.failingInvocations = failingInvocations
    }

    func move(from source: URL, to destination: URL) throws {
        lock.lock()
        invocation += 1
        let shouldFail = failingInvocations.contains(invocation)
        lock.unlock()
        if shouldFail { throw InjectedFailure.move }
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
