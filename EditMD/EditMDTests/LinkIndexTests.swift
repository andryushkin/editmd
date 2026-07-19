import XCTest
@testable import EditMD

final class LinkIndexTests: XCTestCase {

    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("linkidx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ name: String, _ text: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    // MARK: - resolveLink

    func testResolveExactRelativeMarkdown() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[b](b.md)\n", in: root)
        let b = try write("b.md", "hi\n", in: root)
        let raw = scanOutgoingLinks(text: "see [b](b.md)\n")[0]
        let resolved = LinkIndex.resolveLink(raw, from: a, vaultRoot: root, wikiMatches: [])
        XCTAssertEqual(resolved.resolved, b)
        XCTAssertEqual(resolved.candidates, [b])
    }

    func testResolveWikiByBasename() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[Target]]\n", in: root)
        let t = try write("Target.md", "x\n", in: root)
        let raw = scanOutgoingLinks(text: "[[Target]]\n")[0]
        let resolved = LinkIndex.resolveLink(
            raw, from: a, vaultRoot: root, wikiMatches: [t])
        XCTAssertEqual(resolved.resolved, t)
    }

    func testResolveWikiAmbiguous() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let subA = root.appendingPathComponent("a")
        let subB = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: subA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: subB, withIntermediateDirectories: true)
        let source = try write("src.md", "[[Dup]]\n", in: root)
        let d1 = try write("Dup.md", "1\n", in: subA)
        let d2 = try write("Dup.md", "2\n", in: subB)
        let raw = scanOutgoingLinks(text: "[[Dup]]\n")[0]
        let resolved = LinkIndex.resolveLink(
            raw, from: source, vaultRoot: root, wikiMatches: [d1, d2])
        XCTAssertNil(resolved.resolved)
        XCTAssertEqual(Set(resolved.candidates.map(\.path)), Set([d1.path, d2.path]))
    }

    func testResolveWikiPrefersSibling() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let source = try write("src.md", "[[Dup]]\n", in: sub)
        let sibling = try write("Dup.md", "near\n", in: sub)
        let other = try write("Dup.md", "far\n", in: root)
        let raw = scanOutgoingLinks(text: "[[Dup]]\n")[0]
        let resolved = LinkIndex.resolveLink(
            raw, from: source, vaultRoot: root, wikiMatches: [other, sibling])
        XCTAssertEqual(resolved.resolved, sibling)
        XCTAssertEqual(resolved.candidates.count, 2)
    }

    func testResolveMissing() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[Nope]]\n", in: root)
        let raw = scanOutgoingLinks(text: "[[Nope]]\n")[0]
        let resolved = LinkIndex.resolveLink(
            raw, from: a, vaultRoot: root, wikiMatches: [])
        XCTAssertNil(resolved.resolved)
        XCTAssertTrue(resolved.candidates.isEmpty)
    }

    func testHeadingDoesNotBreakResolve() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[T#Head]]\n", in: root)
        let t = try write("T.md", "# Head\n", in: root)
        let raw = scanOutgoingLinks(text: "[[T#Head]]\n")[0]
        XCTAssertEqual(raw.heading, "Head")
        let resolved = LinkIndex.resolveLink(
            raw, from: a, vaultRoot: root, wikiMatches: [t])
        XCTAssertEqual(resolved.resolved, t)
        XCTAssertEqual(resolved.heading, "Head")
    }

    // MARK: - Backlinks projection

    func testBacklinksProjection() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        let b = try write("b.md", "x\n", in: root)
        var link = scanOutgoingLinks(text: "[[B]]\n")[0]
        link.resolved = b
        link.candidates = [b]
        let bl = LinkIndex.projectBacklinks(from: [a: [link]])
        XCTAssertEqual(bl[b]?.count, 1)
        XCTAssertEqual(bl[b]?.first?.source, a)
    }

    func testBacklinksDropWhenUnresolved() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        let link = scanOutgoingLinks(text: "[[B]]\n")[0]
        let bl = LinkIndex.projectBacklinks(from: [a: [link]])
        XCTAssertTrue(bl.isEmpty)
    }

    // MARK: - Workspace scan + incremental

    @MainActor
    func testFullScanAndIncrementalCounter() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        _ = try write("b.md", "target\n", in: root)
        _ = try write("c.md", "no links\n", in: root)

        let index = LinkIndex()
        let scanned = LinkIndex.scanWorkspaceOutgoing(roots: [root])
        XCTAssertEqual(scanned.filesScanned, 3)
        XCTAssertEqual(scanned.outgoing[a]?.first?.rawTarget, "B")

        // Resolve via shared resolver roots.
        await WikiLinkResolver.shared.setRoots([root])
        var map: [URL: [OutgoingLink]] = [:]
        for (src, links) in scanned.outgoing {
            var resolved: [OutgoingLink] = []
            for link in links {
                let hits = await WikiLinkResolver.shared.resolve(link.rawTarget)
                resolved.append(LinkIndex.resolveLink(
                    link, from: src, vaultRoot: root, wikiMatches: hits))
            }
            map[src] = resolved
        }
        let bl = LinkIndex.projectBacklinks(from: map)
        let bURL = root.appendingPathComponent("b.md").standardizedFileURL
        XCTAssertEqual(bl[bURL]?.count, 1)

        // Seed as completed full scan; empty-workspace model avoids full rebuild.
        index.seedForTesting(outgoing: map, key: "seed")
        let beforeFull = index.fullScanCount
        let beforeFile = index.fileScanCount
        let isolated = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        index.noteDocumentPersisted(
            url: a, content: "[[B]] and [[C]]\n", workspace: isolated)
        let deadline = Date().addingTimeInterval(2)
        while index.fileScanCount == beforeFile, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.fullScanCount, beforeFull,
                       "incremental path must not run a full workspace scan")
        XCTAssertGreaterThan(index.fileScanCount, beforeFile)
        XCTAssertEqual(index.outgoing[a]?.map(\.rawTarget), ["B", "C"])
    }

    func testScanSkipsOversized() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("small.md", "[[X]]\n", in: root)
        // maxBytes = 10 → any larger file skipped.
        let big = root.appendingPathComponent("big.md")
        try String(repeating: "a", count: 100).write(to: big, atomically: true, encoding: .utf8)
        let scanned = LinkIndex.scanWorkspaceOutgoing(roots: [root], maxBytes: 10)
        XCTAssertEqual(scanned.skipped, 1)
        XCTAssertEqual(scanned.filesScanned, 1)
    }

    func testScanCacheReparsesOnlyChangedFiles() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        _ = try write("b.md", "# Head\n", in: root)

        let first = LinkIndex.scanWorkspaceOutgoing(roots: [root])
        XCTAssertEqual(first.filesScanned, 2)
        XCTAssertEqual(first.newCache.count, 2)

        // Unchanged workspace: everything comes from the cache.
        let second = LinkIndex.scanWorkspaceOutgoing(roots: [root], cache: first.newCache)
        XCTAssertEqual(second.filesScanned, 0)
        XCTAssertEqual(second.outgoing[a]?.first?.rawTarget, "B")
        XCTAssertEqual(second.headings[root.appendingPathComponent("b.md")
            .standardizedFileURL], ["Head"])

        // Touch one file (content + mtime change) → only it re-parses.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: a.path)
        let third = LinkIndex.scanWorkspaceOutgoing(roots: [root], cache: second.newCache)
        XCTAssertEqual(third.filesScanned, 1)

        // Deleted file drops out of the fresh cache.
        try FileManager.default.removeItem(at: a)
        let fourth = LinkIndex.scanWorkspaceOutgoing(roots: [root], cache: third.newCache)
        XCTAssertEqual(fourth.newCache.count, 1)
        XCTAssertNil(fourth.outgoing[a])
    }

    func testPerfSmoke500Files() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // 200 files × ~20 links is enough for a smoke bound without long CI.
        let n = 200
        for i in 0..<n {
            var body = ""
            for j in 0..<20 {
                body += "[[N\(j)]] "
            }
            body += "\n"
            _ = try write("f\(i).md", body, in: root)
        }
        let start = CFAbsoluteTimeGetCurrent()
        let scanned = LinkIndex.scanWorkspaceOutgoing(roots: [root])
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(scanned.filesScanned, n)
        XCTAssertLessThan(elapsed, 5.0, "scan took \(elapsed)s")
    }

    @MainActor
    func testRepeatedEnsureIndexDoesNotRestartInFlightScan() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<20 {
            _ = try write("n\(i).md", "[[n\((i + 1) % 20)]]\n", in: root)
        }
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        // First call starts the scan; repeated calls with the same key
        // (opening files re-runs ensureIndex via onAppear) must neither
        // cancel it nor queue a rescan.
        index.ensureIndex(workspace: workspace)
        index.ensureIndex(workspace: workspace)
        index.ensureIndex(workspace: workspace)
        let deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(index.hasCompletedFullScan)
        // Let any (incorrectly) queued pending rescan surface before counting.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(index.fullScanCount, 1,
                       "same-key ensureIndex must reuse the in-flight scan")
    }

    @MainActor
    func testResolveCacheSkipsUnchangedFilesOnRescan() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var files: [URL] = []
        for i in 0..<6 {
            files.append(try write("n\(i).md", "[[n\((i + 1) % 6)]]\n", in: root))
        }
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.freshResolveCount, 6)

        // Rewrite ONE file (content + future mtime) and force a rebuild:
        // the unchanged five must come from the resolve cache.
        try Data("[[n3]]\n".utf8).write(to: files[0])
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: files[0].path)
        index.invalidate(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.fullScanCount, 2)
        XCTAssertEqual(index.freshResolveCount, 7,
                       "only the touched file may resolve fresh")
        // Cached resolution stays correct and the touched file re-resolved.
        let n3 = files[3].standardizedFileURL
        XCTAssertEqual(
            index.outgoing[files[0].standardizedFileURL]?.first?.resolved, n3)
        XCTAssertEqual(
            index.outgoing[files[1].standardizedFileURL]?.first?.resolved,
            files[2].standardizedFileURL)
    }

    @MainActor
    func testResolveCacheSeesNewRelativeDirectoryTarget() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[reports](./reports)\n", in: root)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(index.outgoing[a]?.first?.resolved, "no reports dir yet")

        // Create the directory the link points at. a.md itself is untouched
        // (same mtime/size) — only the environment fingerprint may notice.
        let reports = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(
            at: reports, withIntermediateDirectories: false)
        index.invalidate(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.outgoing[a]?.first?.resolved,
                       reports.standardizedFileURL,
                       "new directory target must invalidate the resolve cache")
    }

    @MainActor
    func testOutsideRootLinkIsNotResolveCached() async throws {
        let parent = try tempRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let a = try write("a.md", "[out](../outside.md)\n", in: root)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(index.outgoing[a]?.first?.resolved)

        // The target appears OUTSIDE the walked roots: the fingerprint cannot
        // see it, so such links must never be served from the resolve cache.
        _ = try write("outside.md", "hi\n", in: parent)
        index.invalidate(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.outgoing[a]?.first?.resolved,
                       parent.appendingPathComponent("outside.md").standardizedFileURL,
                       "uncovered links must re-resolve on every full scan")
    }

    func testLocalResolutionCoverage() throws {
        let root = URL(fileURLWithPath: "/tmp/vault").standardizedFileURL
        let fileDir = root.appendingPathComponent("notes")
        let env = LinkIndex.ResolveEnvironment(
            paths: [root.appendingPathComponent("notes").path,
                    root.appendingPathComponent("notes/b.md").path],
            walkedDirs: [root.path, fileDir.path],
            symlinks: [])
        // In-root candidates, first probe hits → covered.
        XCTAssertTrue(LinkIndex.localResolutionCovered(
            "b.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // In-root miss (fingerprint would notice its creation) → covered.
        XCTAssertTrue(LinkIndex.localResolutionCovered(
            "./missing.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Escapes the walked tree → not covered.
        XCTAssertFalse(LinkIndex.localResolutionCovered(
            "../../outside.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Hidden name → not covered.
        XCTAssertFalse(LinkIndex.localResolutionCovered(
            ".hidden.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Symlinked item → not covered (listing does not prove existence).
        let symEnv = LinkIndex.ResolveEnvironment(
            paths: [root.appendingPathComponent("notes/b.md").path],
            walkedDirs: [root.path, fileDir.path],
            symlinks: [root.appendingPathComponent("notes/b.md").path])
        XCTAssertFalse(LinkIndex.localResolutionCovered(
            "b.md", fileDir: fileDir, vaultRoot: root, environment: symEnv))
    }

    @MainActor
    func testActivationRefreshSeesExternalEditOfClosedFile() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[b]]\n", in: root)
        _ = try write("b.md", "target\n", in: root)
        _ = try write("c.md", "target\n", in: root)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.outgoing[a]?.map(\.rawTarget), ["b"])

        // External editor rewrites a CLOSED file while EditMD is in the
        // background; app activation must re-key and pick it up.
        try Data("[[c]]\n".utf8).write(to: a)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: a.path)
        let epochBefore = workspace.linkEpoch
        workspace.refreshLinkGraphAfterActivation(index: index)
        XCTAssertEqual(workspace.linkEpoch, epochBefore + 1)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.outgoing[a]?.map(\.rawTarget), ["c"])
        XCTAssertEqual(
            index.outgoing[a]?.first?.resolved,
            root.appendingPathComponent("c.md").standardizedFileURL)
    }

    @MainActor
    func testActivationRefreshWhileColdStaysLazy() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write("a.md", "[[b]]\n", in: root)
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()

        // Cold index (no consumer built or is building it): activation must
        // neither bump the epoch nor leave a deferred refresh behind.
        let epoch0 = workspace.linkEpoch
        workspace.refreshLinkGraphAfterActivation(index: index)
        XCTAssertEqual(workspace.linkEpoch, epoch0)

        index.ensureIndex(workspace: workspace)
        let deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(index.fullScanCount, 1,
                       "cold activation must not schedule a deferred rescan")
        XCTAssertEqual(workspace.linkEpoch, epoch0)
    }

    @MainActor
    func testActivationDuringScanDefersRebuildWithoutCancelling() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10 {
            _ = try write("n\(i).md", "[[n\((i + 1) % 10)]]\n", in: root)
        }
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()

        // Same main-actor turn as ensureIndex → the scan is guaranteed
        // in flight: the re-key must be deferred (no immediate bump, no
        // cancellation), then replayed once the scan finishes.
        index.ensureIndex(workspace: workspace)
        let epoch0 = workspace.linkEpoch
        workspace.refreshLinkGraphAfterActivation(index: index)
        XCTAssertEqual(workspace.linkEpoch, epoch0,
                       "mid-scan activation must not re-key immediately")
        let deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.fullScanCount, 2,
                       "deferred activation must rebuild exactly once after the scan")
        XCTAssertEqual(workspace.linkEpoch, epoch0 + 1)
        // One deferred replay only — no self-sustaining rescan loop.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(index.fullScanCount, 2)
    }

    func testScanReportsMonotonicProgress() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<5 {
            _ = try write("n\(i).md", "[[Other]]\n", in: root)
        }
        // onProgress is called synchronously from the scanning thread.
        final class Box: @unchecked Sendable { var reports: [(Int, Int)] = [] }
        let box = Box()
        let scanned = LinkIndex.scanWorkspaceOutgoing(roots: [root]) { done, total in
            box.reports.append((done, total))
        }
        XCTAssertEqual(scanned.filesScanned, 5)
        XCTAssertFalse(box.reports.isEmpty)
        XCTAssertTrue(box.reports.allSatisfy { $0.1 == 5 })
        XCTAssertEqual(box.reports.last?.0, 5, "final report must be done == total")
        let dones = box.reports.map(\.0)
        XCTAssertEqual(dones, dones.sorted(), "progress must be monotonic")
    }
}
