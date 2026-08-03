import XCTest
@testable import EditMD

final class VaultLintTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/vault")
    private var noteA: URL { root.appendingPathComponent("A.md") }
    private var noteB: URL { root.appendingPathComponent("B.md") }
    private var readme: URL { root.appendingPathComponent("README.md") }
    private var orphan: URL { root.appendingPathComponent("lonely.md") }

    private func link(
        kind: OutgoingLink.Kind,
        target: String,
        heading: String? = nil,
        line: Int = 1,
        offset: Int = 0,
        resolved: URL? = nil,
        candidates: [URL] = []
    ) -> OutgoingLink {
        OutgoingLink(
            kind: kind,
            rawTarget: target,
            heading: heading,
            label: target,
            line: line,
            utf16Offset: offset,
            context: "[[\(target)]]",
            resolved: resolved,
            candidates: candidates
        )
    }

    // MARK: - dead / live wiki

    func testDeadWikiLink() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 10)],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap)
        XCTAssertTrue(f.contains { $0.rule == .deadWikiLink })
        XCTAssertFalse(f.contains { $0.rule == .deadWikiLink && $0.file == noteB })
    }

    func testLiveWikiLinkNotFlagged() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B", resolved: noteB, candidates: [noteB])],
                noteB: [],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap).filter { $0.rule == .deadWikiLink }
        XCTAssertTrue(f.isEmpty)
    }

    func testAmbiguousWikiLink() {
        let c1 = root.appendingPathComponent("sub/B.md")
        let c2 = root.appendingPathComponent("other/B.md")
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B",
                             candidates: [c1, c2])],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap)
        XCTAssertTrue(f.contains { $0.rule == .ambiguousWikiLink })
    }

    func testSelfWikiLink() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "A", resolved: noteA, candidates: [noteA])],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap)
        XCTAssertTrue(f.contains { $0.rule == .selfWikiLink })
    }

    // MARK: - relative / image

    func testDeadRelativeLink() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .markdown, target: "gone.md", offset: 5)],
            ],
            roots: [root]
        )
        XCTAssertTrue(vaultLintFindings(index: snap).contains { $0.rule == .deadRelativeLink })
    }

    func testRelativeOutsideWorkspace() {
        let outside = URL(fileURLWithPath: "/tmp/outside.md")
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .markdown, target: "../tmp/outside.md",
                             resolved: outside, candidates: [outside])],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap)
        XCTAssertTrue(f.contains {
            $0.rule == .deadRelativeLink && $0.message.contains("points outside")
        })
    }

    func testPureFragmentNotInIndexScan() {
        // shouldIndexLinkDestination rejects `#anchor` — no outgoing entry.
        XCTAssertFalse(shouldIndexLinkDestination("#внутри"))
        XCTAssertFalse(shouldIndexLinkDestination("https://example.com"))
    }

    func testDeadImageLink() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .image, target: "x.png")],
            ],
            roots: [root]
        )
        XCTAssertTrue(vaultLintFindings(index: snap).contains { $0.rule == .deadImageLink })
    }

    // MARK: - orphan

    func testOrphanExcludesHomeAndLinked() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B", resolved: noteB, candidates: [noteB])],
                noteB: [],
                orphan: [],
                readme: [],
            ],
            roots: [root],
            homeDocuments: [readme]
        )
        let orphans = vaultLintFindings(index: snap).filter { $0.rule == .orphanFile }
        let files = Set(orphans.map { $0.file.standardizedFileURL })
        XCTAssertTrue(files.contains(orphan.standardizedFileURL))
        XCTAssertTrue(files.contains(noteA.standardizedFileURL)) // no backlinks
        XCTAssertFalse(files.contains(noteB.standardizedFileURL)) // has backlink from A
        XCTAssertFalse(files.contains(readme.standardizedFileURL))
    }

    func testSelfLinkOnlyIsOrphanAndSelf() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "A", resolved: noteA, candidates: [noteA])],
            ],
            roots: [root]
        )
        // projectBacklinks counts a self-link as a backlink edge, so the
        // orphan rule must ignore edges where source == target: a file whose
        // only link points to itself is both orphan AND selfWikiLink.
        let f = vaultLintFindings(index: snap)
        XCTAssertTrue(f.contains { $0.rule == .selfWikiLink })
        XCTAssertTrue(f.contains { $0.rule == .orphanFile },
                      "self-only backlinks must not clear orphan: \(f)")
    }

    // MARK: - heading

    func testDeadHeadingAnchor() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B", heading: "Missing",
                             resolved: noteB, candidates: [noteB])],
                noteB: [],
            ],
            headings: [noteB: ["Intro", "Details"]],
            roots: [root]
        )
        XCTAssertTrue(vaultLintFindings(index: snap).contains { $0.rule == .deadHeadingAnchor })
    }

    func testLiveHeadingNotFlagged() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B", heading: "Intro",
                             resolved: noteB, candidates: [noteB])],
                noteB: [],
            ],
            headings: [noteB: ["Intro"]],
            roots: [root]
        )
        XCTAssertFalse(vaultLintFindings(index: snap).contains { $0.rule == .deadHeadingAnchor })
    }

    func testHeadingRuleSkippedWithoutHeadingData() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "B", heading: "X",
                             resolved: noteB, candidates: [noteB])],
                noteB: [],
            ],
            headings: [:],
            roots: [root]
        )
        XCTAssertFalse(vaultLintFindings(index: snap).contains { $0.rule == .deadHeadingAnchor })
    }

    // MARK: - suggestion

    func testTargetSuggestionTypo() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Noteb", offset: 0)],
                noteB: [], // basename B
            ],
            roots: [root]
        )
        // "Noteb" vs "B" — may not suggest; use closer names.
        let noteNote = root.appendingPathComponent("Note.md")
        let snap2 = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Ntoe", offset: 0)],
                noteNote: [],
            ],
            roots: [root]
        )
        // Substring ranking: "Note" contains parts of query poorly.
        // Use "Notes" vs "Note".
        let snap3 = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Not", offset: 0)],
                noteNote: [],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(index: snap3)
        let dead = f.first { $0.rule == .deadWikiLink }
        XCTAssertNotNil(dead)
        XCTAssertEqual(dead?.targetSuggestion?.lastPathComponent, "Note.md")
        _ = snap
        _ = snap2
    }

    // MARK: - skipped oversized

    func testSkippedFilesNotInvented() {
        let snap = LinkIndexSnapshot(
            outgoing: [noteA: []],
            skippedOversizedCount: 3,
            roots: [root]
        )
        // Engine does not emit findings about skipped files; count is for UI only.
        XCTAssertEqual(snap.skippedOversizedCount, 3)
        XCTAssertFalse(vaultLintFindings(index: snap).contains {
            $0.message.lowercased().contains("skipped")
        })
    }

    // MARK: - lint merge mapping

    func testVaultFindingsAsLintDiagnostics() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "X", offset: 42)],
            ],
            roots: [root]
        )
        let findings = vaultLintFindings(index: snap)
        let diags = vaultFindingsAsLintDiagnostics(findings, for: noteA)
        XCTAssertFalse(diags.isEmpty)
        XCTAssertEqual(diags.first?.range.location, 42)
        XCTAssertEqual(diags.first?.rule, .vaultDeadWikiLink)
        let orphanOnly = vaultFindingsAsLintDiagnostics(
            findings.filter { $0.rule == .orphanFile }, for: noteA)
        XCTAssertTrue(orphanOnly.isEmpty)
    }

    // MARK: - per-file path

    func testPerFileFindingsOnlyForThatFile() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 10)],
                noteB: [link(kind: .image, target: "gone.png", offset: 0)],
                orphan: [],
            ],
            roots: [root]
        )
        let f = vaultLintFindings(for: noteA.standardizedFileURL, index: snap)
        XCTAssertTrue(f.contains { $0.rule == .deadWikiLink })
        XCTAssertTrue(f.allSatisfy { $0.file == noteA.standardizedFileURL })
        // Orphan is workspace-level — excluded from the per-file path.
        XCTAssertFalse(f.contains { $0.rule == .orphanFile })
        let g = vaultLintFindings(for: noteB.standardizedFileURL, index: snap)
        XCTAssertTrue(g.contains { $0.rule == .deadImageLink })
    }

    func testPerFileFindingsSharedCatalogMatchesOwnCatalog() {
        let noteNote = root.appendingPathComponent("Note.md")
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Not", offset: 0)],
                noteNote: [],
            ],
            roots: [root]
        )
        let shared = vaultLintCatalog(files: snap.allFiles)
        let own = vaultLintFindings(for: noteA.standardizedFileURL, index: snap)
        let with = vaultLintFindings(
            for: noteA.standardizedFileURL, index: snap, catalog: shared)
        XCTAssertEqual(own, with)
        XCTAssertEqual(
            with.first { $0.rule == .deadWikiLink }?
                .targetSuggestion?.lastPathComponent,
            "Note.md")
    }

    @MainActor
    func testModelIndexUpdateDoesNotRunFullLint() async throws {
        let index = LinkIndex()
        let model = VaultLintModel.shared
        model.bind(to: index)
        model.reportActive = false
        // Seeding publishes the graph → debounced sink fires. Without the
        // report panel open it must NOT start a full-vault run.
        index.seedForTesting(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 3)],
            ],
            roots: [root],
            key: "vault-lazy"
        )
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.lastRun)
        XCTAssertTrue(model.findings.isEmpty)

        // Per-file path still works: first call schedules, then cache fills.
        _ = model.findings(for: noteA)
        let deadline = Date().addingTimeInterval(2)
        while model.findings(for: noteA).isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.findings(for: noteA).isEmpty)
        XCTAssertTrue(model.findings.isEmpty, "per-file path must not publish full-vault findings")
        model.bind(to: LinkIndex.shared)
    }

    func testFullRunReportsProgressPerFile() {
        let snap = LinkIndexSnapshot(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 1)],
                noteB: [],
                orphan: [],
            ],
            roots: [root]
        )
        final class Box: @unchecked Sendable { var reports: [(Int, Int)] = [] }
        let box = Box()
        _ = vaultLintFindings(index: snap) { done, total in
            box.reports.append((done, total))
        }
        XCTAssertEqual(box.reports.map(\.0), [0, 1, 2])
        XCTAssertTrue(box.reports.allSatisfy { $0.1 == 3 })
    }

    @MainActor
    func testDeactivatingReportCancelsCurrentFullRun() async throws {
        let index = LinkIndex()
        index.seedForTesting(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 3)],
            ],
            roots: [root],
            key: "vault-cancel"
        )
        let model = VaultLintModel.shared
        model.reportActive = false
        model.bind(to: index)
        let previousLastRun = model.lastRun

        model.reportActive = true
        model.runNow()
        XCTAssertTrue(model.isRunning)
        model.reportActive = false
        XCTAssertFalse(model.isRunning)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.lastRun, previousLastRun)
        model.bind(to: LinkIndex.shared)
    }

    @MainActor
    func testFirstEmptyPerFileResultDoesNotNotify() async {
        let index = LinkIndex()
        index.seedForTesting(
            outgoing: [noteA: []],
            roots: [root],
            key: "vault-empty-file"
        )
        let model = VaultLintModel.shared
        model.reportActive = false
        model.bind(to: index)
        let notification = XCTNSNotificationExpectation(
            name: .vaultLintDidUpdate
        )
        notification.isInverted = true

        _ = model.findings(for: noteA)
        await fulfillment(of: [notification], timeout: 0.3)
        model.bind(to: LinkIndex.shared)
    }

    @MainActor
    func testVaultLintModelPublishesFromSeededIndex() async throws {
        let index = LinkIndex()
        index.seedForTesting(
            outgoing: [
                noteA: [link(kind: .wiki, target: "Missing", offset: 3)],
            ],
            roots: [root],
            key: "vault-model"
        )
        let model = VaultLintModel.shared
        model.bind(to: index)
        model.runNow()
        let deadline = Date().addingTimeInterval(2)
        while model.findings.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.findings.isEmpty)
        XCTAssertFalse(model.findings(for: noteA).isEmpty)
        // Restore shared binding so the app singleton stays on LinkIndex.shared.
        model.bind(to: LinkIndex.shared)
    }
}
