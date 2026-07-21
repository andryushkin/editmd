import XCTest
@testable import EditMD

final class GitCLITests: XCTestCase {

    // MARK: - Suggested commit messages

    func testSuggestedAddUntracked() {
        XCTAssertEqual(
            GitCommitMessage.suggested(fileName: "note.md", pathStatus: .untracked),
            "Add note.md"
        )
    }

    func testSuggestedDelete() {
        XCTAssertEqual(
            GitCommitMessage.suggested(fileName: "gone.md", pathStatus: .deleted),
            "Delete gone.md"
        )
    }

    func testSuggestedUpdatePlain() {
        XCTAssertEqual(
            GitCommitMessage.suggested(fileName: "a.md", pathStatus: .modified),
            "Update a.md"
        )
    }

    func testSuggestedUpdateWithSingleLine() {
        XCTAssertEqual(
            GitCommitMessage.suggested(
                fileName: "a.md", pathStatus: .modified, dirtyLines: [12]),
            "Update a.md (L12)"
        )
    }

    func testSuggestedUpdateWithLineRange() {
        XCTAssertEqual(
            GitCommitMessage.suggested(
                fileName: "a.md", pathStatus: .modified, dirtyLines: [12, 13, 14]),
            "Update a.md (L12–14)"
        )
    }

    func testSuggestedUpdateWithSparseLines() {
        XCTAssertEqual(
            GitCommitMessage.suggested(
                fileName: "a.md", pathStatus: .modified, dirtyLines: [3, 9, 20, 21]),
            "Update a.md (L3, L9, L20–21)"
        )
    }

    func testFormatLineSpanCapsRanges() {
        // 5 separate lines → 4 ranges + ellipsis
        let span = GitCommitMessage.formatLineSpan([1, 3, 5, 7, 9])
        XCTAssertEqual(span, "L1, L3, L5, L7, …")
    }

    func testSuggestedBatch() {
        XCTAssertEqual(GitCommitMessage.suggestedBatch(fileCount: 1), "Update 1 file")
        XCTAssertEqual(GitCommitMessage.suggestedBatch(fileCount: 3), "Update 3 files")
    }

    func testParseUnifiedDiffNewLines() {
        let diff = """
        diff --git a/a.md b/a.md
        --- a/a.md
        +++ b/a.md
        @@ -10,0 +11,2 @@
        +hello
        +world
        @@ -20 +21 @@
        -old
        +new
        """
        let lines = GitCLI.parseUnifiedDiffNewLines(diff)
        XCTAssertEqual(lines, [11, 12, 21])
    }

    func testRelativePath() {
        let root = URL(fileURLWithPath: "/Users/me/repo", isDirectory: true)
        let file = URL(fileURLWithPath: "/Users/me/repo/docs/a.md")
        XCTAssertEqual(GitCLI.relativePath(of: file, to: root), "docs/a.md")
    }

    func testRelativePathRootFile() {
        let root = URL(fileURLWithPath: "/tmp/r", isDirectory: true)
        let file = URL(fileURLWithPath: "/tmp/r/README.md")
        XCTAssertEqual(GitCLI.relativePath(of: file, to: root), "README.md")
    }

    func testLastCommitHashOnThisRepo() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        guard let root = GitCLI.repositoryRoot(containing: thisFile) else {
            throw XCTSkip("not inside a git work tree")
        }
        let hash = GitCLI.lastCommitHash(touching: thisFile)
        if let hash {
            XCTAssertEqual(hash.count, 40, "full SHA-1 expected, got \(hash)")
            XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
        }
        XCTAssertTrue(root.path.contains("editmd") || FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }

    // MARK: - Temp repo write ops (stage 4)

    func testStageAndCommitSingleFile() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let file = repo.appendingPathComponent("note.md")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(GitCLI.pathStatus(of: file), .untracked)

        let result = GitCLI.commit(file: file, message: "add note")
        switch result {
        case .success(let hash):
            XCTAssertEqual(hash.count, 40)
            XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
        case .failure(let err):
            XCTFail("commit failed: \(err.message)")
        }

        XCTAssertEqual(GitCLI.pathStatus(of: file), .clean)
        XCTAssertEqual(GitCLI.lastCommitHash(touching: file)?.count, 40)

        // Second edit → modified → commit again.
        try "hello\nworld\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCLI.pathStatus(of: file), .modified)

        let result2 = GitCLI.commit(file: file, message: "update note")
        guard case .success = result2 else {
            return XCTFail("second commit failed: \(result2)")
        }
        XCTAssertEqual(GitCLI.pathStatus(of: file), .clean)
    }

    func testCommitEmptyMessageFails() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        let result = GitCLI.commit(file: file, message: "   ")
        guard case .failure(let err) = result else {
            return XCTFail("expected failure for empty message")
        }
        XCTAssertTrue(err.message.lowercased().contains("empty"))
    }

    func testCommitNothingToCommitWhenClean() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("a.md")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)
        _ = GitCLI.commit(file: file, message: "first")
        let again = GitCLI.commit(file: file, message: "noop")
        guard case .failure(let err) = again else {
            return XCTFail("expected nothing-to-commit")
        }
        let msg = err.message.lowercased()
        XCTAssertTrue(
            msg.contains("nothing") || msg.contains("clean"),
            "unexpected message: \(err.message)"
        )
    }

    func testCommitDoesNotTouchOtherFiles() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let a = repo.appendingPathComponent("a.md")
        let b = repo.appendingPathComponent("b.md")
        try "A\n".write(to: a, atomically: true, encoding: .utf8)
        try "B\n".write(to: b, atomically: true, encoding: .utf8)

        // Commit only A — B must stay untracked.
        let result = GitCLI.commit(file: a, message: "only a")
        guard case .success = result else {
            return XCTFail("commit a failed: \(result)")
        }
        XCTAssertEqual(GitCLI.pathStatus(of: a), .clean)
        XCTAssertEqual(GitCLI.pathStatus(of: b), .untracked)
    }

    func testPathStatusOutsideRepo() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-not-git-\(UUID().uuidString).md")
        FileManager.default.createFile(atPath: tmp.path, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(GitCLI.pathStatus(of: tmp), .notInRepo)
    }

    // MARK: - Porcelain parsing

    func testParsePorcelainModified() {
        let p = GitCLI.parsePorcelainLine(" M notes/a.md")
        XCTAssertEqual(p?.status, .modified)
        XCTAssertEqual(p?.path, "notes/a.md")
    }

    func testParsePorcelainUntracked() {
        let p = GitCLI.parsePorcelainLine("?? inbox/new.md")
        XCTAssertEqual(p?.status, .untracked)
        XCTAssertEqual(p?.path, "inbox/new.md")
    }

    func testParsePorcelainDeleted() {
        let p = GitCLI.parsePorcelainLine(" D old.md")
        XCTAssertEqual(p?.status, .deleted)
        XCTAssertEqual(p?.path, "old.md")
    }

    func testParsePorcelainRenameUsesNewPath() {
        let p = GitCLI.parsePorcelainLine("R  old.md -> new.md")
        XCTAssertEqual(p?.status, .modified)
        XCTAssertEqual(p?.path, "new.md")
    }

    func testParsePorcelainQuotedPath() {
        let p = GitCLI.parsePorcelainLine(" M \"has space.md\"")
        XCTAssertEqual(p?.status, .modified)
        XCTAssertEqual(p?.path, "has space.md")
    }

    func testHeadFileContentsUntrackedIsEmpty() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("fresh.md")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCLI.pathStatus(of: file), .untracked)
        XCTAssertEqual(GitCLI.headFileContents(of: file), "")
        XCTAssertEqual(GitCLI.workingTreeContents(of: file), "hello\n")
    }

    func testHeadFileContentsAfterCommit() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let file = repo.appendingPathComponent("tracked.md")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        let committed = GitCLI.commit(file: file, message: "add")
        guard case .success = committed else {
            return XCTFail("commit failed: \(committed)")
        }
        XCTAssertEqual(GitCLI.headFileContents(of: file), "v1\n")
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(GitCLI.headFileContents(of: file), "v1\n")
        XCTAssertEqual(GitCLI.workingTreeContents(of: file), "v2\n")
    }

    func testCommitMultipleFilesInOneCommit() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let a = repo.appendingPathComponent("a.md")
        let b = repo.appendingPathComponent("b.md")
        try "a1\n".write(to: a, atomically: true, encoding: .utf8)
        try "b1\n".write(to: b, atomically: true, encoding: .utf8)
        // Seed both on HEAD first so the batch commit is a real update.
        guard case .success = GitCLI.commit(files: [a, b], message: "seed") else {
            return XCTFail("seed commit failed")
        }
        try "a2\n".write(to: a, atomically: true, encoding: .utf8)
        try "b2\n".write(to: b, atomically: true, encoding: .utf8)
        let result = GitCLI.commit(files: [a, b], message: "Update 2 files")
        guard case .success(let hash) = result else {
            return XCTFail("batch commit failed: \(result)")
        }
        XCTAssertEqual(hash.count, 40)
        XCTAssertEqual(GitCLI.pathStatus(of: a), .clean)
        XCTAssertEqual(GitCLI.pathStatus(of: b), .clean)
        XCTAssertEqual(GitCLI.headFileContents(of: a), "a2\n")
        XCTAssertEqual(GitCLI.headFileContents(of: b), "b2\n")
    }

    @MainActor
    func testPorcelainStatusFiltersToWorkspaceMarkdown() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let ws = repo.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let md = ws.appendingPathComponent("note.md")
        let outside = repo.appendingPathComponent("root.md")
        let swift = ws.appendingPathComponent("x.swift")
        try "a\n".write(to: md, atomically: true, encoding: .utf8)
        try "b\n".write(to: outside, atomically: true, encoding: .utf8)
        try "c\n".write(to: swift, atomically: true, encoding: .utf8)

        let snap = GitWorkspaceStatus.snapshot(workspaceRoots: [ws], openURLs: [])
        XCTAssertTrue(snap.hasAnyRepo)
        XCTAssertEqual(snap.sections.count, 1)
        let paths = snap.sections[0].files.map(\.displayPath)
        XCTAssertEqual(paths, ["note.md"])
        XCTAssertFalse(paths.contains("root.md"))
        XCTAssertFalse(paths.contains { $0.hasSuffix(".swift") })
    }

    /// Git sidebar lists working files only — paths already deleted from disk
    /// (git `D`, Trash, missing) are omitted.
    @MainActor
    func testWorkspaceSnapshotOmitsDeletedMarkdown() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let ws = repo.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let kept = ws.appendingPathComponent("kept.md")
        let gone = ws.appendingPathComponent("gone.md")
        try "keep\n".write(to: kept, atomically: true, encoding: .utf8)
        try "drop\n".write(to: gone, atomically: true, encoding: .utf8)
        let addKeep = GitCLI.commit(file: kept, message: "add kept")
        guard case .success = addKeep else {
            return XCTFail("commit kept failed: \(addKeep)")
        }
        let addGone = GitCLI.commit(file: gone, message: "add gone")
        guard case .success = addGone else {
            return XCTFail("commit gone failed: \(addGone)")
        }
        try FileManager.default.removeItem(at: gone)
        try "edited\n".write(to: kept, atomically: true, encoding: .utf8)

        let snap = GitWorkspaceStatus.snapshot(workspaceRoots: [ws], openURLs: [])
        XCTAssertEqual(snap.sections.count, 1)
        let paths = snap.sections[0].files.map(\.displayPath)
        XCTAssertEqual(paths, ["kept.md"])
        XCTAssertFalse(paths.contains("gone.md"))
        XCTAssertFalse(snap.sections[0].files.contains { $0.pathStatus == .deleted })
    }

    /// Even if registry still has a path open, a missing file must not reappear
    /// under openDirty after trash / external delete.
    @MainActor
    func testWorkspaceSnapshotOmitsMissingOpenDirty() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let ws = repo.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let missing = ws.appendingPathComponent("buffer-only.md")
        // Not on disk — openURLs can still name it after a trash.
        let snap = GitWorkspaceStatus.snapshot(
            workspaceRoots: [ws],
            openURLs: [missing])
        XCTAssertTrue(snap.openDirty.isEmpty)
        XCTAssertTrue(snap.sections.allSatisfy(\.files.isEmpty))
    }

    /// Sidebar groups by adopted folder, so two folders sharing one repository
    /// stay two sections and each file is listed under exactly one of them.
    @MainActor
    func testWorkspaceSnapshotGroupsByWorkspaceNotRepo() throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let fm = FileManager.default
        let vault = repo.appendingPathComponent("vault", isDirectory: true)
        let notes = repo.appendingPathComponent("notes", isDirectory: true)
        // Nested adoption: files under it belong to the deepest folder only.
        let inner = notes.appendingPathComponent("inner", isDirectory: true)
        for dir in [vault, notes, inner] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try "a\n".write(to: vault.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b\n".write(to: notes.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try "c\n".write(to: inner.appendingPathComponent("c.md"), atomically: true, encoding: .utf8)

        let snap = GitWorkspaceStatus.snapshot(
            workspaceRoots: [vault, notes, inner],
            openURLs: []
        )
        XCTAssertEqual(snap.sections.count, 3)
        // Section order follows the adopted-folder order, not the repo path.
        XCTAssertEqual(snap.sections.map(\.workspace.lastPathComponent),
                       ["vault", "notes", "inner"])
        XCTAssertTrue(snap.sections.allSatisfy { $0.root == repo })
        XCTAssertEqual(snap.sections[0].files.map(\.displayPath), ["a.md"])
        XCTAssertEqual(snap.sections[1].files.map(\.displayPath), ["b.md"])
        XCTAssertEqual(snap.sections[2].files.map(\.displayPath), ["c.md"])
        XCTAssertEqual(snap.changedCount, 3)
    }

    /// The group header shows the sidebar's (possibly custom) folder name.
    @MainActor
    func testWorkspaceSnapshotKeepsCustomFolderName() async throws {
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let repo = try makeTempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }

        let snap = await GitWorkspaceStatus.snapshotAsync(
            workspaces: [GitWorkspaceInput(url: repo, name: "My Vault")],
            openURLs: []
        )
        XCTAssertEqual(snap.sections.map(\.name), ["My Vault"])
        XCTAssertFalse(snap.sections[0].isNestedInRepo)
    }

    // MARK: - Sidebar disclosure rules

    /// Default: dirty folders open, clean folders collapsed, no stored state.
    func testDisclosureDefaultsFollowDirtiness() {
        let none = Set<String>()
        XCTAssertTrue(GitSidebarDisclosure.isExpanded(
            id: "a", hasChanges: true, expanded: none, collapsed: none, filtering: false))
        XCTAssertFalse(GitSidebarDisclosure.isExpanded(
            id: "a", hasChanges: false, expanded: none, collapsed: none, filtering: false))
        // A filter forces every surviving group open regardless of overrides.
        XCTAssertTrue(GitSidebarDisclosure.isExpanded(
            id: "a", hasChanges: false, expanded: none, collapsed: ["a"], filtering: true))
    }

    func testDisclosureOverridesWinOverDefault() {
        XCTAssertFalse(GitSidebarDisclosure.isExpanded(
            id: "a", hasChanges: true, expanded: [], collapsed: ["a"], filtering: false))
        XCTAssertTrue(GitSidebarDisclosure.isExpanded(
            id: "a", hasChanges: false, expanded: ["a"], collapsed: [], filtering: false))
    }

    /// Toggling back to the derived default stores nothing — overrides only
    /// exist while they disagree with it.
    func testDisclosureToggleStoresOnlyDivergence() {
        // Dirty folder collapsed by hand → recorded.
        let collapsedDirty = GitSidebarDisclosure.toggled(
            id: "a", hasChanges: true, expanded: [], collapsed: [])
        XCTAssertEqual(collapsedDirty.collapsed, ["a"])
        XCTAssertTrue(collapsedDirty.expanded.isEmpty)

        // Expanding it again matches the default → override dropped.
        let backToDefault = GitSidebarDisclosure.toggled(
            id: "a", hasChanges: true, expanded: [], collapsed: ["a"])
        XCTAssertTrue(backToDefault.collapsed.isEmpty)
        XCTAssertTrue(backToDefault.expanded.isEmpty)

        // Clean folder opened by hand → recorded.
        let openedClean = GitSidebarDisclosure.toggled(
            id: "b", hasChanges: false, expanded: [], collapsed: [])
        XCTAssertEqual(openedClean.expanded, ["b"])
    }

    /// A folder collapsed while dirty must not stay pinned closed for the next
    /// dirty cycle: once it is clean the override equals the default and goes.
    func testDisclosurePruneDropsRedundantOverrides() {
        let pruned = GitSidebarDisclosure.pruned(
            expanded: ["dirty", "gone"],
            collapsed: ["clean", "stillDirty"],
            defaults: ["dirty": true, "clean": false, "stillDirty": true]
        )
        // Redundant with the derived default → dropped.
        XCTAssertFalse(pruned.expanded.contains("dirty"))
        XCTAssertFalse(pruned.collapsed.contains("clean"))
        // Still diverging → kept.
        XCTAssertTrue(pruned.collapsed.contains("stillDirty"))
        // Folder absent from this snapshot → left alone.
        XCTAssertTrue(pruned.expanded.contains("gone"))
    }

    /// The header count and "is clean" must come from the section, not from the
    /// filtered subset, or a filter would repaint a dirty folder as clean.
    func testFilteredGroupKeepsSectionTruth() {
        let ws = URL(fileURLWithPath: "/vault")
        let file = GitChangedFile(
            url: ws.appendingPathComponent("a.md"),
            displayPath: "a.md",
            pathStatus: .modified,
            sessionDirtyLines: 0,
            bufferDirty: false
        )
        let section = GitRepoSection(
            workspace: ws, name: "vault", root: ws,
            branch: "main", ahead: 0, behind: 0, files: [file]
        )
        let filteredOut = GitSidebarGroup(section: section, files: [])
        XCTAssertTrue(filteredOut.hasChanges)
        XCTAssertTrue(filteredOut.hiddenByFilter)

        let clean = GitSidebarGroup(
            section: GitRepoSection(
                workspace: ws, name: "vault", root: ws,
                branch: "main", ahead: 0, behind: 0, files: []
            ),
            files: []
        )
        XCTAssertFalse(clean.hasChanges)
        XCTAssertFalse(clean.hiddenByFilter)
    }

    // MARK: - Helpers

    private func makeTempRepo() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("editmd-git-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Identify for commit without global config.
        let envSetup = [
            "git", "init",
        ]
        _ = envSetup
        guard let git = GitCLI.gitExecutable else {
            throw XCTSkip("git missing")
        }
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = git
            p.arguments = args
            p.currentDirectoryURL = root
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                throw NSError(domain: "GitCLITests", code: Int(p.terminationStatus),
                              userInfo: [NSLocalizedDescriptionKey: "git \(args) failed"])
            }
        }
        try run(["init"])
        try run(["config", "user.email", "test@editmd.local"])
        try run(["config", "user.name", "EditMD Test"])
        // Avoid main/master surprises for branch name tests.
        try? run(["checkout", "-b", "main"])
        return root
    }
}
