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
}
