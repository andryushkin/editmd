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
