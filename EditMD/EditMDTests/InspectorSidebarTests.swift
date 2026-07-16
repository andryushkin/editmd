import XCTest
@testable import EditMD

/// Unit tests for the right inspector and left-sidebar tab migration (plan 01).
final class InspectorSidebarTests: XCTestCase {

    // MARK: - sidebarTab migration after Outline moved right

    func testMigrateRetiredOutlineTab() {
        XCTAssertEqual(migrateWorkspaceSidebarTab("outline"), "files")
    }

    func testMigrateKeepsValidTabs() {
        for tab in ["files", "git", "review", "tags"] {
            XCTAssertEqual(migrateWorkspaceSidebarTab(tab), tab, tab)
        }
    }

    func testMigrateUnknownTabUnchanged() {
        // Unknown keys stay as-is; WorkspaceSidebar switch falls back to Files UI.
        XCTAssertEqual(migrateWorkspaceSidebarTab("unknown"), "unknown")
    }
}
