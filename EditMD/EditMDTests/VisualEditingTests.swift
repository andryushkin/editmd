import XCTest
import AppKit
@testable import EditMD

/// Pure helpers behind Visual-mode editing semantics (v21).
final class VisualEditingTests: XCTestCase {

    func testVisualCalloutCarriesPresentationTypeWithoutChangingText() throws {
        for type in ["warning", "Domain-Type"] {
            let markdown = "> [!\(type)] Title\n> body"
            let attributed = renderMarkdownToAttributed(markdown)
            let block = try XCTUnwrap(attributed.attribute(
                .mdBlock, at: 0, effectiveRange: nil) as? MDBlock)
            XCTAssertEqual(block.calloutType, type)
            XCTAssertEqual(serializeAttributedToMarkdown(attributed), markdown)
        }
    }

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

    func testPreviewActionStripContainsOnlyReviewSelectionToolsAndThemes() {
        let ids = EditorActionStrip.toolIDs(
            for: .preview, showVisualExtras: false, showReviewAction: true)

        let themeIDs = PreviewTheme.allPresets.map { "theme.\($0.id)" }
        XCTAssertEqual(ids, ["strike", "highlight", "review"] + themeIDs)
        XCTAssertFalse(ids.contains("checklist"),
                       "Preview toggles existing task boxes in-page; it must not create lists")
        XCTAssertFalse(ids.contains("bold"))
        XCTAssertFalse(ids.contains("h1"))
    }

    func testPreviewWithoutSidebarOmitsReviewAction() {
        let ids = EditorActionStrip.toolIDs(
            for: .preview, showVisualExtras: false, showReviewAction: false)
        XCTAssertEqual(Array(ids.prefix(2)), ["strike", "highlight"])
        XCTAssertFalse(ids.contains("review"))
        XCTAssertTrue(ids.contains("theme.default"))
    }

    func testThemeGroupStaysOutOfEditingModes() {
        for mode in [EditorMode.source, .visual, .split] {
            XCTAssertFalse(EditorActionStrip.toolIDs(
                for: mode, showVisualExtras: true, showReviewAction: true)
                .contains { $0.hasPrefix("theme.") }, "\(mode)")
        }
    }

    func testSourceAndVisualKeepTheirEditingProfilesWithoutCopy() {
        let source = EditorActionStrip.toolIDs(
            for: .source, showVisualExtras: true, showReviewAction: true)
        let visual = EditorActionStrip.toolIDs(
            for: .visual, showVisualExtras: true, showReviewAction: true)

        XCTAssertTrue(source.contains("bold"))
        XCTAssertTrue(source.contains("image"))
        XCTAssertFalse(source.contains("review"))
        XCTAssertFalse(source.contains("copy"))
        XCTAssertFalse(source.contains("table"))
        XCTAssertTrue(visual.contains("table"))
        XCTAssertTrue(visual.contains("image"))
        XCTAssertFalse(visual.contains("copy"))
        // Column ops are Visual-only, via the strip Table menu / "…" overflow.
        XCTAssertTrue(visual.contains("table.addColumn"))
        XCTAssertTrue(visual.contains("table.delColumn"))
        XCTAssertFalse(source.contains("table.addColumn"))
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
        actions.insertImage = {}

        MarkdownPreviewView.Coordinator().bindToolbar(actions)

        XCTAssertNotNil(actions.toggleHighlight)
        XCTAssertNotNil(actions.toggleStrikethrough)
        XCTAssertNil(actions.toggleBold)
        XCTAssertNil(actions.toggleItalic)
        XCTAssertNil(actions.toggleChecklist)
        XCTAssertNil(actions.setHeading)
        XCTAssertNil(actions.insertImage)
    }

    // MARK: - Image insertion

    func testImageMarkdownEscapesAltAndWrapsSpacedDestination() {
        let asset = ImageInsertionAsset(source: "assets/my image(2).png",
                                        suggestedAlt: "my image")
        XCTAssertEqual(asset.markdown(alt: #"a[b]\c"#),
                       #"![a\[b\]\\c](<assets/my image(2).png>)"#)
    }

    func testUniqueImageAssetFilenamePreservesExtension() {
        let occupied: Set<String> = ["photo.png", "photo-2.png"]
        XCTAssertEqual(uniqueImageAssetFilename("photo.png", exists: occupied.contains),
                       "photo-3.png")
        XCTAssertEqual(uniqueImageAssetFilename("fresh.svg", exists: occupied.contains),
                       "fresh.svg")
    }

    @MainActor
    func testStoresClipboardImageBesidePlainMarkdownAndAvoidsCollision() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-image-insert-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let documentURL = dir.appendingPathComponent("note.md")
        try "".write(to: documentURL, atomically: true, encoding: .utf8)
        let document = MarkdownDocument()

        let first = try storeImageAsset(.data(Data([1, 2, 3]), filename: "Pasted image.png"),
                                        document: document, fileURL: documentURL)
        let second = try storeImageAsset(.data(Data([4]), filename: "Pasted image.png"),
                                         document: document, fileURL: documentURL)
        let repeated = try storeImageAsset(
            .data(Data([1, 2, 3]), filename: "another-name.png"),
            document: document, fileURL: documentURL)

        XCTAssertEqual(first.source, "assets/Pasted image.png")
        XCTAssertEqual(second.source, "assets/Pasted image-2.png")
        XCTAssertEqual(repeated.source, first.source)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(first.source)),
                       Data([1, 2, 3]))
    }

    @MainActor
    func testStoresImageInsideTextbundleWrapper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-textbundle-image-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Note.textbundle")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = MarkdownDocument()
        let asset = try storeImageAsset(.data(Data([9, 8]), filename: "diagram.svg"),
                                        document: document, fileURL: bundle)

        XCTAssertEqual(asset.source, "assets/diagram.svg")
        XCTAssertEqual(document.assetsFileWrapper?.fileWrappers?["diagram.svg"]?
            .regularFileContents, Data([9, 8]))
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(asset.source)),
                       Data([9, 8]))
    }

    @MainActor
    func testTextbundleReusesDiskAssetWhenWrapperIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-textbundle-dedup-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Note.textbundle")
        let assetsDirectory = bundle.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([7, 6, 5, 4])
        try bytes.write(to: assetsDirectory.appendingPathComponent("existing.png"))
        let document = MarkdownDocument()

        let asset = try storeImageAsset(.data(bytes, filename: "duplicate.png"),
                                        document: document, fileURL: bundle)

        XCTAssertEqual(asset.source, "assets/existing.png")
        XCTAssertEqual(document.assetsFileWrapper?.fileWrappers?["existing.png"]?
            .regularFileContents, bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: assetsDirectory.path),
                       ["existing.png"])
    }

    @MainActor
    func testTextbundleDoesNotReplaceHiddenAssetWithSameName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-textbundle-hidden-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Note.textbundle")
        let assetsDirectory = bundle.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDirectory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = assetsDirectory.appendingPathComponent(".hidden.png")
        try Data([1]).write(to: occupied)

        let asset = try storeImageAsset(.data(Data([2]), filename: ".hidden.png"),
                                        document: MarkdownDocument(), fileURL: bundle)

        XCTAssertEqual(asset.source, "assets/.hidden-2.png")
        XCTAssertEqual(try Data(contentsOf: occupied), Data([1]))
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(asset.source)),
                       Data([2]))
    }

    func testImageFileVersionChangesWhenFileBytesChangeAtSameURL() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-image-version-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url)
        let first = try XCTUnwrap(imageFileVersion(at: url))

        try Data([1, 2]).write(to: url, options: .atomic)
        let second = try XCTUnwrap(imageFileVersion(at: url))

        XCTAssertNotEqual(first, second)
    }

    @MainActor
    func testClipboardPNGBecomesImageCandidateButTextDoesNot() {
        let board = NSPasteboard(name: NSPasteboard.Name("editmd-image-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(Data([1, 2, 3]), forType: .png)
        guard case .data(let bytes, let filename)? = imageCandidate(from: board) else {
            return XCTFail("PNG pasteboard was not recognized")
        }
        XCTAssertEqual(bytes, Data([1, 2, 3]))
        XCTAssertTrue(filename.hasPrefix("Pasted image "))
        XCTAssertTrue(filename.hasSuffix(".png"))

        board.clearContents()
        board.setString("ordinary text", forType: .string)
        XCTAssertNil(imageCandidate(from: board))
    }

    /// The drag path shares `imageCandidate(from:)`: a Finder drag exposes the
    /// dropped file as a file-URL, which must resolve to a `.file` candidate for
    /// an image extension and be ignored for a non-image one.
    @MainActor
    func testFileURLPasteboardBecomesImageCandidate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let image = dir.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: image)
        let board = NSPasteboard(name: NSPasteboard.Name("editmd-drag-\(UUID().uuidString)"))
        board.clearContents()
        board.setString(image.absoluteString, forType: .fileURL)
        guard case .file(let url)? = imageCandidate(from: board) else {
            return XCTFail("image file URL was not recognized")
        }
        XCTAssertEqual(url.lastPathComponent, "photo.png")

        let text = dir.appendingPathComponent("notes.txt")
        try Data([0]).write(to: text)
        board.clearContents()
        board.setString(text.absoluteString, forType: .fileURL)
        XCTAssertNil(imageCandidate(from: board), "non-image file must not be an image drop")
    }

    func testSourcePasteConsumesTableBeforeImageFlavor() {
        var calls: [String] = []
        let handled = handleSourceSpecialPaste(
            insideFence: false,
            tableMarkdown: { calls.append("table-probe"); return "| A | B |" },
            insertTable: { _ in calls.append("table-insert") },
            insertImage: { calls.append("image"); return true },
            linkifySelection: { calls.append("link"); return true })

        XCTAssertTrue(handled)
        XCTAssertEqual(calls, ["table-probe", "table-insert"])
    }

    func testSourcePasteLinkifiesAfterImageBeforePlain() {
        var calls: [String] = []
        let handled = handleSourceSpecialPaste(
            insideFence: false,
            tableMarkdown: { calls.append("table"); return nil },
            insertTable: { _ in calls.append("insert") },
            insertImage: { calls.append("image"); return false },
            linkifySelection: { calls.append("link"); return true })

        XCTAssertTrue(handled)
        XCTAssertEqual(calls, ["table", "image", "link"],
                       "link door runs only after table and image decline")
    }

    func testSourceFenceSkipsTableAndImageDoors() {
        var calls: [String] = []
        let handled = handleSourceSpecialPaste(
            insideFence: true,
            tableMarkdown: { calls.append("table"); return "table" },
            insertTable: { _ in calls.append("insert") },
            insertImage: { calls.append("image"); return true },
            linkifySelection: { calls.append("link"); return true })

        XCTAssertFalse(handled)
        XCTAssertTrue(calls.isEmpty)
    }

    func testVisualPasteUsesMarkdownBeforeImageAndFallsBackOnFailure() {
        var calls: [String] = []
        XCTAssertTrue(handleVisualSpecialPaste(
            pasteMarkdown: { calls.append("markdown"); return true },
            pasteImage: { calls.append("image"); return true },
            pasteURLLink: { calls.append("link"); return true }))
        XCTAssertEqual(calls, ["markdown"])

        calls = []
        XCTAssertFalse(handleVisualSpecialPaste(
            pasteMarkdown: { calls.append("markdown"); return false },
            pasteImage: { calls.append("image"); return false },
            pasteURLLink: { calls.append("link"); return false }))
        XCTAssertEqual(calls, ["markdown", "image", "link"],
                       "false must reach NSTextView's plain-text fallback")
    }

    func testVisualLiteralAndStructuralContextsRejectImagePaste() {
        XCTAssertTrue(visualContextAllowsStructuredPaste(.paragraph))
        XCTAssertFalse(visualContextAllowsStructuredPaste(.codeBlock(language: "swift")))
        XCTAssertFalse(visualContextAllowsStructuredPaste(
            .tableCell(row: 0, column: 0, columns: 2, alignment: 0)))
        XCTAssertFalse(visualContextAllowsStructuredPaste(.raw("verbatim")))
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
