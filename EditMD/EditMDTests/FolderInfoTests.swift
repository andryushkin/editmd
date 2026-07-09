import XCTest
@testable import EditMD

final class FolderInfoTests: XCTestCase {

    // MARK: - FolderNaming

    func testMarkdownFileNameAppendsMd() throws {
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "Note"), "Note.md")
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "  Note  "), "Note.md")
    }

    func testMarkdownFileNameKeepsExistingExtension() throws {
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "Note.md"), "Note.md")
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "Note.markdown"), "Note.markdown")
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "Note.MD"), "Note.MD")
    }

    func testMarkdownFileNameRejectsEmptyAndPath() {
        XCTAssertThrowsError(try FolderNaming.markdownFileName(from: "  ")) { err in
            XCTAssertEqual(err as? FolderCreateError, .emptyName)
        }
        XCTAssertThrowsError(try FolderNaming.markdownFileName(from: "a/b")) { err in
            XCTAssertEqual(err as? FolderCreateError, .invalidName)
        }
        XCTAssertThrowsError(try FolderNaming.markdownFileName(from: "..")) { err in
            XCTAssertEqual(err as? FolderCreateError, .invalidName)
        }
        XCTAssertThrowsError(try FolderNaming.markdownFileName(from: "foo:bar")) { err in
            XCTAssertEqual(err as? FolderCreateError, .invalidName)
        }
    }

    func testFolderName() throws {
        XCTAssertEqual(try FolderNaming.folderName(from: "Notes"), "Notes")
        XCTAssertThrowsError(try FolderNaming.folderName(from: ""))
        XCTAssertThrowsError(try FolderNaming.folderName(from: "a/b"))
    }

    // MARK: - homeDocument

    func testHomeDocumentPrefersReadmeOverIndex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "i".write(to: dir.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(homeDocument(in: dir)?.lastPathComponent, "index.md")

        try "r".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(homeDocument(in: dir)?.lastPathComponent, "README.md")
    }

    func testHomeDocumentCaseInsensitiveReadme() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "r".write(to: dir.appendingPathComponent("ReadMe.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(homeDocument(in: dir)?.lastPathComponent, "ReadMe.md")
    }

    func testHomeDocumentNilWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "x".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(homeDocument(in: dir))
    }

    // MARK: - Recursive tree stats

    func testScanFolderTreeStatsRecursive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-stats-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("a").appendingPathComponent("b")
        let empty = root.appendingPathComponent("empty")
        let onlyTxt = root.appendingPathComponent("txt-only")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: onlyTxt, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "1".write(to: root.appendingPathComponent("root.md"), atomically: true, encoding: .utf8)
        try "2".write(to: nested.appendingPathComponent("deep.md"), atomically: true, encoding: .utf8)
        try "t".write(to: root.appendingPathComponent("skip.txt"), atomically: true, encoding: .utf8)
        try "t".write(to: onlyTxt.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        // Package counts as one markdown file, not a subfolder to descend.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("pack.textbundle"), withIntermediateDirectories: true)

        let stats = scanFolderTreeStats(at: root)
        // root.md + deep.md + pack.textbundle
        XCTAssertEqual(stats.markdownCount, 3)
        // a + a/b (have md in subtree). empty / txt-only / textbundle — not counted.
        XCTAssertEqual(stats.subfolderCount, 2)
    }

    func testScanFolderTreeStatsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = scanFolderTreeStats(at: root)
        XCTAssertEqual(stats.markdownCount, 0)
        XCTAssertEqual(stats.subfolderCount, 0)
    }
}

@MainActor
final class FolderCreateWorkspaceTests: XCTestCase {

    private var dir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-create-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        suiteName = "create-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testCreateMarkdownFileAndSubfolder() throws {
        let model = WorkspaceModel(defaults: defaults)
        model.addWorkspace(dir)

        let file = try model.createMarkdownFile(named: "Hello", in: dir)
        XCTAssertEqual(file.lastPathComponent, "Hello.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.markdownFiles(in: dir).map(\.lastPathComponent), ["Hello.md"])

        let sub = try model.createSubfolder(named: "Nested", in: dir)
        // Parent is a workspace root → expandWorkspace (collapsed flag), not
        // expandedFolders (that's for nested subfolders only).
        XCTAssertFalse(model.workspaces[0].collapsed)
        XCTAssertEqual(model.subfolders(in: dir).map(\.lastPathComponent), ["Nested"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sub.path))
    }

    func testCreateDuplicateThrows() throws {
        let model = WorkspaceModel(defaults: defaults)
        _ = try model.createMarkdownFile(named: "A.md", in: dir)
        XCTAssertThrowsError(try model.createMarkdownFile(named: "A", in: dir)) { err in
            XCTAssertEqual(err as? FolderCreateError, .alreadyExists("A.md"))
        }
    }
}
