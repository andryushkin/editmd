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

    /// An index of its own: adopting a root re-keys the link graph, and the
    /// shared index may already have scanned under the full suite — these
    /// temp roots must never start a background scan in it.
    private func model(roots: [URL]) -> WorkspaceModel {
        let model = WorkspaceModel(defaults: defaults, index: LinkIndex())
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

    // MARK: - Drag a root onto a root / a collection

    func testDroppingARootOnAnUngroupedRootAsksForANewCollection() {
        let workspaces = [ws("a"), ws("b")]
        XCTAssertEqual(rootDropOutcome(dragged: "/tmp/a", onto: "/tmp/b", workspaces: workspaces),
                       .createCollection(dragged: "/tmp/a", target: "/tmp/b"))
    }

    func testDroppingARootOnAGroupedRootJoinsThatCollection() {
        let workspaces = [ws("a"), ws("b", collection: "c1")]
        XCTAssertEqual(rootDropOutcome(dragged: "/tmp/a", onto: "/tmp/b", workspaces: workspaces),
                       .join(collectionID: "c1"))
    }

    func testRootDropIsIgnoredOnItselfOnAMemberOfTheSameCollectionAndOnStrangers() {
        let workspaces = [ws("a", collection: "c1"), ws("b", collection: "c1")]
        XCTAssertEqual(rootDropOutcome(dragged: "/tmp/a", onto: "/tmp/a", workspaces: workspaces),
                       .ignore)
        XCTAssertEqual(rootDropOutcome(dragged: "/tmp/a", onto: "/tmp/b", workspaces: workspaces),
                       .ignore)
        // A path that is not an adopted root (a subfolder, a stale drag).
        XCTAssertEqual(rootDropOutcome(dragged: "/tmp/a", onto: "/tmp/a/sub", workspaces: workspaces),
                       .ignore)
    }

    /// Both drop paths end in the same state as the menu commands do.
    func testDropOutcomesApplyToTheModel() throws {
        let a = try root("A"), b = try root("B"), c = try root("C")
        let model = model(roots: [a, b, c])

        // A dropped on B, neither grouped → the caller names a new collection.
        guard case .createCollection = rootDropOutcome(
            dragged: a.path, onto: b.path, workspaces: model.workspaces)
        else { return XCTFail("expected a new collection") }
        let collection = try XCTUnwrap(
            model.createCollection(named: "Work", with: model.workspaces.first { $0.folderName == "B" }!))
        model.assign(model.workspaces.first { $0.folderName == "A" }!, to: collection)

        // C dropped on A, which is now grouped → C joins the same collection.
        guard case .join(let id) = rootDropOutcome(
            dragged: c.path, onto: a.path, workspaces: model.workspaces)
        else { return XCTFail("expected a join") }
        XCTAssertEqual(id, collection.id)
        model.assign(model.workspaces.first { $0.folderName == "C" }!,
                     to: try XCTUnwrap(model.collection(withID: id)))

        XCTAssertEqual(model.collections.count, 1)
        XCTAssertEqual(model.sidebarTopLevelItems.count, 1)
        // The block keeps the roots' own order and sits at the first member's
        // place — dropping never shuffles the list beyond making it contiguous.
        XCTAssertEqual(names(model.visibleWorkspaces), ["A", "B", "C"])
    }

    /// Roots travel under their own drag type, so a file target never sees a
    /// root drag and a root target never sees a file drag.
    func testRootDragUsesItsOwnTypeAndRoundTrips() throws {
        XCTAssertNotEqual(sidebarRootDragContentType, sidebarFileDragContentType)

        let data = try encodeSidebarRootDragPayload(SidebarRootDragPayload(path: "/tmp/a"))
        XCTAssertEqual(decodeSidebarRootDragPayload(data), "/tmp/a")

        // A file payload is not a root payload even if it reaches this decoder.
        let fileData = try encodeSidebarFileDragPayload(
            SidebarFileDragPayload(files: [URL(fileURLWithPath: "/tmp/a/note.md")]))
        XCTAssertNil(decodeSidebarRootDragPayload(fileData))
        XCTAssertNil(decodeSidebarRootDragPayload(Data(#"{"hello":"world"}"#.utf8)))
    }

    // MARK: - Reordering and the active root

    /// With a document open, the vault is the root that owns it — reordering
    /// the sidebar must not move it.
    func testReorderingDoesNotMoveTheVaultWhileADocumentIsOpen() throws {
        let a = try root("A"), b = try root("B")
        try "note\n".write(to: b.appendingPathComponent("note.md"),
                           atomically: true, encoding: .utf8)
        let model = model(roots: [a, b])
        model.noteActive(b.appendingPathComponent("note.md"))

        model.moveWorkspace(model.workspaces.first { $0.folderName == "B" }!, by: -1)
        XCTAssertEqual(names(model.workspaces), ["B", "A"])
        XCTAssertEqual(model.activeWorkspaceRoot, b.standardizedFileURL)
        XCTAssertEqual(model.linkIndexRoots, [b.standardizedFileURL])
    }

    /// With nothing open the vault is the first root — the branch a fresh
    /// launch opens — so it follows the arrangement, and grouping alone (which
    /// only makes members contiguous) must not disturb it.
    func testFallbackVaultFollowsTheFirstRootAndSurvivesGrouping() throws {
        let a = try root("A"), b = try root("B")
        let model = model(roots: [a, b])
        XCTAssertEqual(model.activeWorkspaceRoot, a.standardizedFileURL)

        let collection = try XCTUnwrap(
            model.createCollection(named: "Work", with: model.workspaces.first { $0.folderName == "B" }!))
        XCTAssertEqual(model.activeWorkspaceRoot, a.standardizedFileURL)
        model.assign(model.workspaces.first { $0.folderName == "A" }!, to: collection)
        XCTAssertEqual(model.activeWorkspaceRoot, a.standardizedFileURL)

        model.moveWorkspace(model.workspaces.first { $0.folderName == "A" }!, by: 1)
        XCTAssertEqual(names(model.workspaces), ["B", "A"])
        XCTAssertEqual(model.activeWorkspaceRoot, b.standardizedFileURL)
    }

    /// The re-key itself, not just the computed root: a live index must stop
    /// answering for the root that is no longer the vault. Covers both paths —
    /// reordering the sidebar and dropping the root the index was built for.
    func testMovingTheVaultRekeysALiveIndex() async throws {
        for scenario in ["reorder", "remove"] {
            let a = try root("A-\(scenario)"), b = try root("B-\(scenario)")
            try "[[note]]\n".write(to: a.appendingPathComponent("index.md"),
                                   atomically: true, encoding: .utf8)
            try "note\n".write(to: b.appendingPathComponent("note.md"),
                               atomically: true, encoding: .utf8)

            let index = LinkIndex()
            // A suite of its own: the two scenarios must not inherit each
            // other's adopted roots through the shared store.
            let suite = "colltest-\(UUID().uuidString)"
            let store = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { store.removePersistentDomain(forName: suite) }
            let model = WorkspaceModel(defaults: store, index: index)
            model.addWorkspace(a)
            model.addWorkspace(b)
            // Nothing open: the vault is the first root, and the index is live.
            index.seedForTesting(outgoing: [:], roots: [a], key: "seeded")
            XCTAssertEqual(model.activeWorkspaceRoot, a.standardizedFileURL)

            let before = index.fullScanCount
            switch scenario {
            case "reorder":
                model.moveWorkspace(model.workspaces[0], by: 1)
            default:
                model.removeWorkspace(model.workspaces[0])
            }
            XCTAssertEqual(model.activeWorkspaceRoot, b.standardizedFileURL, scenario)

            let deadline = Date().addingTimeInterval(3)
            while index.fullScanCount == before, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertGreaterThan(index.fullScanCount, before,
                                 "\(scenario) left the index answering for the old vault")
        }
    }

    /// The sidebar dims Move Up/Down from a row's position; the model answers
    /// from the arrangement. They must never disagree, or a live menu item
    /// does nothing (or a possible move looks impossible).
    func testRowMoveFlagsAgreeWithTheModel() throws {
        let a = try root("A"), b = try root("B"), c = try root("C"), d = try root("D")
        let model = model(roots: [a, b, c, d])
        let collection = try XCTUnwrap(
            model.createCollection(named: "Work", with: model.workspaces.first { $0.folderName == "B" }!))
        model.assign(model.workspaces.first { $0.folderName == "C" }!, to: collection)

        let items = model.sidebarTopLevelItems
        for (index, item) in items.enumerated() {
            let moves = SidebarMoves(position: index, count: items.count)
            switch item {
            case .root(let ws):
                XCTAssertEqual(moves.up, model.canMoveWorkspace(ws, by: -1), ws.folderName)
                XCTAssertEqual(moves.down, model.canMoveWorkspace(ws, by: 1), ws.folderName)
            case .collection(let collection, let members):
                XCTAssertEqual(moves.up, model.canMoveCollection(collection, by: -1))
                XCTAssertEqual(moves.down, model.canMoveCollection(collection, by: 1))
                for (i, member) in members.enumerated() {
                    let inside = SidebarMoves(position: i, count: members.count)
                    XCTAssertEqual(inside.up, model.canMoveWorkspace(member, by: -1),
                                   member.folderName)
                    XCTAssertEqual(inside.down, model.canMoveWorkspace(member, by: 1),
                                   member.folderName)
                }
            }
        }
    }

    /// Renaming an adopted root on disk rewrites every path-keyed entry — the
    /// collection membership has to ride along with it.
    func testRenamingARootOnDiskKeepsItsCollection() async throws {
        let a = try root("A"), b = try root("B")
        let model = model(roots: [a, b])
        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.assign(model.workspaces.first { $0.folderName == "B" }!, to: collection)

        _ = try await model.renameFolderOnDisk(
            model.workspaces[0], to: "Renamed", openDocumentURLs: [])
        let renamed = try XCTUnwrap(model.workspaces.first { $0.folderName == "Renamed" })
        XCTAssertEqual(model.collection(of: renamed)?.id, collection.id)
        XCTAssertEqual(model.collections.count, 1)
        XCTAssertEqual(model.sidebarTopLevelItems.count, 1)
    }

    /// Hand-edited or merged defaults can repeat an id. Only the first one
    /// could ever be rendered, so the rest must not reach the live model as
    /// rows nobody can see, rename or collapse. (The stored JSON keeps them
    /// until the next mutation rewrites the key — every load prunes them, so
    /// they never surface.)
    func testDuplicateCollectionIDsDoNotSurvivePruning() {
        let pruned = WorkspaceModel.prunedCollections(
            [WorkspaceCollection(id: "x", name: "Work"),
             WorkspaceCollection(id: "x", name: "Personal")],
            workspaces: [ws("a", collection: "x")])
        XCTAssertEqual(pruned.map(\.name), ["Work"])
    }

    func testDuplicateCollectionIDsDoNotSurviveStartup() throws {
        let a = try root("A")
        let stored = [["id": "x", "name": "Work", "collapsed": false],
                      ["id": "x", "name": "Personal", "collapsed": false]]
        defaults.set(try JSONSerialization.data(withJSONObject: stored),
                     forKey: "workspace.collections")
        defaults.set(try JSONSerialization.data(withJSONObject:
            [["folderPath": a.path, "collapsed": false, "collectionID": "x"]]),
                     forKey: "workspace.folders")

        let model = WorkspaceModel(defaults: defaults)
        XCTAssertEqual(model.collections.map(\.name), ["Work"])
        XCTAssertEqual(model.sidebarTopLevelItems.count, 1)
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

    /// Everything a link ends up carrying once it is resolved — the shape the
    /// backlinks panel, vault lint and ⌘-click all read.
    private struct ResolvedLink: Equatable, CustomStringConvertible {
        let kind: OutgoingLink.Kind
        let rawTarget: String
        let resolved: URL?
        let candidates: [URL]

        var description: String {
            "\(kind.rawValue) \(rawTarget) → \(resolved?.path ?? "nil") \(candidates.map(\.path))"
        }
    }

    /// The same walk `LinkIndex` performs: scan, build the wiki index over the
    /// index roots, resolve. Anything grouping might disturb — which root wins
    /// as the vault, which basenames are in the index, whether a target becomes
    /// ambiguous — shows up in the result.
    private func resolvedLinks(in model: WorkspaceModel) -> [URL: [ResolvedLink]] {
        let roots = model.linkIndexRoots
        let scan = LinkGraphEngine.scanWorkspaceOutgoing(roots: roots)
        let wikiIndex = WikiLinkCore.buildIndex(roots: roots)
        var result: [URL: [ResolvedLink]] = [:]
        for (source, links) in scan.outgoing {
            let resolved = LinkGraphEngine.resolveScannedLinks(
                links, source: source, roots: roots,
                vaultFallback: roots.first, wikiIndex: wikiIndex,
                environment: scan.environment)
            result[source] = resolved.links.map {
                ResolvedLink(kind: $0.kind, rawTarget: $0.rawTarget,
                             resolved: $0.resolved, candidates: $0.candidates)
            }
        }
        return result
    }

    /// Acceptance: grouping the same roots must not move a single index,
    /// resolution result, or path-keyed piece of sidebar state.
    func testGroupingChangesNothingOutsideThePresentation() throws {
        let a = try root("A"), b = try root("B")
        try "---\ntags: [work]\n---\n[[note]] and [link](note.md)\n"
            .write(to: a.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        try "note in A\n".write(to: a.appendingPathComponent("note.md"),
                                atomically: true, encoding: .utf8)
        // Same basename in the other root: if a collection ever merged vaults,
        // `[[note]]` would gain a second candidate.
        try "note in B\n".write(to: b.appendingPathComponent("note.md"),
                                atomically: true, encoding: .utf8)
        try "---\ntags: [personal]\n---\n[[note]]\n"
            .write(to: b.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

        let model = model(roots: [a, b])
        model.noteActive(a.appendingPathComponent("index.md"))
        model.hide(a.appendingPathComponent("note.md"), in: model.workspaces[0])
        model.addFavorite(a.appendingPathComponent("index.md"))

        let rootsBefore = model.linkIndexRoots
        let activeBefore = model.activeWorkspaceRoot
        let hiddenBefore = model.hiddenFiles
        let favoritesBefore = model.favoritePathsByWorkspace
        let linksBefore = resolvedLinks(in: model)
        let tagsBefore = scanWorkspaceTags(roots: model.workspaces.map(\.url))
        let searchBefore = collectSearchFileMetas(roots: model.workspaces.map(\.url))

        let collection = try XCTUnwrap(model.createCollection(named: "Work", with: model.workspaces[0]))
        model.assign(model.workspaces.first { $0.folderName == "B" }!, to: collection)

        XCTAssertEqual(model.linkIndexRoots, rootsBefore)
        XCTAssertEqual(model.activeWorkspaceRoot, activeBefore)
        XCTAssertEqual(model.hiddenFiles, hiddenBefore)
        XCTAssertEqual(model.favoritePathsByWorkspace, favoritesBefore)

        // A collection is never a vault: the same links resolve to the same
        // files, with the same candidate sets, out of the same single root.
        let linksAfter = resolvedLinks(in: model)
        XCTAssertEqual(linksAfter, linksBefore)
        let indexLinks = try XCTUnwrap(linksAfter[a.appendingPathComponent("index.md")
            .standardizedFileURL])
        let wiki = try XCTUnwrap(indexLinks.first { $0.kind == .wiki })
        XCTAssertEqual(wiki.resolved, a.appendingPathComponent("note.md").standardizedFileURL)
        // Spelled out rather than via PathScope on purpose: a test that checks
        // behaviour by calling the code under test proves only that it agrees
        // with itself.
        XCTAssertTrue(wiki.candidates.allSatisfy {
            $0.path.hasPrefix(a.standardizedFileURL.path + "/")
        }, "grouping must not pull the other root's note.md into resolution")
        XCTAssertFalse(linksAfter.keys.contains {
            $0.path.hasPrefix(b.standardizedFileURL.path + "/")
        })

        // Tags and search still cover every adopted root, grouped or not.
        let tagsAfter = scanWorkspaceTags(roots: model.workspaces.map(\.url))
        XCTAssertEqual(tagsAfter.mapValues { Set($0) }, tagsBefore.mapValues { Set($0) })
        XCTAssertEqual(Set(collectSearchFileMetas(roots: model.workspaces.map(\.url)).map(\.url)),
                       Set(searchBefore.map(\.url)))
    }

    /// With nothing remembered there is no branch to reveal, so a collapsed
    /// collection stays collapsed — the launch must not undo the user's own
    /// collapse just because the first root happens to sit inside it.
    func testStartupKeepsACollapsedCollectionWithNoRememberedBranch() throws {
        let a = try root("A"), b = try root("B")
        let first = model(roots: [a, b])
        let collection = try XCTUnwrap(first.createCollection(named: "Work", with: first.workspaces[0]))
        first.toggleCollapsed(collection)

        let reopened = WorkspaceModel(defaults: defaults)
        XCTAssertNil(reopened.lastActivePath)
        XCTAssertTrue(reopened.collections[0].collapsed)
        XCTAssertEqual(names(reopened.visibleWorkspaces), ["B"])
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
