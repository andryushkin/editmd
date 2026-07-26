import XCTest
@testable import EditMD

/// What a one-line field hands back: no control character may reach a path
/// component or markdown syntax, and nothing else may be touched.
final class SingleLineTextTests: XCTestCase {

    func testControlCharactersBecomeOneSpace() {
        XCTAssertEqual(singleLineFieldText("My\nNote"), "My Note")
        XCTAssertEqual(singleLineFieldText("My\tNote"), "My Note")
        XCTAssertEqual(singleLineFieldText("a\r\nb"), "a b")
        XCTAssertEqual(singleLineFieldText("  spaced \n"), "spaced")
    }

    func testTypedSpacesSurvive() {
        // Collapsing runs would rename a file behind the user's back: the rename
        // prompt is prefilled with the current name and confirmed unedited.
        XCTAssertEqual(singleLineFieldText("My  Note.md"), "My  Note.md")
        XCTAssertEqual(singleLineFieldText("Two words"), "Two words")
    }

    func testFormatCharactersSurvive() {
        // Cf, not Cc: a zero-width joiner holds an emoji together, and folding it
        // would split the sequence into its parts.
        XCTAssertEqual(singleLineFieldText("👨‍💻 Notes"), "👨‍💻 Notes")
        XCTAssertEqual(singleLineFieldText("🏳️‍🌈 Pride"), "🏳️‍🌈 Pride")
        XCTAssertEqual(singleLineFieldText("Neue\u{00AD}Notiz"), "Neue\u{00AD}Notiz")
    }

    func testControlCharactersAreDroppedForURLs() {
        // A space is no better than the tab it replaced inside a destination.
        XCTAssertEqual(withoutControlCharacters("https://x.com/a\tb"), "https://x.com/ab")
        XCTAssertEqual(withoutControlCharacters("a\r\nb"), "ab")
        XCTAssertEqual(withoutControlCharacters("👨‍💻"), "👨‍💻")
    }

    /// The naming funnel every create and rename goes through applies the filter,
    /// so no caller can bypass it.
    func testNamingFunnelFoldsThem() throws {
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "My\nNote"), "My Note.md")
        XCTAssertEqual(try FolderNaming.folderName(from: "My\tFolder"), "My Folder")
        XCTAssertEqual(try FolderNaming.markdownFileName(from: "My  Note.md"), "My  Note.md")
    }
}
