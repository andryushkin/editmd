import XCTest
@testable import EditMD

/// Two properties are load-bearing and both are tested without
/// any UI:
///
///  1. **Exactly one resolution per continuation.** Claude blocks on `openDiff`;
///     a leaked continuation hangs it forever, a double resume traps.
///  2. **Accept writes through `DocumentRegistry`.** Writing the file directly
///     would make our own write look like an external change.
@MainActor
final class DiffApprovalControllerTests: XCTestCase {

    private var controller: DiffApprovalController!
    private var tmp: URL!

    override func setUp() async throws {
        controller = DiffApprovalController()
        controller.timeout = .milliseconds(150)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-diff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controller.rejectAll(reason: "teardown")
        DocumentRegistry.shared.clearSessionCache()
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func diff(tab: String = "tab",
                      url: URL,
                      before: String = "old\n",
                      after: String = "new\n",
                      dirty: Bool = false,
                      isNew: Bool = false) -> DiffApprovalController.PendingDiff {
        DiffApprovalController.PendingDiff(tabName: tab, targetURL: url, before: before,
                                          after: after, bufferIsDirty: dirty, isNewFile: isNew)
    }

    /// Starts `present` and waits until the diff is queued. Waits on queue
    /// membership, not on `current` — a second diff sits behind the first.
    private func startPresenting(_ pending: DiffApprovalController.PendingDiff)
        async throws -> Task<DiffOutcome, Never> {
        let task = Task { await controller.present(pending) }
        try await waitUntil { self.controller.queue.contains { $0.tabName == pending.tabName } }
        return task
    }

    private func waitUntil(timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition not met within \(timeout)s")
    }

    private func makeFile(_ name: String, _ content: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url.standardizedFileURL
    }

    // MARK: - Accept

    func testAcceptWritesClosedFileAndAnswersFileSaved() async throws {
        let url = try makeFile("closed.md", "old\n")
        let task = try await startPresenting(diff(url: url, after: "# New\n"))

        controller.accept("tab")

        let outcome = await task.value
        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# New\n")
        XCTAssertNil(controller.current)
    }

    /// Accepting an edit to an OPEN file goes through the
    /// registry, so the buffer updates, the file is flushed, and the write is
    /// not announced back to us as an external change.
    func testAcceptOnOpenFileUpdatesBufferAndRaisesNoConflict() async throws {
        let url = try makeFile("open.md", "old\n")
        let document = try DocumentRegistry.shared.acquire(url)
        defer { DocumentRegistry.shared.release(url) }
        ExternalChangeCenter.shared.dismiss(url)

        let task = try await startPresenting(diff(url: url, after: "# Claude\n"))
        controller.accept("tab")
        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .accepted)

        XCTAssertEqual(document.content, "# Claude\n")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Claude\n")
        XCTAssertFalse(DocumentRegistry.shared.isDirty(url))
        XCTAssertNil(ExternalChangeCenter.shared.notice(for: url),
                     "Our own accepted write must not surface as an external change")
    }

    func testAcceptCreatesANewFile() async throws {
        let url = tmp.appendingPathComponent("brand-new.md").standardizedFileURL
        let task = try await startPresenting(
            diff(url: url, before: "", after: "# Created\n", isNew: true))

        controller.accept("tab")

        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .accepted)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "# Created\n")
    }

    /// An unwritable target must report DIFF_REJECTED — Claude may not believe
    /// a file changed when it did not.
    func testAcceptOnUnwritablePathAnswersRejected() async throws {
        let url = tmp.appendingPathComponent("no-such-dir/deep.md").standardizedFileURL
        let task = try await startPresenting(diff(url: url, isNew: true))

        controller.accept("tab")

        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Reject paths

    func testRejectLeavesTheFileUntouched() async throws {
        let url = try makeFile("keep.md", "old\n")
        let task = try await startPresenting(diff(url: url, after: "new\n"))

        controller.reject("tab")

        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .rejected)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    func testCloseTabRejectsAndReportsWhetherItExisted() async throws {
        let url = try makeFile("a.md", "old\n")
        let task = try await startPresenting(diff(tab: "one", url: url))

        XCTAssertTrue(controller.closeTab(named: "one"))
        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .rejected)
        XCTAssertFalse(controller.closeTab(named: "one"), "Second close finds nothing")
    }

    func testCloseAllTabsReturnsTheCountAndRejectsEach() async throws {
        let url = try makeFile("a.md", "old\n")
        let first = try await startPresenting(diff(tab: "one", url: url))
        let second = try await startPresenting(diff(tab: "two", url: url))

        XCTAssertEqual(controller.closeAllTabs(), 2)

        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .rejected)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .rejected)
        XCTAssertFalse(controller.hasPending)
        XCTAssertEqual(controller.closeAllTabs(), 0)
    }

    /// Client disconnect: nobody will read the answer, but the continuation
    /// still has to be released or the task leaks.
    func testRejectAllReleasesEveryPendingDiff() async throws {
        let url = try makeFile("a.md", "old\n")
        let first = try await startPresenting(diff(tab: "one", url: url))
        let second = try await startPresenting(diff(tab: "two", url: url))

        controller.rejectAll(reason: "client disconnected")

        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .rejected)
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .rejected)
        XCTAssertNil(controller.current)
    }

    func testTimeoutRejects() async throws {
        let url = try makeFile("a.md", "old\n")
        let task = try await startPresenting(diff(url: url))

        // `controller.timeout` is 150 ms in setUp.
        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .rejected)
        XCTAssertNil(controller.current)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    // MARK: - Exactly-once

    func testSecondResolutionIsANoop() async throws {
        let url = try makeFile("a.md", "old\n")
        let task = try await startPresenting(diff(url: url))

        controller.reject("tab")
        let taskOutcome = await task.value
        XCTAssertEqual(taskOutcome, .rejected)

        // Any of these would double-resume a live continuation.
        controller.reject("tab")
        controller.accept("tab")
        XCTAssertFalse(controller.closeTab(named: "tab"))
        controller.rejectAll(reason: "again")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    func testAcceptAfterRejectDoesNotWriteTheFile() async throws {
        let url = try makeFile("a.md", "old\n")
        let task = try await startPresenting(diff(url: url, after: "new\n"))

        controller.reject("tab")
        _ = await task.value
        controller.accept("tab")

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    /// A repeat `openDiff` for the same tab name replaces the pending diff;
    /// the superseded one answers DIFF_REJECTED rather than leaking.
    func testRepeatOpenDiffForSameTabRejectsThePreviousOne() async throws {
        let url = try makeFile("a.md", "old\n")
        let first = try await startPresenting(diff(tab: "same", url: url, after: "first\n"))

        let second = Task { await controller.present(diff(tab: "same", url: url, after: "second\n")) }
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .rejected)
        try await waitUntil { self.controller.current?.after == "second\n" }

        controller.accept("same")
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .accepted)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second\n")
    }

    func testQueueKeepsDistinctTabsAndShowsTheOldestFirst() async throws {
        let url = try makeFile("a.md", "old\n")
        let first = try await startPresenting(diff(tab: "one", url: url))
        let second = Task { await controller.present(diff(tab: "two", url: url)) }
        try await waitUntil { self.controller.queue.count == 2 }

        XCTAssertEqual(controller.current?.tabName, "one")
        controller.reject("one")
        _ = await first.value
        XCTAssertEqual(controller.current?.tabName, "two")
        controller.reject("two")
        _ = await second.value
    }
}
