import XCTest
@testable import EditMD

/// Plan-11 typography baseline: `EditorSettings.migratedVisual` hard-resets
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
        // The stamp gates re-migration; 11.2 bumps it when element defaults
        // change again. Guard against accidental decrements.
        XCTAssertGreaterThanOrEqual(EditorSettings.visualTypographyBaseline, 2)
    }
}
