import XCTest
@testable import EditMD

/// Typography baseline: `EditorSettings.migratedVisual` hard-resets
/// the redesigned fields (reading column, element styles) and keeps the
/// user's personal font/margins.
@MainActor
final class EditorSettingsMigrationTests: XCTestCase {

    private func legacyVisual() -> ModeSettings {
        var elements = ElementStyles()
        elements.h1 = ElementStyle(colorHex: "ff0000", weight: .heavy, sizeScale: 2.5)
        elements.inlineCode = ElementStyle(colorHex: "d1242f")
        return ModeSettings(fontSize: 21, insetH: 12, insetV: 60, columnWidth: 0,
                            fontFamily: "Avenir", fontWeight: .medium,
                            elements: elements)
    }

    func testMigrationReplacesColumnAndElements() {
        let migrated = EditorSettings.migratedVisual(legacyVisual())
        XCTAssertEqual(migrated.columnWidth, 736)
        XCTAssertEqual(migrated.elements, ElementStyles(),
                       "redesign replaces stored element styles wholesale")
    }

    func testMigrationKeepsPersonalFontAndMargins() {
        let migrated = EditorSettings.migratedVisual(legacyVisual())
        XCTAssertEqual(migrated.fontSize, 21)
        XCTAssertEqual(migrated.insetH, 12)
        XCTAssertEqual(migrated.insetV, 60)
        XCTAssertEqual(migrated.fontFamily, "Avenir")
        XCTAssertEqual(migrated.fontWeight, .medium)
    }

    func testMigrationOverridesCustomColumnWidthToo() {
        // Hard reset by design: even a deliberately chosen width is replaced.
        var stored = legacyVisual()
        stored.columnWidth = 1200
        XCTAssertEqual(EditorSettings.migratedVisual(stored).columnWidth, 736)
    }

    func testBaselineStampIsCurrent() {
        // The stamp gates re-migration (2 = 11.0 column, 3 = 11.2 ramp).
        // Exact match on purpose: changing element defaults without bumping
        // this — or bumping it without meaning to re-wipe stored elements —
        // must fail a test.
        XCTAssertEqual(EditorSettings.visualTypographyBaseline, 3)
    }
}

/// Optical limits in `VisualStyle`: heading increment caps and the
/// mono `codeSize` floor/ceiling across the 9–40pt base range.
final class VisualTypographyScaleTests: XCTestCase {

    private func style(base: CGFloat) -> VisualStyle {
        var style = VisualStyle()
        style.baseSize = base
        return style
    }

    func testHeadingRampUncappedAtDefaultBase() {
        let s = style(base: 15)
        XCTAssertEqual(s.headingSize(1), 15 * 1.75, accuracy: 0.01)
        XCTAssertEqual(s.headingSize(2), 15 * 1.45, accuracy: 0.01)
        XCTAssertEqual(s.headingSize(3), 15 * 1.2, accuracy: 0.01)
    }

    func testHeadingCapsCompressRampAtAccessibilityBases() {
        let s = style(base: 40)
        XCTAssertEqual(s.headingSize(1), 56, accuracy: 0.01)   // 40 + 16, not 70
        XCTAssertEqual(s.headingSize(2), 50, accuracy: 0.01)   // 40 + 10
        XCTAssertEqual(s.headingSize(3), 46, accuracy: 0.01)   // 40 + 6
        XCTAssertEqual(s.headingSize(4), 40 * 1.07, accuracy: 0.01) // under the +4 cap
    }

    func testCodeSizeScalesFloorsAndNeverExceedsBody() {
        XCTAssertEqual(style(base: 15).codeSize, 15 * 0.88, accuracy: 0.01)
        XCTAssertEqual(style(base: 12).codeSize, 11, accuracy: 0.01)  // floor
        XCTAssertEqual(style(base: 9).codeSize, 9, accuracy: 0.01)    // ≤ body
        XCTAssertEqual(style(base: 40).codeSize, 40 * 0.88, accuracy: 0.01)
        for base in stride(from: 9.0, through: 40.0, by: 0.5) {
            XCTAssertLessThanOrEqual(style(base: base).codeSize, base)
        }
    }
}
