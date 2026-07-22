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

    // MARK: editable grid + serialization

    func testSerializePreservesAlignmentsAndEscapes() {
        // Cell strings are inline markdown: a bare pipe gets the structural
        // escape, an existing backslash pair passes through verbatim.
        let grid = TableGrid(
            headers: ["A", "B"],
            rows: [["x|y", #"a\b"#]],
            alignments: [.center, .trailing]
        )
        XCTAssertEqual(
            serializeGFMTable(grid),
            "| A | B |\n| :-: | --: |\n| x\\|y | a\\b |"
        )
    }

    func testGridMutationKeepsMarkdownEscapesVerbatim() throws {
        // `\_` / `\[` are markdown escapes inside cell markdown. Re-escaping
        // their backslashes made every row op grow them: `\_` → `\\_` → `\\\\_`.
        let raw = "| A |\n| --- |\n| vitamin\\_d |\n| pdf\\_x \\[9\\] |"
        var grid = try XCTUnwrap(parseGFMTable(raw))
        grid.insertRow(at: 0)
        let serialized = serializeGFMTable(grid)
        XCTAssertTrue(serialized.contains("| vitamin\\_d |"), serialized)
        XCTAssertTrue(serialized.contains("| pdf\\_x \\[9\\] |"), serialized)
        XCTAssertEqual(serializeGFMTable(try XCTUnwrap(parseGFMTable(serialized))),
                       serialized)
    }

    func testSplitTreatsEscapedBackslashPipeAsBoundary() {
        // `\\|` = literal backslash, then a STRUCTURAL pipe: three cells.
        XCTAssertEqual(splitTableRow(#"| a\\ | b | c |"#), [#"a\\"#, "b", "c"])
    }

    func testUpdateInsertDeleteRowFlow() {
        var grid = TableGrid(
            headers: ["A", "B"],
            rows: [["1", "2"]],
            alignments: [.leading, .leading]
        )
        grid.updateCell(row: 0, column: 1, value: "BB")
        grid.updateCell(row: 1, column: 0, value: "11")
        grid.insertRow(at: 1)
        grid.updateCell(row: 2, column: 1, value: "tail")
        XCTAssertEqual(grid.headers, ["A", "BB"])
        XCTAssertEqual(grid.rows, [["11", "2"], ["", "tail"]])

        XCTAssertTrue(grid.deleteRow(at: 0))
        XCTAssertEqual(grid.rows, [["", "tail"]])
        XCTAssertFalse(grid.deleteRow(at: 5))
    }

    func testGridParseSerializeRoundTrip() throws {
        let raw = "| l | c | r |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |"
        let grid = try XCTUnwrap(parseGFMTable(raw))
        XCTAssertEqual(parseGFMTable(serializeGFMTable(grid)), grid)
    }

    func testEditFlowRoundTripKeepsAlignmentAndEscaping() throws {
        var grid = try XCTUnwrap(parseGFMTable("| A | B |\n| :-- | --: |\n| 1 | 2 |"))
        grid.updateCell(row: 1, column: 0, value: "x|y")
        grid.insertRow(at: 1)
        grid.updateCell(row: 2, column: 1, value: #"a\b"#)
        let serialized = serializeGFMTable(grid)
        XCTAssertEqual(serialized, "| A | B |\n| --- | --: |\n| x\\|y | 2 |\n|  | a\\b |")
        let reparsed = try XCTUnwrap(parseGFMTable(serialized))
        XCTAssertEqual(reparsed.alignments, [.leading, .trailing])
        XCTAssertEqual(reparsed.rows, [["x|y", "2"], ["", #"a\b"#]])
    }

    func testParseSerializeLargeTablePerformance() {
        var lines = ["| A | B | C |", "| --- | --- | --- |"]
        for i in 0..<2000 {
            lines.append("| \(i) | value-\(i) | \(i * 2) |")
        }
        let raw = lines.joined(separator: "\n")
        measure {
            guard let grid = parseGFMTable(raw) else {
                XCTFail("expected table")
                return
            }
            _ = serializeGFMTable(grid)
        }
    }

    // MARK: renderTableCellAttributed (large-table Visual inline markdown)

    private func cellAttr(_ md: String) -> NSAttributedString {
        renderTableCellAttributed(md,
                                  baseFont: .systemFont(ofSize: 14),
                                  textColor: .labelColor,
                                  linkColor: .linkColor,
                                  codeColor: .systemOrange)
    }

    private func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
    }

    private func isItalic(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic)
    }

    func testCellRenderStripsBoldMarkers() {
        let attr = cellAttr("**bold**")
        XCTAssertEqual(attr.string, "bold")
        let font = attr.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertNotNil(font)
        XCTAssertTrue(isBold(font!), "expected bold font for **…**")
    }

    func testCellRenderItalicStrikeCode() {
        let italic = cellAttr("*em*")
        XCTAssertEqual(italic.string, "em")
        XCTAssertTrue(isItalic(italic.attribute(.font, at: 0, effectiveRange: nil) as! NSFont))

        let strike = cellAttr("~~gone~~")
        XCTAssertEqual(strike.string, "gone")
        let strikeStyle = strike.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(strikeStyle, NSUnderlineStyle.single.rawValue)

        let code = cellAttr("`x`")
        XCTAssertEqual(code.string, "x")
        // Code: monospaced + tint + background (markers stripped).
        let codeFont = code.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        XCTAssertEqual(codeFont.pointSize, mono.pointSize)
        XCTAssertEqual(codeFont.fontName, mono.fontName)
        XCTAssertNotNil(code.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNotNil(code.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    func testCellRenderLinkAndWikiLink() {
        let link = cellAttr("[label](https://example.com)")
        XCTAssertEqual(link.string, "label")
        let underline = link.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(underline, NSUnderlineStyle.single.rawValue)

        let wiki = cellAttr("[[Note|alias]]")
        XCTAssertEqual(wiki.string, "alias")
        let wikiUnderline = wiki.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(wikiUnderline, NSUnderlineStyle.single.rawValue)

        let wikiBare = cellAttr("[[Target]]")
        XCTAssertEqual(wikiBare.string, "Target")
    }

    func testCellRenderMixedAndPlain() {
        let mixed = cellAttr("a **b** c")
        XCTAssertEqual(mixed.string, "a b c")
        // "b" run should be bold.
        var boldRange = NSRange()
        let fontAtB = mixed.attribute(.font, at: 2, effectiveRange: &boldRange) as? NSFont
        XCTAssertTrue(isBold(fontAtB!))

        let plain = cellAttr("just text")
        XCTAssertEqual(plain.string, "just text")

        let empty = cellAttr("")
        XCTAssertEqual(empty.string, "")
    }

    func testCellRenderDoesNotLeakMarkersIntoPlainCells() {
        // Escaped-looking content and partial markers stay literal when unparsed.
        let partial = cellAttr("2 * 3 = 6")
        XCTAssertEqual(partial.string, "2 * 3 = 6")
    }

    // MARK: - Variable row height geometry (wrap)

    func testIslandRowGeometryOffsetsAndLookup() {
        let heights: [CGFloat] = [20, 40, 30]
        XCTAssertEqual(tableIslandTotalHeight(heights), 90)
        XCTAssertEqual(tableIslandRowOffset(heights, row: 0), 0)
        XCTAssertEqual(tableIslandRowOffset(heights, row: 1), 20)
        XCTAssertEqual(tableIslandRowOffset(heights, row: 2), 60)
        XCTAssertEqual(tableIslandRowOffset(heights, row: 3), 90)

        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: -1), 0)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 0), 0)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 19.9), 0)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 20), 1)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 59.9), 1)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 60), 2)
        XCTAssertEqual(tableIslandRowIndex(heights: heights, localY: 200), 2)
    }
}
