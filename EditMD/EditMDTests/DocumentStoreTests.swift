import XCTest
@testable import EditMD

/// Phase 1 gate: proves the extracted markdown/textbundle IO (DocumentStore.swift)
/// round-trips losslessly and that DocumentRegistry shares one model per URL and
/// saves without losing writes — validated BEFORE the scene moves off
/// DocumentGroup.
final class DocumentStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-doctests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Free-function round-trip

    func testMarkdownRoundTrip() throws {
        let url = tmp.appendingPathComponent("note.md")
        let content = "# Title\n\nБунтарь ✅ `code` — line.\n"
        try writeMarkdownDocument(content: content, assets: nil, to: url)

        let loaded = try loadMarkdownDocument(from: url)
        XCTAssertEqual(loaded.content, content)
        XCTAssertNil(loaded.assets)
        // On-disk bytes are exactly the UTF-8 content (plain .md, no wrapping).
        XCTAssertEqual(try Data(contentsOf: url), content.data(using: .utf8))
    }

    func testTextBundleRoundTripWithAssets() throws {
        let url = tmp.appendingPathComponent("note.textbundle")
        let content = "Body with image ![](assets/img.png)\n"
        let asset = FileWrapper(regularFileWithContents: Data([0x1, 0x2, 0x3]))
        asset.preferredFilename = "img.png"
        let assets = FileWrapper(directoryWithFileWrappers: ["img.png": asset])

        try writeMarkdownDocument(content: content, assets: assets, to: url)

        // Package shape: info.json + text.md + assets/img.png.
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("info.json").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: url.appendingPathComponent("assets/img.png").path))

        let loaded = try loadMarkdownDocument(from: url)
        XCTAssertEqual(loaded.content, content)
        XCTAssertEqual(loaded.assets?.fileWrappers?["img.png"]?.regularFileContents,
                       Data([0x1, 0x2, 0x3]))
    }

    // MARK: - Wrapper builder parity

    func testMakeWrapperPlainIsRawContent() {
        let wrapper = makeMarkdownWrapper(content: "hello", assets: nil, isTextBundle: false)
        XCTAssertFalse(wrapper.isDirectory)
        XCTAssertEqual(wrapper.regularFileContents, "hello".data(using: .utf8))
    }

    func testMakeWrapperTextBundleShape() {
        let wrapper = makeMarkdownWrapper(content: "hi", assets: nil, isTextBundle: true)
        XCTAssertTrue(wrapper.isDirectory)
        let keys = wrapper.fileWrappers?.keys.sorted()
        XCTAssertEqual(keys, ["info.json", "text.md"])
        XCTAssertEqual(wrapper.fileWrappers?["text.md"]?.regularFileContents,
                       "hi".data(using: .utf8))
    }

    // MARK: - DocumentRegistry

    @MainActor
    func testRegistrySharesOneModelPerURL() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("shared.md")
        try writeMarkdownDocument(content: "start", assets: nil, to: url)

        let a = try registry.acquire(url)
        let b = try registry.acquire(url)   // second window on the same file
        XCTAssertTrue(a === b, "same URL must resolve to one shared instance")
        XCTAssertEqual(a.content, "start")

        registry.release(url)               // one window closes
        XCTAssertTrue(registry.isOpen(url), "still held by the other window")
        registry.release(url)               // last window closes
        XCTAssertFalse(registry.isOpen(url))
    }

    @MainActor
    func testRegistrySaveNowWritesToDisk() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("edit.md")
        try writeMarkdownDocument(content: "old", assets: nil, to: url)

        let doc = try registry.acquire(url)
        doc.content = "new content"
        registry.markDirty(url)
        XCTAssertTrue(registry.isDirty(url))

        try registry.saveNow(url)
        XCTAssertFalse(registry.isDirty(url))
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "new content")

        registry.release(url)
    }

    @MainActor
    func testRegistryFlushesDirtyOnLastRelease() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("flush.md")
        try writeMarkdownDocument(content: "old", assets: nil, to: url)

        let doc = try registry.acquire(url)
        doc.content = "unsaved edit"
        registry.markDirty(url)
        registry.release(url)   // last release flushes before dropping the model

        XCTAssertFalse(registry.isOpen(url))
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "unsaved edit")
    }
}
