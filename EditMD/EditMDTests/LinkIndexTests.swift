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
}
