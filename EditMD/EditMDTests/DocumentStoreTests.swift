import XCTest
@testable import EditMD

/// Markdown/textbundle IO (DocumentStore.swift) round-trips losslessly;
/// DocumentRegistry shares one model per URL and saves without losing writes.
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

    @MainActor
    func testMovePreparationBlocksUnresolvedExternalConflictWithoutWriting() throws {
        let probe = DocumentMoveWriterProbe()
        let registry = DocumentRegistry(moveWriter: probe.write)
        let url = tmp.appendingPathComponent("move-conflict.md")
        try writeMarkdownDocument(content: "disk-old", assets: nil, to: url)
        let originalModDate = try XCTUnwrap(
            url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)

        let document = try registry.acquire(url)
        document.content = "local-unsaved"
        registry.markDirty(url)
        try writeMarkdownDocument(content: "disk-new", assets: nil, to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModDate],
            ofItemAtPath: url.path)

        do {
            _ = try registry.beginMovePreparation(url)
            XCTFail("Move preflight must reconcile a not-yet-debounced disk change")
        } catch let error as DocumentMovePreparationError {
            XCTAssertEqual(error, .unresolvedExternalConflict("move-conflict.md"))
        }

        XCTAssertEqual(probe.callCount, 0)
        XCTAssertTrue(registry.isOpen(url))
        XCTAssertEqual(document.content, "local-unsaved")
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "disk-new",
                       "move preparation must not silently choose Keep Mine")

        registry.applyExternalContent(url, content: "disk-new")
        registry.release(url)
    }

    @MainActor
    func testDismissedExternalConflictStillBlocksMovePreparation() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("dismissed-move-conflict.md")
        try writeMarkdownDocument(content: "disk-old", assets: nil, to: url)

        let document = try registry.acquire(url)
        document.content = "local-unsaved"
        registry.markDirty(url)
        try writeMarkdownDocument(content: "disk-new", assets: nil, to: url)
        XCTAssertFalse(registry.syncFromDiskIfNeeded(url))

        registry.dismissExternalChange(url)
        XCTAssertThrowsError(try registry.beginMovePreparation(url)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .unresolvedExternalConflict("dismissed-move-conflict.md"))
        }
        XCTAssertEqual(document.content, "local-unsaved")
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "disk-new")

        registry.applyExternalContent(url, content: "disk-new")
        registry.release(url)
    }

    @MainActor
    func testMovePreparationWritesOnlyDirtyDocuments() async throws {
        let probe = DocumentMoveWriterProbe()
        let registry = DocumentRegistry(moveWriter: probe.write)
        let cleanURL = tmp.appendingPathComponent("clean.md")
        let dirtyURL = tmp.appendingPathComponent("dirty.md")
        try writeMarkdownDocument(content: "clean", assets: nil, to: cleanURL)
        try writeMarkdownDocument(content: "old", assets: nil, to: dirtyURL)

        let cleanDocument = try registry.acquire(cleanURL)
        let cleanPreparation = try XCTUnwrap(
            registry.beginMovePreparation(cleanURL))
        try await registry.persistMovePreparation(cleanPreparation)
        XCTAssertEqual(probe.callCount, 0,
                       "clean move preparation must avoid an atomic rewrite")
        XCTAssertThrowsError(try registry.acquire(cleanURL)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("clean.md"),
                "a prepared model must stay transaction-owned until cancel or relocate")
        }
        registry.cancelMovePreparation(cleanPreparation)
        XCTAssertTrue(try registry.acquire(cleanURL) === cleanDocument)
        registry.release(cleanURL)

        let dirtyDocument = try registry.acquire(dirtyURL)
        dirtyDocument.content = "edited"
        registry.markDirty(dirtyURL)
        let dirtyPreparation = try XCTUnwrap(
            registry.beginMovePreparation(dirtyURL))
        try await registry.persistMovePreparation(dirtyPreparation)
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertFalse(probe.didWriteOnMainThread,
                       "dirty move writes must not execute on MainActor")
        XCTAssertEqual(try loadMarkdownDocument(from: dirtyURL).content, "edited")
        registry.cancelMovePreparation(dirtyPreparation)
        XCTAssertTrue(try registry.acquire(dirtyURL) === dirtyDocument)
        registry.release(dirtyURL)
    }

    @MainActor
    func testMovePreparationPersistsLocalTextBundleAssetChanges() async throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("local-assets.textbundle")
        try writeMarkdownDocument(
            content: "Body",
            assets: makeNestedAssets("disk-asset"),
            to: url)

        let document = try registry.acquire(url)
        document.assetsFileWrapper = makeNestedAssets("local-asset")
        registry.markDirty(url)

        let preparation = try XCTUnwrap(registry.beginMovePreparation(url))
        try await registry.persistMovePreparation(preparation)
        let loaded = try loadMarkdownDocument(from: url)
        XCTAssertEqual(nestedAssetPayload(loaded.assets), "local-asset")

        registry.cancelMovePreparation(preparation)
        XCTAssertTrue(try registry.acquire(url) === document)
        registry.release(url)
    }

    @MainActor
    func testExternalNestedAssetChangeBlocksMoveEvenAfterDismiss() throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("external-assets.textbundle")
        try writeMarkdownDocument(
            content: "Body",
            assets: makeNestedAssets("disk-old"),
            to: url)

        let document = try registry.acquire(url)
        document.assetsFileWrapper = makeNestedAssets("local-unsaved")
        registry.markDirty(url)
        try writeMarkdownDocument(
            content: "Body",
            assets: makeNestedAssets("disk-external"),
            to: url)

        XCTAssertThrowsError(try registry.beginMovePreparation(url)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .unresolvedExternalConflict("external-assets.textbundle"))
        }
        registry.dismissExternalChange(url)
        XCTAssertThrowsError(try registry.beginMovePreparation(url)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .unresolvedExternalConflict("external-assets.textbundle"))
        }
        XCTAssertEqual(
            nestedAssetPayload(document.assetsFileWrapper), "local-unsaved")
        XCTAssertEqual(
            nestedAssetPayload(try loadMarkdownDocument(from: url).assets),
            "disk-external")

        registry.applyExternalContent(url, content: "Body")
        XCTAssertEqual(
            nestedAssetPayload(document.assetsFileWrapper), "disk-external")
        registry.release(url)
    }

    @MainActor
    func testFailedMoveWriteKeepsPreparedModelDirtyForRestore() async throws {
        struct ExpectedFailure: Error {}
        let registry = DocumentRegistry { _, _ in throw ExpectedFailure() }
        let url = tmp.appendingPathComponent("failed-write.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: url)
        let document = try registry.acquire(url)
        document.contentUndoManager.groupsByEvent = false
        document.applyUndoableContent("edited", actionName: "Edit")
        registry.markDirty(url)

        let preparation = try XCTUnwrap(
            registry.beginMovePreparation(url))
        do {
            try await registry.persistMovePreparation(preparation)
            XCTFail("Expected the injected write failure")
        } catch is ExpectedFailure {}

        XCTAssertFalse(registry.isOpen(url))
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "disk")
        registry.cancelMovePreparation(preparation)
        let restored = try registry.acquire(url)
        XCTAssertTrue(restored === document)
        XCTAssertTrue(registry.isDirty(url))
        XCTAssertTrue(restored.contentUndoManager.canUndo)
        try registry.saveNow(url)
        XCTAssertFalse(registry.isDirty(url))
        XCTAssertEqual(try loadMarkdownDocument(from: url).content, "edited",
                       "the expected stale disk after a failed write is not an external conflict")
        registry.release(url)
    }

    @MainActor
    func testAvailablePreparedModelReconcilesActualDestinationBeforeAcquire() async throws {
        let registry = DocumentRegistry()
        let source = tmp.appendingPathComponent("prepared-source.md")
        let destination = tmp.appendingPathComponent("prepared-destination.md")
        try writeMarkdownDocument(content: "before", assets: nil, to: source)

        let document = try registry.acquire(source)
        let preparation = try XCTUnwrap(registry.beginMovePreparation(source))
        try await registry.persistMovePreparation(preparation)
        try FileManager.default.moveItem(at: source, to: destination)
        registry.relocatePreparedDocument(from: source, to: destination)

        try writeMarkdownDocument(content: "external-at-destination", assets: nil, to: destination)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: destination.path)

        let restored = try registry.acquire(destination)
        XCTAssertTrue(restored === document)
        XCTAssertEqual(restored.content, "external-at-destination",
                       "available hand-off must reconcile the destination, not the old source")
        registry.release(destination)
    }

    @MainActor
    func testMoveReservationBlocksReentrantOpenWithoutInMemoryModel() async throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("closed-no-cache.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: url)

        let preparation = try XCTUnwrap(registry.beginMovePreparation(url))
        XCTAssertThrowsError(try registry.acquire(url)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("closed-no-cache.md"))
        }
        XCTAssertThrowsError(try registry.applyAgentEdit(url, content: "racing edit")) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("closed-no-cache.md"))
        }

        try await registry.persistMovePreparation(preparation)
        registry.cancelMovePreparation(preparation)
        let opened = try registry.acquire(url)
        XCTAssertEqual(opened.content, "disk")
        registry.release(url)
    }

    @MainActor
    func testDestinationReservationRejectsModelsAndBlocksUntilReleased() throws {
        let registry = DocumentRegistry()
        let occupied = tmp.appendingPathComponent("occupied-destination.md")
        let free = tmp.appendingPathComponent("free-destination.md")
        try writeMarkdownDocument(content: "occupied", assets: nil, to: occupied)
        try writeMarkdownDocument(content: "free", assets: nil, to: free)

        let occupiedDocument = try registry.acquire(occupied)
        XCTAssertThrowsError(try registry.reserveMoveDestination(occupied)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("occupied-destination.md"))
        }
        registry.release(occupied)
        XCTAssertThrowsError(try registry.reserveMoveDestination(occupied)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("occupied-destination.md"),
                "a cached destination must be rejected without evicting its identity")
        }
        XCTAssertTrue(try registry.acquire(occupied) === occupiedDocument)
        registry.release(occupied)

        let reservation = try registry.reserveMoveDestination(free)
        XCTAssertThrowsError(try registry.acquire(free)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("free-destination.md"))
        }
        XCTAssertThrowsError(try registry.applyAgentEdit(free, content: "racing edit")) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("free-destination.md"))
        }
        registry.cancelMovePreparation(reservation)
        let opened = try registry.acquire(free)
        XCTAssertEqual(opened.content, "free")
        registry.release(free)

        registry.clearSessionCache()
        let discardedReservation = try registry.reserveMoveDestination(free)
        registry.discardMovePreparation(discardedReservation)
        let reopened = try registry.acquire(free)
        XCTAssertEqual(reopened.content, "free")
        registry.release(free)
    }

    @MainActor
    func testURLOnlyMoveReservationRelocatesAndReleasesDestination() async throws {
        let registry = DocumentRegistry()
        let source = tmp.appendingPathComponent("url-only-source.md")
        let destination = tmp.appendingPathComponent("url-only-destination.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: source)

        let preparation = try XCTUnwrap(registry.beginMovePreparation(source))
        try await registry.persistMovePreparation(preparation)
        try FileManager.default.moveItem(at: source, to: destination)
        registry.relocatePreparedDocument(from: source, to: destination)

        let opened = try registry.acquire(destination)
        XCTAssertEqual(opened.content, "disk")
        registry.release(destination)
    }

    @MainActor
    func testCachedMoveRelocatesIdentityAndUndoWithoutRevivingOldPath() async throws {
        let registry = DocumentRegistry()
        let source = tmp.appendingPathComponent("cached-source.md")
        let destination = tmp.appendingPathComponent("cached-destination.md")
        try writeMarkdownDocument(content: "original", assets: nil, to: source)

        let cachedDocument = try registry.acquire(source)
        cachedDocument.contentUndoManager.groupsByEvent = false
        cachedDocument.applyUndoableContent("edited", actionName: "Edit")
        registry.markDirty(source)
        registry.release(source)

        let preparation = try XCTUnwrap(registry.beginMovePreparation(source))
        XCTAssertThrowsError(try registry.acquire(source)) { error in
            XCTAssertEqual(
                error as? DocumentMovePreparationError,
                .moveInProgress("cached-source.md"))
        }
        try await registry.persistMovePreparation(preparation)
        try FileManager.default.moveItem(at: source, to: destination)
        registry.relocatePreparedDocument(from: source, to: destination)

        try writeMarkdownDocument(content: "replacement", assets: nil, to: source)
        let oldPathDocument = try registry.acquire(source)
        XCTAssertFalse(oldPathDocument === cachedDocument,
                       "the source cache key must be consumed by relocation")
        XCTAssertEqual(oldPathDocument.content, "replacement")

        let movedDocument = try registry.acquire(destination)
        XCTAssertTrue(movedDocument === cachedDocument)
        XCTAssertEqual(movedDocument.content, "edited")
        XCTAssertTrue(movedDocument.contentUndoManager.canUndo)
        registry.release(source)
        registry.release(destination)
    }

    @MainActor
    func testCachedUnmarkedBufferIsPersistedBeforeMove() async throws {
        let registry = DocumentRegistry()
        let source = tmp.appendingPathComponent("cached-unmarked-source.md")
        let destination = tmp.appendingPathComponent("cached-unmarked-destination.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: source)

        let cachedDocument = try registry.acquire(source)
        cachedDocument.contentUndoManager.groupsByEvent = false
        cachedDocument.applyUndoableContent("memory", actionName: "Edit")
        // Deliberately omit markDirty: move preflight is a correctness boundary
        // and must compare the cached buffer with its disk baseline itself.
        registry.release(source)
        XCTAssertEqual(try loadMarkdownDocument(from: source).content, "disk")

        let preparation = try XCTUnwrap(registry.beginMovePreparation(source))
        try await registry.persistMovePreparation(preparation)
        XCTAssertEqual(try loadMarkdownDocument(from: source).content, "memory")
        try FileManager.default.moveItem(at: source, to: destination)
        registry.relocatePreparedDocument(from: source, to: destination)

        let restored = try registry.acquire(destination)
        XCTAssertTrue(restored === cachedDocument)
        XCTAssertEqual(restored.content, "memory")
        XCTAssertEqual(try loadMarkdownDocument(from: destination).content, "memory")
        XCTAssertTrue(restored.contentUndoManager.canUndo)
        registry.release(destination)
    }

    @MainActor
    func testCachedMoveCancelRestoresIdentityAtSource() async throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("cached-cancel.md")
        try writeMarkdownDocument(content: "original", assets: nil, to: url)

        let cachedDocument = try registry.acquire(url)
        cachedDocument.contentUndoManager.groupsByEvent = false
        cachedDocument.applyUndoableContent("edited", actionName: "Edit")
        registry.markDirty(url)
        registry.release(url)

        let preparation = try XCTUnwrap(registry.beginMovePreparation(url))
        try await registry.persistMovePreparation(preparation)
        registry.cancelMovePreparation(preparation)

        let restored = try registry.acquire(url)
        XCTAssertTrue(restored === cachedDocument)
        XCTAssertTrue(restored.contentUndoManager.canUndo)
        registry.release(url)
    }

    @MainActor
    func testCachedMoveDiscardDropsParkedIdentity() async throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("cached-discard.md")
        try writeMarkdownDocument(content: "disk", assets: nil, to: url)

        let cachedDocument = try registry.acquire(url)
        registry.release(url)
        let preparation = try XCTUnwrap(registry.beginMovePreparation(url))
        try await registry.persistMovePreparation(preparation)
        registry.discardMovePreparation(preparation)

        let reopened = try registry.acquire(url)
        XCTAssertFalse(reopened === cachedDocument)
        XCTAssertEqual(reopened.content, "disk")
        registry.release(url)
    }

    @MainActor
    func testDiscardedMovePreparationDoesNotRestoreDirtyModel() async throws {
        let registry = DocumentRegistry()
        let url = tmp.appendingPathComponent("discarded-preparation.md")
        try writeMarkdownDocument(content: "disk-old", assets: nil, to: url)

        let preparedDocument = try registry.acquire(url)
        preparedDocument.content = "prepared-dirty"
        registry.markDirty(url)
        let preparation = try XCTUnwrap(
            registry.beginMovePreparation(url))
        try await registry.persistMovePreparation(preparation)

        try writeMarkdownDocument(content: "repaired-on-disk", assets: nil, to: url)
        registry.discardMovePreparation(preparation)

        let reopenedDocument = try registry.acquire(url)
        XCTAssertFalse(reopenedDocument === preparedDocument,
                       "discard must remove the ambiguously keyed model identity")
        XCTAssertEqual(reopenedDocument.content, "repaired-on-disk",
                       "the next explicit open must load the repaired disk file")
        registry.release(url)
    }

    @MainActor
    func testFolderRelocationRekeysClosedIdentityAndDropsStaleDestinationCache() throws {
        let registry = DocumentRegistry()
        let oldRoot = tmp.appendingPathComponent("Old Root", isDirectory: true)
        let newRoot = tmp.appendingPathComponent("New Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: newRoot, withIntermediateDirectories: true)
        let oldFile = oldRoot.appendingPathComponent("note.md")
        let staleDestinationFile = newRoot.appendingPathComponent("note.md")
        let oldUncachedFile = oldRoot.appendingPathComponent("uncached.md")
        let staleExtraDestinationFile = newRoot.appendingPathComponent("uncached.md")
        try writeMarkdownDocument(content: "source", assets: nil, to: oldFile)
        try writeMarkdownDocument(
            content: "source-uncached", assets: nil, to: oldUncachedFile)
        try writeMarkdownDocument(
            content: "stale-destination", assets: nil, to: staleDestinationFile)
        try writeMarkdownDocument(
            content: "stale-extra", assets: nil, to: staleExtraDestinationFile)

        let sourceDocument = try registry.acquire(oldFile)
        sourceDocument.contentUndoManager.groupsByEvent = false
        sourceDocument.applyUndoableContent("source-edited", actionName: "Edit")
        registry.markDirty(oldFile)
        registry.release(oldFile)
        let staleDestinationDocument = try registry.acquire(staleDestinationFile)
        registry.release(staleDestinationFile)
        let staleExtraDocument = try registry.acquire(staleExtraDestinationFile)
        registry.release(staleExtraDestinationFile)

        try FileManager.default.removeItem(at: newRoot)
        try FileManager.default.moveItem(at: oldRoot, to: newRoot)
        registry.relocateFolder(from: oldRoot, to: newRoot)

        let newFile = newRoot.appendingPathComponent("note.md")
        let restored = try registry.acquire(newFile)
        XCTAssertTrue(restored === sourceDocument)
        XCTAssertFalse(restored === staleDestinationDocument)
        XCTAssertTrue(restored.contentUndoManager.canUndo)
        XCTAssertEqual(restored.content, "source-edited")
        registry.release(newFile)

        let relocatedUncachedFile = newRoot.appendingPathComponent("uncached.md")
        let uncached = try registry.acquire(relocatedUncachedFile)
        XCTAssertFalse(uncached === staleExtraDocument)
        XCTAssertEqual(uncached.content, "source-uncached")
        registry.release(relocatedUncachedFile)
    }

    @MainActor
    func testAmbiguousFolderOutcomeDropsClosedIdentity() throws {
        let registry = DocumentRegistry()
        let root = tmp.appendingPathComponent("Ambiguous Root", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("note.md")
        try writeMarkdownDocument(content: "before", assets: nil, to: file)

        let cached = try registry.acquire(file)
        registry.release(file)
        registry.discardFolderCaches(at: [root])
        try writeMarkdownDocument(content: "repaired", assets: nil, to: file)

        let reopened = try registry.acquire(file)
        XCTAssertFalse(reopened === cached)
        XCTAssertEqual(reopened.content, "repaired")
        registry.release(file)
    }

    @MainActor
    func testPreparedBatchIsNotEvictedBySessionCacheLimit() async throws {
        let destinationFolder = tmp.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.createDirectory(
            at: destinationFolder, withIntermediateDirectories: true)
        let registry = DocumentRegistry()
        let count = DocumentRegistry.sessionCacheLimit + 2
        var sources: [URL] = []
        var destinations: [URL] = []
        var documents: [MarkdownDocument] = []
        var preparations: [DocumentMovePreparation] = []

        for index in 0..<count {
            let source = tmp.appendingPathComponent("note-\(index).md")
            let destination = destinationFolder.appendingPathComponent(source.lastPathComponent)
            try writeMarkdownDocument(content: "\(index)", assets: nil, to: source)
            sources.append(source)
            destinations.append(destination)
            documents.append(try registry.acquire(source))
        }

        documents[0].contentUndoManager.groupsByEvent = false
        documents[0].applyUndoableContent("edited zero", actionName: "Edit")
        registry.markDirty(sources[0])

        for source in sources {
            let preparation = try XCTUnwrap(
                registry.beginMovePreparation(source))
            // Mirrors DocHost teardown after the synchronous reservation. The
            // release must be harmless and must not enter the capped LRU.
            registry.release(source)
            try await registry.persistMovePreparation(preparation)
            preparations.append(preparation)
        }
        XCTAssertEqual(preparations.count, count)
        registry.clearSessionCache()
        for (source, destination) in zip(sources, destinations) {
            try FileManager.default.moveItem(at: source, to: destination)
            registry.relocatePreparedDocument(from: source, to: destination)
        }

        for index in 0..<count {
            let restored = try registry.acquire(destinations[index])
            XCTAssertTrue(restored === documents[index],
                          "prepared model \(index) must survive batches larger than the LRU")
            if index == 0 {
                XCTAssertTrue(restored.contentUndoManager.canUndo)
                restored.contentUndoManager.undo()
                XCTAssertEqual(restored.content, "0")
            }
            registry.release(destinations[index])
        }
    }
}

private func makeNestedAssets(_ payload: String) -> FileWrapper {
    let image = FileWrapper(
        regularFileWithContents: Data(payload.utf8))
    let nested = FileWrapper(
        directoryWithFileWrappers: ["image.bin": image])
    return FileWrapper(
        directoryWithFileWrappers: ["nested": nested])
}

private func nestedAssetPayload(_ assets: FileWrapper?) -> String? {
    guard let data = assets?
        .fileWrappers?["nested"]?
        .fileWrappers?["image.bin"]?
        .regularFileContents else { return nil }
    return String(data: data, encoding: .utf8)
}

private final class DocumentMoveWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var wroteOnMainThread = false

    func write(_ snapshot: MarkdownDocument.Snapshot, to url: URL) throws {
        lock.lock()
        calls += 1
        wroteOnMainThread = wroteOnMainThread || Thread.isMainThread
        lock.unlock()
        try writeMarkdownDocument(
            content: snapshot.content,
            assets: snapshot.assetsFileWrapper,
            to: url)
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    var didWriteOnMainThread: Bool {
        lock.lock()
        defer { lock.unlock() }
        return wroteOnMainThread
    }
}
