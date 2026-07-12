import XCTest
@testable import EditMD

// Table editing sprint: TableGrid structure ops (columns, row move),
// cursor-relative table context in Source markdown, clipboard conversion
// (HTML tables from web/Word/Excel, TSV from spreadsheets).

// MARK: - TableGrid structure ops

final class TableGridStructureTests: XCTestCase {

    private func makeGrid() -> TableGrid {
        TableGrid(headers: ["A", "B", "C"],
                  rows: [["1", "2", "3"], ["4", "5", "6"]],
                  alignments: [.leading, .center, .trailing])
    }

    func testInsertColumnMiddle() {
        var grid = makeGrid()
        grid.insertColumn(at: 1)
        XCTAssertEqual(grid.headers, ["A", "", "B", "C"])
        XCTAssertEqual(grid.rows[0], ["1", "", "2", "3"])
        XCTAssertEqual(grid.alignments, [.leading, .leading, .center, .trailing])
    }

    func testInsertColumnAtEdges() {
        var grid = makeGrid()
        grid.insertColumn(at: 0)
        XCTAssertEqual(grid.headers, ["", "A", "B", "C"])
        grid.insertColumn(at: grid.columnCount)
        XCTAssertEqual(grid.headers, ["", "A", "B", "C", ""])
        XCTAssertEqual(grid.rows[1], ["", "4", "5", "6", ""])
    }

    func testInsertColumnPadsRaggedRow() {
        var grid = TableGrid(headers: ["A", "B", "C"],
                             rows: [["1"]],
                             alignments: [.leading, .leading, .leading])
        grid.insertColumn(at: 2)
        // Ragged row is shorter than the insertion point — the new cell lands
        // at the row's end and serialization pads the rest.
        XCTAssertEqual(grid.headers, ["A", "B", "", "C"])
        let serialized = serializeGFMTable(grid)
        let reparsed = parseGFMTable(serialized)
        XCTAssertEqual(reparsed?.columnCount, 4)
    }

    func testDeleteColumn() {
        var grid = makeGrid()
        XCTAssertTrue(grid.deleteColumn(at: 1))
        XCTAssertEqual(grid.headers, ["A", "C"])
        XCTAssertEqual(grid.rows[0], ["1", "3"])
        XCTAssertEqual(grid.alignments, [.leading, .trailing])
    }

    func testDeleteColumnKeepsAtLeastOne() {
        var grid = TableGrid(headers: ["only"], rows: [["x"]], alignments: [.leading])
        XCTAssertFalse(grid.deleteColumn(at: 0))
        XCTAssertEqual(grid.columnCount, 1)
    }

    func testDeleteColumnOutOfRange() {
        var grid = makeGrid()
        XCTAssertFalse(grid.deleteColumn(at: 3))
        XCTAssertFalse(grid.deleteColumn(at: -1))
    }

    func testMoveRowDown() {
        var grid = TableGrid(headers: ["H"],
                             rows: [["r0"], ["r1"], ["r2"]],
                             alignments: [.leading])
        // Move r0 to the gap after r1 (gap index 2).
        XCTAssertTrue(grid.moveRow(from: 0, toGap: 2))
        XCTAssertEqual(grid.rows.map { $0[0] }, ["r1", "r0", "r2"])
    }

    func testMoveRowUp() {
        var grid = TableGrid(headers: ["H"],
                             rows: [["r0"], ["r1"], ["r2"]],
                             alignments: [.leading])
        XCTAssertTrue(grid.moveRow(from: 2, toGap: 0))
        XCTAssertEqual(grid.rows.map { $0[0] }, ["r2", "r0", "r1"])
    }

    func testMoveRowNoOpGaps() {
        var grid = TableGrid(headers: ["H"],
                             rows: [["r0"], ["r1"]],
                             alignments: [.leading])
        XCTAssertFalse(grid.moveRow(from: 1, toGap: 1))   // gap before itself
        XCTAssertFalse(grid.moveRow(from: 1, toGap: 2))   // gap after itself
        XCTAssertFalse(grid.moveRow(from: 5, toGap: 0))   // out of range
        XCTAssertEqual(grid.rows.map { $0[0] }, ["r0", "r1"])
    }
}

// MARK: - Source table context

final class SourceTableContextTests: XCTestCase {

    private let doc = """
    Intro line.

    | Name | Qty | Price |
    | --- | :-: | --: |
    | Tea | 2 | 40 |
    | Coffee | 1 | 300 |

    Outro.
    """

    private func offset(of needle: String) -> Int {
        (doc as NSString).range(of: needle).location
    }

    func testHeaderLine() {
        let context = sourceTableContext(in: doc, at: offset(of: "Qty"))
        XCTAssertEqual(context?.line, 0)
        XCTAssertNil(context?.bodyIndex)
        XCTAssertEqual(context?.column, 1)
        XCTAssertEqual(context?.grid.headers, ["Name", "Qty", "Price"])
    }

    func testDelimiterLine() {
        let context = sourceTableContext(in: doc, at: offset(of: ":-:"))
        XCTAssertEqual(context?.line, 1)
        XCTAssertNil(context?.bodyIndex)
    }

    func testBodyCell() {
        let context = sourceTableContext(in: doc, at: offset(of: "300"))
        XCTAssertEqual(context?.line, 3)
        XCTAssertEqual(context?.bodyIndex, 1)
        XCTAssertEqual(context?.column, 2)
    }

    func testOutsideTable() {
        XCTAssertNil(sourceTableContext(in: doc, at: offset(of: "Intro")))
        XCTAssertNil(sourceTableContext(in: doc, at: offset(of: "Outro")))
    }

    func testTableRangeCoversWholeTable() {
        guard let context = sourceTableContext(in: doc, at: offset(of: "Tea")) else {
            return XCTFail("no context")
        }
        let text = (doc as NSString).substring(with: context.tableRange)
        XCTAssertTrue(text.hasPrefix("| Name"))
        XCTAssertTrue(text.hasSuffix("| Coffee | 1 | 300 |"))
        // Replacing the range with the canonical serialization round-trips.
        XCTAssertEqual(parseGFMTable(serializeGFMTable(context.grid))?.rows.count, 2)
    }

    func testBorderlessRowsColumnDetection() {
        let table = """
        Name | Qty
        --- | ---
        Tea | 2
        """
        let context = sourceTableContext(in: table,
                                         at: (table as NSString).range(of: "2").location)
        XCTAssertEqual(context?.column, 1)
        XCTAssertEqual(context?.bodyIndex, 0)
    }

    func testProseWithPipeAboveHeaderIsNotTable() {
        let text = """
        a|b prose
        | H1 | H2 |
        | --- | --- |
        | x | y |
        """
        // Cursor on the prose line: the table starts below it.
        XCTAssertNil(sourceTableContext(in: text, at: 0))
        // Cursor in the table body still resolves.
        let context = sourceTableContext(in: text,
                                         at: (text as NSString).range(of: "y").location)
        XCTAssertEqual(context?.bodyIndex, 0)
        XCTAssertEqual(context?.grid.headers, ["H1", "H2"])
    }

    func testRowInsertProducesValidMarkdown() {
        guard let context = sourceTableContext(in: doc, at: offset(of: "Tea")) else {
            return XCTFail("no context")
        }
        var grid = context.grid
        grid.insertRow(at: (context.bodyIndex ?? 0) + 1)
        let serialized = serializeGFMTable(grid)
        XCTAssertEqual(parseGFMTable(serialized)?.rows.count, 3)
        XCTAssertEqual(parseGFMTable(serialized)?.rows[1], ["", "", ""])
    }
}

// MARK: - Clipboard: TSV

final class TableClipboardTSVTests: XCTestCase {

    func testBasicTSVWithCRLF() {
        let grid = tableGridFromTSV("Name\tQty\r\nTea\t2\r\nCoffee\t1\r\n")
        XCTAssertEqual(grid?.headers, ["Name", "Qty"])
        XCTAssertEqual(grid?.rows, [["Tea", "2"], ["Coffee", "1"]])
    }

    func testLeadingEmptyCellSurvives() {
        let grid = tableGridFromTSV("\tQ1\tQ2\nRevenue\t10\t20")
        XCTAssertEqual(grid?.headers, ["", "Q1", "Q2"])
    }

    func testRaggedRowsPadded() {
        let grid = tableGridFromTSV("A\tB\tC\n1\t2")
        XCTAssertEqual(grid?.rows, [["1", "2", ""]])
    }

    func testRejectsProse() {
        XCTAssertNil(tableGridFromTSV("just a line\nanother line"))
        XCTAssertNil(tableGridFromTSV("one\tline only"))
        XCTAssertNil(tableGridFromTSV("a\tb\nno tab here\nc\td"))
        XCTAssertNil(tableGridFromTSV(""))
    }
}

// MARK: - Clipboard: HTML

final class TableClipboardHTMLTests: XCTestCase {

    func testBasicTableWithTH() {
        let html = "<table><tr><th>Name</th><th>Qty</th></tr>" +
                   "<tr><td>Tea</td><td>2</td></tr></table>"
        let md = markdownTablesFromHTML(html)
        XCTAssertEqual(md, "| Name | Qty |\n| --- | --- |\n| Tea | 2 |")
    }

    func testWordStyleWrappersStayDominant() {
        let html = """
        <html><body><p>&nbsp;</p>
        <table><tbody><tr><td>a</td><td>b</td></tr>
        <tr><td>c</td><td>d</td></tr></tbody></table>
        <p> </p></body></html>
        """
        let md = markdownTablesFromHTML(html)
        XCTAssertEqual(md, "| a | b |\n| --- | --- |\n| c | d |")
    }

    func testProseAroundTableRejects() {
        let html = "<p>Here is a paragraph of real text around the data.</p>" +
                   "<table><tr><td>a</td><td>b</td></tr></table>"
        XCTAssertNil(markdownTablesFromHTML(html))
    }

    func testInlineMarkupMapsToMarkdown() {
        let html = "<table><tr><th>K</th><th>V</th></tr>" +
                   "<tr><td><b>bold</b> and <code>code</code></td>" +
                   "<td><a href=\"https://x.y\">link</a></td></tr></table>"
        let md = markdownTablesFromHTML(html)
        XCTAssertNotNil(md)
        XCTAssertTrue(md?.contains("**bold** and `code`") == true, "\(md ?? "")")
        XCTAssertTrue(md?.contains("[link](https://x.y)") == true, "\(md ?? "")")
    }

    func testPipeInCellIsEscaped() {
        let html = "<table><tr><th>H</th><th>I</th></tr>" +
                   "<tr><td>a|b</td><td>c</td></tr></table>"
        let md = markdownTablesFromHTML(html)
        XCTAssertTrue(md?.contains("a\\|b") == true, "\(md ?? "")")
    }

    func testSingleColumnTableRejected() {
        // A copied Excel cell/column arrives as a 1-column <table> — that
        // should stay plain text, not become a degenerate pipe table.
        XCTAssertNil(markdownTablesFromHTML("<table><tr><td>lonely</td></tr></table>"))
        XCTAssertNil(markdownTablesFromHTML(
            "<table><tr><td>a</td></tr><tr><td>b</td></tr></table>"))
    }

    func testColspanPadsColumns() {
        let html = "<table><tr><th>A</th><th>B</th><th>C</th></tr>" +
                   "<tr><td colspan=\"2\">wide</td><td>x</td></tr></table>"
        let md = markdownTablesFromHTML(html)
        let grid = md.flatMap(parseGFMTable)
        XCTAssertEqual(grid?.columnCount, 3)
        XCTAssertEqual(grid?.rows.first, ["wide", "", "x"])
    }

    func testAlignmentAttributes() {
        let html = "<table><tr><th align=\"center\">A</th>" +
                   "<th style=\"text-align: right\">B</th></tr>" +
                   "<tr><td>1</td><td>2</td></tr></table>"
        let md = markdownTablesFromHTML(html)
        let grid = md.flatMap(parseGFMTable)
        XCTAssertEqual(grid?.alignments, [.center, .trailing])
    }

    func testMultipleTablesJoin() {
        let html = "<table><tr><td>a</td><td>b</td></tr></table>" +
                   "<table><tr><td>c</td><td>d</td></tr></table>"
        let md = markdownTablesFromHTML(html)
        XCTAssertEqual(md?.components(separatedBy: "\n\n").count, 2)
    }
}

// MARK: - Clipboard: decision funnel

final class TablePasteFunnelTests: XCTestCase {

    func testHTMLTableWins() {
        let md = markdownTableFromPasteboard(
            html: "<table><tr><td>a</td><td>b</td></tr></table>",
            plain: "a\tb")
        XCTAssertEqual(md, "| a | b |\n| --- | --- |")
    }

    func testTSVWhenNoHTML() {
        let md = markdownTableFromPasteboard(html: nil, plain: "A\tB\n1\t2")
        XCTAssertEqual(md, "| A | B |\n| --- | --- |\n| 1 | 2 |")
    }

    func testRichTextHTMLSuppressesTSV() {
        // HTML without a table = ordinary rich text; tabs in its plain form
        // must not become a table.
        let md = markdownTableFromPasteboard(html: "<p>hello</p>",
                                             plain: "a\tb\nc\td")
        XCTAssertNil(md)
    }

    func testPlainProseStaysNil() {
        XCTAssertNil(markdownTableFromPasteboard(html: nil, plain: "hello world"))
    }
}
