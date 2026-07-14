import XCTest
@testable import EditMD

/// Pure helpers behind Visual-mode editing semantics (v21).
final class VisualEditingTests: XCTestCase {

    func testEditorModesIncludeDedicatedSourcePreviewSplit() {
        XCTAssertEqual(EditorMode.allCases.map(\.rawValue),
                       ["source", "visual", "preview", "split"])
        XCTAssertEqual(EditorMode.split.title, "Split")
        XCTAssertEqual(EditorMode.split.shortcutHint, "⌘4")
    }

    func testOnlyTinyVisualLayoutDriftIsRestored() {
        XCTAssertFalse(SplitScrollSync.isMinorLayoutDrift(0.005))
        XCTAssertTrue(SplitScrollSync.isMinorLayoutDrift(2))
        XCTAssertTrue(SplitScrollSync.isMinorLayoutDrift(-4))
        XCTAssertFalse(SplitScrollSync.isMinorLayoutDrift(4.1))
        XCTAssertFalse(SplitScrollSync.isMinorLayoutDrift(20))
    }

    func testSplitActionStripMeasuresToolsAgainstTheSourcePane() {
        XCTAssertEqual(EditorActionStrip.resolvedEditingPaneWidth(
            stripWidth: 1200, editingPaneWidth: 600), 600)
        XCTAssertEqual(EditorActionStrip.resolvedEditingPaneWidth(
            stripWidth: 1200, editingPaneWidth: nil), 1200)
        XCTAssertEqual(EditorActionStrip.resolvedEditingPaneWidth(
            stripWidth: 500, editingPaneWidth: 700), 500)
    }

    func testPreviewActionStripContainsOnlyReviewSelectionTools() {
        let ids = EditorActionStrip.toolIDs(
            for: .preview, showVisualExtras: false, showReviewAction: true)

        XCTAssertEqual(ids, ["strike", "highlight", "review"])
        XCTAssertFalse(ids.contains("checklist"),
                       "Preview toggles existing task boxes in-page; it must not create lists")
        XCTAssertFalse(ids.contains("bold"))
        XCTAssertFalse(ids.contains("h1"))
    }

    func testPreviewWithoutSidebarOmitsReviewAction() {
        XCTAssertEqual(EditorActionStrip.toolIDs(
            for: .preview, showVisualExtras: false, showReviewAction: false),
                       ["strike", "highlight"])
    }

    func testSourceAndVisualKeepTheirEditingProfilesWithoutCopy() {
        let source = EditorActionStrip.toolIDs(
            for: .source, showVisualExtras: true, showReviewAction: true)
        let visual = EditorActionStrip.toolIDs(
            for: .visual, showVisualExtras: true, showReviewAction: true)

        XCTAssertTrue(source.contains("bold"))
        XCTAssertFalse(source.contains("review"))
        XCTAssertFalse(source.contains("copy"))
        XCTAssertFalse(source.contains("table"))
        XCTAssertTrue(visual.contains("table"))
        XCTAssertFalse(visual.contains("copy"))
    }

    func testSplitAddsReviewToSourceEditingProfile() {
        let ids = EditorActionStrip.toolIDs(
            for: .split, showVisualExtras: false, showReviewAction: true)

        XCTAssertTrue(ids.contains("bold"))
        XCTAssertTrue(ids.contains("review"))
        XCTAssertFalse(ids.contains("table"))
        XCTAssertEqual(EditorActionStrip.groupIDs(
            for: .split, showVisualExtras: false, showReviewAction: true),
                       ["inline", "paragraph", "lists", "review"])
    }

    func testSplitWithoutSidebarOmitsReviewAction() {
        XCTAssertFalse(EditorActionStrip.toolIDs(
            for: .split, showVisualExtras: false, showReviewAction: false)
            .contains("review"))
    }

    @MainActor
    func testPreviewCoordinatorClearsEditingCallbacksFromPreviousMode() {
        let actions = EditorStripActions()
        actions.toggleBold = {}
        actions.toggleItalic = {}
        actions.toggleChecklist = {}
        actions.setHeading = { _ in }

        MarkdownPreviewView.Coordinator().bindToolbar(actions)

        XCTAssertNotNil(actions.toggleHighlight)
        XCTAssertNotNil(actions.toggleStrikethrough)
        XCTAssertNil(actions.toggleBold)
        XCTAssertNil(actions.toggleItalic)
        XCTAssertNil(actions.toggleChecklist)
        XCTAssertNil(actions.setHeading)
    }

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
