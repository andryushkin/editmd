import XCTest
@testable import EditMD

/// B1: side panels must never overflow their slots and overlap when the window
/// is too narrow — `resolveSidePaneWidths` clamps the rigid panel widths so the
/// flexible editor keeps its floor and every pane stays side-by-side.
final class PaneLayoutTests: XCTestCase {

    func testWidePanelsKeepRequestedWidths() {
        let panes = resolveSidePaneWidths(
            available: 1200,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: 260)
        XCTAssertEqual(panes.sidebar, 220, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 220, accuracy: 0.001)
    }

    func testHiddenPanelsAreZero() {
        let panes = resolveSidePaneWidths(
            available: 400,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: false, inspectorVisible: false)
        XCTAssertEqual(panes.sidebar, 0)
        XCTAssertEqual(panes.inspector, 0)
    }

    func testNarrowWindowShrinksPanelsInsteadOfOverlapping() {
        // 500 wide, both panels want 220 (+2 dividers) → editor would get only
        // 58, below its 260 floor. Panels must shrink so they never overlap.
        let available: CGFloat = 500
        let editorMin: CGFloat = 260
        let panes = resolveSidePaneWidths(
            available: available,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorMin, dividerWidth: 1)
        let editor = available - 2 - panes.sidebar - panes.inspector
        // Editor keeps its floor and nothing overflows.
        XCTAssertEqual(editor, editorMin, accuracy: 0.5)
        XCTAssertLessThan(panes.sidebar, 220)
        XCTAssertLessThan(panes.inspector, 220)
        // Proportional shrink keeps equal requests equal.
        XCTAssertEqual(panes.sidebar, panes.inspector, accuracy: 0.001)
    }

    func testShrinkIsProportionalToRequestedWidths() {
        // Sidebar 300, inspector 100 → shrink keeps the 3:1 ratio.
        let panes = resolveSidePaneWidths(
            available: 500,
            sidebarWidth: 300, inspectorWidth: 100,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: 260, dividerWidth: 1)
        XCTAssertEqual(panes.sidebar / panes.inspector, 3, accuracy: 0.001)
    }

    func testDegenerateWidthNeverGoesNegative() {
        // Window narrower than the editor floor: panels collapse to 0, never
        // negative, so no rigid frame overflows.
        let panes = resolveSidePaneWidths(
            available: 120,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: 260)
        XCTAssertEqual(panes.sidebar, 0, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 0, accuracy: 0.001)
    }

    func testOnlySidebarVisibleClampsAlone() {
        let panes = resolveSidePaneWidths(
            available: 400,
            sidebarWidth: 300, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: false,
            editorMin: 260, dividerWidth: 1)
        XCTAssertEqual(panes.inspector, 0)
        // 400 - 1 divider - 260 editor = 139 budget for the sidebar.
        XCTAssertEqual(panes.sidebar, 139, accuracy: 0.5)
    }
}
