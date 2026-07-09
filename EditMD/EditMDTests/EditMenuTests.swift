import XCTest
import UniformTypeIdentifiers
@testable import EditMD

// MARK: - MarkdownDocument tests

@MainActor
final class MarkdownDocumentTests: XCTestCase {

    func testEmptyDocumentContent() {
        let doc = MarkdownDocument()
        XCTAssertEqual(doc.content, "")
        XCTAssertNil(doc.assetsFileWrapper)
    }

    func testReadableContentTypes() {
        let types = MarkdownDocument.readableContentTypes
        XCTAssertTrue(types.contains(.markdown))
        XCTAssertTrue(types.contains(.textBundle))
    }

    func testWritableContentTypes() {
        let types = MarkdownDocument.writableContentTypes
        XCTAssertTrue(types.contains(.markdown))
        XCTAssertTrue(types.contains(.textBundle))
    }

    func testSnapshotCapturesContent() throws {
        let doc = MarkdownDocument()
        doc.content = "Snapshot test"
        let snapshot = try doc.snapshot(contentType: .markdown)
        XCTAssertEqual(snapshot.content, "Snapshot test")
    }

    func testSnapshotCapturesAssets() throws {
        let doc = MarkdownDocument()
        doc.content = "With assets"
        doc.assetsFileWrapper = FileWrapper(directoryWithFileWrappers: [:])
        let snapshot = try doc.snapshot(contentType: .textBundle)
        XCTAssertEqual(snapshot.content, "With assets")
        XCTAssertNotNil(snapshot.assetsFileWrapper)
    }

    func testUTTypeMarkdownExists() {
        XCTAssertEqual(UTType.markdown.identifier, "net.daringfireball.markdown")
    }

    func testUTTypeTextBundleExists() {
        XCTAssertEqual(UTType.textBundle.identifier, "org.textbundle.package")
    }

    func testApplyUndoableContentUndoAndRedo() {
        let doc = MarkdownDocument()
        doc.content = "hello"
        doc.contentUndoManager.groupsByEvent = false

        doc.applyUndoableContent("~~hello~~", actionName: "Strikethrough")
        XCTAssertEqual(doc.content, "~~hello~~")
        XCTAssertTrue(doc.contentUndoManager.canUndo)
        XCTAssertFalse(doc.contentUndoManager.canRedo)

        doc.contentUndoManager.undo()
        XCTAssertEqual(doc.content, "hello")
        XCTAssertTrue(doc.contentUndoManager.canRedo)

        doc.contentUndoManager.redo()
        XCTAssertEqual(doc.content, "~~hello~~")
    }

    func testApplyUndoableContentNoOpWhenUnchanged() {
        let doc = MarkdownDocument()
        doc.content = "same"
        doc.contentUndoManager.groupsByEvent = false
        doc.applyUndoableContent("same", actionName: "X")
        XCTAssertFalse(doc.contentUndoManager.canUndo)
    }

    func testTypingCheckpointSurvivesAsDocumentUndo() {
        let doc = MarkdownDocument()
        doc.content = "hi"
        doc.contentUndoManager.groupsByEvent = false

        doc.beginContentEdit()
        doc.content = "hi!"
        doc.commitContentEdit(actionName: "Typing")

        XCTAssertEqual(doc.content, "hi!")
        XCTAssertTrue(doc.contentUndoManager.canUndo)
        doc.contentUndoManager.undo()
        XCTAssertEqual(doc.content, "hi")
    }
}
