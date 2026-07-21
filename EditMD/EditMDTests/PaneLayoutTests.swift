import XCTest
@testable import EditMD

/// B1: side panels must never overflow their slots and overlap when the window
/// is too narrow — `resolveSidePaneWidths` clamps the rigid panel widths so the
/// flexible editor keeps its floor and every pane stays side-by-side. Divider
/// drags invert that clamp so a resize keeps the *preferred* width.
final class PaneLayoutTests: XCTestCase {

    /// Synthetic drag range for the pure-function tests; the real panes derive
    /// their floors from their navigator strips (see the pane-floor tests).
    private let range = 150.0...400.0

    // MARK: - window floors

    /// Main window min must leave a readable editor at *default* panel widths
    /// (sidebar 220 + inspector 280), not only at the drag floors — 720 still
    /// mid-word-wrapped.
    @MainActor
    func testMainWindowMinLeavesReadableEditorAtDefaultPanelWidths() {
        let defaultPanels = 220 + InspectorPane.defaultWidth + 2
        let editorAtMin = Double(mainWindowMinWidth) - defaultPanels
        XCTAssertGreaterThanOrEqual(editorAtMin, 380,
                                    "editor should keep ≥380pt at default side panels")
        // Still above the dual-panel clamp onset (both floors + dividers + editor).
        let dualPanelFloor = Double(WorkspaceSidebar.minimumPaneWidth)
            + Double(InspectorSidebar.minimumPaneWidth)
            + 2 + Double(editorColumnMinWidth)
        XCTAssertGreaterThan(Double(mainWindowMinWidth), dualPanelFloor)
        XCTAssertLessThan(liteWindowMinWidth, mainWindowMinWidth)
        XCTAssertGreaterThanOrEqual(liteWindowMinWidth, editorColumnMinWidth)
    }

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

    /// Boundary: requested == budget still fits (scale stays 1). Synthetic
    /// 150pt panes — the pure function knows no floors (150 + 150 + 2 + 260).
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

    // MARK: - Pane floors (a *drag* may not clip the navigator strip)

    /// Floors are derived from the navigator capsule, so a dragged pane always
    /// fits its tabs: inspector 7 × 28 buttons + 6 × 7 dividers + 2 × 5 pill +
    /// 2 × 8 pane = 264; the 4-tab sidebar the same way = 159.
    @MainActor
    func testPaneFloorsFitTheirNavigatorStrips() {
        XCTAssertEqual(InspectorSidebar.minimumPaneWidth, 264, accuracy: 0.001)
        XCTAssertEqual(InspectorPane.widthRange.lowerBound, 264, accuracy: 0.001)
        XCTAssertEqual(WorkspaceSidebar.minimumPaneWidth, 159, accuracy: 0.001)
    }

    /// The ceiling must survive a floor that outgrows it (invalid ranges trap).
    func testWidthRangeStaysValidWhenFloorExceedsCeiling() {
        let range = sidePaneWidthRange(floor: 900)
        XCTAssertEqual(range.lowerBound, 900, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 900, accuracy: 0.001)
    }

    /// The floor bounds the PREFERRED width only: the anti-overlap squeeze may
    /// still paint below it (documented on `resolveSidePaneWidths`). Pinned so
    /// the trade-off is a decision, not a surprise.
    @MainActor
    func testCompressedRegimeMayPaintBelowTheInspectorFloor() {
        // Main window at its minimum with the sidebar at its 400pt max: the
        // editor area gets 900 - 400 - 1 = 499.
        let panes = resolveSidePaneWidths(
            available: 499,
            sidebarWidth: 0,
            inspectorWidth: InspectorPane.widthRange.lowerBound,
            sidebarVisible: false, inspectorVisible: true)
        XCTAssertLessThan(panes.inspector, InspectorSidebar.minimumPaneWidth)
        // …but never wider than what is physically there — no overlap.
        XCTAssertLessThanOrEqual(panes.inspector + 1, 499)
    }

    @MainActor
    func testInspectorDragCannotGoNarrowerThanTheStrip() {
        let dragged = preferredPaneWidthFromDrag(
            displayWidth: 120, scale: 1, range: InspectorPane.widthRange)
        XCTAssertEqual(dragged, InspectorPane.widthRange.lowerBound, accuracy: 0.001)
    }

    /// Widths persisted before the floor existed (the old 150…400 range) are
    /// clamped on read, so an upgrade does not reopen with clipped tabs.
    @MainActor
    func testPersistedNarrowWidthIsClampedOnRead() {
        XCTAssertEqual(InspectorPane.clampWidth(150),
                       InspectorPane.widthRange.lowerBound, accuracy: 0.001)
        XCTAssertEqual(InspectorPane.clampWidth(320), 320, accuracy: 0.001)
        XCTAssertEqual(InspectorPane.clampWidth(9_000), 400, accuracy: 0.001)
    }

    func testNonPositiveScaleGuardsToUnity() {
        // A degenerate scale must not divide by zero / flip sign.
        XCTAssertEqual(
            preferredPaneWidthFromDrag(displayWidth: 200, scale: 0, range: range),
            200, accuracy: 0.001)
    }
}
