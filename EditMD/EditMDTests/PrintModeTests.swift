import XCTest
import PDFKit
@testable import EditMD

/// Print mode's pure parts: what the flag exposes, the page geometry gate, the
/// font-set contract, the theme catalog and the settings migration. What
/// reaches the page renderer is in `PrintCoreRenderTests`.
final class PrintModeTests: XCTestCase {

    // MARK: - The flag

    func testPrintIsAbsentFromTheOfferedModesWhileTheFlagIsOff() {
        let offered = EditorMode.available(printEnabled: false)
        XCTAssertEqual(offered, [.source, .visual, .preview, .split])
        XCTAssertFalse(offered.contains(.print))
    }

    func testPrintIsOfferedLastWhenTheFlagIsOn() {
        XCTAssertEqual(EditorMode.available(printEnabled: true),
                       [.source, .visual, .preview, .split, .print])
    }

    func testGatedModeDoesNotResolveFromAStoredName() {
        XCTAssertNil(EditorMode.resolve(rawValue: "print", printEnabled: false))
        XCTAssertEqual(EditorMode.resolve(rawValue: "print", printEnabled: true), .print)
        // Ungated modes resolve either way; nonsense never does.
        XCTAssertEqual(EditorMode.resolve(rawValue: "visual", printEnabled: false), .visual)
        XCTAssertNil(EditorMode.resolve(rawValue: "typeset", printEnabled: true))
    }

    func testEveryModeKeepsItsOwnShortcutAndIdentity() {
        let keys = EditorMode.allCases.map(\.shortcutHint)
        XCTAssertEqual(keys, ["⌘1", "⌘2", "⌘3", "⌘4", "⌘5"])
        XCTAssertEqual(Set(EditorMode.allCases.map(\.rawValue)).count, EditorMode.allCases.count)
    }

    // MARK: - Page geometry

    func testA4PortraitLeavesTheExpectedTextFrame() throws {
        let geometry = try PrintPageGeometry.resolve(
            paper: .a4, orientation: .portrait,
            margins: PrintMargins(uniform: 56)).get()
        XCTAssertEqual(geometry.pageSize, CGSize(width: 595, height: 842))
        XCTAssertEqual(geometry.textFrame, CGSize(width: 595 - 112, height: 842 - 112))
    }

    func testLandscapeSwapsThePageSides() throws {
        let geometry = try PrintPageGeometry.resolve(
            paper: .a4, orientation: .landscape,
            margins: PrintMargins(uniform: 40)).get()
        XCTAssertEqual(geometry.pageSize, CGSize(width: 842, height: 595))
    }

    /// The case that took a process down when it reached layout: a margin that
    /// is not a finite number must come back as a value, never as a trap.
    func testNonFiniteMarginIsRejectedRatherThanLaidOut() {
        var margins = PrintMargins(uniform: 56)
        margins.top = .infinity
        XCTAssertEqual(PrintPageGeometry.resolve(paper: .a4, orientation: .portrait,
                                                 margins: margins).problem, .nonFinite)
        margins.top = .nan
        XCTAssertEqual(PrintPageGeometry.resolve(paper: .a4, orientation: .portrait,
                                                 margins: margins).problem, .nonFinite)
    }

    func testMarginsThatEatThePageAreRejected() {
        let margins = PrintMargins(top: 400, bottom: 400, leading: 40, trailing: 40)
        XCTAssertEqual(PrintPageGeometry.resolve(paper: .a4, orientation: .portrait,
                                                 margins: margins).problem,
                       .marginsExceedPage)
    }

    func testNegativeMarginIsRejected() {
        let margins = PrintMargins(top: -10, bottom: 56, leading: 56, trailing: 56)
        XCTAssertEqual(PrintPageGeometry.resolve(paper: .a4, orientation: .portrait,
                                                 margins: margins).problem, .nonFinite)
    }

    // MARK: - Font set

    func testCoverageFontsAreAlwaysAppended() {
        let set = printFontSet(bodyFamilies: ["New York"], headingFamilies: [],
                               monoFamilies: ["SF Mono"])
        for family in printCoverageFontFamilies {
            XCTAssertTrue(set.contains(family), "\(family) missing from \(set)")
        }
    }

    func testCoverageSurvivesAnEmptyThemeAndAnEmptyUserChoice() {
        let set = printFontSet(bodyFamilies: [], headingFamilies: [], monoFamilies: [])
        XCTAssertEqual(set, printCoverageFontFamilies)
    }

    func testFontSetKeepsTheHighestPriorityPositionOfADuplicate() {
        let set = printFontSet(bodyFamilies: ["Helvetica", "  "],
                               headingFamilies: ["Helvetica"],
                               monoFamilies: ["Menlo", "Helvetica"])
        XCTAssertEqual(set, ["Helvetica", "Menlo"] + printCoverageFontFamilies)
    }

    func testSettingsFontSetPutsTheUserFamilyFirstAndStillCarriesCoverage() {
        var settings = PrintSettings()
        settings.fontFamily = "Iowan Old Style"
        let set = settings.fontSet
        XCTAssertEqual(set.first, "Iowan Old Style")
        XCTAssertEqual(Array(set.suffix(printCoverageFontFamilies.count)),
                       printCoverageFontFamilies)
    }

    // MARK: - Theme catalog

    func testEveryPresetResolvesAndUnknownIdsFallBack() {
        for theme in PrintTheme.allPresets {
            XCTAssertEqual(PrintTheme.preset(named: theme.id).id, theme.id)
        }
        XCTAssertEqual(PrintTheme.preset(named: "no-such-theme").id, "default")
        XCTAssertEqual(PrintTheme.preset(named: "").id, "default")
    }

    func testCatalogIdsAreUnique() {
        let ids = PrintTheme.allPresets.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "\(ids)")
    }

    /// The chosen family leads the stack; it does not replace it. Replacing it
    /// leaves a machine that no longer has that face with no text face at all,
    /// and the page then prints in whatever came next — the monospaced one.
    func testUserFamilyLeadsTheThemeStackWithoutReplacingIt() {
        let compact = PrintTheme.preset(named: "compact")
        XCTAssertEqual(compact.resolvedBodyFamilies(userFamily: "Avenir"),
                       ["Avenir"] + compact.bodyFamilies)
        XCTAssertEqual(compact.resolvedHeadingFamilies(userFamily: "Avenir"),
                       ["Avenir"] + compact.headingFamilies)
        XCTAssertEqual(compact.resolvedHeadingFamilies(userFamily: ""), compact.headingFamilies)
        // Named twice is named once, and still first.
        XCTAssertEqual(compact.resolvedBodyFamilies(userFamily: "Helvetica Neue"),
                       ["Helvetica Neue", "SF Pro Text"])
        XCTAssertEqual(compact.resolvedBodyFamilies(userFamily: "  "), compact.bodyFamilies)
    }

    func testHeadingsInheritTheBodyStackWhenAThemeSetsNone() {
        let standard = PrintTheme.standard
        XCTAssertTrue(standard.headingFamilies.isEmpty)
        XCTAssertEqual(standard.resolvedHeadingFamilies(userFamily: ""), standard.bodyFamilies)
    }

    // MARK: - Theme switch migration

    @MainActor
    func testUntouchedGeometryFollowsTheIncomingTheme() {
        let current = EditorSettings.printDefaults()
        let migrated = EditorSettings.migratedPrintGeometry(
            current, from: .standard, to: .compact)
        XCTAssertEqual(migrated.fontSize, PrintTheme.compact.preferredFontSize)
        XCTAssertEqual(migrated.lineHeight, PrintTheme.compact.preferredLineHeight)
        XCTAssertEqual(migrated.margins, PrintTheme.compact.preferredMargins)
    }

    @MainActor
    func testATouchedValueSurvivesTheThemeSwitch() {
        var current = EditorSettings.printDefaults()
        current.fontSize = 13
        current.margins = PrintMargins(uniform: 30)
        let migrated = EditorSettings.migratedPrintGeometry(
            current, from: .standard, to: .book)
        XCTAssertEqual(migrated.fontSize, 13)
        XCTAssertEqual(migrated.margins, PrintMargins(uniform: 30))
        // Untouched leading still moves.
        XCTAssertEqual(migrated.lineHeight, PrintTheme.book.preferredLineHeight)
    }

    // MARK: - Settings coding

    func testStoredSettingsMissingEveryOptionalKeyDecodeToDefaults() throws {
        let data = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(PrintSettings.self, from: data)
        XCTAssertEqual(decoded, PrintSettings())
    }

    func testRoundTrip() throws {
        var settings = PrintSettings()
        settings.paper = .legal
        settings.orientation = .landscape
        settings.theme = "book"
        settings.margins = PrintMargins(top: 10, bottom: 20, leading: 30, trailing: 40)
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(PrintSettings.self, from: data), settings)
    }

    // MARK: - Outline

    @MainActor
    func testOutlineIsRebuiltFromHeadingsWhenThePDFCarriesNone() throws {
        let markdown = """
        # Intro

        Body text.

        ## Notes

        More text.
        """
        let pdf = try XCTUnwrap(Self.pdf(pages: ["Intro\nBody text.", "Notes\nMore text."]))
        XCTAssertNil(pdf.outlineRoot)
        let outline = printOutline(for: pdf, markdown: markdown)
        XCTAssertEqual(outline.map(\.title), ["Intro", "Notes"])
        XCTAssertEqual(outline.map(\.level), [1, 2])
        XCTAssertEqual(outline.map(\.pageIndex), [0, 1])
    }

    /// A repeated title must land under its own section, not jump back to the
    /// first page that happens to contain the same word.
    @MainActor
    func testRepeatedTitlesAdvanceInsteadOfJumpingBack() throws {
        let markdown = "# Notes\n\nOne.\n\n# Later\n\nTwo.\n\n# Notes\n\nThree."
        let pdf = try XCTUnwrap(Self.pdf(pages: ["Notes One.", "Later Two.", "Notes Three."]))
        let outline = printOutline(for: pdf, markdown: markdown)
        XCTAssertEqual(outline.map(\.pageIndex), [0, 1, 2])
    }

    @MainActor
    func testOutlineIsEmptyForADocumentWithoutHeadings() throws {
        let pdf = try XCTUnwrap(Self.pdf(pages: ["Just prose."]))
        XCTAssertTrue(printOutline(for: pdf, markdown: "Just prose.").isEmpty)
    }

    /// Minimal multi-page PDF with known text per page.
    private static func pdf(pages: [String]) -> PDFDocument? {
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        var mediaBox = bounds
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }
        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 14)])
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: bounds.insetBy(dx: 40, dy: 40), transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRangeMake(0, attributed.length), path, nil)
            CTFrameDraw(frame, context)
            context.endPDFPage()
        }
        context.closePDF()
        return PDFDocument(data: data as Data)
    }
}

private extension Result where Failure == PrintGeometryProblem {
    /// The failure of a geometry check, or nil when it passed.
    var problem: PrintGeometryProblem? {
        if case .failure(let problem) = self { return problem }
        return nil
    }
}
