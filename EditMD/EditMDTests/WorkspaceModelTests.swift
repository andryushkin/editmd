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
        XCTAssertEqual(names(model.visibleFiles(model.workspaces[0])),
                       ["a.md", "b.md", "sub.textbundle"])   // note.txt excluded, sorted
    }

    func testHideUnhide() {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        let ws = model.workspaces[0]
        let a = dir.appendingPathComponent("a.md")

        model.hide(a, in: ws)
        XCTAssertEqual(names(model.visibleFiles(ws)), ["b.md", "sub.textbundle"])
        XCTAssertEqual(names(model.hiddenFilesList(ws)), ["a.md"])
        XCTAssertEqual(model.totalHiddenCount, 1)

        model.unhide(a, in: ws)
        XCTAssertEqual(names(model.visibleFiles(ws)), ["a.md", "b.md", "sub.textbundle"])
        XCTAssertEqual(model.totalHiddenCount, 0)
    }

    func testHiddenPersistsAcrossInstances() {
        let m1 = WorkspaceModel(defaults: defaults)
        m1.addWorkspace(dir)
        m1.hide(dir.appendingPathComponent("a.md"), in: m1.workspaces[0])

        let m2 = WorkspaceModel(defaults: defaults)   // reloads from the same suite
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

    func testNoteOpenedSkipsFilesInsideAWorkspace() {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)
        model.noteOpened(dir.appendingPathComponent("a.md"))   // inside workspace
        XCTAssertTrue(model.looseFilesToShow.isEmpty)

        model.noteOpened(URL(fileURLWithPath: "/tmp/outside.md")) // not in a workspace
        XCTAssertEqual(names(model.looseFilesToShow), ["outside.md"])
    }
}
