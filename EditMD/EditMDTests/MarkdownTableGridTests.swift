import XCTest
@testable import EditMD

final class MarkdownTableGridTests: XCTestCase {

    // MARK: parseGFMTable

    func testParsesBasicTable() {
        let raw = """
        | Name | Age | City |
        | --- | --- | --- |
        | Alice | 30 | London |
        | Bob | 25 | Paris |
        """
        let grid = parseGFMTable(raw)
        XCTAssertNotNil(grid)
        XCTAssertEqual(grid?.headers, ["Name", "Age", "City"])
        XCTAssertEqual(grid?.rows.count, 2)
        XCTAssertEqual(grid?.rows[0], ["Alice", "30", "London"])
        XCTAssertEqual(grid?.rows[1], ["Bob", "25", "Paris"])
        XCTAssertEqual(grid?.columnCount, 3)
    }

    func testParsesAlignments() {
        let raw = """
        | L | C | R | D |
        | :-- | :-: | --: | --- |
        | a | b | c | d |
        """
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.alignments, [.leading, .center, .trailing, .leading])
    }

    func testAlignmentsPaddedToHeaderCount() {
        // Delimiter row shorter than header → remaining columns default leading.
        let raw = """
        | A | B | C |
        | :-: | --- |
        | x | y | z |
        """
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.alignments, [.center, .leading, .leading])
    }

    func testEscapedPipeIsLiteralInsideCell() {
        // Wiki-link alias separator inside a cell: `\|` is one cell, not two.
        let raw = """
        | Doc | Note |
        | --- | --- |
        | [[a\\|📄]] | ok |
        """
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.rows[0], ["[[a|📄]]", "ok"])
    }

    func testPreservesEmptyInteriorCell() {
        let raw = """
        | A | B | C |
        | --- | --- | --- |
        | x |  | z |
        """
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.rows[0], ["x", "", "z"])
    }

    func testSingleColumnTable() {
        let raw = """
        | Only |
        | --- |
        | one |
        | two |
        """
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.headers, ["Only"])
        XCTAssertEqual(grid?.rows.map { $0.first }, ["one", "two"])
    }

    func testTrailingBlankLinesIgnored() {
        let raw = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n"
        let grid = parseGFMTable(raw)
        XCTAssertEqual(grid?.rows.count, 1)
        XCTAssertEqual(grid?.rows[0], ["1", "2"])
    }

    // MARK: Rejections (fall back to plain island)

    func testRejectsNonTable() {
        XCTAssertNil(parseGFMTable("<div>hello</div>"))
        XCTAssertNil(parseGFMTable("just some text\nmore text"))
    }

    func testRejectsMissingDelimiterRow() {
        let raw = """
        | A | B |
        | 1 | 2 |
        """
        XCTAssertNil(parseGFMTable(raw))
    }

    func testRejectsHeaderWithoutPipe() {
        // Setext-like `Foo\n---`: header has no pipe → not a table.
        XCTAssertNil(parseGFMTable("Foo\n---"))
    }

    func testRejectsSingleLine() {
        XCTAssertNil(parseGFMTable("| A | B |"))
    }

    // MARK: splitTableRow specifics

    func testSplitRowWithoutBorderPipes() {
        XCTAssertEqual(splitTableRow("a | b | c"), ["a", "b", "c"])
    }

    func testSplitRowDropsBorderPipesOnly() {
        XCTAssertEqual(splitTableRow("| a | b |"), ["a", "b"])
    }

    // MARK: scanSourceTables (virtual column alignment)

    func testScanFindsTableAndAllRows() {
        let text = """
        # Title

        | A | B |
        | --- | --- |
        | x | y |
        | zz | ww |

        after
        """
        let tables = scanSourceTables(text)
        XCTAssertEqual(tables.count, 1)
        // 4 physical rows (header, delimiter, 2 body) × 2 cells = 8.
        XCTAssertEqual(tables[0].count, 8)
        XCTAssertEqual(Set(tables[0].map(\.column)), [0, 1])
    }

    func testScanSegmentRangesPointAtCellContent() {
        let text = "| A | B |\n| --- | --- |\n| xx | y |"
        let ns = text as NSString
        let cells = scanSourceTables(text)[0]
        // First body row's first cell content is " xx " between the pipes.
        let bodyFirst = cells.first { ns.substring(with: $0.segmentRange).contains("xx") }
        XCTAssertNotNil(bodyFirst)
        XCTAssertEqual(ns.substring(with: bodyFirst!.segmentRange), " xx ")
        // kernIndex sits just before the closing pipe.
        XCTAssertEqual(ns.character(at: bodyFirst!.kernIndex + 1), 0x7C)
    }

    func testScanTreatsEscapedPipeAsCellContent() {
        // `\|` inside a cell is not a column boundary → 2 cells per row, not 3.
        let text = "| Doc | Note |\n| --- | --- |\n| [[a\\|x]] | ok |"
        let cells = scanSourceTables(text)[0]
        let bodyRowColumns = cells.filter { $0.column >= 0 }
        // Each of the 3 rows has exactly 2 cells.
        XCTAssertEqual(cells.count, 6)
        XCTAssertEqual(bodyRowColumns.filter { $0.column == 1 }.count, 3)
    }

    func testScanIgnoresNonTables() {
        XCTAssertTrue(scanSourceTables("just text\nmore text\n").isEmpty)
        XCTAssertTrue(scanSourceTables("| a | b |\nno delimiter here").isEmpty)
    }
}
