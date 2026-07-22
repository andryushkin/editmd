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
                                   themeCSS: theme.css)
        XCTAssertTrue(page.contains("Open Sans"), page)
        // Typora's Github-theme link blue and quote gray survive into the page.
        XCTAssertTrue(page.contains("#4183C4"), page)
        XCTAssertTrue(page.contains("border-left: 4px solid #dfe2e5"), page)
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
