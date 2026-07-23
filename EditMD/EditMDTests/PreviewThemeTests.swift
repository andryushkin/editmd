import XCTest
@testable import EditMD

/// Preview themes: catalog lookup, font resolution, and the CSS layering
/// contract (base < theme < user element overrides) in `previewHTMLPage`.
final class PreviewThemeTests: XCTestCase {

    // MARK: - Catalog

    func testPresetLookupFindsEveryCatalogEntryAndFallsBackToDefault() {
        for theme in PreviewTheme.allPresets {
            XCTAssertEqual(PreviewTheme.preset(named: theme.id).id, theme.id)
        }
        XCTAssertEqual(PreviewTheme.preset(named: "no-such-theme").id, "default")
        // Legacy/empty ids from old prefs must resolve, not crash or mis-style.
        XCTAssertEqual(PreviewTheme.preset(named: "").id, "default")
    }

    func testCatalogIdsAreUnique() {
        let ids = PreviewTheme.allPresets.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "\(ids)")
    }

    // MARK: - Font resolution

    func testUserFontFamilyBeatsThemeStack() {
        let literary = PreviewTheme.preset(named: "literary")
        XCTAssertTrue(literary.cssFontFamily(userFamily: "").contains("serif"))
        XCTAssertTrue(literary.cssFontFamily(userFamily: "Avenir").contains("\"Avenir\""))
        XCTAssertFalse(literary.cssFontFamily(userFamily: "Avenir").contains("New York"))
    }

    func testDefaultThemeKeepsSystemSansStack() {
        XCTAssertTrue(PreviewTheme.standard.cssFontFamily(userFamily: "")
            .contains("-apple-system"))
    }

    // MARK: - Page layering

    func testThemeCSSIsInjectedBetweenBaseAndUserElementCSS() {
        var elements = ElementStyles()
        elements.h1 = ElementStyle(sizeScale: 2.5)
        let page = previewHTMLPage(markdown: "# H", fontSize: 14,
                                   elements: elements,
                                   themeCSS: "h1 { font-size: 1.4em; } /* theme-marker */")
        let themeIndex = page.range(of: "/* theme-marker */")
        let userIndex = page.range(of: "h1 { font-size: 2.5em; }")
        let baseIndex = page.range(of: "h1 { font-size: 1.8em;")
        XCTAssertNotNil(themeIndex, page)
        XCTAssertNotNil(userIndex, page)
        XCTAssertNotNil(baseIndex, page)
        // Cascade order: base rules, then the theme layer, then user overrides.
        XCTAssertTrue(baseIndex!.lowerBound < themeIndex!.lowerBound)
        XCTAssertTrue(themeIndex!.lowerBound < userIndex!.lowerBound)
    }

    func testDefaultElementStylesEmitNoOverrideCSS() {
        let page = previewHTMLPage(markdown: "# H\n\n**b**", fontSize: 14)
        // Base rules carry the defaults; a silent element layer is what lets a
        // theme restyle elements the user never touched.
        XCTAssertFalse(page.contains("strong, b {"), page)
        XCTAssertEqual(page.components(separatedBy: "h2 { font-size: 1.5em").count, 2, page)
        XCTAssertTrue(page.contains("h1 { font-size: 1.8em; font-weight: 700; }"), page)
    }

    func testChangedElementStylesStillEmitOverrides() {
        var elements = ElementStyles()
        elements.h1 = ElementStyle(colorHex: "#FF0000", weight: .black, sizeScale: 2.5)
        elements.bold = ElementStyle(colorHex: "#00FF00", weight: .heavy)
        let page = previewHTMLPage(markdown: "# H", fontSize: 14, elements: elements)
        XCTAssertTrue(page.contains("h1 { font-size: 2.5em; font-weight: 900; color: #FF0000; }"), page)
        XCTAssertTrue(page.contains("strong, b { font-weight: 800; color: #00FF00; }"), page)
    }

    func testLiteraryThemePageUsesSerifAndItalicQuotes() {
        let theme = PreviewTheme.preset(named: "literary")
        let page = previewHTMLPage(markdown: "> q", fontSize: 14,
                                   fontFamily: theme.cssFontFamily(userFamily: ""),
                                   themeCSS: theme.css)
        XCTAssertTrue(page.contains("New York"), page)
        XCTAssertTrue(page.contains("font-style: italic"), page)
    }

    func testTyporaThemePageUsesOpenSansStackAndGithubTokens() {
        let theme = PreviewTheme.preset(named: "typora")
        let page = previewHTMLPage(markdown: "[l](https://e)", fontSize: 14,
                                   fontFamily: theme.cssFontFamily(userFamily: ""),
                                   themeCSS: theme.pageCSS(userFamily: ""))
        XCTAssertTrue(page.contains("Open Sans"), page)
        // Typora's Github-theme link blue and quote gray survive into the page.
        XCTAssertTrue(page.contains("#4183C4"))
        XCTAssertTrue(page.contains("border-left: 4px solid #dfe2e5"))
    }

    func testTyporaThemeBundlesOpenSansAsDataURIFaces() {
        let css = PreviewTheme.preset(named: "typora").pageCSS(userFamily: "")
        // The CSP allows only `font-src data:` — a file/https URL would never
        // load, so the faces must carry the actual woff payload.
        XCTAssertTrue(css.contains("@font-face"))
        XCTAssertTrue(css.contains("data:font/woff;base64,"))
        XCTAssertEqual(css.components(separatedBy: "@font-face").count - 1, 4, "4 faces expected")
        XCTAssertGreaterThan(css.count, 300_000, "bundled woff payload missing")
    }

    func testTyporaThemeDarkBlockIsNightNotRecoloredGithub() {
        let theme = PreviewTheme.preset(named: "typora")
        let css = theme.css
        // Night structure: heading family, underlined gray links, square
        // bullets, #333 code panels — not just darker Github grays.
        XCTAssertTrue(css.contains("Lucida Grande"))
        XCTAssertTrue(css.contains("color: #e0e0e0; text-decoration: underline"))
        XCTAssertTrue(css.contains("list-style: square"))
        XCTAssertTrue(css.contains("background: #333"))
        // Night vertical rhythm and full-width tables (night.css:242).
        XCTAssertTrue(css.contains("p { margin: 0 0 1.5rem; }"))
        XCTAssertTrue(css.contains("ul, ol { margin: 0 0 1.5rem; }"))
        XCTAssertTrue(css.contains("table { margin: 0 0 1.5rem; display: table; width: 100%;"))
        // Night body font applies only while the user keeps the default family.
        XCTAssertTrue(theme.pageCSS(userFamily: "").contains(
            "@media (prefers-color-scheme: dark) { body { font-family: \"Helvetica Neue\""))
        XCTAssertFalse(theme.pageCSS(userFamily: "Avenir").contains("body { font-family:"))
    }

    @MainActor
    func testThemeSwitchMigratesGeometryOnlyWhileOnThemeDefaults() {
        let typora = PreviewTheme.preset(named: "typora")
        let standard = PreviewTheme.standard
        let stock = EditorSettings.previewDefaults()

        // Stock geometry follows the selected theme in both directions.
        let toTypora = EditorSettings.migratedPreviewGeometry(stock, from: standard, to: typora)
        XCTAssertEqual(toTypora.fontSize, 16)
        XCTAssertEqual(toTypora.columnWidth, 860)
        let backToStock = EditorSettings.migratedPreviewGeometry(toTypora, from: typora, to: standard)
        XCTAssertEqual(backToStock.fontSize, 15)
        XCTAssertEqual(backToStock.columnWidth, 736)

        // Values the user touched survive — including explicitly re-picking
        // the stock numbers while the Typora theme is active.
        var chosen = stock
        chosen.fontSize = 15
        chosen.columnWidth = 736
        let kept = EditorSettings.migratedPreviewGeometry(chosen, from: typora, to: standard)
        XCTAssertEqual(kept.fontSize, 15)
        XCTAssertEqual(kept.columnWidth, 736)

        // 0 = "full width" is a deliberate choice, never rewritten.
        var wide = stock
        wide.columnWidth = 0
        XCTAssertEqual(EditorSettings.migratedPreviewGeometry(wide, from: standard, to: typora).columnWidth, 0)

        // Switching between two themes without preferred geometry is a no-op.
        let minimal = PreviewTheme.preset(named: "minimal")
        XCTAssertEqual(EditorSettings.migratedPreviewGeometry(stock, from: standard, to: minimal), stock)
    }

    @MainActor
    func testLegacyTyporaStartupUpgradesStockGeometry() {
        // Install that picked typora before selection-time rewriting existed:
        // stored geometry stayed stock, but rendered as 16/860 back then —
        // the startup upgrade reproduces what the user saw.
        let stock = EditorSettings.previewDefaults()
        let upgraded = EditorSettings.legacyPreviewGeometryUpgrade(stock, activeThemeID: "typora")
        XCTAssertEqual(upgraded.fontSize, 16)
        XCTAssertEqual(upgraded.columnWidth, 860)

        // Touched values and full width survive the upgrade.
        var custom = stock
        custom.fontSize = 18
        custom.columnWidth = 0
        let kept = EditorSettings.legacyPreviewGeometryUpgrade(custom, activeThemeID: "typora")
        XCTAssertEqual(kept.fontSize, 18)
        XCTAssertEqual(kept.columnWidth, 0)

        // Themes without preferred geometry make the startup pass a no-op —
        // including unknown/legacy ids, which resolve to the default look.
        XCTAssertEqual(EditorSettings.legacyPreviewGeometryUpgrade(stock, activeThemeID: "minimal"), stock)
        XCTAssertEqual(EditorSettings.legacyPreviewGeometryUpgrade(stock, activeThemeID: ""), stock)
    }

    @MainActor
    func testPreviewGeometryBaselineStampIsCurrent() {
        // Exact match on purpose (mirrors visualTypographyBaseline): changing
        // theme geometry semantics without bumping the stamp — or bumping it
        // accidentally, re-running the upgrade over deliberate stock values —
        // must fail a test.
        XCTAssertEqual(EditorSettings.previewGeometryBaseline, 1)
    }

    // MARK: - Settings persistence

    func testPreviewTypographySettingsDecodeWithoutThemeField() throws {
        let legacy = Data("{\"lineHeight\": 1.5}".utf8)
        let decoded = try JSONDecoder().decode(PreviewTypographySettings.self, from: legacy)
        XCTAssertEqual(decoded.lineHeight, 1.5)
        XCTAssertEqual(decoded.theme, "default")
    }

    func testPreviewTypographySettingsRoundTripKeepsTheme() throws {
        let settings = PreviewTypographySettings(lineHeight: 1.7, theme: "academic")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(PreviewTypographySettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }
}
