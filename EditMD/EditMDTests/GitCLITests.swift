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
        // editmd itself is a git repo — pick a tracked file if git exists.
        guard GitCLI.gitExecutable != nil else {
            throw XCTSkip("git not installed")
        }
        let thisFile = URL(fileURLWithPath: #filePath)
        guard let root = GitCLI.repositoryRoot(containing: thisFile) else {
            throw XCTSkip("not inside a git work tree")
        }
        // Root itself may not have a single-file log; use this test file.
        let hash = GitCLI.lastCommitHash(touching: thisFile)
        // File may be untracked in a dirty worktree — only assert shape if present.
        if let hash {
            XCTAssertEqual(hash.count, 40, "full SHA-1 expected, got \(hash)")
            XCTAssertTrue(hash.allSatisfy(\.isHexDigit))
        }
        XCTAssertTrue(root.path.contains("editmd") || FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
    }
}
