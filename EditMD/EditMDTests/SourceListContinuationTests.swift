import XCTest
@testable import EditMD

// MARK: - Return auto-continuation of lists / checkboxes / tables (Source mode)

final class ListReturnActionTests: XCTestCase {

    // Caret at end of the line unless noted.
    private func action(_ line: String, caret: Int? = nil) -> ListReturnAction? {
        listReturnAction(line: line, caretColumn: caret ?? (line as NSString).length)
    }

    func testBulletContinues() {
        XCTAssertEqual(action("- item"), .insertMarker("- "))
        XCTAssertEqual(action("* item"), .insertMarker("* "))
        XCTAssertEqual(action("+ item"), .insertMarker("+ "))
    }

    func testBulletKeepsIndent() {
        XCTAssertEqual(action("    - nested"), .insertMarker("    - "))
    }

    func testChecklistContinuesUnchecked() {
        XCTAssertEqual(action("- [ ] todo"), .insertMarker("- [ ] "))
        XCTAssertEqual(action("- [x] done"), .insertMarker("- [ ] "))
        XCTAssertEqual(action("- [X] done"), .insertMarker("- [ ] "))
    }

    func testOrderedIncrements() {
        XCTAssertEqual(action("1. first"), .insertMarker("2. "))
        XCTAssertEqual(action("9. ninth"), .insertMarker("10. "))
        XCTAssertEqual(action("3) paren"), .insertMarker("4) "))
    }

    func testOrderedKeepsIndent() {
        XCTAssertEqual(action("  2. sub"), .insertMarker("  3. "))
    }

    func testEmptyBulletTerminates() {
        XCTAssertEqual(action("- "), .clearMarker(NSRange(location: 0, length: 2)))
    }

    func testEmptyChecklistTerminates() {
        XCTAssertEqual(action("- [ ] "), .clearMarker(NSRange(location: 0, length: 6)))
    }

    func testEmptyOrderedTerminates() {
        XCTAssertEqual(action("1. "), .clearMarker(NSRange(location: 0, length: 3)))
    }

    func testEmptyNestedBulletClearsWholePrefix() {
        // Indent is part of the marker prefix and is cleared with it.
        XCTAssertEqual(action("  - "), .clearMarker(NSRange(location: 0, length: 4)))
    }

    func testNonListLineIsNil() {
        XCTAssertNil(action("plain text"))
        XCTAssertNil(action(""))
        XCTAssertNil(action("# heading"))
    }

    func testCaretInsideMarkerIsNil() {
        // Caret sits in the indentation / marker, before the content.
        XCTAssertNil(action("- item", caret: 1))
    }

    func testCaretMidContentStillContinues() {
        // Splitting a line still gets a marker on the moved tail.
        XCTAssertEqual(action("- hello world", caret: 4), .insertMarker("- "))
    }

    func testDashWithoutSpaceIsNotAList() {
        XCTAssertNil(action("-notalist"))
    }
}

final class PipeRowTests: XCTestCase {

    func testEmptyPipeRowShape() {
        XCTAssertEqual(emptyPipeRow(columns: 1), "|  |")
        XCTAssertEqual(emptyPipeRow(columns: 3), "|  |  |  |")
    }

    func testPipeRowIsEmpty() {
        XCTAssertTrue(pipeRowIsEmpty("|  |  |"))
        XCTAssertTrue(pipeRowIsEmpty("| |"))
        XCTAssertFalse(pipeRowIsEmpty("| a |  |"))
        XCTAssertFalse(pipeRowIsEmpty("   "))
        XCTAssertFalse(pipeRowIsEmpty(""))
    }
}
