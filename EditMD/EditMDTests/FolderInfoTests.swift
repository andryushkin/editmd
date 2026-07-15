import XCTest
import Testing
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
        XCTAssertEqual(model.primeFolderListing(dir).map(\.lastPathComponent), ["Hello.md"])

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

    func testCreateWorkspaceFolderCreatesAndAdoptsRoot() throws {
        let model = WorkspaceModel(defaults: defaults)

        let folder = try model.createWorkspaceFolder(named: "New Notes", in: dir)

        XCTAssertEqual(folder, dir.appendingPathComponent("New Notes").standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(model.workspaces.map(\.folderPath), [folder.path])
    }

    func testCreateWorkspaceFolderRejectsExistingFolder() throws {
        let model = WorkspaceModel(defaults: defaults)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Existing"), withIntermediateDirectories: false)

        XCTAssertThrowsError(
            try model.createWorkspaceFolder(named: "Existing", in: dir)
        ) { error in
            XCTAssertEqual(error as? FolderCreateError, .alreadyExists("Existing"))
        }
        XCTAssertTrue(model.workspaces.isEmpty)
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

        #expect(try registry.prepareForMove(source))
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

        #expect(try registry.prepareForMove(first))
        #expect(try registry.prepareForMove(second))
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

@Suite("Sidebar file selection")
@MainActor
struct SidebarFileSelectionTests {

    @Test("Command-click toggles without opening")
    func commandClickTogglesSelection() {
        let first = URL(fileURLWithPath: "/tmp/first.md")
        var selection = Set<URL>()

        #expect(!updateSidebarFileSelection(
            for: first, commandHeld: true, selectedFiles: &selection))
        #expect(selection == [first])
        #expect(!updateSidebarFileSelection(
            for: first, commandHeld: true, selectedFiles: &selection))
        #expect(selection.isEmpty)
    }

    @Test("Normal click replaces the group, selects, and opens the row")
    func normalClickReplacesSelection() {
        let first = URL(fileURLWithPath: "/tmp/first.md")
        let second = URL(fileURLWithPath: "/tmp/second.md")
        var selection: Set<URL> = [first, second]

        #expect(updateSidebarFileSelection(
            for: first, commandHeld: false, selectedFiles: &selection))
        #expect(selection == [first])
    }

    @Test("A selected drag carries the whole stable group")
    func selectedDragCarriesGroup() {
        let first = URL(fileURLWithPath: "/tmp/a/first.md")
        let second = URL(fileURLWithPath: "/tmp/b/second.md")
        let selection: Set<URL> = [second, first]

        #expect(sidebarMoveFiles(anchor: first, selectedFiles: selection) == [first, second])
        #expect(sidebarMoveFiles(
            anchor: URL(fileURLWithPath: "/tmp/third.md"),
            selectedFiles: selection
        ) == [URL(fileURLWithPath: "/tmp/third.md")])
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

@Suite("New file editor mode")
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
}
