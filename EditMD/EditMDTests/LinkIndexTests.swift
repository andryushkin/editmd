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
        let resolved = LinkGraphEngine.resolveLink(raw, from: a, vaultRoot: root, wikiMatches: [])
        XCTAssertEqual(resolved.resolved, b)
        XCTAssertEqual(resolved.candidates, [b])
    }

    func testResolveWikiByBasename() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[Target]]\n", in: root)
        let t = try write("Target.md", "x\n", in: root)
        let raw = scanOutgoingLinks(text: "[[Target]]\n")[0]
        let resolved = LinkGraphEngine.resolveLink(
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
        let resolved = LinkGraphEngine.resolveLink(
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
        let resolved = LinkGraphEngine.resolveLink(
            raw, from: source, vaultRoot: root, wikiMatches: [other, sibling])
        XCTAssertEqual(resolved.resolved, sibling)
        XCTAssertEqual(resolved.candidates.count, 2)
    }

    func testResolveMissing() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[Nope]]\n", in: root)
        let raw = scanOutgoingLinks(text: "[[Nope]]\n")[0]
        let resolved = LinkGraphEngine.resolveLink(
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
        let resolved = LinkGraphEngine.resolveLink(
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
        let bl = LinkGraphEngine.projectBacklinks(from: [a: [link]])
        XCTAssertEqual(bl[b]?.count, 1)
        XCTAssertEqual(bl[b]?.first?.source, a)
    }

    func testBacklinksDropWhenUnresolved() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        let link = scanOutgoingLinks(text: "[[B]]\n")[0]
        let bl = LinkGraphEngine.projectBacklinks(from: [a: [link]])
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
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root])
        XCTAssertEqual(scanned.filesScanned, 3)
        XCTAssertEqual(scanned.outgoing[a]?.first?.rawTarget, "B")

        // Resolve via shared resolver roots.
        await WikiLinkResolver.shared.setRoots([root])
        var map: [URL: [OutgoingLink]] = [:]
        for (src, links) in scanned.outgoing {
            var resolved: [OutgoingLink] = []
            for link in links {
                let hits = await WikiLinkResolver.shared.resolve(link.rawTarget)
                resolved.append(LinkGraphEngine.resolveLink(
                    link, from: src, vaultRoot: root, wikiMatches: hits))
            }
            map[src] = resolved
        }
        let bl = LinkGraphEngine.projectBacklinks(from: map)
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
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root], maxBytes: 10)
        XCTAssertEqual(scanned.skipped, 1)
        XCTAssertEqual(scanned.filesScanned, 1)
    }

    func testScanCacheReparsesOnlyChangedFiles() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[B]]\n", in: root)
        _ = try write("b.md", "# Head\n", in: root)

        let first = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root])
        XCTAssertEqual(first.filesScanned, 2)
        XCTAssertEqual(first.newCache.count, 2)

        // Unchanged workspace: everything comes from the cache.
        let second = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root], cache: first.newCache)
        XCTAssertEqual(second.filesScanned, 0)
        XCTAssertEqual(second.outgoing[a]?.first?.rawTarget, "B")
        XCTAssertEqual(second.headings[root.appendingPathComponent("b.md")
            .standardizedFileURL], ["Head"])

        // Touch one file (content + mtime change) → only it re-parses.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: a.path)
        let third = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root], cache: second.newCache)
        XCTAssertEqual(third.filesScanned, 1)

        // Deleted file drops out of the fresh cache.
        try FileManager.default.removeItem(at: a)
        let fourth = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root], cache: third.newCache)
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
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root])
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
        let env = LinkGraphEngine.ResolveEnvironment(
            paths: [root.appendingPathComponent("notes").path,
                    root.appendingPathComponent("notes/b.md").path],
            walkedDirs: [root.path, fileDir.path],
            symlinks: [])
        // In-root candidates, first probe hits → covered.
        XCTAssertTrue(LinkGraphEngine.localResolutionCovered(
            "b.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // In-root miss (fingerprint would notice its creation) → covered.
        XCTAssertTrue(LinkGraphEngine.localResolutionCovered(
            "./missing.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Escapes the walked tree → not covered.
        XCTAssertFalse(LinkGraphEngine.localResolutionCovered(
            "../../outside.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Hidden name → not covered.
        XCTAssertFalse(LinkGraphEngine.localResolutionCovered(
            ".hidden.md", fileDir: fileDir, vaultRoot: root, environment: env))
        // Symlinked item → not covered (listing does not prove existence).
        let symEnv = LinkGraphEngine.ResolveEnvironment(
            paths: [root.appendingPathComponent("notes/b.md").path],
            walkedDirs: [root.path, fileDir.path],
            symlinks: [root.appendingPathComponent("notes/b.md").path])
        XCTAssertFalse(LinkGraphEngine.localResolutionCovered(
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
    func testColdLaunchFirstActivationDoesNotDoubleScan() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<10 {
            _ = try write("n\(i).md", "[[n\((i + 1) % 10)]]\n", in: root)
        }
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()

        // Launch: warm scan starts, then the process's first activation
        // arrives with NO prior resign — it must not defer a second rebuild.
        index.ensureIndex(workspace: workspace)
        let epoch0 = workspace.linkEpoch
        workspace.handleAppActivation(index: index)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(index.fullScanCount, 1,
                       "launch activation must not queue a second full scan")
        XCTAssertEqual(workspace.linkEpoch, epoch0)

        // A real background → foreground transition still re-keys.
        workspace.noteAppResignedActive()
        workspace.handleAppActivation(index: index)
        XCTAssertEqual(workspace.linkEpoch, epoch0 + 1)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(index.fullScanCount, 2)
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

    @MainActor
    func testIndexScopesToActiveWorkspaceAndKeepsCacheAcrossSwitch() async throws {
        let rootA = try tempRoot()
        let rootB = try tempRoot()
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let a1 = try write("a1.md", "[[a2]]\n", in: rootA)
        _ = try write("a2.md", "target\n", in: rootA)
        let b1 = try write("b1.md", "[[b2]]\n", in: rootB)
        _ = try write("b2.md", "target\n", in: rootB)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(rootA)
        workspace.addWorkspace(rootB)
        let index = LinkIndex()

        // No active document → the first workspace is the indexed one.
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(index.outgoing[a1])
        XCTAssertNil(index.outgoing[b1], "inactive workspace must not be scanned")

        // Activating a document in B re-keys the index to B only.
        workspace.noteActive(b1)
        index.ensureIndex(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 2),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(index.outgoing[b1])
        XCTAssertNil(index.outgoing[a1])

        // Back to A: parse and resolve caches for A survived the switch —
        // the rescan is stats-only (no files re-parsed, no fresh resolves).
        let parsedBefore = index.fileScanCount
        let resolvedBefore = index.freshResolveCount
        workspace.noteActive(a1)
        index.ensureIndex(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !(index.hasCompletedFullScan && index.fullScanCount == 3),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(index.outgoing[a1])
        XCTAssertEqual(
            index.outgoing[a1]?.first?.resolved,
            rootA.appendingPathComponent("a2.md").standardizedFileURL)
        XCTAssertEqual(index.fileScanCount, parsedBefore,
                       "returning to a workspace must not re-parse its files")
        XCTAssertEqual(index.freshResolveCount, resolvedBefore,
                       "returning to a workspace must not re-resolve its files")
    }

    // MARK: - Persisted index

    @MainActor
    func testPersistedIndexSeedsColdStart() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[b]] and [c](c.md)\n# Head A\n", in: root)
        let b = try write("b.md", "text\n", in: root)
        _ = try write("c.md", "text\n", in: root)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // The save runs detached after publication — wait for the file.
        let fileURL = LinkIndexPersistence.indexFileURL(root: root)
        deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fileURL.path),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let gitignore = root.appendingPathComponent(".editmd/.gitignore")
        XCTAssertEqual(try String(contentsOf: gitignore, encoding: .utf8), "*\n")

        // Fresh index (new "process"): the seed must make the scan stats-only
        // and the persisted fingerprint must still match (stable hash).
        let cold = LinkIndex()
        cold.ensureIndex(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !cold.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cold.fileScanCount, 0,
                       "seeded cold start must not re-parse unchanged files")
        XCTAssertEqual(cold.freshResolveCount, 0,
                       "persisted fingerprint must survive a new LinkIndex")
        XCTAssertEqual(cold.outgoing[a]?.map(\.rawTarget), ["b", "c.md"])
        XCTAssertEqual(cold.outgoing[a]?.first?.resolved, b)
        XCTAssertEqual(cold.headings[a], ["Head A"])
        XCTAssertEqual(cold.backlinkEdges(for: b).map(\.source), [a])
    }

    @MainActor
    func testPersistedIndexRevalidatesChangedAndIgnoresCorrupt() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try write("a.md", "[[b]]\n", in: root)
        _ = try write("b.md", "text\n", in: root)

        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.addWorkspace(root)
        let index = LinkIndex()
        index.ensureIndex(workspace: workspace)
        var deadline = Date().addingTimeInterval(5)
        while !index.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let fileURL = LinkIndexPersistence.indexFileURL(root: root)
        deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: fileURL.path),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        // External edit while "EditMD was closed": the stale entry must lose
        // to the live file on the next seeded scan.
        try Data("[[c]]\n".utf8).write(to: a)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: a.path)
        let cold = LinkIndex()
        cold.ensureIndex(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !cold.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cold.fileScanCount, 1, "only the changed file re-parses")
        XCTAssertEqual(cold.outgoing[a]?.map(\.rawTarget), ["c"])

        // Corrupt file: silently ignored, scan still completes correctly.
        try Data("not json".utf8).write(to: fileURL)
        let corrupt = LinkIndex()
        corrupt.ensureIndex(workspace: workspace)
        deadline = Date().addingTimeInterval(5)
        while !corrupt.hasCompletedFullScan, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(corrupt.outgoing[a]?.map(\.rawTarget), ["c"])
    }

    func testPersistenceEncodeIsDeterministicAndRelative() throws {
        let root = URL(fileURLWithPath: "/tmp/vault").standardizedFileURL
        let a = root.appendingPathComponent("notes/a.md")
        let b = root.appendingPathComponent("b.md")
        let link = OutgoingLink(
            kind: .wiki, rawTarget: "b", label: "b", line: 1,
            utf16Offset: 0, context: "[[b]]")
        var resolved = link
        resolved.resolved = b
        resolved.candidates = [b]
        var entry = LinkGraphEngine.FileScanEntry(
            mtime: Date(timeIntervalSinceReferenceDate: 700000000.123456),
            size: 6, links: [link], headings: ["H"])
        entry.resolvedLinks = [resolved]
        entry.resolveFingerprint = 42
        let outside = URL(fileURLWithPath: "/tmp/elsewhere/x.md")
        let cache = [a: entry, outside: entry]

        let first = LinkIndexPersistence.encode(cache: cache, root: root)
        let second = LinkIndexPersistence.encode(cache: cache, root: root)
        let json = try XCTUnwrap(first)
        // scannedAt differs between calls at second granularity; compare the
        // stable part: both payloads must decode to identical entries.
        let decodedA = LinkIndexPersistence.decode(json, root: root)
        let decodedB = LinkIndexPersistence.decode(try XCTUnwrap(second), root: root)
        XCTAssertEqual(decodedA.keys.sorted { $0.path < $1.path },
                       decodedB.keys.sorted { $0.path < $1.path })
        // Outside-root entries never persist.
        XCTAssertEqual(decodedA.count, 1)
        let restored = try XCTUnwrap(decodedA[a.standardizedFileURL])
        XCTAssertEqual(restored.mtime, entry.mtime, "mtime must be bit-exact")
        XCTAssertEqual(restored.size, 6)
        XCTAssertEqual(restored.headings, ["H"])
        XCTAssertEqual(restored.links.map(\.rawTarget), ["b"])
        XCTAssertNil(restored.links.first?.resolved,
                     "raw links must come back unresolved")
        XCTAssertEqual(restored.resolveFingerprint, 42)
        XCTAssertEqual(restored.resolvedLinks?.first?.resolved,
                       b.standardizedFileURL)
        // Relative paths only — the payload must not contain the root path.
        XCTAssertFalse(String(decoding: json, as: UTF8.self)
            .contains(root.path + "/"))
    }

    func testPersistenceDecodeRejectsEscapingPaths() throws {
        let root = URL(fileURLWithPath: "/tmp/vault").standardizedFileURL
        let payload = """
        {"version": 1, "scannedAt": "2026-07-19T00:00:00Z", "files": [
          {"path": "../escape.md", "mtimeBits": 0, "size": 1,
           "headings": [], "links": []},
          {"path": "/abs.md", "mtimeBits": 0, "size": 1,
           "headings": [], "links": []},
          {"path": "ok.md", "mtimeBits": 0, "size": 1,
           "headings": [], "links": []}
        ]}
        """
        let cache = LinkIndexPersistence.decode(Data(payload.utf8), root: root)
        XCTAssertEqual(cache.keys.map(\.lastPathComponent), ["ok.md"])
    }

    func testPersistenceDecodeRejectsEscapingResolvedPath() throws {
        let root = URL(fileURLWithPath: "/tmp/vault").standardizedFileURL
        // A valid entry whose cached resolution points OUTSIDE the root — the
        // attack the raw appendingPathComponent path allowed. The entry must
        // survive (raw links kept) but its resolve-info must be dropped so no
        // out-of-root URL reaches outgoing/backlinks.
        let payload = """
        {"version": 1, "scannedAt": "2026-07-19T00:00:00Z", "files": [
          {"path": "a.md", "mtimeBits": 0, "size": 1, "headings": [],
           "resolveFingerprint": 42,
           "links": [{"kind": "wiki", "rawTarget": "x", "label": "x",
             "line": 1, "utf16Offset": 0, "context": "[[x]]",
             "resolvedPath": "../outside.md"}]}
        ]}
        """
        let cache = LinkIndexPersistence.decode(Data(payload.utf8), root: root)
        let entry = try XCTUnwrap(cache[root.appendingPathComponent("a.md")])
        XCTAssertEqual(entry.links.map(\.rawTarget), ["x"], "raw links kept")
        XCTAssertNil(entry.resolvedLinks, "tainted resolution dropped wholesale")
        XCTAssertNil(entry.resolveFingerprint)
    }

    func testPersistenceDecodeRejectsEscapingCandidatePath() throws {
        let root = URL(fileURLWithPath: "/tmp/vault").standardizedFileURL
        let payload = """
        {"version": 1, "scannedAt": "2026-07-19T00:00:00Z", "files": [
          {"path": "a.md", "mtimeBits": 0, "size": 1, "headings": [],
           "resolveFingerprint": 42,
           "links": [{"kind": "wiki", "rawTarget": "x", "label": "x",
             "line": 1, "utf16Offset": 0, "context": "[[x]]",
             "candidatePaths": ["ok.md", "/etc/passwd"]}]}
        ]}
        """
        let cache = LinkIndexPersistence.decode(Data(payload.utf8), root: root)
        let entry = try XCTUnwrap(cache[root.appendingPathComponent("a.md")])
        XCTAssertNil(entry.resolvedLinks,
                     "an absolute candidate taints the whole entry's resolution")
    }

    func testStableFingerprintSurvivesVaultMove() {
        let rootA = URL(fileURLWithPath: "/tmp/vaultA").standardizedFileURL
        let rootB = URL(fileURLWithPath: "/tmp/moved/vaultB").standardizedFileURL
        func env(_ root: URL) -> (wiki: [String: [URL]], paths: Set<String>) {
            let b = root.appendingPathComponent("b.md")
            let dir = root.appendingPathComponent("reports")
            return (["b": [b]], [b.path, dir.path])
        }
        let a = env(rootA)
        let b = env(rootB)
        XCTAssertEqual(
            LinkGraphEngine.resolveEnvironmentFingerprint(
                roots: [rootA], wikiIndex: a.wiki, paths: a.paths),
            LinkGraphEngine.resolveEnvironmentFingerprint(
                roots: [rootB], wikiIndex: b.wiki, paths: b.paths),
            "fingerprint must depend on relative structure, not vault location")
        XCTAssertNotEqual(
            LinkGraphEngine.resolveEnvironmentFingerprint(
                roots: [rootA], wikiIndex: a.wiki, paths: a.paths),
            LinkGraphEngine.resolveEnvironmentFingerprint(
                roots: [rootA], wikiIndex: a.wiki,
                paths: a.paths.union([rootA.appendingPathComponent("new.md").path])),
            "adding an item must change the fingerprint")
    }

    @MainActor
    func testLooseFileNeverCreatesEditmdDirectory() async throws {
        let dir = try tempRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try write("loose.md", "[[other]]\n", in: dir)

        // No adopted workspace: single-file in-memory map only.
        let workspace = WorkspaceModel(
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let index = LinkIndex()
        index.noteDocumentPersisted(
            url: file, content: "[[other]]\n", workspace: workspace)
        let deadline = Date().addingTimeInterval(2)
        while index.fileScanCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(index.fileScanCount, 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(".editmd").path),
            "loose files must not build or persist a workspace index")
    }

    func testCoverageForSubdirectoryRelativeLink() throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        _ = try write("gamma.md", "# G\n", in: notes)
        _ = try write("alpha.md", "[c](notes/gamma.md)\n", in: root)
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root])
        XCTAssertTrue(LinkGraphEngine.localResolutionCovered(
            "notes/gamma.md",
            fileDir: root.standardizedFileURL,
            vaultRoot: root.standardizedFileURL,
            environment: scanned.environment),
            "walked dirs: \(scanned.environment.walkedDirs)")
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
        let scanned = LinkGraphEngine.scanWorkspaceOutgoing(roots: [root]) { done, total in
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
