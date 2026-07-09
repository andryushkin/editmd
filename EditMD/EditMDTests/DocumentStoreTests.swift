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
        registry.release(url)   // last release flushes; model parks in session cache

        XCTAssertFalse(registry.isOpen(url))
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "unsaved edit")
    }

    @MainActor
    func testRegistryKeepsPerFileUndoAcrossSwitch() throws {
        let registry = DocumentRegistry()
        let urlA = tmp.appendingPathComponent("a.md")
        let urlB = tmp.appendingPathComponent("b.md")
        try writeMarkdownDocument(content: "A0", assets: nil, to: urlA)
        try writeMarkdownDocument(content: "B0", assets: nil, to: urlB)

        let a = try registry.acquire(urlA)
        a.contentUndoManager.groupsByEvent = false
        a.applyUndoableContent("A1", actionName: "Edit A")
        XCTAssertTrue(a.contentUndoManager.canUndo)
        registry.release(urlA)   // switch away — not open, but session-cached
        XCTAssertFalse(registry.isOpen(urlA))

        let b = try registry.acquire(urlB)
        b.contentUndoManager.groupsByEvent = false
        b.applyUndoableContent("B1", actionName: "Edit B")
        registry.release(urlB)

        // Re-open A: same instance, independent undo stack still has the edit.
        let a2 = try registry.acquire(urlA)
        XCTAssertTrue(a2 === a, "session cache must return the same document")
        XCTAssertEqual(a2.content, "A1")
        XCTAssertTrue(a2.contentUndoManager.canUndo)
        a2.contentUndoManager.undo()
        XCTAssertEqual(a2.content, "A0")

        // B's history is separate.
        let b2 = try registry.acquire(urlB)
        XCTAssertTrue(b2 === b)
        XCTAssertEqual(b2.content, "B1")
        XCTAssertTrue(b2.contentUndoManager.canUndo)
        b2.contentUndoManager.undo()
        XCTAssertEqual(b2.content, "B0")

        registry.release(urlA)
        registry.release(urlB)
    }

    @MainActor
    func testRegistryReloadsExternalDiskChange() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("external.md")
        try writeMarkdownDocument(content: "- [ ] one\n", assets: nil, to: url)

        let doc = try registry.acquire(url)
        XCTAssertEqual(doc.content, "- [ ] one\n")

        // Agent / another app rewrites the open file on disk.
        try writeMarkdownDocument(content: "- [x] one\n- [x] two\n", assets: nil, to: url)
        // Bump mtime slightly in case the write is same-second as the original
        // (some filesystems only store second resolution).
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: url.path)

        XCTAssertTrue(registry.syncFromDiskIfNeeded(url),
                      "clean document must pick up external rewrite")
        XCTAssertEqual(doc.content, "- [x] one\n- [x] two\n")
        XCTAssertFalse(registry.isDirty(url))

        registry.release(url)
    }

    @MainActor
    func testRegistryKeepsDirtyOverExternalDiskChange() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("conflict.md")
        try writeMarkdownDocument(content: "disk-old", assets: nil, to: url)

        let doc = try registry.acquire(url)
        doc.content = "local-unsaved"
        registry.markDirty(url)

        try writeMarkdownDocument(content: "disk-new", assets: nil, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: url.path)

        XCTAssertFalse(registry.syncFromDiskIfNeeded(url),
                       "dirty buffer must not be clobbered by external write")
        XCTAssertEqual(doc.content, "local-unsaved")

        registry.release(url)
    }

    @MainActor
    func testRegistrySyncsSessionCacheOnReacquire() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("parked.md")
        try writeMarkdownDocument(content: "v1", assets: nil, to: url)

        let doc = try registry.acquire(url)
        registry.release(url)   // parks in session cache
        XCTAssertFalse(registry.isOpen(url))

        // External edit while parked — bump mtime so the registry sees it as newer.
        try writeMarkdownDocument(content: "v2-from-agent", assets: nil, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: url.path)

        let again = try registry.acquire(url)
        XCTAssertTrue(again === doc, "session cache should still return the same instance")
        XCTAssertEqual(again.content, "v2-from-agent",
                       "re-acquire must reload if disk changed while parked")

        registry.release(url)
    }

    @MainActor
    func testRegistrySessionCacheKeepsUnflushedMemory() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("unflushed.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: url)

        let doc = try registry.acquire(url)
        // In-memory edit without markDirty (undo stack still tracks it) — disk stays "disk".
        doc.contentUndoManager.groupsByEvent = false
        doc.applyUndoableContent("memory", actionName: "Edit")
        registry.release(url)

        let again = try registry.acquire(url)
        XCTAssertEqual(again.content, "memory",
                       "stale disk must not clobber session-cached buffer")
        XCTAssertTrue(again.contentUndoManager.canUndo)

        registry.release(url)
    }
}


final class TextDiffTests: XCTestCase {

    func testIdentical() {
        let r = lineDiff(before: "a\nb\n", after: "a\nb\n")
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.lines.count, 3) // a, b, trailing empty from final \n
        XCTAssertTrue(r.lines.allSatisfy { $0.kind == .same })
    }

    func testInsertLine() {
        let r = lineDiff(before: "a\nc\n", after: "a\nb\nc\n")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 0)
        let inserts = r.lines.filter { $0.kind == .insert }
        XCTAssertEqual(inserts.map(\.text), ["b"])
    }

    func testDeleteLine() {
        let r = lineDiff(before: "a\nb\nc\n", after: "a\nc\n")
        XCTAssertEqual(r.added, 0)
        XCTAssertEqual(r.removed, 1)
        let deletes = r.lines.filter { $0.kind == .delete }
        XCTAssertEqual(deletes.map(\.text), ["b"])
    }

    func testReplaceLine() {
        let r = lineDiff(before: "- [ ] one\n", after: "- [x] one\n")
        XCTAssertEqual(r.added, 1)
        XCTAssertEqual(r.removed, 1)
        XCTAssertTrue(r.lines.contains { $0.kind == .delete && $0.text.contains("[ ]") })
        XCTAssertTrue(r.lines.contains { $0.kind == .insert && $0.text.contains("[x]") })
    }

    func testSplitKeepsEmpty() {
        XCTAssertEqual(splitDiffLines(""), [""])
        XCTAssertEqual(splitDiffLines("a"), ["a"])
        XCTAssertEqual(splitDiffLines("a\n"), ["a", ""])
        XCTAssertEqual(splitDiffLines("a\nb"), ["a", "b"])
    }

    func testLineNumbers() {
        let r = lineDiff(before: "a\nb\n", after: "a\nx\nb\n")
        let insert = r.lines.first { $0.kind == .insert }
        XCTAssertEqual(insert?.text, "x")
        XCTAssertNil(insert?.oldNumber)
        XCTAssertEqual(insert?.newNumber, 2)
    }
}
