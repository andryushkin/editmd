import XCTest
@testable import EditMD

/// Phase 3: folder scan filtering, hide/unhide, per-path persistence, pinning,
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

    // MARK: - Frontmatter tags (D11)

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
