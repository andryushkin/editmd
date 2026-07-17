import XCTest
@testable import EditMD

/// Per-document editor mode persistence (FSNotes' previewState idea).
@MainActor
final class EditorModeStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "EditorModeStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testUnseenFileHasNoRememberedMode() {
        let url = URL(fileURLWithPath: "/tmp/never-opened.md")
        XCTAssertNil(EditorModeStore.mode(for: url, defaults: defaults))
    }

    func testRecordsAndRestoresPerFile() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        let b = URL(fileURLWithPath: "/tmp/b.md")
        EditorModeStore.setMode(.preview, for: a, defaults: defaults)
        EditorModeStore.setMode(.visual, for: b, defaults: defaults)

        XCTAssertEqual(EditorModeStore.mode(for: a, defaults: defaults), .preview)
        XCTAssertEqual(EditorModeStore.mode(for: b, defaults: defaults), .visual)
    }

    func testLatestModeWins() {
        let a = URL(fileURLWithPath: "/tmp/a.md")
        EditorModeStore.setMode(.source, for: a, defaults: defaults)
        EditorModeStore.setMode(.split, for: a, defaults: defaults)
        XCTAssertEqual(EditorModeStore.mode(for: a, defaults: defaults), .split)
    }

    func testUntitledIsNoOp() {
        EditorModeStore.setMode(.visual, for: nil, defaults: defaults)
        XCTAssertNil(EditorModeStore.mode(for: nil, defaults: defaults))
    }

    func testPathIsStandardized() {
        // Two spellings of the same file share one remembered mode.
        let messy = URL(fileURLWithPath: "/tmp/./sub/../a.md")
        let clean = URL(fileURLWithPath: "/tmp/a.md")
        EditorModeStore.setMode(.preview, for: messy, defaults: defaults)
        XCTAssertEqual(EditorModeStore.mode(for: clean, defaults: defaults), .preview)
    }
}
