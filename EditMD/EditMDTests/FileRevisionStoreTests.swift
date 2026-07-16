import XCTest
@testable import EditMD

final class FileRevisionStoreTests: XCTestCase {
    private var tmp: URL!
    private var store: FileRevisionStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("editmd-rev-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = FileRevisionStore(rootURL: tmp)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        store = nil
        tmp = nil
        super.tearDown()
    }

    private func fileURL(_ name: String = "note.md") -> URL {
        // Stable path under tmp so pathKey is unique per test root.
        tmp.appendingPathComponent(name)
    }

    // MARK: - append / dedup

    func testRecordAppendsAndListsNewestFirst() {
        let url = fileURL()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 1_000 + FileRevisionStore.debounceInterval + 1)
        XCTAssertNotNil(store.record(url: url, content: "v1", force: true, now: t0))
        XCTAssertNotNil(store.record(url: url, content: "v2", force: true, now: t1))
        let list = store.revisions(for: url)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].contentSHA, fileRevisionContentSHA("v2"))
        XCTAssertEqual(list[1].contentSHA, fileRevisionContentSHA("v1"))
        XCTAssertEqual(store.content(for: url, contentSHA: list[0].contentSHA), "v2")
    }

    func testDedupIdenticalContent() {
        let url = fileURL()
        let t0 = Date(timeIntervalSince1970: 2_000)
        let t1 = Date(timeIntervalSince1970: 2_000 + FileRevisionStore.debounceInterval + 1)
        XCTAssertNotNil(store.record(url: url, content: "same", force: true, now: t0))
        XCTAssertNil(store.record(url: url, content: "same", force: true, now: t1))
        XCTAssertEqual(store.revisions(for: url).count, 1)
    }

    func testDebounceSkipsWithinWindow() {
        let url = fileURL()
        let t0 = Date(timeIntervalSince1970: 3_000)
        XCTAssertNotNil(store.record(url: url, content: "a", now: t0))
        XCTAssertNil(store.record(url: url, content: "b",
                                  now: t0.addingTimeInterval(30)))
        XCTAssertEqual(store.revisions(for: url).count, 1)
        XCTAssertNotNil(store.record(
            url: url, content: "b",
            now: t0.addingTimeInterval(FileRevisionStore.debounceInterval + 1)))
        XCTAssertEqual(store.revisions(for: url).count, 2)
    }

    func testForceBypassesDebounce() {
        let url = fileURL()
        let t0 = Date(timeIntervalSince1970: 4_000)
        XCTAssertNotNil(store.record(url: url, content: "a", now: t0))
        XCTAssertNotNil(store.record(url: url, content: "b", force: true,
                                     now: t0.addingTimeInterval(1)))
        XCTAssertEqual(store.revisions(for: url).count, 2)
    }

    // MARK: - size / prune

    func testSkipsOversizedContent() {
        let url = fileURL()
        let huge = String(repeating: "x", count: FileRevisionStore.maxContentBytes + 1)
        XCTAssertNil(store.record(url: url, content: huge, force: true))
        XCTAssertTrue(store.revisions(for: url).isEmpty)
    }

    func testPrunesToMaxRevisionsAndRemovesOrphans() {
        let url = fileURL()
        var t = Date(timeIntervalSince1970: 5_000)
        for i in 0..<(FileRevisionStore.maxRevisionsPerFile + 5) {
            _ = store.record(url: url, content: "rev-\(i)", force: true, now: t)
            t = t.addingTimeInterval(1)
        }
        let list = store.revisions(for: url)
        XCTAssertEqual(list.count, FileRevisionStore.maxRevisionsPerFile)
        // Oldest of the first batch gone.
        XCTAssertNil(store.content(for: url, contentSHA: fileRevisionContentSHA("rev-0")))
        // Newest kept.
        XCTAssertEqual(store.content(for: url, contentSHA: list[0].contentSHA),
                       "rev-\(FileRevisionStore.maxRevisionsPerFile + 4)")
    }

    // MARK: - corrupt manifest

    func testCorruptManifestDoesNotCrash() throws {
        let url = fileURL()
        XCTAssertNotNil(store.record(url: url, content: "ok", force: true))
        let pathKey = fileRevisionPathKey(for: url)
        let manifestURL = tmp
            .appendingPathComponent(pathKey)
            .appendingPathComponent("manifest.json")
        try "not-json{{{".write(to: manifestURL, atomically: true, encoding: .utf8)
        // List returns empty (recreated index); app must not crash.
        XCTAssertEqual(store.revisions(for: url).count, 0)
        // Can record again.
        XCTAssertNotNil(store.record(url: url, content: "again", force: true))
        XCTAssertEqual(store.revisions(for: url).count, 1)
    }

    // MARK: - concurrent

    func testConcurrentRecordsDoNotCorrupt() {
        let urlA = fileURL("a.md")
        let urlB = fileURL("b.md")
        let exp = expectation(description: "both")
        exp.expectedFulfillmentCount = 2
        DispatchQueue.global().async {
            for i in 0..<20 {
                _ = self.store.record(url: urlA, content: "A-\(i)", force: true)
            }
            exp.fulfill()
        }
        DispatchQueue.global().async {
            for i in 0..<20 {
                _ = self.store.record(url: urlB, content: "B-\(i)", force: true)
            }
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        XCTAssertEqual(store.revisions(for: urlA).count, 20)
        XCTAssertEqual(store.revisions(for: urlB).count, 20)
    }

    func testPathKeyStable() {
        let u = URL(fileURLWithPath: "/tmp/vault/note.md")
        XCTAssertEqual(fileRevisionPathKey(for: u), fileRevisionPathKey(for: u))
        XCTAssertNotEqual(fileRevisionPathKey(for: u),
                          fileRevisionPathKey(for: URL(fileURLWithPath: "/tmp/vault/other.md")))
    }
}
