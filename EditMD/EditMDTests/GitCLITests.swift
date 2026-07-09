import XCTest
@testable import EditMD

final class GitCLITests: XCTestCase {

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
