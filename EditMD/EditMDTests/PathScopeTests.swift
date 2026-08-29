import XCTest
@testable import EditMD

/// The three corners of text containment, and the relative path that follows.
final class PathScopeTests: XCTestCase {

    func testAPathUnderARootIsInsideIt() {
        XCTAssertEqual(PathScope.relative("/vault/a/b.md", under: "/vault"), "a/b.md")
        XCTAssertTrue(PathScope.contains("/vault/a/b.md", under: "/vault"))
    }

    /// The root itself is inside itself, and says so with an empty relative
    /// path — callers that must reject it look for exactly that.
    func testTheRootItselfIsInsideItselfAndRelativizesToNothing() {
        XCTAssertEqual(PathScope.relative("/vault", under: "/vault"), "")
        XCTAssertTrue(PathScope.contains("/vault", under: "/vault"))
    }

    /// `root + "/"` asks for a prefix `//` and matches nothing, so a workspace
    /// adopted at the filesystem root used to own no file.
    func testTheFilesystemRootContainsEverything() {
        XCTAssertEqual(PathScope.relative("/etc/hosts", under: "/"), "etc/hosts")
        XCTAssertEqual(PathScope.relative("/", under: "/"), "")
        XCTAssertTrue(PathScope.contains("/vault/a.md", under: "/"))
    }

    /// Same failure one level down: a root carrying a trailing slash.
    func testARootSpelledWithATrailingSlash() {
        XCTAssertEqual(PathScope.relative("/vault/a.md", under: "/vault/"), "a.md")
        XCTAssertEqual(PathScope.relative("/vault", under: "/vault/"), "")
        XCTAssertEqual(PathScope.relative("/vault/", under: "/vault/"), "")
    }

    /// This one the hand-written form already got right; repairing the two
    /// above must not lose it.
    func testASiblingWhoseNameStartsWithTheRootsIsOutside() {
        XCTAssertNil(PathScope.relative("/vaultx/b.md", under: "/vault"))
        XCTAssertNil(PathScope.relative("/vaultx", under: "/vault"))
        XCTAssertFalse(PathScope.contains("/vaultx/b.md", under: "/vault"))
    }

    /// The root is inside itself but not *strictly* inside — the distinction
    /// the index and relative-path callers depend on.
    func testStrictContainmentExcludesTheRootItself() {
        XCTAssertFalse(PathScope.containsStrictly("/vault", under: "/vault"))
        XCTAssertFalse(PathScope.containsStrictly("/vault", under: "/vault/"))
        XCTAssertTrue(PathScope.containsStrictly("/vault/a.md", under: "/vault"))
        XCTAssertFalse(PathScope.containsStrictly("/vaultx", under: "/vault"))
        XCTAssertFalse(PathScope.containsStrictly("/", under: "/"))
    }

    func testAnUnrelatedPathIsOutside() {
        XCTAssertNil(PathScope.relative("/etc/hosts", under: "/vault"))
        XCTAssertFalse(PathScope.contains("/etc/hosts", under: "/vault"))
    }

    /// A nested root wins over its ancestor by producing the shorter relative
    /// path — the property `workspaceOwning` relies on.
    func testNestingProducesTheShorterRelativePath() {
        XCTAssertEqual(PathScope.relative("/a/b/c.md", under: "/a"), "b/c.md")
        XCTAssertEqual(PathScope.relative("/a/b/c.md", under: "/a/b"), "c.md")
    }
}
