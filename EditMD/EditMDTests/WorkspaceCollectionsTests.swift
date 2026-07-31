import XCTest
@testable import EditMD

/// Named collections in the Files sidebar: arrangement rules (pure), the model
/// mutations built on them, legacy decode, and the invariant that grouping is
/// presentation only — no index, resolution or path-keyed state may move.
@MainActor
final class WorkspaceCollectionsTests: XCTestCase {

    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-coll-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "colltest-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Helpers

    private func root(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func model(roots: [URL]) -> WorkspaceModel {
        let model = WorkspaceModel(defaults: defaults)
        for root in roots { model.addWorkspace(root) }
        return model
    }

    private func names(_ workspaces: [WorkspaceModel.Workspace]) -> [String] {
        workspaces.map(\.folderName)
    }

    private func ws(_ path: String, collection: String? = nil) -> WorkspaceModel.Workspace {
        WorkspaceModel.Workspace(folderPath: "/tmp/" + path, collectionID: collection)
    }

    // MARK: - Arrangement rules

    func testMembersBecomeContiguousAtTheFirstMembersPlace() {
        let collections = [WorkspaceCollection(id: "c1", name: "Work")]
        let arranged = WorkspaceModel.normalizedWorkspaces(
            [ws("a", collection: "c1"), ws("b"), ws("c", collection: "c1")],
            collections: collections)
        XCTAssertEqual(names(arranged), ["a", "c", "b"])
    }

    func testMembershipInAnUnknownCollectionDecaysToUngrouped() {
        let arranged = WorkspaceModel.normalizedWorkspaces(
            [ws("a"), ws("b", collection: "gone")], collections: [])
        XCTAssertEqual(names(arranged), ["a", "b"])
        XCTAssertNil(arranged[1].collectionID)
    }

    func testEmptyCollectionsArePruned() {
        let pruned = WorkspaceModel.prunedCollections(
            [WorkspaceCollection(id: "c1", name: "Work"),
             WorkspaceCollection(id: "c2", name: "Empty")],
            workspaces: [ws("a", collection: "c1")])
        XCTAssertEqual(pruned.map(\.id), ["c1"])
    }

    func testTopLevelItemsGroupMembersUnderTheirCollection() {
        let collections = [WorkspaceCollection(id: "c1", name: "Work")]
        let items = WorkspaceModel.topLevelItems(
            workspaces: [ws("a", collection: "c1"), ws("b"), ws("c", collection: "c1")],
            collections: collections)
        XCTAssertEqual(items.count, 2)
        guard case .collection(let collection, let members) = items[0] else {
            return XCTFail("first item should be the collection")
        }
        XCTAssertEqual(collection.id, "c1")
        XCTAssertEqual(names(members), ["a", "c"])
        XCTAssertEqual(items[1].id, "r:/tmp/b")
    }

    func testMovingAnUngroupedRootJumpsTheWholeCollectionBlock() {
        let collections = [WorkspaceCollection(id: "c1", name: "Work")]
        let moved = WorkspaceModel.movingTopLevelItem(
            id: "r:/tmp/b", by: -1,
            workspaces: [ws("a", collection: "c1"), ws("c", collection: "c1"), ws("b")],
            collections: collections)
        XCTAssertEqual(names(moved), ["b", "a", "c"])
    }

    func testMovingAMemberStaysInsideItsCollection() {
        let collections = [WorkspaceCollection(id: "c1", name: "Work")]
        let workspaces = [ws("a", collection: "c1"), ws("c", collection: "c1"), ws("b")]
        XCTAssertEqual(
            names(WorkspaceModel.movingMember(path: "/tmp/c", by: -1,
                                              workspaces: workspaces, collections: collections)),
            ["c", "a", "b"])
        // Down would leave the block — refused, the arrangement stands.
        XCTAssertEqual(
            names(WorkspaceModel.movingMember(path: "/tmp/c", by: 1,
                                              workspaces: workspaces, collections: collections)),
            ["a", "c", "b"])
    }

    // MARK: - Model mutations

    func testCreateAssignAndDissolve() throws {
        let a = try root("A"), b = try root("B")
        let model = model(roots: [a, b])
        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.assign(model.workspaces[1], to: collection)

        XCTAssertEqual(model.collections.count, 1)
        XCTAssertEqual(model.sidebarTopLevelItems.count, 1)
        XCTAssertEqual(model.collection(of: model.workspaces[1])?.id, collection.id)

        model.dissolveCollection(collection)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(names(model.workspaces), ["A", "B"])
    }

    func testTakingOutTheLastMemberDropsTheCollection() throws {
        let a = try root("A")
        let model = model(roots: [a])
        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.assign(model.workspaces[0], to: nil)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertNil(model.collection(withID: collection.id))
    }

    func testRemovingTheLastMemberRootDropsTheCollection() throws {
        let a = try root("A")
        let model = model(roots: [a])
        _ = model.createCollection(named: "Work", with: model.workspaces[0])
        model.removeWorkspace(model.workspaces[0])
        XCTAssertTrue(model.collections.isEmpty)
    }

    func testCollapsedCollectionHidesItsMembersFromTheVisibleTree() throws {
        let a = try root("A"), b = try root("B")
        let model = model(roots: [a, b])
        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        XCTAssertEqual(names(model.visibleWorkspaces), ["A", "B"])
        model.toggleCollapsed(collection)
        XCTAssertEqual(names(model.visibleWorkspaces), ["B"])
        XCTAssertEqual(names(model.workspaces), ["A", "B"])   // still adopted
    }

    func testRenameKeepsMembershipAndIgnoresBlankNames() throws {
        let a = try root("A")
        let model = model(roots: [a])
        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.renameCollection(collection, to: "  ")
        XCTAssertEqual(model.collections[0].name, "Work")
        model.renameCollection(collection, to: " Personal ")
        XCTAssertEqual(model.collections[0].name, "Personal")
        XCTAssertEqual(model.collection(of: model.workspaces[0])?.id, collection.id)
    }

    // MARK: - Persistence and legacy data

    func testArrangementSurvivesRelaunch() throws {
        let a = try root("A"), b = try root("B"), c = try root("C")
        let first = model(roots: [a, b, c])
        let collection = try XCTUnwrap(first.createCollection(named: "Work", with: first.workspaces[0]))
        first.assign(first.workspaces.first { $0.folderName == "C" }!, to: collection)
        first.toggleCollapsed(collection)

        let reopened = WorkspaceModel(defaults: defaults)
        XCTAssertEqual(names(reopened.workspaces), ["A", "C", "B"])
        XCTAssertEqual(reopened.collections.map(\.name), ["Work"])
        XCTAssertTrue(reopened.collections[0].collapsed)
        XCTAssertEqual(names(reopened.visibleWorkspaces), ["B"])
    }

    /// Every install that predates collections has a flat list and no
    /// collections key at all: it must open exactly as it did before.
    func testLegacyUngroupedDataOpensUnchanged() throws {
        let a = try root("A"), b = try root("B")
        let legacy = [["folderPath": a.path, "collapsed": false],
                      ["folderPath": b.path, "collapsed": true]]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "workspace.folders")

        let model = WorkspaceModel(defaults: defaults)
        XCTAssertEqual(names(model.workspaces), ["A", "B"])
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertTrue(model.workspaces.allSatisfy { $0.collectionID == nil })
        XCTAssertEqual(model.sidebarTopLevelItems.map(\.id),
                       ["r:" + a.path, "r:" + b.path])
    }

    // MARK: - Presentation only

    /// Acceptance: grouping the same roots must not move a single index,
    /// resolution result, or path-keyed piece of sidebar state.
    func testGroupingChangesNothingOutsideThePresentation() throws {
        let a = try root("A"), b = try root("B")
        try "[[note]]\n".write(to: a.appendingPathComponent("index.md"),
                               atomically: true, encoding: .utf8)
        try "note\n".write(to: a.appendingPathComponent("note.md"),
                           atomically: true, encoding: .utf8)
        try "[[note]]\n".write(to: b.appendingPathComponent("other.md"),
                               atomically: true, encoding: .utf8)

        let model = model(roots: [a, b])
        model.noteActive(a.appendingPathComponent("index.md"))
        model.hide(a.appendingPathComponent("note.md"), in: model.workspaces[0])
        model.addFavorite(a.appendingPathComponent("index.md"))

        let rootsBefore = model.linkIndexRoots
        let activeBefore = model.activeWorkspaceRoot
        let hiddenBefore = model.hiddenFiles
        let favoritesBefore = model.favoritePathsByWorkspace
        let scanBefore = LinkGraphEngine.scanWorkspaceOutgoing(roots: rootsBefore)

        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.assign(model.workspaces.first { $0.folderName == "B" }!, to: collection)

        XCTAssertEqual(model.linkIndexRoots, rootsBefore)
        XCTAssertEqual(model.activeWorkspaceRoot, activeBefore)
        XCTAssertEqual(model.hiddenFiles, hiddenBefore)
        XCTAssertEqual(model.favoritePathsByWorkspace, favoritesBefore)

        // A collection is never a vault: the scan still covers the active root
        // alone and resolves exactly the same links.
        let scanAfter = LinkGraphEngine.scanWorkspaceOutgoing(roots: model.linkIndexRoots)
        XCTAssertEqual(scanAfter.filesScanned, scanBefore.filesScanned)
        XCTAssertEqual(
            scanAfter.outgoing.mapValues { $0.map(\.rawTarget) },
            scanBefore.outgoing.mapValues { $0.map(\.rawTarget) })
        XCTAssertFalse(scanAfter.outgoing.keys.contains {
            $0.path.hasPrefix(b.standardizedFileURL.path + "/")
        })
    }

    /// The launch reopens one branch — it must be visible even when its
    /// collection was left collapsed.
    func testStartupExpandsTheCollectionOwningTheActiveBranch() throws {
        let a = try root("A"), b = try root("B")
        let first = model(roots: [a, b])
        let collection = try XCTUnwrap(first.createCollection(named: "Work", with: first.workspaces[0]))
        first.toggleCollapsed(collection)
        first.noteActive(a.appendingPathComponent("index.md"))

        let reopened = WorkspaceModel(defaults: defaults)
        XCTAssertFalse(reopened.collections[0].collapsed)
        XCTAssertEqual(names(reopened.visibleWorkspaces), ["A", "B"])
    }
}
