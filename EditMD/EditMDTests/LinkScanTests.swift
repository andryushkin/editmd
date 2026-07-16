import XCTest
@testable import EditMD

final class LinkScanTests: XCTestCase {

    // MARK: - Wiki forms

    func testWikiPlain() {
        let links = scanOutgoingLinks(text: "See [[Note]] here\n")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .wiki)
        XCTAssertEqual(links[0].rawTarget, "Note")
        XCTAssertEqual(links[0].label, "Note")
        XCTAssertNil(links[0].heading)
        XCTAssertEqual(links[0].line, 1)
        XCTAssertNil(links[0].resolved)
        XCTAssertTrue(links[0].candidates.isEmpty)
    }

    func testWikiAlias() {
        let links = scanOutgoingLinks(text: "[[Note|Display]]")
        XCTAssertEqual(links[0].rawTarget, "Note")
        XCTAssertEqual(links[0].label, "Display")
    }

    func testWikiHeading() {
        let links = scanOutgoingLinks(text: "[[Note#Section]]")
        XCTAssertEqual(links[0].rawTarget, "Note")
        XCTAssertEqual(links[0].heading, "Section")
    }

    func testWikiEmbedImage() {
        let links = scanOutgoingLinks(text: "pic ![[img.png]] end")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .image)
        XCTAssertEqual(links[0].rawTarget, "img.png")
    }

    // MARK: - Markdown links

    func testMarkdownRelative() {
        let links = scanOutgoingLinks(text: "see [plans](plans/02.md) please")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .markdown)
        XCTAssertEqual(links[0].rawTarget, "plans/02.md")
        XCTAssertEqual(links[0].label, "plans")
    }

    func testMarkdownAbsolutePath() {
        let links = scanOutgoingLinks(text: "[root](/docs/todo.md)")
        XCTAssertEqual(links[0].rawTarget, "/docs/todo.md")
    }

    func testMarkdownWithFragment() {
        let links = scanOutgoingLinks(text: "[x](note.md#Heading)")
        XCTAssertEqual(links[0].rawTarget, "note.md")
        XCTAssertEqual(links[0].heading, "Heading")
    }

    func testMarkdownNetworkExcluded() {
        let text = """
        [a](https://example.com) [b](http://x) [c](mailto:a@b.c)
        """
        XCTAssertTrue(scanOutgoingLinks(text: text).isEmpty)
    }

    func testMarkdownPureFragmentExcluded() {
        XCTAssertTrue(scanOutgoingLinks(text: "[jump](#section)").isEmpty)
    }

    func testMarkdownImage() {
        let links = scanOutgoingLinks(text: "![alt](assets/pic.png)")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].kind, .image)
        XCTAssertEqual(links[0].rawTarget, "assets/pic.png")
        XCTAssertEqual(links[0].label, "alt")
    }

    // MARK: - Code exclusion

    func testWikiInsideFenceIgnored() {
        let text = """
        outside [[Real]]
        ```
        [[Fake]]
        ```
        """
        let links = scanOutgoingLinks(text: text)
        XCTAssertEqual(links.map(\.rawTarget), ["Real"])
    }

    func testWikiInsideInlineCodeIgnored() {
        let links = scanOutgoingLinks(text: "x `[[Fake]]` y [[Real]]")
        XCTAssertEqual(links.map(\.rawTarget), ["Real"])
    }

    func testMarkdownInsideFenceIgnored() {
        let text = """
        [ok](a.md)
        ```
        [no](b.md)
        ```
        """
        XCTAssertEqual(scanOutgoingLinks(text: text).map(\.rawTarget), ["a.md"])
    }

    // MARK: - Multiple / UTF-16 / CRLF

    func testSeveralOnOneLine() {
        let links = scanOutgoingLinks(text: "[[A]] and [b](b.md) and [[C|c]]")
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links.map(\.rawTarget), ["A", "b.md", "C"])
    }

    func testCyrillicAndEmoji() {
        let links = scanOutgoingLinks(text: "см. [[Заметка 📝]] и [файл](папка/файл.md)")
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].rawTarget, "Заметка 📝")
        XCTAssertEqual(links[1].rawTarget, "папка/файл.md")
        XCTAssertFalse(links[0].context.isEmpty)
    }

    func testCRLFLineNumbers() {
        let text = "line1\r\n[[Note]]\r\nline3\r\n"
        let links = scanOutgoingLinks(text: text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].line, 2)
        XCTAssertTrue(links[0].context.contains("Note"))
    }

    func testEmpty() {
        XCTAssertTrue(scanOutgoingLinks(text: "").isEmpty)
    }

    // MARK: - Destination filter unit

    func testShouldIndexDestination() {
        XCTAssertTrue(shouldIndexLinkDestination("a.md"))
        XCTAssertTrue(shouldIndexLinkDestination("/vault/a.md"))
        XCTAssertTrue(shouldIndexLinkDestination("../x.md"))
        XCTAssertFalse(shouldIndexLinkDestination("#frag"))
        XCTAssertFalse(shouldIndexLinkDestination("https://x.com"))
        XCTAssertFalse(shouldIndexLinkDestination("mailto:a@b.c"))
        XCTAssertFalse(shouldIndexLinkDestination(""))
    }
}
