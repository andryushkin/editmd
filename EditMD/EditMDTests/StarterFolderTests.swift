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

    /// A suite of its own, so nothing here touches the developer's defaults.
    @MainActor
    private func makeSuite() throws -> (String, UserDefaults) {
        let suiteName = "starter-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return (suiteName, defaults)
    }

    /// Seeding is once per installation, and it is what makes the flag stick.
    @MainActor
    func testSeedsOncePerInstallation() async throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        let (suiteName, defaults) = try makeSuite()
        let owner = StarterFolderOwner(preferring: preferred, defaultsSuite: suiteName)

        let seeded = await StarterFolder.seedIfNeeded(
            owner: owner, defaultsSuite: suiteName, bundle: .main)
        XCTAssertEqual(seeded?.path, preferred.standardizedFileURL.path)
        XCTAssertTrue(defaults.bool(forKey: StarterFolder.seededKey))
        XCTAssertEqual(defaults.string(forKey: StarterFolder.folderKey),
                       preferred.standardizedFileURL.path)
        // A user who deletes the folder is not given it back.
        try FileManager.default.removeItem(at: preferred)
        let again = await StarterFolder.seedIfNeeded(
            owner: owner, defaultsSuite: suiteName, bundle: .main)
        XCTAssertNil(again)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferred.path))
    }

    /// One owner, one answer: the launch seed and a clip that arrived first
    /// must not each create their own folder.
    @MainActor
    func testOwnerAnswersEveryCallerTheSameFolder() async throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        let (suiteName, defaults) = try makeSuite()
        let owner = StarterFolderOwner(preferring: preferred, defaultsSuite: suiteName)

        let answers = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await owner.folder().path }
            }
            var seen: [String?] = []
            for await answer in group { seen.append(answer) }
            return seen
        }

        XCTAssertEqual(Set(answers.compactMap { $0 }).count, 1, "\(answers)")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: parent.path),
            ["EditMD"], "exactly one folder was created")
        XCTAssertEqual(defaults.string(forKey: StarterFolder.folderKey),
                       preferred.standardizedFileURL.path)
    }

    /// A later launch (a fresh actor) must land on the recorded folder, not
    /// re-run the naming dance and pick a second one.
    @MainActor
    func testOwnerReusesTheRecordedFolder() async throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        let (suiteName, defaults) = try makeSuite()

        let first = try await StarterFolderOwner(
            preferring: preferred, defaultsSuite: suiteName).folder()
        // Content of ours or the user's — the recorded path still wins.
        try "clip".write(to: first.appendingPathComponent("note.md"),
                         atomically: true, encoding: .utf8)
        let second = try await StarterFolderOwner(
            preferring: preferred, defaultsSuite: suiteName).folder()

        XCTAssertEqual(first, second)
        XCTAssertEqual(defaults.string(forKey: StarterFolder.folderKey), first.path)
    }

    /// A guide that fails to copy must not cost the clips their home: the
    /// folder is recorded as soon as it exists.
    @MainActor
    func testFolderSurvivesAFailedSeed() async throws {
        let parent = makeTemporaryRoot()
        let preferred = parent.appendingPathComponent("EditMD")
        let (suiteName, defaults) = try makeSuite()
        let owner = StarterFolderOwner(preferring: preferred, defaultsSuite: suiteName)
        // The test bundle carries none of the starter documents.
        let empty = Bundle(for: StarterFolderTests.self)

        let seeded = await StarterFolder.seedIfNeeded(
            owner: owner, defaultsSuite: suiteName, bundle: empty)

        XCTAssertNil(seeded, "the guide did not land")
        XCTAssertEqual(defaults.string(forKey: StarterFolder.folderKey),
                       preferred.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferred.path))
        XCTAssertEqual(StarterFolder.ownedFolder(defaults: defaults).path,
                       preferred.standardizedFileURL.path)
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

    /// "Empty" means empty, not "empty once you skip the dotfiles": a folder
    /// holding only `.git` or `.obsidian` is somebody's vault.
    func testHiddenContentMakesAFolderSomebodysElse() throws {
        for hidden in [".git", ".obsidian", ".DS_Store"] {
            let parent = makeTemporaryRoot()
            let preferred = parent.appendingPathComponent("EditMD")
            try FileManager.default.createDirectory(
                at: preferred, withIntermediateDirectories: true)
            try "x".write(to: preferred.appendingPathComponent(hidden),
                          atomically: true, encoding: .utf8)

            XCTAssertFalse(StarterFolder.isAdoptableEmptyDirectory(preferred), hidden)
            XCTAssertEqual(
                try StarterFolder.makeOwnFolder(preferring: preferred).lastPathComponent,
                "EditMD 2", hidden)
            // The user's folder gained nothing.
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: preferred.path),
                [hidden])
        }
    }

    /// A symlink is never adopted, whatever it points at — the target is not
    /// ours to fill.
    func testSymlinkIsNeverAdopted() throws {
        let parent = makeTemporaryRoot()
        let target = parent.appendingPathComponent("Somewhere else")
        let link = parent.appendingPathComponent("EditMD")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(StarterFolder.isAdoptableEmptyDirectory(link))
        XCTAssertEqual(
            try StarterFolder.makeOwnFolder(preferring: link).lastPathComponent,
            "EditMD 2")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
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
    @MainActor
    func testClipsDefaultToTheStarterFolder() throws {
        let (_, defaults) = try makeSuite()
        XCTAssertNil(ClipDestination.configuredFolder(forSettingsPath: ""))
        XCTAssertEqual(StarterFolder.defaultURL.lastPathComponent, "EditMD")
        // Nothing recorded yet: the preferred location is what the UI shows.
        XCTAssertEqual(StarterFolder.ownedFolder(defaults: defaults),
                       StarterFolder.defaultURL)
        defaults.set("/tmp/Elsewhere", forKey: StarterFolder.folderKey)
        XCTAssertEqual(StarterFolder.ownedFolder(defaults: defaults).path, "/tmp/Elsewhere")
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
