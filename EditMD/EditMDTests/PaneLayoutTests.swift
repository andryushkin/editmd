import XCTest
@testable import EditMD

/// B1: side panels must never overflow their slots and overlap when the window
/// is too narrow — `resolveSidePaneWidths` clamps the rigid panel widths so the
/// flexible editor keeps its floor and every pane stays side-by-side. Divider
/// drags invert that clamp so a resize keeps the *preferred* width.
final class PaneLayoutTests: XCTestCase {

    private let range = 150.0...400.0

    // MARK: - resolveSidePaneWidths

    func testWidePanelsKeepRequestedWidths() {
        let panes = resolveSidePaneWidths(
            available: 1200,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true)
        XCTAssertEqual(panes.sidebar, 220, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 220, accuracy: 0.001)
        XCTAssertEqual(panes.scale, 1)
    }

    func testHiddenPanelsAreZero() {
        let panes = resolveSidePaneWidths(
            available: 400,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: false, inspectorVisible: false)
        XCTAssertEqual(panes.sidebar, 0)
        XCTAssertEqual(panes.inspector, 0)
        XCTAssertEqual(panes.scale, 1)
    }

    /// Boundary: requested == budget still fits (scale stays 1). Documents the
    /// ~562pt onset noted on `editorColumnMinWidth` (150 + 150 + 2 + 260).
    func testExactlyFittingKeepsFullWidthsScaleOne() {
        let panes = resolveSidePaneWidths(
            available: 562,
            sidebarWidth: 150, inspectorWidth: 150,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        XCTAssertEqual(panes.sidebar, 150, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 150, accuracy: 0.001)
        XCTAssertEqual(panes.scale, 1)
    }

    func testComfortablyUnderBudgetIsUnchanged() {
        // Requested (400) well under budget (700 - 2 - 260 = 438).
        let panes = resolveSidePaneWidths(
            available: 700,
            sidebarWidth: 200, inspectorWidth: 200,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        XCTAssertEqual(panes.sidebar, 200, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 200, accuracy: 0.001)
        XCTAssertEqual(panes.scale, 1)
    }

    func testNarrowWindowShrinksPanelsInsteadOfOverlapping() {
        // 500 wide, both panels want 220 (+2 dividers) → editor would get only
        // 58, below its floor. Panels must shrink so they never overlap.
        let available: CGFloat = 500
        let panes = resolveSidePaneWidths(
            available: available,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        let editor = available - 2 - panes.sidebar - panes.inspector
        XCTAssertEqual(editor, editorColumnMinWidth, accuracy: 0.5)
        XCTAssertLessThan(panes.sidebar, 220)
        XCTAssertLessThan(panes.inspector, 220)
        XCTAssertLessThan(panes.scale, 1)
        // Proportional shrink keeps equal requests equal.
        XCTAssertEqual(panes.sidebar, panes.inspector, accuracy: 0.001)
    }

    func testShrinkIsProportionalToRequestedWidths() {
        // Sidebar 300, inspector 100 → shrink keeps the 3:1 ratio.
        let panes = resolveSidePaneWidths(
            available: 500,
            sidebarWidth: 300, inspectorWidth: 100,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        XCTAssertEqual(panes.sidebar / panes.inspector, 3, accuracy: 0.001)
    }

    func testDegenerateWidthNeverGoesNegative() {
        // Window narrower than the editor floor: panels collapse to 0, never
        // negative, so no rigid frame overflows.
        let panes = resolveSidePaneWidths(
            available: 120,
            sidebarWidth: 220, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true,
            editorMin: editorColumnMinWidth)
        XCTAssertEqual(panes.sidebar, 0, accuracy: 0.001)
        XCTAssertEqual(panes.inspector, 0, accuracy: 0.001)
    }

    func testOnlySidebarVisibleClampsAlone() {
        let panes = resolveSidePaneWidths(
            available: 400,
            sidebarWidth: 300, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: false,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        XCTAssertEqual(panes.inspector, 0)
        // 400 - 1 divider - 260 editor = 139 budget for the sidebar.
        XCTAssertEqual(panes.sidebar, 139, accuracy: 0.5)
    }

    func testOnlyInspectorVisibleClampsAlone() {
        let panes = resolveSidePaneWidths(
            available: 400,
            sidebarWidth: 220, inspectorWidth: 300,
            sidebarVisible: false, inspectorVisible: true,
            editorMin: editorColumnMinWidth, dividerWidth: 1)
        XCTAssertEqual(panes.sidebar, 0)
        // 400 - 1 divider - 260 editor = 139 budget for the inspector.
        XCTAssertEqual(panes.inspector, 139, accuracy: 0.5)
        XCTAssertLessThan(panes.scale, 1)
    }

    // MARK: - preferredPaneWidthFromDrag (divider drag inverts the clamp)

    func testUnclampedDragWritesRawWidth() {
        // scale 1: dragging to 300 stores 300 unchanged (in range).
        XCTAssertEqual(
            preferredPaneWidthFromDrag(displayWidth: 300, scale: 1, range: range),
            300, accuracy: 0.001)
    }

    func testDragClampsToRange() {
        XCTAssertEqual(preferredPaneWidthFromDrag(displayWidth: 50, scale: 1, range: range), 150)
        XCTAssertEqual(preferredPaneWidthFromDrag(displayWidth: 999, scale: 1, range: range), 400)
    }

    /// The core bug: at rest in a clamped window, feeding the shrunken display
    /// edge back in (a no-op drag / incidental click) must NOT overwrite the
    /// stored preferred width.
    func testNoOpDragInClampedWindowPreservesPreferredWidth() {
        let stored: CGFloat = 220
        let panes = resolveSidePaneWidths(
            available: 500,
            sidebarWidth: stored, inspectorWidth: 220,
            sidebarVisible: true, inspectorVisible: true)
        XCTAssertLessThan(panes.scale, 1) // sanity: clamped regime
        let rewritten = preferredPaneWidthFromDrag(
            displayWidth: panes.sidebar, scale: panes.scale, range: range)
        XCTAssertEqual(rewritten, Double(stored), accuracy: 0.001)
    }

    func testNonPositiveScaleGuardsToUnity() {
        // A degenerate scale must not divide by zero / flip sign.
        XCTAssertEqual(
            preferredPaneWidthFromDrag(displayWidth: 200, scale: 0, range: range),
            200, accuracy: 0.001)
    }
}
