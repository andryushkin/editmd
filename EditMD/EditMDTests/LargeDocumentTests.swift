import XCTest
@testable import EditMD

/// Large / table-heavy document handling (the "hang on open" fix):
/// - `markdownIsHeavy` classification (gates Source highlight + lint),
/// - big tables render as a monospace island instead of a native NSTextTable
///   (whose per-cell layout pegs the CPU), while small tables stay native,
/// - the island still round-trips the table verbatim.
final class LargeDocumentTests: XCTestCase {

    // MARK: markdownIsHeavy

    func testSmallDocumentIsNotHeavy() {
        XCTAssertFalse(markdownIsHeavy("# Title\n\nsome text\n"))
        XCTAssertFalse(markdownIsHeavy(""))
    }

    func testHugeDocumentIsHeavyBySize() {
        XCTAssertTrue(markdownIsHeavy(String(repeating: "x", count: 250_000)))
    }

    func testMediumProseIsNotHeavy() {
        // ~62K of prose, no tables → stays highlighted in Source.
        let prose = String(repeating: "the quick brown fox jumps\n", count: 2400)
        XCTAssertGreaterThan(prose.utf16.count, 40_000)
        XCTAssertLessThan(prose.utf16.count, 200_000)
        XCTAssertFalse(markdownIsHeavy(prose))
    }

    func testMediumTableHeavyIsHeavy() {
        // ~60K dominated by table rows → heavy (plain Source).
        let table = String(repeating: "| aaaa | bbbb | cccc |\n", count: 2000)
        XCTAssertGreaterThan(table.utf16.count, 40_000)
        XCTAssertLessThan(table.utf16.count, 200_000)
        XCTAssertTrue(markdownIsHeavy(table))
    }

    // MARK: Table island fallback

    private func bigTableMarkdown(rows: Int) -> String {
        var md = "| A | B | C | D |\n| --- | --- | --- | --- |\n"
        for i in 0..<rows { md += "| \(i)a | \(i)b | \(i)c | \(i)d |\n" }
        return md
    }

    func testSmallTableStaysNative() {
        let attr = renderMarkdownToAttributed("| a | b |\n| --- | --- |\n| 1 | 2 |")
        let block = attr.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock
        if case .tableCell = block?.kind {} else {
            XCTFail("small table should stay a native NSTextTable (tableCell block)")
        }
    }

    func testLargeTableBecomesIsland() {
        // 200 rows × 4 cols = 800 cells > the native-table budget.
        let attr = renderMarkdownToAttributed(bigTableMarkdown(rows: 200))
        let block = attr.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock
        if case .raw = block?.kind {} else {
            XCTFail("large table should fall back to a monospace .raw island")
        }
        // No tableCell blocks anywhere (the whole table is one island).
        attr.enumerateAttribute(.mdBlock, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if case .tableCell = (value as? MDBlock)?.kind {
                XCTFail("island table must not emit tableCell blocks")
            }
        }
    }

    func testLargeTableRoundTrips() {
        let md = bigTableMarkdown(rows: 200)
        let once = serializeAttributedToMarkdown(renderMarkdownToAttributed(md))
        // Idempotent, and the row data survives verbatim.
        let twice = serializeAttributedToMarkdown(renderMarkdownToAttributed(once))
        XCTAssertEqual(once, twice)
        XCTAssertTrue(once.contains("| 199a | 199b | 199c | 199d |"),
                      "island must preserve the table rows verbatim")
    }
}
