import XCTest
@testable import EditMD

final class WikiLinkResolverTests: XCTestCase {

    private func makeTempVault() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wikitest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ name: String, in dir: URL) throws {
        try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func subdir(_ name: String, in root: URL) throws -> URL {
        let d = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testResolvesByBasenameCaseInsensitive() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Magnesium.md", in: root)

        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let hits = await resolver.resolve("magnesium")
        XCTAssertEqual(hits.map { $0.lastPathComponent }, ["Magnesium.md"])
    }

    func testResolvesRecursively() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Zinc.md", in: try subdir("nested", in: root))

        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let hits = await resolver.resolve("Zinc")
        XCTAssertEqual(hits.count, 1)
    }

    func testStripsMdSuffixAndFolderPath() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Iron.md", in: root)

        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let byExt = await resolver.resolve("Iron.md")
        let byPath = await resolver.resolve("some/folder/Iron")
        XCTAssertEqual(byExt.count, 1)
        XCTAssertEqual(byPath.count, 1)
    }

    func testUnresolvedReturnsEmpty() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let hits = await resolver.resolve("Nonexistent")
        XCTAssertTrue(hits.isEmpty)
    }

    func testMultipleMatchesSortedByPath() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("Dup.md", in: try subdir("a", in: root))
        try write("Dup.md", in: try subdir("b", in: root))

        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let hits = await resolver.resolve("dup")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits[0].path < hits[1].path)
    }

    func testTextbundleIsIndexedNotDescended() async throws {
        let root = try makeTempVault()
        defer { try? FileManager.default.removeItem(at: root) }
        // A .textbundle is a document (package): index it, don't walk inside.
        let bundle = try subdir("Note.textbundle", in: root)
        try write("text.md", in: bundle)  // internal file must NOT be indexed

        let resolver = WikiLinkResolver()
        await resolver.setRoots([root])
        let bundleHit = await resolver.resolve("Note")
        let inner = await resolver.resolve("text")
        XCTAssertEqual(bundleHit.count, 1)
        XCTAssertTrue(inner.isEmpty)
    }
}
