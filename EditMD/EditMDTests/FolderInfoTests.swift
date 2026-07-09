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
