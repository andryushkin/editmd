import XCTest
@testable import EditMD

/// The folder EditMD creates on a first launch: what lands in it, and the
/// promise that a second pass never touches what the user has since edited.
final class StarterFolderTests: XCTestCase {

    private func makeTemporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StarterFolderTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func relativePaths(in root: URL) -> Set<String> {
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        // `/var/folders/…` is a symlink to `/private/var/folders/…`: the
        // enumerator resolves it, the root URL does not.
        let base = root.resolvingSymlinksInPath().path + "/"
        var found: Set<String> = []
        for case let url as URL in walker {
            let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile ?? false
            guard isFile else { continue }
            found.insert(url.resolvingSymlinksInPath().path
                .replacingOccurrences(of: base, with: ""))
        }
        return found
    }

    func testSeedsReadmeAndGuide() throws {
        let root = makeTemporaryRoot()

        let created = try StarterFolder.seedContents(at: root, bundle: .main)

        let paths = relativePaths(in: root)
        XCTAssertTrue(paths.contains("README.md"), "\(paths)")
        XCTAssertTrue(paths.contains("Guide/Editing modes.md"), "\(paths)")
        XCTAssertTrue(paths.contains("Guide/Web clipper.md"), "\(paths)")
        XCTAssertTrue(paths.contains("Guide/Markdown showcase.md"), "\(paths)")
        XCTAssertEqual(created.count, paths.count)
    }

    /// The seeded documents are the user's the moment they land — a second
    /// pass must not restore the bundled text over their edits, and must not
    /// remove anything they added.
    func testSecondPassKeepsUserEdits() throws {
        let root = makeTemporaryRoot()
        try StarterFolder.seedContents(at: root, bundle: .main)
        let readme = root.appendingPathComponent("README.md")
        try "mine now".write(to: readme, atomically: true, encoding: .utf8)
        let clip = root.appendingPathComponent("Clipped article.md")
        try "a clip".write(to: clip, atomically: true, encoding: .utf8)

        let created = try StarterFolder.seedContents(at: root, bundle: .main)

        XCTAssertEqual(created, [], "nothing left to create")
        XCTAssertEqual(try String(contentsOf: readme, encoding: .utf8), "mine now")
        XCTAssertEqual(try String(contentsOf: clip, encoding: .utf8), "a clip")
    }

    /// Seeding is once per installation, and it is what makes the flag stick.
    @MainActor
    func testSeedsOncePerInstallation() throws {
        let root = makeTemporaryRoot()
        let suiteName = "starter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(
            StarterFolder.seedIfNeeded(at: root, defaults: defaults, bundle: .main)?.path,
            root.standardizedFileURL.path)
        XCTAssertTrue(defaults.bool(forKey: StarterFolder.seededKey))
        // A user who deletes the folder is not given it back.
        try FileManager.default.removeItem(at: root)
        XCTAssertNil(
            StarterFolder.seedIfNeeded(at: root, defaults: defaults, bundle: .main))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    /// A `~/Documents/EditMD` that belongs to the user is not adopted, not
    /// written into, and not opened: the guide steps aside to `EditMD 2`.
    func testExistingFolderIsNotTakenOver() throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        try FileManager.default.createDirectory(
            at: preferred, withIntermediateDirectories: true)
        let theirs = preferred.appendingPathComponent("README.md")
        try "my own notes".write(to: theirs, atomically: true, encoding: .utf8)

        let root = try StarterFolder.makeOwnFolder(preferring: preferred)
        try StarterFolder.seedContents(at: root, bundle: .main)

        XCTAssertEqual(root.lastPathComponent, "EditMD 2")
        XCTAssertEqual(try String(contentsOf: theirs, encoding: .utf8), "my own notes")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: preferred.path),
            ["README.md"],
            "nothing was added to the user's folder")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Guide/Web clipper.md").path))
    }

    /// An empty folder of that name is nobody's — using it avoids a pointless
    /// `EditMD 2` next to an empty `EditMD`.
    func testEmptyFolderOfTheSameNameIsUsed() throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        try FileManager.default.createDirectory(
            at: preferred, withIntermediateDirectories: true)

        XCTAssertEqual(try StarterFolder.makeOwnFolder(preferring: preferred).path,
                       preferred.standardizedFileURL.path)
    }

    /// Occupied names keep stepping aside, in order.
    func testFolderNamesStepAsideInOrder() throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        for name in ["EditMD", "EditMD 2"] {
            let url = parent.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try "x".write(to: url.appendingPathComponent("note.md"),
                          atomically: true, encoding: .utf8)
        }

        XCTAssertEqual(
            try StarterFolder.makeOwnFolder(preferring: preferred).lastPathComponent,
            "EditMD 3")
    }

    /// What a launch is allowed to do with the folder it just made.
    func testPresentationRules() {
        // Fresh start: the folder becomes the sidebar and opens its README.
        XCTAssertEqual(
            StarterFolder.presentation(
                sidebarIsEmpty: true, mainPaneIsWelcome: true, hasEditorModeClaim: false),
            .adoptAndOpenReadme)
        // A clip arrived first (or something else filled the window): adopt
        // the folder, leave the document alone.
        XCTAssertEqual(
            StarterFolder.presentation(
                sidebarIsEmpty: true, mainPaneIsWelcome: true, hasEditorModeClaim: true),
            .adopt)
        XCTAssertEqual(
            StarterFolder.presentation(
                sidebarIsEmpty: true, mainPaneIsWelcome: false, hasEditorModeClaim: false),
            .adopt)
        // An existing user: their sidebar is never rearranged.
        for welcome in [true, false] {
            for claim in [true, false] {
                XCTAssertEqual(
                    StarterFolder.presentation(
                        sidebarIsEmpty: false,
                        mainPaneIsWelcome: welcome,
                        hasEditorModeClaim: claim),
                    .none)
            }
        }
    }

    /// The clips default and the starter folder are the same place — that is
    /// the whole point of seeding the guide where the notes will land.
    func testClipsDefaultToTheStarterFolder() {
        XCTAssertEqual(ClipDestination.defaultFolder, StarterFolder.defaultURL)
        XCTAssertEqual(
            ClipDestination.configuredFolder(forSettingsPath: ""),
            StarterFolder.defaultURL)
        XCTAssertEqual(StarterFolder.defaultURL.lastPathComponent, "EditMD")
    }

    /// The seeded documents must render, not just exist: they are the first
    /// Markdown a new user sees, and they link to each other by wiki-link.
    func testSeededDocumentsLinkToEachOther() throws {
        let root = makeTemporaryRoot()
        try StarterFolder.seedContents(at: root, bundle: .main)
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)

        XCTAssertTrue(readme.contains("[[Editing modes]]"))
        XCTAssertTrue(readme.contains("chromewebstore.google.com"))
        // Wiki-links resolve against the folder's own files.
        let guide = root.appendingPathComponent("Guide")
        for target in ["Editing modes", "Web clipper", "Markdown showcase"] {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: guide.appendingPathComponent("\(target).md").path),
                "missing wiki-link target \(target)")
        }
    }
}
