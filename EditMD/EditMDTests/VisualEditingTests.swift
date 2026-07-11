import XCTest
@testable import EditMD

/// Pure helpers behind Visual-mode editing semantics (v21).
final class VisualEditingTests: XCTestCase {

    // MARK: - Autoformat triggers

    func testDashBecomesBullet() {
        let result = autoformatKind(for: "- ", currentKind: .paragraph)
        XCTAssertEqual(result?.kind, .bulletItem(depth: 0))
        XCTAssertEqual(result?.consumed, 2)
    }

    func testBracketsBecomeTask() {
        let result = autoformatKind(for: "[] buy milk", currentKind: .paragraph)
        XCTAssertEqual(result?.kind, .taskItem(depth: 0, done: false))
        XCTAssertEqual(result?.consumed, 3)
    }

    func testBracketsInsideBulletKeepDepth() {
        let result = autoformatKind(for: "[] x", currentKind: .bulletItem(depth: 2))
        XCTAssertEqual(result?.kind, .taskItem(depth: 2, done: false))
    }

    func testHashesBecomeHeading() {
        XCTAssertEqual(autoformatKind(for: "## ", currentKind: .paragraph)?.kind, .heading(2))
        XCTAssertEqual(autoformatKind(for: "## ", currentKind: .paragraph)?.consumed, 3)
    }

    func testNumberBecomesOrderedItem() {
        let result = autoformatKind(for: "3. step", currentKind: .paragraph)
        XCTAssertEqual(result?.kind, .orderedItem(depth: 0, number: 3))
        XCTAssertEqual(result?.consumed, 3)
    }

    func testNoTriggerInsideHeading() {
        XCTAssertNil(autoformatKind(for: "- ", currentKind: .heading(1)))
        XCTAssertNil(autoformatKind(for: "[] ", currentKind: .codeBlock(language: "")))
    }

    func testPlainTextDoesNotTrigger() {
        XCTAssertNil(autoformatKind(for: "hello ", currentKind: .paragraph))
        XCTAssertNil(autoformatKind(for: "7 dwarfs", currentKind: .paragraph))
    }

    // MARK: - Enter continuation

    func testBulletContinues() {
        XCTAssertEqual(continuationKind(after: .bulletItem(depth: 1)), .bulletItem(depth: 1))
    }

    func testOrderedIncrementsNumber() {
        XCTAssertEqual(continuationKind(after: .orderedItem(depth: 0, number: 4)),
                       .orderedItem(depth: 0, number: 5))
    }

    func testTaskContinuesUnchecked() {
        XCTAssertEqual(continuationKind(after: .taskItem(depth: 0, done: true)),
                       .taskItem(depth: 0, done: false))
    }

    func testHeadingDoesNotContinue() {
        XCTAssertNil(continuationKind(after: .heading(2)))
        XCTAssertNil(continuationKind(after: .paragraph))
    }

    func testCodeBlockContinues() {
        XCTAssertEqual(continuationKind(after: .codeBlock(language: "swift")),
                       .codeBlock(language: "swift"))
    }

    // MARK: - Tab indent

    func testTabIndentsBullet() {
        XCTAssertEqual(indentedKind(.bulletItem(depth: 0), by: 1), .bulletItem(depth: 1))
        XCTAssertEqual(indentedKind(.taskItem(depth: 1, done: true), by: 1),
                       .taskItem(depth: 2, done: true))
    }

    func testShiftTabOutdents() {
        XCTAssertEqual(indentedKind(.bulletItem(depth: 2), by: -1), .bulletItem(depth: 1))
    }

    func testOutdentAtZeroReturnsNil() {
        XCTAssertNil(indentedKind(.bulletItem(depth: 0), by: -1))
    }

    func testIndentCapsAtFive() {
        XCTAssertNil(indentedKind(.bulletItem(depth: 5), by: 1))
    }

    func testIndentNotApplicableToParagraph() {
        XCTAssertNil(indentedKind(.paragraph, by: 1))
        XCTAssertNil(indentedKind(.heading(1), by: 1))
    }

    // MARK: - Table Tab navigation

    func testTabMovesToNextColumn() {
        XCTAssertEqual(nextTableCellPosition(row: 0, column: 0, columns: 3, rows: 2,
                                             forward: true)?.column, 1)
    }

    func testTabWrapsToNextRow() {
        let next = nextTableCellPosition(row: 0, column: 2, columns: 3, rows: 2, forward: true)
        XCTAssertEqual(next?.row, 1)
        XCTAssertEqual(next?.column, 0)
    }

    func testTabPastLastCellReturnsNil() {
        XCTAssertNil(nextTableCellPosition(row: 1, column: 2, columns: 3, rows: 2, forward: true))
    }

    func testShiftTabWrapsToPreviousRowLastColumn() {
        let previous = nextTableCellPosition(row: 1, column: 0, columns: 3, rows: 2, forward: false)
        XCTAssertEqual(previous?.row, 0)
        XCTAssertEqual(previous?.column, 2)
    }

    func testShiftTabBeforeFirstCellReturnsNil() {
        XCTAssertNil(nextTableCellPosition(row: 0, column: 0, columns: 3, rows: 2, forward: false))
    }

    // MARK: - Markdown paste detection

    func testMarkdownPasteRecognizesStructuredSyntax() {
        XCTAssertTrue(looksLikeMarkdownForVisualPaste("## Heading"))
        XCTAssertTrue(looksLikeMarkdownForVisualPaste("- one\n- two"))
        XCTAssertTrue(looksLikeMarkdownForVisualPaste("Text with **bold** and `code`"))
        XCTAssertTrue(looksLikeMarkdownForVisualPaste("[OpenAI](https://openai.com)"))
        XCTAssertTrue(looksLikeMarkdownForVisualPaste("| A | B |\n| --- | --- |\n| 1 | 2 |"))
    }

    func testMarkdownPasteLeavesOrdinaryTextPlain() {
        XCTAssertFalse(looksLikeMarkdownForVisualPaste("ordinary prose"))
        XCTAssertFalse(looksLikeMarkdownForVisualPaste("snake_case and 2 * 3"))
        XCTAssertFalse(looksLikeMarkdownForVisualPaste("a-b@example.com"))
        XCTAssertFalse(looksLikeMarkdownForVisualPaste(""))
    }

    func testMarkdownPasteKeepsMarkersInsideCodeBlock() {
        let markdown = "## Heading\n\n**bold** and `code`"
        XCTAssertTrue(shouldFormatVisualPaste(markdown, in: .paragraph))
        XCTAssertFalse(shouldFormatVisualPaste(markdown, in: .codeBlock(language: "swift")))
    }
}
