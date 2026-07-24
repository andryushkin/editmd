import XCTest
import Testing
import UniformTypeIdentifiers
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
        // Dot-prefixed names are hidden files — every listing would skip them.
        XCTAssertThrowsError(try FolderNaming.markdownFileName(from: ".hidden")) { err in
            XCTAssertEqual(err as? FolderCreateError, .hiddenName)
        }
    }

    func testFolderName() throws {
        XCTAssertEqual(try FolderNaming.folderName(from: "Notes"), "Notes")
        XCTAssertThrowsError(try FolderNaming.folderName(from: ""))
        XCTAssertThrowsError(try FolderNaming.folderName(from: "a/b"))
        XCTAssertThrowsError(try FolderNaming.folderName(from: ".git")) { err in
            XCTAssertEqual(err as? FolderCreateError, .hiddenName)
        }
    }

    func testRenamedFileNameKeepsOrRestoresExtension() throws {
        let original = URL(fileURLWithPath: "/tmp/note.md")
        // Explicit extension is respected as typed.
        XCTAssertEqual(
            try FolderNaming.renamedFileName(from: "renamed.md", keepingExtensionOf: original),
            "renamed.md")
        // A dropped extension is restored from the original.
        XCTAssertEqual(
            try FolderNaming.renamedFileName(from: "renamed", keepingExtensionOf: original),
            "renamed.md")
        XCTAssertEqual(
            try FolderNaming.renamedFileName(from: "  renamed  ", keepingExtensionOf: original),
            "renamed.md")
        // A different explicit extension is allowed.
        XCTAssertEqual(
            try FolderNaming.renamedFileName(from: "photo.png", keepingExtensionOf: original),
            "photo.png")
    }

    func testRenamedFileNameRejectsEmptyAndPath() {
        let original = URL(fileURLWithPath: "/tmp/note.md")
        XCTAssertThrowsError(
            try FolderNaming.renamedFileName(from: "  ", keepingExtensionOf: original)) { err in
            XCTAssertEqual(err as? FolderCreateError, .emptyName)
        }
        XCTAssertThrowsError(
            try FolderNaming.renamedFileName(from: "a/b", keepingExtensionOf: original)) { err in
            XCTAssertEqual(err as? FolderCreateError, .invalidName)
        }
        XCTAssertThrowsError(
            try FolderNaming.renamedFileName(from: "foo:bar", keepingExtensionOf: original)) { err in
            XCTAssertEqual(err as? FolderCreateError, .invalidName)
        }
        // A dot-prefixed rename would silently hide the file from the sidebar.
        XCTAssertThrowsError(
            try FolderNaming.renamedFileName(from: ".notes", keepingExtensionOf: original)) { err in
            XCTAssertEqual(err as? FolderCreateError, .hiddenName)
        }
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
        // Main grid: only direct child `a`. Empty / txt-only go to the bottom section.
        XCTAssertEqual(stats.directMarkdownFolders.map(\.lastPathComponent), ["a"])
        XCTAssertEqual(Set(stats.directEmptyFolders.map(\.lastPathComponent)),
                       Set(["empty", "txt-only"]))
    }

    func testScanFolderTreeStatsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stats = scanFolderTreeStats(at: root)
        XCTAssertEqual(stats.markdownCount, 0)
        XCTAssertEqual(stats.subfolderCount, 0)
        XCTAssertTrue(stats.directMarkdownFolders.isEmpty)
    }

    func testImageOnlyFolderIsNotClassifiedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-image-stats-\(UUID().uuidString)")
        let gallery = root.appendingPathComponent("gallery")
        try FileManager.default.createDirectory(at: gallery, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: gallery.appendingPathComponent("drawing.svg"))
        try Data().write(to: gallery.appendingPathComponent("photo.JPG"))

        let stats = scanFolderTreeStats(at: root)
        XCTAssertEqual(stats.markdownCount, 2)
        XCTAssertEqual(stats.subfolderCount, 1)
        XCTAssertEqual(stats.directMarkdownFolders.map(\.lastPathComponent), ["gallery"])
        XCTAssertTrue(stats.directEmptyFolders.isEmpty)
    }

    func testImageFileDetectionAndSidebarIcon() {
        XCTAssertTrue(isImageFile(URL(fileURLWithPath: "/tmp/vector.SVG")))
        XCTAssertTrue(isImageFile(URL(fileURLWithPath: "/tmp/photo.jpeg")))
        XCTAssertFalse(isImageFile(URL(fileURLWithPath: "/tmp/note.md")))
        XCTAssertEqual(sidebarFileIcon(for: URL(fileURLWithPath: "/tmp/photo.webp")), "photo")
    }
}

@Suite("Folder creation")
@MainActor
struct FolderCreateWorkspaceTests {

    @Test("Creates a markdown file and subfolder")
    func createMarkdownFileAndSubfolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.directory)

        let file = try model.createMarkdownFile(
            named: "Hello", in: fixture.directory)
        #expect(file.lastPathComponent == "Hello.md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(model.primeFolderListing(fixture.directory).map(\.lastPathComponent)
            == ["Hello.md"])

        let sub = try model.createSubfolder(
            named: "Nested", in: fixture.directory)
        // Parent is a workspace root → expandWorkspace (collapsed flag), not
        // expandedFolders (that's for nested subfolders only).
        #expect(!model.workspaces[0].collapsed)
        #expect(model.subfolders(in: fixture.directory).map(\.lastPathComponent)
            == ["Nested"])
        #expect(FileManager.default.fileExists(atPath: sub.path))
    }

    @Test("Duplicate markdown name fails")
    func createDuplicateThrows() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        _ = try model.createMarkdownFile(named: "A.md", in: fixture.directory)

        #expect(throws: FolderCreateError.alreadyExists("A.md")) {
            try model.createMarkdownFile(named: "A", in: fixture.directory)
        }
    }

    @Test("Built-in templates render placeholders and valid frontmatter")
    func templatesRenderPlaceholders() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 16)))

        for template in FileTemplate.allCases where template != .blank && template != .daily {
            let name = "Bob's \(template.rawValue)"
            let url = try model.createMarkdownFile(
                named: name,
                in: fixture.directory,
                template: template,
                date: date,
                calendar: calendar)
            let content = try String(contentsOf: url, encoding: .utf8)
            #expect(!content.contains("{{date}}"))
            #expect(!content.contains("{{title}}"))
            #expect(!content.contains("{{yamlTitle}}"))
            #expect(content.contains("2026-07-16"))
            #expect(content.contains("title: 'Bob''s \(template.rawValue)'"))
            #expect(content.contains("# Bob's \(template.rawValue)"))
            let range = try #require(frontmatterRange(in: content))
            let body = (content as NSString).substring(with: range.body)
            #expect(!parseFrontmatterProperties(body).isEmpty)
        }
    }

    @Test("Daily note reopens today's file without overwriting it")
    func dailyTemplateDeduplicates() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 7, day: 16)))

        let first = try model.createMarkdownFile(
            named: "ignored",
            in: fixture.directory,
            template: .daily,
            date: date,
            calendar: calendar)
        try "kept".write(to: first, atomically: true, encoding: .utf8)
        let epoch = model.contentEpoch
        let second = try model.createMarkdownFile(
            named: "also ignored",
            in: fixture.directory,
            template: .daily,
            date: date,
            calendar: calendar)

        #expect(first == second)
        #expect(first.lastPathComponent == "2026-07-16.md")
        #expect(try String(contentsOf: second, encoding: .utf8) == "kept")
        #expect(model.contentEpoch == epoch)
    }

    @Test("Creates and adopts a new workspace folder")
    func createWorkspaceFolderCreatesAndAdoptsRoot() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)

        let folder = try model.createWorkspaceFolder(
            named: "New Notes", in: fixture.directory)

        #expect(folder == fixture.directory
            .appendingPathComponent("New Notes").standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(model.workspaces.map(\.folderPath) == [folder.path])
    }

    @Test("Existing workspace folder is rejected")
    func createWorkspaceFolderRejectsExistingFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        try FileManager.default.createDirectory(
            at: fixture.directory.appendingPathComponent("Existing"),
            withIntermediateDirectories: false)

        #expect(throws: FolderCreateError.alreadyExists("Existing")) {
            try model.createWorkspaceFolder(
                named: "Existing", in: fixture.directory)
        }
        #expect(model.workspaces.isEmpty)
    }

    private struct Fixture {
        let directory: URL
        let suiteName: String
        let defaults: UserDefaults

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("editmd-create-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            suiteName = "create-\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suiteName))
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Workspace folder identity")
@MainActor
struct WorkspaceFolderIdentityTests {

    @Test("Display name is independent from the folder name")
    func displayNameCanBeChangedAndCleared() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)

        let original = try #require(model.workspaces.first)
        #expect(original.folderName == "Notes")
        #expect(original.displayName == nil)
        #expect(original.name == "Notes")

        model.setDisplayName("Research", for: original)
        #expect(model.workspaces.first?.folderName == "Notes")
        #expect(model.workspaces.first?.displayName == "Research")
        #expect(model.workspaces.first?.name == "Research")

        model.setDisplayName("   ", for: try #require(model.workspaces.first))
        #expect(model.workspaces.first?.displayName == nil)
        #expect(model.workspaces.first?.name == "Notes")
    }

    @Test("Disk rename migrates path-keyed workspace state")
    func diskRenameMigratesWorkspaceState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let child = fixture.root.appendingPathComponent("Child", isDirectory: true)
        let note = child.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
        try "text".write(to: note, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)
        let original = try #require(model.workspaces.first)
        model.setDisplayName("Research", for: original)
        model.hiddenFiles[fixture.root.path] = ["Child/note.md"]
        model.addFavorite(note)
        model.expandedFolders.insert(child.path)
        model.noteActive(child)
        model.snapshot.update(path: fixture.root.path) { entry in
            entry.files = [note.path]
            entry.mdFolders = [child.path]
        }

        let renamed = try await model.renameFolderOnDisk(
            original, to: "Archive", openDocumentURLs: [])
        let renamedChild = renamed.appendingPathComponent("Child", isDirectory: true)

        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(FileManager.default.fileExists(atPath: renamedChild.path))
        #expect(model.workspaces.first?.folderPath == renamed.path)
        #expect(model.workspaces.first?.folderName == "Archive")
        #expect(model.workspaces.first?.displayName == "Research")
        #expect(model.hiddenFiles[renamed.path] == ["Child/note.md"])
        #expect(model.hiddenFiles[fixture.root.path] == nil)
        #expect(model.isFavorite(renamedChild.appendingPathComponent("note.md")))
        #expect(!model.isFavorite(note))
        #expect(model.expandedFolders == [renamedChild.path])
        #expect(model.lastActivePath == renamedChild.path)
        #expect(model.snapshot.entry(for: fixture.root.path) == nil)
        #expect(model.snapshot.entry(for: renamed.path)?.files == [
            renamedChild.appendingPathComponent("note.md").path
        ])
        #expect(model.snapshot.entry(for: renamed.path)?.mdFolders == [renamedChild.path])
    }

    @Test("Disk rename is blocked while a document inside is open")
    func diskRenameRejectsOpenDocuments() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let note = fixture.root.appendingPathComponent("note.md")
        try "text".write(to: note, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)
        let original = try #require(model.workspaces.first)

        do {
            _ = try await model.renameFolderOnDisk(
                original, to: "Archive", openDocumentURLs: [note])
            Issue.record("Expected an open-document error")
        } catch {
            #expect(error as? FolderRenameError == .openDocuments(1))
        }

        #expect(FileManager.default.fileExists(atPath: fixture.root.path))
        #expect(model.workspaces.first?.folderPath == fixture.root.path)
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-rename-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "rename-\(UUID().uuidString)"
        return Fixture(parent: parent, root: root, suiteName: suiteName,
                       defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("File moves")
@MainActor
struct FileMoveTests {

    @Test("Move crosses workspaces and preserves hidden review state")
    func moveAcrossWorkspaces() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.first.appendingPathComponent("note.md")
        let sourceSidecar = ReviewSidecar.url(for: source)
        let existing = fixture.second.appendingPathComponent("alpha.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        try "marks".write(to: sourceSidecar, atomically: true, encoding: .utf8)
        try "existing".write(to: existing, atomically: true, encoding: .utf8)

        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)
        model.hide(source)
        model.noteActive(source)
        model.snapshot.update(path: fixture.first.path) { $0.files = [source.path] }
        model.snapshot.update(path: fixture.second.path) { $0.files = [existing.path] }

        let destination = try await model.moveFileOnDisk(
            source, to: fixture.second)
        let destinationSidecar = ReviewSidecar.url(for: destination)

        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: sourceSidecar.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: destinationSidecar.path))
        #expect(model.hiddenFiles[fixture.first.path] == nil)
        #expect(model.hiddenFiles[fixture.second.path] == ["note.md"])
        #expect(model.lastActivePath == destination.path)
        #expect(model.snapshot.entry(for: fixture.first.path)?.files == [])
        #expect(model.snapshot.entry(for: fixture.second.path)?.files == [
            existing.path, destination.path
        ])
    }

    @Test("Move never overwrites an existing destination")
    func moveRejectsCollision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.first.appendingPathComponent("note.md")
        let existing = fixture.second.appendingPathComponent("note.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "destination".write(to: existing, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)

        do {
            _ = try await model.moveFileOnDisk(
                source, to: fixture.second)
            Issue.record("Expected a destination collision")
        } catch {
            #expect(error as? FileMoveError == .alreadyExists("note.md"))
        }

        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "destination")
    }

    @Test("Open document is saved and its model follows the moved path")
    func openDocumentFollowsMove() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.first.appendingPathComponent("note.md")
        try "disk".write(to: source, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)
        let registry = DocumentRegistry()
        let document = try registry.acquire(source)
        document.content = "edited"
        registry.markDirty(source)

        let preparation = try #require(
            try registry.beginMovePreparation(source))
        try await registry.persistMovePreparation(preparation)
        #expect(!registry.isOpen(source))
        #expect(try String(contentsOf: source, encoding: .utf8) == "edited")

        let destination = try await model.moveFileOnDisk(source, to: fixture.second)
        registry.relocatePreparedDocument(from: source, to: destination)
        let reopened = try registry.acquire(destination)

        #expect(reopened === document)
        #expect(reopened.content == "edited")
        #expect(registry.isOpen(destination))
        registry.release(destination)
    }

    @Test("Moving a pinned loose file into a workspace clears loose state")
    func looseFileBecomesWorkspaceFile() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.parent.appendingPathComponent("loose.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.second)
        model.noteOpened(source)
        model.pin(source)

        let destination = try await model.moveFileOnDisk(
            source, to: fixture.second)

        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!model.isPinned(destination))
        #expect(!model.looseFilesToShow.contains(destination))
    }

    @Test("Moving a favorite preserves it at the destination workspace")
    func favoriteFollowsMove() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.first.appendingPathComponent("favorite.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)
        model.addFavorite(source)

        let destination = try await model.moveFileOnDisk(source, to: fixture.second)

        #expect(!model.isFavorite(source))
        #expect(model.isFavorite(destination))
        #expect(model.favoriteFiles == [destination])
    }

    @Test("Batch move accepts files from different folders and workspaces")
    func batchMoveAcrossFolders() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let nested = fixture.first.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = fixture.first.appendingPathComponent("first.md")
        let second = nested.appendingPathComponent("second.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)
        model.hide(second)

        let moves = try await model.moveFilesOnDisk(
            [first, second], to: fixture.second)

        #expect(moves.map(\.source) == [first, second])
        #expect(moves.map(\.destination) == [
            fixture.second.appendingPathComponent("first.md"),
            fixture.second.appendingPathComponent("second.md")
        ])
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try String(contentsOf: moves[0].destination, encoding: .utf8) == "first")
        #expect(try String(contentsOf: moves[1].destination, encoding: .utf8) == "second")
        #expect(model.hiddenFiles[fixture.first.path] == nil)
        #expect(model.hiddenFiles[fixture.second.path] == ["second.md"])
    }

    @Test("Batch collision is rejected before any source moves")
    func batchRejectsDuplicateBasenamesAtomically() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let nested = fixture.first.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let first = fixture.first.appendingPathComponent("same.md")
        let second = nested.appendingPathComponent("same.md")
        try "first".write(to: first, atomically: true, encoding: .utf8)
        try "second".write(to: second, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)

        do {
            _ = try await model.moveFilesOnDisk([first, second], to: fixture.second)
            Issue.record("Expected a duplicate destination collision")
        } catch {
            #expect(error as? FileMoveError == .alreadyExists("same.md"))
        }

        #expect(try String(contentsOf: first, encoding: .utf8) == "first")
        #expect(try String(contentsOf: second, encoding: .utf8) == "second")
        #expect(!FileManager.default.fileExists(
            atPath: fixture.second.appendingPathComponent("same.md").path))
    }

    @Test("Multiple open document models follow a batch move")
    func openDocumentsFollowBatchMove() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let first = fixture.first.appendingPathComponent("first.md")
        let second = fixture.first.appendingPathComponent("second.md")
        try "disk one".write(to: first, atomically: true, encoding: .utf8)
        try "disk two".write(to: second, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.first)
        model.addWorkspace(fixture.second)
        let registry = DocumentRegistry()
        let firstDocument = try registry.acquire(first)
        let secondDocument = try registry.acquire(second)
        firstDocument.content = "edited one"
        secondDocument.content = "edited two"
        registry.markDirty(first)
        registry.markDirty(second)

        let firstPreparation = try #require(
            try registry.beginMovePreparation(first))
        let secondPreparation = try #require(
            try registry.beginMovePreparation(second))
        try await registry.persistMovePreparation(firstPreparation)
        try await registry.persistMovePreparation(secondPreparation)
        let moves = try await model.moveFilesOnDisk([first, second], to: fixture.second)
        for move in moves {
            registry.relocatePreparedDocument(from: move.source, to: move.destination)
        }
        let reopenedFirst = try registry.acquire(moves[0].destination)
        let reopenedSecond = try registry.acquire(moves[1].destination)

        #expect(reopenedFirst === firstDocument)
        #expect(reopenedSecond === secondDocument)
        #expect(reopenedFirst.content == "edited one")
        #expect(reopenedSecond.content == "edited two")
        registry.release(moves[0].destination)
        registry.release(moves[1].destination)
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-file-move-\(UUID().uuidString)",
                                    isDirectory: true)
        let first = parent.appendingPathComponent("First", isDirectory: true)
        let second = parent.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let suiteName = "file-move-\(UUID().uuidString)"
        return Fixture(parent: parent, first: first, second: second,
                       suiteName: suiteName,
                       defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private struct Fixture {
        let parent: URL
        let first: URL
        let second: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("File rename")
@MainActor
struct FileRenameTests {

    @Test("Rename moves the file and its review sidecar, migrating state")
    func renameKeepsSidecarAndState() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.md")
        let sourceSidecar = ReviewSidecar.url(for: source)
        try "text".write(to: source, atomically: true, encoding: .utf8)
        try "marks".write(to: sourceSidecar, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)
        model.hide(source)
        model.addFavorite(source)
        model.noteActive(source)

        // Extension is restored from the original when the new name omits one.
        let destination = try await model.renameFileOnDisk(source, to: "renamed")
        let destinationSidecar = ReviewSidecar.url(for: destination)

        #expect(destination == fixture.root
            .appendingPathComponent("renamed.md").standardizedFileURL)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: sourceSidecar.path))
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(FileManager.default.fileExists(atPath: destinationSidecar.path))
        #expect(model.hiddenFiles[fixture.root.path] == ["renamed.md"])
        #expect(!model.isFavorite(source))
        #expect(model.isFavorite(destination))
        #expect(model.lastActivePath == destination.path)
    }

    @Test("Rename refuses to overwrite an existing sibling")
    func renameRejectsCollision() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.md")
        let existing = fixture.root.appendingPathComponent("taken.md")
        try "source".write(to: source, atomically: true, encoding: .utf8)
        try "existing".write(to: existing, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)

        do {
            _ = try await model.renameFileOnDisk(source, to: "taken")
            Issue.record("Expected a destination collision")
        } catch {
            #expect(error as? FileMoveError == .alreadyExists("taken.md"))
        }
        #expect(try String(contentsOf: source, encoding: .utf8) == "source")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "existing")
    }

    @Test("Rename to the same effective name is a no-op")
    func renameSameNameNoOp() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.md")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)

        let destination = try await model.renameFileOnDisk(source, to: "note")
        #expect(destination == source)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("Case-only rename changes the spelling on disk and keeps the sidecar")
    func caseOnlyFileRename() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.md")
        let sourceSidecar = ReviewSidecar.url(for: source)
        try "text".write(to: source, atomically: true, encoding: .utf8)
        try "marks".write(to: sourceSidecar, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)

        let destination = try await model.renameFileOnDisk(source, to: "NOTE.md")

        #expect(destination.lastPathComponent == "NOTE.md")
        // Probe the real on-disk spelling via a directory listing — both a
        // case-insensitive fileExists and resourceValues(.nameKey) on a URL
        // that existed before the move report the stale name.
        let listing = Set(try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.path))
        #expect(listing.contains("NOTE.md"))
        #expect(listing.contains("NOTE.md.review.json"))
        #expect(!listing.contains("note.md"))
        #expect(try String(contentsOf: destination, encoding: .utf8) == "text")
        #expect(try String(
            contentsOf: ReviewSidecar.url(for: destination),
            encoding: .utf8) == "marks")
    }

    @Test("Exact-spelling probe distinguishes case-only aliases")
    func directoryEntryExistsIsCaseExact() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("note.md")
        try "text".write(to: file, atomically: true, encoding: .utf8)

        #expect(WorkspaceModel.directoryEntryExists(file))
        let alias = fixture.root.appendingPathComponent("NOTE.md")
        // On a case-insensitive volume fileExists(alias) is true; the exact
        // probe must still say the NOTE.md entry does not exist. On a
        // case-sensitive volume both probes agree.
        #expect(!WorkspaceModel.directoryEntryExists(alias))
        #expect(!WorkspaceModel.directoryEntryExists(
            fixture.root.appendingPathComponent("missing.md")))
    }

    @Test("Case-only rollback failure follows the surviving spelling")
    func caseOnlyRollbackFailureKeepsDestination() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.md")
        let sourceSidecar = ReviewSidecar.url(for: source)
        try "text".write(to: source, atomically: true, encoding: .utf8)
        try "marks".write(to: sourceSidecar, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)
        model.hide(source)
        let destination = fixture.root
            .appendingPathComponent("NOTE.md").standardizedFileURL

        // Fail the sidecar's first hop, then the file rollback's first hop:
        // the document survives only under the NEW spelling while the sidecar
        // keeps the old one.
        struct InjectedFailure: Error {}
        let failingMove: FileMoveItemOperation = { from, to in
            if from.lastPathComponent == "note.md.review.json" { throw InjectedFailure() }
            if from.lastPathComponent == "NOTE.md" { throw InjectedFailure() }
            try FileManager.default.moveItem(at: from, to: to)
        }

        do {
            _ = try await model.renameFileOnDisk(
                source, to: "NOTE.md", moveItem: failingMove)
            Issue.record("Expected a rollback failure")
        } catch {
            guard let moveError = error as? FileMoveError,
                  case .rollbackFailed(let states) = moveError else {
                Issue.record("Expected rollbackFailed, got \(error)")
                return
            }
            // Exact-spelling probes: the file is only at the destination.
            let state = try #require(states.first)
            #expect(!state.fileAtSource)
            #expect(state.fileAtDestination)
            #expect(state.reviewSidecarAtSource)
            #expect(!state.reviewSidecarAtDestination)
            // For a case-only pair the sidecar's spelling is not a split
            // state — the classifier follows the sole surviving spelling.
            let resolution = fileMoveRecoveryResolutions(
                for: [source], after: error)[source]
            #expect(resolution == .destination(destination))
        }

        // Sidebar state migrated to the surviving spelling.
        #expect(model.hiddenFiles[fixture.root.path] == ["NOTE.md"])
        // Disk: document under the new spelling, sidecar under the old one.
        let listing = Set(try FileManager.default.contentsOfDirectory(
            atPath: fixture.root.path))
        #expect(listing.contains("NOTE.md"))
        #expect(listing.contains("note.md.review.json"))
    }

    @Test("Rename refuses a file EditMD does not list")
    func renameRejectsUnsupported() async throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("note.txt")
        try "text".write(to: source, atomically: true, encoding: .utf8)
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)

        do {
            _ = try await model.renameFileOnDisk(source, to: "renamed")
            Issue.record("Expected an unsupported-source error")
        } catch {
            #expect(error as? FileMoveError == .unsupportedSource)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-rename-file-\(UUID().uuidString)",
                                    isDirectory: true)
        let root = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "rename-file-\(UUID().uuidString)"
        return Fixture(parent: parent, root: root, suiteName: suiteName,
                       defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Folder trash")
@MainActor
struct FolderTrashTests {

    @Test("Open-document count sees only files at or inside the folder")
    func openDocumentCountInsideOnly() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sub = fixture.root.appendingPathComponent("Sub", isDirectory: true)
        let inside = sub.appendingPathComponent("inside.md")
        let outside = fixture.root.appendingPathComponent("outside.md")
        let model = WorkspaceModel(defaults: fixture.defaults)

        #expect(model.openDocumentCount(inside: sub, among: [inside, outside]) == 1)
        #expect(model.openDocumentCount(inside: sub, among: [outside]) == 0)
    }

    @Test("Forgetting a trashed folder drops roots, favorites and expansion inside it")
    func forgetTrashedFolderPurgesState() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let sub = fixture.root.appendingPathComponent("Sub", isDirectory: true)
        let nestedRoot = sub.appendingPathComponent("Nested", isDirectory: true)
        let insideFile = sub.appendingPathComponent("note.md")
        let keepFile = fixture.root.appendingPathComponent("keep.md")
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.addWorkspace(fixture.root)   // ancestor root — kept
        model.addWorkspace(nestedRoot)     // adopted root inside Sub — dropped
        model.addFavorite(insideFile)
        model.addFavorite(keepFile)
        model.expandFolder(sub)
        model.noteActive(insideFile)

        model.forgetTrashedFolder(sub)

        #expect(model.workspaces.map(\.folderPath) == [fixture.root.path])
        #expect(!model.isFavorite(insideFile))
        #expect(model.isFavorite(keepFile))
        #expect(!model.expandedFolders.contains(sub.path))
        #expect(model.lastActivePath == nil)
    }

    @Test("Unsaved changes are visible for open and parked documents inside a folder")
    func hasUnsavedChangesInsideFolder() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let file = fixture.root.appendingPathComponent("draft.md")
        try "disk".write(to: file, atomically: true, encoding: .utf8)
        let registry = DocumentRegistry()

        #expect(!registry.hasUnsavedChanges(inside: fixture.root))
        let document = try registry.acquire(file)
        document.content = "edited"
        registry.markDirty(file)
        #expect(registry.hasUnsavedChanges(inside: fixture.root))
        let outside = fixture.parent.appendingPathComponent("Other", isDirectory: true)
        #expect(!registry.hasUnsavedChanges(inside: outside))

        // Parked (move-prepared) documents keep their dirty flag too.
        let preparation = try #require(try registry.beginMovePreparation(file))
        #expect(registry.hasUnsavedChanges(inside: fixture.root))
        registry.cancelMovePreparation(preparation)
        registry.release(file)
    }

    @Test("Line-change baselines under a trashed folder are forgotten")
    func lineChangeTrackerForgetsUnderRoot() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let inside = fixture.root.appendingPathComponent("inside.md")
        let outside = fixture.parent.appendingPathComponent("outside.md")
        let tracker = LineChangeTracker.shared
        tracker.noteBaseline(url: inside, content: "a\nb\n")
        tracker.noteContent(url: inside, content: "a\nchanged\n")
        tracker.noteBaseline(url: outside, content: "x\n")
        defer { tracker.forget(url: outside) }

        #expect(!tracker.dirtyLines(for: inside).isEmpty)
        tracker.forget(under: fixture.root)

        #expect(tracker.dirtyLines(for: inside).isEmpty)
        #expect(!tracker.trackedURLs().contains(inside.standardizedFileURL))
        #expect(tracker.trackedURLs().contains(outside.standardizedFileURL))
    }

    @Test("Forgetting a trashed folder drops loose and pinned files inside it")
    func forgetTrashedFolderDropsLoose() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let looseDir = fixture.parent.appendingPathComponent("Loose", isDirectory: true)
        let looseFile = looseDir.appendingPathComponent("x.md")
        let model = WorkspaceModel(defaults: fixture.defaults)
        model.noteOpened(looseFile)
        model.pin(looseFile)
        #expect(model.isPinned(looseFile))

        model.forgetTrashedFolder(looseDir)

        #expect(!model.isPinned(looseFile))
        #expect(!model.looseFilesToShow.contains(looseFile.standardizedFileURL))
    }

    private func makeFixture() throws -> Fixture {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-folder-trash-\(UUID().uuidString)",
                                    isDirectory: true)
        let root = parent.appendingPathComponent("Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suiteName = "folder-trash-\(UUID().uuidString)"
        return Fixture(parent: parent, root: root, suiteName: suiteName,
                       defaults: try #require(UserDefaults(suiteName: suiteName)))
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let suiteName: String
        let defaults: UserDefaults

        func cleanup() {
            try? FileManager.default.removeItem(at: parent)
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}

@Suite("Sidebar file selection")
@MainActor
struct SidebarFileSelectionTests {

    @Test("Command-click toggles without opening")
    func commandClickTogglesSelection() {
        let first = URL(fileURLWithPath: "/tmp/first.md")
        var selection = Set<URL>()
        var anchor: URL?

        #expect(!updateSidebarFileSelection(
            for: first, commandHeld: true, shiftHeld: false,
            orderedFiles: [first], selectedFiles: &selection,
            selectionAnchor: &anchor))
        #expect(selection == [first])
        #expect(anchor == first)
        #expect(!updateSidebarFileSelection(
            for: first, commandHeld: true, shiftHeld: false,
            orderedFiles: [first], selectedFiles: &selection,
            selectionAnchor: &anchor))
        #expect(selection.isEmpty)
    }

    @Test("Normal click replaces the group, selects, and opens the row")
    func normalClickReplacesSelection() {
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        var selection: Set<URL> = [first, second]
        var anchor: URL? = second

        #expect(updateSidebarFileSelection(
            for: first, commandHeld: false, shiftHeld: false,
            orderedFiles: [first, second], selectedFiles: &selection,
            selectionAnchor: &anchor))
        #expect(selection == [first])
        #expect(anchor == first)
    }

    @Test("Shift-click selects the visible range from the anchor")
    func shiftClickSelectsRange() {
        let files = (1...4).map { URL(fileURLWithPath: "/tmp/\($0).md") }
        var selection: Set<URL> = [files[0]]
        var anchor: URL? = files[0]

        #expect(!updateSidebarFileSelection(
            for: files[2], commandHeld: false, shiftHeld: true,
            orderedFiles: files, selectedFiles: &selection,
            selectionAnchor: &anchor))
        #expect(selection == Set(files[0...2]))
        #expect(anchor == files[0])

        #expect(!updateSidebarFileSelection(
            for: files[1], commandHeld: false, shiftHeld: true,
            orderedFiles: files, selectedFiles: &selection,
            selectionAnchor: &anchor))
        #expect(selection == Set(files[0...1]))
    }

    @Test("A selected drag carries the whole stable group")
    func selectedDragCarriesGroup() {
        let first = URL(fileURLWithPath: "/tmp/a/first.md")
        let second = URL(fileURLWithPath: "/tmp/b/second.md")
        let selection: Set<URL> = [second, first]

        #expect(sidebarMoveFiles(
            anchor: first,
            selectedFiles: selection,
            orderedFiles: [first, second]
        ) == [first, second])
        #expect(sidebarMoveFiles(
            anchor: URL(fileURLWithPath: "/tmp/third.md"),
            selectedFiles: selection,
            orderedFiles: [first, second]
        ) == [URL(fileURLWithPath: "/tmp/third.md")])
    }

    @Test("Move menu title counts the selection without the sidebar order")
    func moveMenuTitleFromSelectionOnly() {
        let first = URL(fileURLWithPath: "/tmp/a/first.md")
        let second = URL(fileURLWithPath: "/tmp/b/second.md")
        let outsider = URL(fileURLWithPath: "/tmp/third.md")

        // Anchor not selected → single-file wording.
        #expect(sidebarMoveMenuTitle(anchor: outsider,
                                     selectedFiles: [first, second])
                == "Move…")
        // Anchor inside a multi-selection → count = whole selection
        // (same count sidebarMoveFiles would return, without walking the tree).
        #expect(sidebarMoveMenuTitle(anchor: first,
                                     selectedFiles: [first, second])
                == "Move 2 Files…")
        // Single-file selection keeps the plain wording.
        #expect(sidebarMoveMenuTitle(anchor: first, selectedFiles: [first])
                == "Move…")
    }

    @Test("Drag payload round-trips the complete group")
    func dragPayloadRoundTrips() throws {
        let files = [
            URL(fileURLWithPath: "/tmp/first.md"),
            URL(fileURLWithPath: "/tmp/nested/second.md")
        ]
        let payload = SidebarFileDragPayload(files: files)

        let data = try encodeSidebarFileDragPayload(payload)
        #expect(try decodeSidebarFileDragPayload(data) == payload)
    }

    @Test("Drag item provider exports the registered group representation")
    func dragProviderExportsGroup() async throws {
        let files = [
            URL(fileURLWithPath: "/tmp/first.md"),
            URL(fileURLWithPath: "/tmp/nested/second.md")
        ]
        let provider = sidebarFileItemProvider(files: files)
        #expect(sidebarFileDragContentType == .json)
        #expect(provider.hasItemConformingToTypeIdentifier(
            sidebarFileDragContentType.identifier))

        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: sidebarFileDragContentType.identifier
            ) { data, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CocoaError(.fileReadUnknown))
                }
            }
        }

        #expect(try decodeSidebarFileDragPayload(data).files == files)
    }

    @Test("Drag payload rejects JSON from another process")
    func dragPayloadRejectsForeignProcess() throws {
        let valid = try encodeSidebarFileDragPayload(SidebarFileDragPayload(
            files: [URL(fileURLWithPath: "/tmp/first.md")]))
        var object = try #require(
            JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["processToken"] = "someone.else"
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: CocoaError.self) {
            try decodeSidebarFileDragPayload(data)
        }
    }

    // MARK: - Stale selection on navigation

    @Test("Empty selection never needs clearing")
    func staleSelectionEmpty() {
        #expect(!shouldClearSidebarSelection(
            activeURL: URL(fileURLWithPath: "/tmp/a.md"), selectedFiles: []))
    }

    @Test("Active file inside the selection stays highlighted")
    func staleSelectionActiveInSet() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        #expect(!shouldClearSidebarSelection(activeURL: a, selectedFiles: [a]))
        // Multi-selection where one member becomes active — keep the group.
        #expect(!shouldClearSidebarSelection(activeURL: a, selectedFiles: [a, b]))
    }

    @Test("Active target outside the selection clears it")
    func staleSelectionActiveOutside() {
        let file = URL(fileURLWithPath: "/tmp/a.md")
        let folder = URL(fileURLWithPath: "/tmp/sub")
        // Navigated to a folder.
        #expect(shouldClearSidebarSelection(activeURL: folder, selectedFiles: [file]))
        // Opened a different file from outside the sidebar.
        #expect(shouldClearSidebarSelection(
            activeURL: URL(fileURLWithPath: "/tmp/other.md"), selectedFiles: [file]))
        // Welcome screen (nil active) with a lingering selection.
        #expect(shouldClearSidebarSelection(activeURL: nil, selectedFiles: [file]))
    }

    @Test("Comparison standardizes the active URL")
    func staleSelectionStandardizes() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let messy = URL(fileURLWithPath: "/tmp/./sub/../a.md")
        #expect(!shouldClearSidebarSelection(activeURL: messy, selectedFiles: [a]))
    }

}

@Suite("Path-mutation routing")
@MainActor
struct PathMutationRouteQueueTests {

    @Test("Routes under a renamed root wait and follow its destination")
    func deferredRouteRelocatesBeforeReplay() throws {
        var queue = PathMutationRouteQueue()
        let oldRoot = URL(fileURLWithPath: "/tmp/Notes", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/tmp/Archive", isDirectory: true)
        let note = oldRoot.appendingPathComponent("Child/note.md")
        let id = queue.begin(at: oldRoot)

        let blocked = queue.enqueueIfBlocked(note, destination: .main)
        let unrelatedWasBlocked = queue.enqueueIfBlocked(
            URL(fileURLWithPath: "/tmp/Other/note.md"), destination: .main)
        #expect(blocked)
        #expect(!unrelatedWasBlocked)

        queue.relocate(from: oldRoot, to: newRoot)
        let routes = queue.finish(id)
        let route = try #require(routes.first)
        #expect(route.url == newRoot.appendingPathComponent("Child/note.md"))
        #expect(route.destination == .main)
    }

    @Test("Failed rename replays the original path")
    func failedMutationKeepsOriginalRoute() throws {
        var queue = PathMutationRouteQueue()
        let root = URL(fileURLWithPath: "/tmp/Notes", isDirectory: true)
        let note = root.appendingPathComponent("note.md")
        let id = queue.begin(at: root)
        #expect(queue.isBlocked(note))
        let blocked = queue.enqueueIfBlocked(note, destination: .separate)
        #expect(blocked)

        let routes = queue.finish(id)
        #expect(!queue.isBlocked(note))
        let route = try #require(routes.first)
        #expect(route == .init(url: note, destination: .separate))
    }

    @Test("Overlapping mutations release a route only after both finish")
    func overlappingMutationsRemainBlocked() throws {
        var queue = PathMutationRouteQueue()
        let parent = URL(fileURLWithPath: "/tmp/Parent", isDirectory: true)
        let child = parent.appendingPathComponent("Child", isDirectory: true)
        let renamed = URL(fileURLWithPath: "/tmp/Renamed", isDirectory: true)
        let parentID = queue.begin(at: parent)
        let childID = queue.begin(at: child)
        let blocked = queue.enqueueIfBlocked(
            child.appendingPathComponent("note.md"), destination: .main)
        #expect(blocked)

        queue.relocate(from: parent, to: renamed)
        let parentRoutes = queue.finish(parentID)
        #expect(parentRoutes.isEmpty)
        let childRoutes = queue.finish(childID)
        let route = try #require(childRoutes.first)
        #expect(route.url == renamed.appendingPathComponent("Child/note.md"))
    }

    @Test("An unresolved path drops its deferred routes across overlapping gates")
    func unresolvedMutationDiscardsRoutes() {
        var queue = PathMutationRouteQueue()
        let parent = URL(fileURLWithPath: "/tmp/Parent", isDirectory: true)
        let note = parent.appendingPathComponent("note.md")
        let parentID = queue.begin(at: parent)
        let fileID = queue.begin(at: note)
        let blocked = queue.enqueueIfBlocked(note, destination: .separate)
        #expect(blocked)

        let fileRoutes = queue.finish(fileID, discardingRoutes: true)
        #expect(fileRoutes.isEmpty)
        let parentRoutes = queue.finish(parentID)
        #expect(parentRoutes.isEmpty)
    }

    @Test("Presentation restore bypasses only its own mutation gate")
    func restoreHonorsOtherMutationGates() throws {
        var queue = PathMutationRouteQueue()
        let parent = URL(fileURLWithPath: "/tmp/Parent", isDirectory: true)
        let note = parent.appendingPathComponent("note.md")
        let parentID = queue.begin(at: parent)
        let fileID = queue.begin(at: note)

        let blockedByParent = queue.enqueueIfBlocked(
            note, destination: .main, ignoring: [fileID])
        #expect(blockedByParent)
        let fileRoutes = queue.finish(fileID)
        #expect(fileRoutes.isEmpty)
        let parentRoutes = queue.finish(parentID)
        let route = try #require(parentRoutes.first)
        #expect(route == .init(url: note, destination: .main))

        var isolatedQueue = PathMutationRouteQueue()
        let isolatedID = isolatedQueue.begin(at: note)
        let blockedByOwnGate = isolatedQueue.enqueueIfBlocked(
            note, destination: .main, ignoring: [isolatedID])
        #expect(!blockedByOwnGate)
    }

    @Test("Batch release preserves deferred open FIFO")
    func atomicBatchFinishPreservesRouteOrder() {
        var queue = PathMutationRouteQueue()
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let firstID = queue.begin(at: first)
        let secondID = queue.begin(at: second)
        _ = queue.enqueueIfBlocked(second, destination: .main)
        _ = queue.enqueueIfBlocked(first, destination: .main)

        let routes = queue.finish([firstID, secondID])

        #expect(routes.map(\.url) == [second, first])
    }

    @Test("Destination is gated before source relocation")
    func destinationGateClosesEarlyOpenWindow() {
        var queue = PathMutationRouteQueue()
        let source = URL(fileURLWithPath: "/tmp/source.md")
        let destination = URL(fileURLWithPath: "/tmp/destination.md")
        let sourceID = queue.begin(at: source)
        let destinationID = queue.begin(at: destination)

        let blocked = queue.enqueueIfBlocked(
            destination, destination: .separate)
        #expect(blocked)
        queue.relocate(from: source, to: destination)
        let routes = queue.finish([sourceID, destinationID])

        #expect(routes == [.init(
            url: destination, destination: .separate)])
    }

    @Test("An earlier blocked route holds later ready routes")
    func unfinishedMutationKeepsGlobalFIFO() {
        var queue = PathMutationRouteQueue()
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        let firstID = queue.begin(at: first)
        let secondID = queue.begin(at: second)
        _ = queue.enqueueIfBlocked(second, destination: .main)
        _ = queue.enqueueIfBlocked(first, destination: .main)

        let firstRelease = queue.finish(firstID)
        #expect(firstRelease.isEmpty)
        let secondRelease = queue.finish(secondID)
        #expect(secondRelease.map(\.url) == [second, first])
    }

    @Test("Unresolved mutation clears current route and pending control jump")
    func unresolvedMutationClearsAppPathState() throws {
        let suiteName = "path-drop-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appState = AppState(defaults: defaults)
        let root = URL(fileURLWithPath: "/tmp/Unsafe", isDirectory: true)
        let file = root.appendingPathComponent("note.md")

        appState.openInMainWindow(file)
        appState.requestControlJump(url: file, offset: 17)
        let token = appState.beginPathMutation(at: root)

        appState.finishPathMutations(
            [token], discardingRouteIDs: [token])

        #expect(appState.currentURL == nil)
        #expect(appState.consumeControlJump(for: file) == nil)
    }
}

@Suite("File-move recovery routing")
struct FileMoveRecoveryResolutionTests {

    @Test("Ordinary failure restores every source")
    func ordinaryFailureUsesSourcePaths() {
        let first = URL(fileURLWithPath: "/tmp/First/a.md")
        let second = URL(fileURLWithPath: "/tmp/First/b.md")

        let resolutions = fileMoveRecoveryResolutions(
            for: [first, second],
            after: FileMoveError.destinationNotFolder)

        #expect(resolutions[first] == .source)
        #expect(resolutions[second] == .source)
    }

    @Test("Rollback recovery follows only a unique coherent survivor")
    func rollbackFailureClassifiesEachSource() {
        let sourceRoot = URL(fileURLWithPath: "/tmp/Source", isDirectory: true)
        let destinationRoot = URL(
            fileURLWithPath: "/tmp/Destination", isDirectory: true)
        let sourceOnly = sourceRoot.appendingPathComponent("source.md")
        let destinationOnly = sourceRoot.appendingPathComponent("destination.md")
        let duplicated = sourceRoot.appendingPathComponent("duplicated.md")
        let missing = sourceRoot.appendingPathComponent("missing.md")
        let splitSidecar = sourceRoot.appendingPathComponent("split.md")
        let untouched = sourceRoot.appendingPathComponent("untouched.md")
        let files = [
            sourceOnly, destinationOnly, duplicated, missing, splitSidecar, untouched
        ]

        func state(
            _ source: URL,
            fileAtSource: Bool,
            fileAtDestination: Bool,
            reviewAtSource: Bool,
            reviewAtDestination: Bool
        ) -> FileMoveRollbackState {
            FileMoveRollbackState(
                move: .init(
                    source: source,
                    destination: destinationRoot
                        .appendingPathComponent(source.lastPathComponent)),
                expectedReviewSidecar: true,
                fileAtSource: fileAtSource,
                fileAtDestination: fileAtDestination,
                reviewSidecarAtSource: reviewAtSource,
                reviewSidecarAtDestination: reviewAtDestination)
        }

        let resolutions = fileMoveRecoveryResolutions(
            for: files,
            after: FileMoveError.rollbackFailed([
                state(sourceOnly,
                      fileAtSource: true, fileAtDestination: false,
                      reviewAtSource: true, reviewAtDestination: false),
                state(destinationOnly,
                      fileAtSource: false, fileAtDestination: true,
                      reviewAtSource: false, reviewAtDestination: true),
                state(duplicated,
                      fileAtSource: true, fileAtDestination: true,
                      reviewAtSource: true, reviewAtDestination: true),
                state(missing,
                      fileAtSource: false, fileAtDestination: false,
                      reviewAtSource: false, reviewAtDestination: false),
                state(splitSidecar,
                      fileAtSource: true, fileAtDestination: false,
                      reviewAtSource: false, reviewAtDestination: true)
            ]))

        #expect(resolutions[sourceOnly] == .source)
        #expect(resolutions[destinationOnly] == .destination(
            destinationRoot.appendingPathComponent("destination.md")))
        #expect(resolutions[duplicated] == .unresolved)
        #expect(resolutions[missing] == .unresolved)
        #expect(resolutions[splitSidecar] == .unresolved)
        #expect(resolutions[untouched] == .source)
    }
}

@Suite("Long-running operation center")
@MainActor
struct LongRunningOperationCenterTests {

    @Test("Fast operation blocks input without revealing delayed progress")
    func fastOperationDoesNotFlash() async {
        let center = LongRunningOperationCenter(revealDelay: .seconds(60))
        let result = await center.run(title: "Moving…") { 42 }

        #expect(result == 42)
        #expect(!center.isBlocking)
        #expect(center.visibleOperation == nil)
    }

    @Test("Finishing one operation keeps overlapping work blocked")
    func overlappingOperationsStayBlocked() {
        let center = LongRunningOperationCenter(revealDelay: .seconds(60))
        let first = center.begin(title: "First")
        let second = center.begin(title: "Second")

        center.finish(second)
        #expect(center.isBlocking)
        center.finish(first)
        #expect(!center.isBlocking)
    }
}

@Suite("Editor mode open rules")
@MainActor
struct NewFileEditorModeTests {

    @Test("Opening reason selects the intended override", arguments: [
        (EditorOpenReason.created, EditorMode.visual),
        (EditorOpenReason.finder, EditorMode.preview)
    ])
    func explicitModeOverrides(reason: EditorOpenReason, expected: EditorMode) {
        #expect(editorModeOverride(for: reason) == expected)
    }

    @Test("Ordinary navigation preserves the selected mode")
    func existingFileHasNoOverride() {
        #expect(editorModeOverride(for: .existing) == nil)
    }

    @Test("Untitled documents start in Visual")
    func untitledStartsInVisual() throws {
        let suiteName = "new-file-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(EditorMode.source.rawValue, forKey: "editorMode")
        let appState = AppState(defaults: defaults)

        appState.openUntitled()

        #expect(defaults.string(forKey: "editorMode") == EditorMode.visual.rawValue)
        #expect(appState.isUntitled)
        #expect(appState.currentURL == nil)
    }

    @Test("Cold launch resets a stuck mode back to Preview")
    func coldLaunchResetsToPreview() throws {
        let suiteName = "cold-launch-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Last session was left in Source, with a stale per-document map.
        defaults.set(EditorMode.source.rawValue, forKey: "editorMode")
        defaults.set(["/a.md": EditorMode.visual.rawValue], forKey: "editorMode.byPath")

        resetEditorModeForColdLaunch(defaults)

        #expect(defaults.string(forKey: "editorMode") == EditorMode.preview.rawValue)
        #expect(defaults.dictionary(forKey: "editorMode.byPath") == nil)
    }
}

// MARK: - Folder inspector aggregates

struct FolderInspectorAggregateTests {

    // MARK: countMarkdownTasks

    @Test("Counts GFM task checkboxes, open and done")
    func countsTasks() {
        let text = """
        # Title

        - [ ] open one
        - [x] done one
        * [X] done upper bullet
        +   [ ] extra spaces before marker
          - [ ] indented open

        - regular list item, no checkbox
        - [] malformed, empty brackets
        [ ] no bullet, not a task
        - [~] unknown marker
        """
        let (done, total) = countMarkdownTasks(in: text)
        #expect(total == 5)
        #expect(done == 2)
    }

    @Test("No tasks in plain prose")
    func noTasks() {
        let (done, total) = countMarkdownTasks(in: "Just a paragraph.\nAnother line.")
        #expect(done == 0)
        #expect(total == 0)
    }

    // MARK: folderGraphStats

    @Test("Scopes link totals to the subtree and flags orphans")
    func graphStatsScoped() {
        let root = URL(fileURLWithPath: "/vault/sub").standardizedFileURL
        let inA = root.appendingPathComponent("a.md")
        let inB = root.appendingPathComponent("deep/b.md")
        let outside = URL(fileURLWithPath: "/vault/other/c.md").standardizedFileURL

        func link(_ target: String) -> OutgoingLink {
            OutgoingLink(kind: .wiki, rawTarget: target, label: target,
                         line: 1, utf16Offset: 0, context: "[[\(target)]]")
        }
        // a → b (in folder), a → c (target outside). c → a (backlink into folder).
        let outgoing: [URL: [OutgoingLink]] = [
            inA: [link("b"), link("c")],
            inB: [],
            outside: [link("a")],
        ]
        let backlinks: [URL: [BacklinkEdge]] = [
            inB: [BacklinkEdge(source: inA, link: link("b"))],
            inA: [BacklinkEdge(source: outside, link: link("a"))],
        ]
        let snapshot = LinkIndexSnapshot(outgoing: outgoing, backlinks: backlinks)

        let stats = folderGraphStats(snapshot: snapshot, folderPathPrefix: root.path)
        // Outgoing counts only edges from files inside the folder: a has 2, b has 0.
        #expect(stats.outgoing == 2)
        // Backlinks into folder files: b(1) + a(1) = 2.
        #expect(stats.backlinks == 2)
        // a and b are inside; only b has an incoming edge that lands on it,
        // a also has one → both linked, so 0 orphans here.
        #expect(stats.orphans == 0)
    }

    @Test("Orphan is a subtree file with no incoming edge")
    func graphStatsOrphan() {
        let root = URL(fileURLWithPath: "/vault").standardizedFileURL
        let lonely = root.appendingPathComponent("lonely.md")
        let hub = root.appendingPathComponent("hub.md")
        func link(_ t: String) -> OutgoingLink {
            OutgoingLink(kind: .wiki, rawTarget: t, label: t, line: 1,
                         utf16Offset: 0, context: "")
        }
        let outgoing: [URL: [OutgoingLink]] = [lonely: [link("hub")], hub: []]
        let backlinks: [URL: [BacklinkEdge]] = [
            hub: [BacklinkEdge(source: lonely, link: link("hub"))],
        ]
        let snapshot = LinkIndexSnapshot(outgoing: outgoing, backlinks: backlinks)
        let stats = folderGraphStats(snapshot: snapshot, folderPathPrefix: root.path)
        // lonely has no backlink → 1 orphan; hub is linked.
        #expect(stats.orphans == 1)
    }

    // MARK: scanFolderAggregates

    @Test("Aggregates words and tasks over a temp tree")
    func scanTempTree() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fi-scan-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let sub = root.appendingPathComponent("nested")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        let textA = "# One\n\nalpha beta gamma\n- [ ] todo\n- [x] did\n"
        let textB = "delta epsilon\n- [ ] another\n"
        try textA.write(to: root.appendingPathComponent("a.md"),
                        atomically: true, encoding: .utf8)
        try textB.write(to: sub.appendingPathComponent("b.markdown"),
                        atomically: true, encoding: .utf8)

        let expectedWords = wordAndCharCount(in: textA).words
            + wordAndCharCount(in: textB).words

        let agg = scanFolderAggregates(at: root)
        #expect(agg.markdownFiles == 2)
        #expect(agg.tasksTotal == 3)
        #expect(agg.tasksDone == 1)
        #expect(agg.words == expectedWords)
        #expect(!agg.contentPartial)
    }

    @Test("Oversized single file is skipped and marks the read partial")
    func scanOversizedSkipped() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("fi-budget-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let big = String(repeating: "word ", count: 5000) // ~25 KB
        try big.write(to: root.appendingPathComponent("big.md"),
                      atomically: true, encoding: .utf8)

        // Force the per-file cap below the file size: content is skipped.
        let agg = scanFolderAggregates(at: root, maxFileBytes: 1024)
        #expect(agg.markdownFiles == 1)     // still counted as a file
        #expect(agg.words == 0)             // content never read
        #expect(agg.contentPartial)
    }
}
