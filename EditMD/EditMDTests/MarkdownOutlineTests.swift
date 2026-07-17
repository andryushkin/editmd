import XCTest
@testable import EditMD

/// markdownOutline(_:) — the sidebar's heading extractor. Pure function of
/// the markdown text: levels, plain titles, UTF-16 jump offsets.
final class MarkdownOutlineTests: XCTestCase {

    func testEmptyTextYieldsNoItems() {
        XCTAssertEqual(markdownOutline(""), [])
    }

    func testTextWithoutHeadingsYieldsNoItems() {
        XCTAssertEqual(markdownOutline("plain paragraph\n\n- list item\n"), [])
    }

    func testLevelsAndTitles() {
        let md = "# One\n\ntext\n\n## Two\n\n### Three\n\n#### Four\n"
        let items = markdownOutline(md)
        XCTAssertEqual(items.map(\.level), [1, 2, 3, 4])
        XCTAssertEqual(items.map(\.title), ["One", "Two", "Three", "Four"])
    }

    func testInlineMarkupStrippedFromTitle() {
        // plainText drops emphasis markers and link destinations but keeps
        // inline-code backticks — fine for the outline display.
        let items = markdownOutline("# Hello **bold** and `code` [link](url)\n")
        XCTAssertEqual(items.first?.title, "Hello bold and `code` link")
    }

    func testOffsetsAreUTF16AndPointAtHeadingStart() {
        let md = "# Привет 🎯\n\ntext\n\n## Second\n"
        let items = markdownOutline(md)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].markdownOffset, 0)
        XCTAssertEqual(items[1].markdownOffset, ("# Привет 🎯\n\ntext\n\n" as NSString).length)
    }

    func testHeadingInsideCodeFenceIgnored() {
        let md = "```\n# not a heading\n```\n\n# Real\n"
        XCTAssertEqual(markdownOutline(md).map(\.title), ["Real"])
    }

    func testSetextHeadingsRecognized() {
        let md = "Title\n=====\n\nSub\n---\n"
        let items = markdownOutline(md)
        XCTAssertEqual(items.map(\.level), [1, 2])
        XCTAssertEqual(items.map(\.title), ["Title", "Sub"])
        XCTAssertEqual(items[0].markdownOffset, 0)
    }

    func testHeadingInsideBlockquoteIncluded() {
        let items = markdownOutline("> # Quoted\n")
        XCTAssertEqual(items.map(\.title), ["Quoted"])
        // offset points at the heading's own start (after "> ")
        XCTAssertEqual(items[0].markdownOffset, 2)
    }

    func testFrontmatterNotAHeadingAndOffsetsRebased() {
        // Without stripping, the closing `---` turns the YAML into a setext
        // h2 ("title: x") — the outline must contain only real headings, with
        // offsets valid in the ORIGINAL text (frontmatter included).
        let md = "---\ntitle: x\nicon: \"🎯\"\n---\n\n# Real\n\n## Sub\n"
        let items = markdownOutline(md)
        XCTAssertEqual(items.map(\.title), ["Real", "Sub"])
        XCTAssertEqual(items[0].markdownOffset,
                       ("---\ntitle: x\nicon: \"🎯\"\n---\n\n" as NSString).length)
    }

    func testFrontmatterOnlyDocumentYieldsNoItems() {
        XCTAssertEqual(markdownOutline("---\ntitle: x\n---"), [])
    }

    func testIDIsStablePerOffset() {
        let items = markdownOutline("# A\n\n# A\n")
        XCTAssertEqual(items.count, 2)
        XCTAssertNotEqual(items[0].id, items[1].id)
    }
}
