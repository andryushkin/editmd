import XCTest
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import EditMD

/// What the Print pane sends to the page renderer, and what comes back.
///
/// Two kinds of probe live here and they are not interchangeable. One reads the
/// **job** — what the app said — and catches a mistranslation without a PDF in
/// the way. The other reads the **PDF** — what the renderer did — and is the only
/// kind that can catch a value that was computed correctly and then never sent.
/// A job probe passing is never evidence of delivery, which is why every claim
/// about something reaching paper is made against the bytes.
///
/// Three properties of the renderer are used as instruments rather than tested:
/// under PDF/UA a glyph with no font behind it stops the export outright
/// (measured 25 Aug 2026, status 13), the sheet geometry is exact to the
/// thousandth of a point, and printing the same document twice gives the same
/// bytes — there is no clock in it.
final class PrintCoreRenderTests: XCTestCase {

    // MARK: - Fixtures

    /// PostScript points for a length in millimetres — the app stores margins in
    /// points, the renderer takes millimetres.
    private static func pt(_ mm: Double) -> CGFloat { CGFloat(mm * 72 / 25.4) }

    /// Long enough to fill several sheets of A4 at the default settings.
    private static let filler = (1...30).map { index in
        "Paragraph \(index). " + String(
            repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do "
                     + "eiusmod tempor incididunt ut labore. ", count: 5)
    }.joined(separator: "\n\n")

    /// One paragraph, several sheets long, with nothing in it that a page may
    /// break at other than a line.
    ///
    /// The margin probe needs this: at a paragraph boundary the typesetter also
    /// refuses to strand a line, so the foot of a sheet can sit two lines above
    /// the margin for a reason that has nothing to do with margins. Inside one
    /// paragraph the only slack left is where the line grid happens to land.
    private static let unbrokenParagraph = String(
        repeating: "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod "
                 + "tempor incididunt ut labore et dolore magna aliqua enim ad minim. ",
        count: 60)

    private static func request(_ markdown: String,
                                settings: PrintSettings = PrintSettings(),
                                baseDir: URL? = nil) -> PrintRenderRequest {
        PrintRenderRequest(markdown: markdown, baseDir: baseDir,
                           settings: settings, syntaxHighlighting: false)
    }

    /// Every character box on a page that is a real box, unioned.
    ///
    /// A box that is not finite or has no area is not a mark on the page and is
    /// skipped; a finite one that lies outside the sheet is a defect and is
    /// reported by the caller, never quietly dropped — dropping it is how a
    /// renderer that puts text off the paper passes a margin check.
    private static func inkBounds(_ page: PDFPage) -> (union: CGRect, outside: Int) {
        let sheet = page.bounds(for: .mediaBox)
        var union = CGRect.null
        var outside = 0
        for index in 0..<page.numberOfCharacters {
            let box = page.characterBounds(at: index)
            guard box.origin.x.isFinite, box.origin.y.isFinite,
                  box.size.width.isFinite, box.size.height.isFinite,
                  box.width > 0, box.height > 0 else { continue }
            if !sheet.insetBy(dx: -0.5, dy: -0.5).contains(box) { outside += 1 }
            union = union.union(box)
        }
        return (union, outside)
    }

    private static func find(_ needle: String, in pdf: Data) -> Bool {
        pdf.range(of: Data(needle.utf8)) != nil
    }

    /// Baseline-to-baseline distance on a page, in points: the commonest gap
    /// between consecutive rows of glyph boxes.
    ///
    /// Rows, not baselines read out of the PDF: PDFKit answers with a box per
    /// character, and the boxes of one row differ in `origin.y` by 2–3 pt
    /// (ascenders, descenders, digits) while consecutive rows sit 12–19 pt apart
    /// at ordinary sizes. Hence the 5 pt grouping threshold — 1 pt splits a
    /// single row into several and the result is rubbish.
    ///
    /// The *mode* and not the mean: a sheet also carries a page number, and may
    /// carry a heading, each contributing one gap that is not the body leading.
    private static func modeLineAdvance(_ page: PDFPage) -> Double? {
        var tops: [CGFloat] = []
        for index in 0..<page.numberOfCharacters {
            let box = page.characterBounds(at: index)
            guard box.origin.y.isFinite, box.size.height.isFinite,
                  box.width > 0, box.height > 0 else { continue }
            tops.append(box.origin.y)
        }
        guard tops.count > 2 else { return nil }
        tops.sort()

        var rows: [CGFloat] = []
        var row: [CGFloat] = [tops[0]]
        for y in tops.dropFirst() {
            if y - (row.last ?? y) <= 5 {
                row.append(y)
            } else {
                rows.append(row.reduce(0, +) / CGFloat(row.count))
                row = [y]
            }
        }
        rows.append(row.reduce(0, +) / CGFloat(row.count))
        guard rows.count > 2 else { return nil }

        // Half a point of bucketing: two rows of one paragraph never differ by
        // that much, and the tolerance the caller checks against is far wider.
        var buckets: [Double: [Double]] = [:]
        for gap in zip(rows.dropFirst(), rows).map({ Double($0 - $1) }) {
            buckets[(gap * 2).rounded() / 2, default: []].append(gap)
        }
        guard let commonest = buckets.max(by: { $0.value.count < $1.value.count })?.value
        else { return nil }
        return commonest.reduce(0, +) / Double(commonest.count)
    }

    /// `PDM_WARN_MISSING_ASSET`, the frozen number out of the ABI header.
    ///
    /// Written down here rather than imported from the module: the header ships
    /// *inside* the artifact, so an imported constant would move together with
    /// the library and this probe could never disagree with it.
    private static let missingAssetWarning: Int32 = 1

    /// `PDM_WARN_UNREADABLE_ASSET` — bytes were handed over and were not a
    /// picture the renderer reads. Same rule about writing the number down.
    private static let unreadableAssetWarning: Int32 = 2

    // MARK: - R-03 · the print is paginated

    /// The sheet is the sheet that was asked for, and a smaller one takes more of
    /// them.
    ///
    /// Compared against the exact geometry of the paper, not against
    /// `PrintPaperSize.size`: that one is rounded for on-screen layout (595 × 842
    /// for A4) and would pass a renderer that is a point and a half out.
    func testTheSheetIsTheDeclaredPaperAndASmallerOneTakesMorePages() async throws {
        let markdown = "# Heading\n\n\(Self.filler)\n"
        var a5Settings = PrintSettings()
        a5Settings.paper = .a5

        let a4 = try await PrintPDFRenderer.render(Self.request(markdown))
        let a5 = try await PrintPDFRenderer.render(Self.request(markdown, settings: a5Settings))

        XCTAssertGreaterThan(a5.pageCount, a4.pageCount,
                             "A5 = \(a5.pageCount), A4 = \(a4.pageCount)")

        let sheet = try XCTUnwrap(PDFDocument(data: a4.pdf)?.page(at: 0))
            .bounds(for: .mediaBox)
        XCTAssertEqual(sheet.width, 595.276, accuracy: 0.5)
        XCTAssertEqual(sheet.height, 841.890, accuracy: 0.5)
        XCTAssertEqual(a4.pageCount, PDFDocument(data: a4.pdf)?.pageCount)
    }

    func testLandscapeSwapsTheSidesOfTheSheet() async throws {
        var settings = PrintSettings()
        settings.orientation = .landscape
        let result = try await PrintPDFRenderer.render(
            Self.request("# Heading\n\nShort.\n", settings: settings))
        let sheet = try XCTUnwrap(PDFDocument(data: result.pdf)?.page(at: 0))
            .bounds(for: .mediaBox)
        XCTAssertEqual(sheet.width, 841.890, accuracy: 0.5)
        XCTAssertEqual(sheet.height, 595.276, accuracy: 0.5)
    }

    /// Four *different* margins, checked from both sides.
    ///
    /// Different because equal ones cannot show a transposition. From both sides
    /// because "the text is inside the margins" is also true of a page whose
    /// margins came out three times too wide — which is exactly what happens when
    /// points are handed over as millimetres, and is therefore the one mistake a
    /// one-sided check is blind to.
    ///
    /// The bottom edge gets a little more room than the other three, and only a
    /// little: the last line of a sheet lands on the leading grid, so the gap
    /// there is the margin plus whatever is left over — under one line box, now
    /// that the fixture is a single unbroken paragraph and the widow rule has no
    /// boundary to act at. Three line boxes, which an earlier revision allowed,
    /// would have let an implementation widen the bottom margin by 17 mm and stay
    /// green.
    ///
    /// Two settings differ from the pane's, and neither is a shortcut. Page
    /// numbers are off because a number sits *in* the bottom margin and would be
    /// measured as text. Text is justified because a ragged right edge measures
    /// where the words happened to break, not where the margin is — measured
    /// 25 Aug 2026, 14 pt short of it on this fixture, which is a property of the
    /// sentence rather than of the page.
    func testEveryMarginReachesTheSheet() async throws {
        var settings = PrintSettings()
        settings.margins = PrintMargins(top: Self.pt(10), bottom: Self.pt(30),
                                        leading: Self.pt(40), trailing: Self.pt(20))
        var options = PrintPageOptions.standard
        options.pageNumbers = false
        options.justify = true

        let result = try await PrintPDFRenderer.render(
            Self.request(Self.unbrokenParagraph, settings: settings), options: options)
        XCTAssertGreaterThan(result.pageCount, 1,
                             "the first sheet must be full for its foot to mean anything")
        let page = try XCTUnwrap(PDFDocument(data: result.pdf)?.page(at: 0))
        let sheet = page.bounds(for: .mediaBox)
        let (ink, outside) = Self.inkBounds(page)

        XCTAssertEqual(outside, 0, "characters printed outside the sheet")
        XCTAssertFalse(ink.isNull, "no text on the first page to measure margins against")

        let tolerance = Self.pt(1)  // ≈ 2.8 pt: ragged edges and side bearings
        XCTAssertEqual(ink.minX, Self.pt(40), accuracy: tolerance, "left")
        XCTAssertEqual(sheet.maxX - ink.maxX, Self.pt(20), accuracy: tolerance, "right")
        XCTAssertEqual(sheet.maxY - ink.maxY, Self.pt(10), accuracy: tolerance, "top")

        let lineBox = settings.fontSize * settings.lineHeight
        print("bottom gap: \(ink.minY) pt, margin \(Self.pt(30)) pt, "
              + "line box \(lineBox) pt")
        XCTAssertGreaterThanOrEqual(ink.minY, Self.pt(30) - tolerance, "bottom, too little")
        XCTAssertLessThanOrEqual(ink.minY, Self.pt(30) + tolerance + lineBox,
                                 "bottom, too much")
    }

    /// A link to a heading of this document is a jump inside the PDF, and it
    /// lands on the heading's own page rather than merely somewhere.
    func testAnInternalAnchorJumpsToThePageOfItsHeading() async throws {
        let markdown = """
        # First heading

        A [jump](#second-heading) link.

        \(Self.filler)

        ## Second heading

        Tail text.
        """
        let result = try await PrintPDFRenderer.render(Self.request(markdown))
        let document = try XCTUnwrap(PDFDocument(data: result.pdf))
        XCTAssertGreaterThan(document.pageCount, 1, "the fixture must span sheets")

        var destinations: [Int] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                guard let action = annotation.action as? PDFActionGoTo,
                      let target = action.destination.page else { continue }
                destinations.append(document.index(for: target))
            }
        }
        XCTAssertEqual(destinations.count, 1, "expected exactly one internal jump")

        let headingPage = (0..<document.pageCount).first {
            document.page(at: $0)?.string?.contains("Second heading") == true
        }
        XCTAssertEqual(destinations.first, headingPage)
    }

    /// The pages carry bookmarks, and the top level of them is the document's
    /// top-level headings.
    func testTheDocumentOutlineIsWrittenIntoThePDF() async throws {
        let markdown = """
        # Alpha

        One.

        ## Alpha detail

        Two.

        # Beta

        Three.
        """
        let result = try await PrintPDFRenderer.render(Self.request(markdown))
        let document = try XCTUnwrap(PDFDocument(data: result.pdf))
        let root = try XCTUnwrap(document.outlineRoot, "no bookmarks in the PDF")

        var top: [String] = []
        for index in 0..<root.numberOfChildren {
            top.append(root.child(at: index)?.label ?? "")
        }
        XCTAssertEqual(top, ["Alpha", "Beta"])

        let alpha = try XCTUnwrap(root.child(at: 0))
        XCTAssertEqual((0..<alpha.numberOfChildren).map { alpha.child(at: $0)?.label ?? "" },
                       ["Alpha detail"])
    }

    // MARK: - R-06 · language and accessibility are stated, not assumed

    /// A language chosen at the boundary reaches the PDF.
    ///
    /// Asked for as `de`, never as `en`: the renderer writes `/Lang(en)` by
    /// itself when nobody says anything, so a probe looking for `en` is green
    /// with the call removed entirely (measured 25 Aug 2026).
    func testTheChosenLanguageReachesThePDF() async throws {
        var options = PrintPageOptions.standard
        options.lang = "de"
        let result = try await PrintPDFRenderer.render(
            Self.request("# Heading\n\nBody.\n"), options: options)
        XCTAssertTrue(Self.find("/Lang(de)", in: result.pdf), "no /Lang(de) in the PDF")
    }

    /// The default is a value the app states, not one it inherits. Read off the
    /// job, deliberately: this is a claim about what was said, and the PDF cannot
    /// tell "we sent en" from "we sent nothing".
    func testTheDefaultLanguageIsStatedInTheJob() async throws {
        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n"))
        XCTAssertEqual(job.lang, PrintJob.defaultLanguage)
        XCTAssertEqual(PrintJob.defaultLanguage, "en")
    }

    /// PDF/UA is declared only when it was asked for.
    ///
    /// Checked through the XMP identifier and nothing else: `/StructTreeRoot` and
    /// `/MarkInfo` are in every document this renderer makes, accessible or not,
    /// so a probe built on them is green either way.
    func testAccessibilityIsDeclaredOnlyWhenAskedFor() async throws {
        var options = PrintPageOptions.standard
        options.pdfUA = true
        let markdown = "# Heading\n\nBody.\n"

        let accessible = try await PrintPDFRenderer.render(Self.request(markdown),
                                                           options: options)
        let plain = try await PrintPDFRenderer.render(Self.request(markdown))
        XCTAssertTrue(Self.find("pdfuaid", in: accessible.pdf))
        XCTAssertFalse(Self.find("pdfuaid", in: plain.pdf))
        XCTAssertFalse(PrintPageOptions.standard.pdfUA)
    }

    /// Accessibility is not a label: with it on, a glyph no supplied font can
    /// draw stops the export instead of vanishing from the page.
    ///
    /// This is what makes the two delivery probes below possible, so it is
    /// asserted rather than assumed. Built by taking a real job and removing the
    /// coverage faces — the same document prints when they are there.
    func testAccessibilityRefusesAGlyphWithNoFontBehindIt() async throws {
        var options = PrintPageOptions.standard
        options.pdfUA = true
        var job = try await PrintPDFRenderer.job(for: Self.request("Target 🎯 here.\n"),
                                                 options: options)
        job.fonts.removeAll { printCoverageFontFamilies.contains($0.family) }

        XCTAssertThrowsError(try PDMCore.render(job) { _ in nil }) { error in
            guard case .call(_, let status, let message)? = error as? PDMCore.CoreError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(status, 13, "\(message ?? "")")
            XCTAssertNotNil(message)
        }
    }

    /// What the renderer answers when it is given no fonts at all.
    ///
    /// Written down because the whole font path is built on the assumption that
    /// an empty set is a refusal and not a fallback — the renderer is compiled
    /// without bundled faces on purpose.
    func testAnEmptyFontSetIsRefusedRatherThanSubstituted() async throws {
        var job = try await PrintPDFRenderer.job(for: Self.request("Body.\n"))
        job.fonts = []
        XCTAssertThrowsError(try PDMCore.render(job) { _ in nil }) { error in
            guard case .call(_, let status, _)? = error as? PDMCore.CoreError else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(status, 10)
        }
    }

    // MARK: - R-07 · the font set reaches the output

    /// The job carries the whole set the Settings panel shows, in the order it
    /// shows it, with coverage last and bytes behind every family that resolved.
    func testTheJobCarriesTheWholeFontSetInOrder() async throws {
        let settings = PrintSettings()
        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n",
                                                                   settings: settings))

        var families: [String] = []
        for file in job.fonts where families.last != file.family {
            families.append(file.family)
        }
        XCTAssertEqual(Set(families).count, families.count, "a family appears twice: \(families)")

        // Every family the host has a face for, and no other, in the set's order.
        let expected = settings.fontSet.filter { !PrintFontLoader.faceFiles(of: $0).isEmpty }
        XCTAssertEqual(families, expected)
        XCTAssertEqual(Array(families.suffix(printCoverageFontFamilies.count)),
                       printCoverageFontFamilies)
        XCTAssertTrue(job.fonts.allSatisfy { !$0.bytes.isEmpty })

        // The measured shape of that list on macOS, so that "expected" above
        // cannot quietly become empty and still agree with itself.
        XCTAssertTrue(families.contains("New York"), "\(families)")
        XCTAssertTrue(families.contains("Menlo"), "\(families)")
        XCTAssertFalse(families.contains("SF Mono"),
                       "SF Mono resolves to no file on macOS; if it now does, this list moved")
        XCTAssertEqual(job.bodyFont, "New York")
        XCTAssertEqual(job.monoFont, "Menlo")
    }

    /// The emoji face is not merely listed — it is delivered.
    ///
    /// Under PDF/UA an undrawable glyph is fatal, so a document that prints is
    /// proof the bytes arrived. Removing the family from the *job* and removing
    /// its `add_font` at the boundary both turn this red; a probe on the job
    /// alone would only catch the first.
    func testTheEmojiFaceIsDeliveredToTheRenderer() async throws {
        var options = PrintPageOptions.standard
        options.pdfUA = true
        let result = try await PrintPDFRenderer.render(
            Self.request("# Heading\n\nTarget 🎯 here.\n"), options: options)
        XCTAssertGreaterThan(result.pageCount, 0)
    }

    /// The symbol face is delivered too, and it takes its own witness.
    ///
    /// `∮` (U+222E), not an emoji and not `⌘` or `✓`: those three print without
    /// Apple Symbols, so they witness nothing. This character is the one measured
    /// to fail without it (25 Aug 2026).
    func testTheSymbolFaceIsDeliveredToTheRenderer() async throws {
        var options = PrintPageOptions.standard
        options.pdfUA = true
        let result = try await PrintPDFRenderer.render(
            Self.request("# Heading\n\nA contour integral ∮ here.\n"), options: options)
        XCTAssertGreaterThan(result.pageCount, 0)
    }

    // MARK: - The job the request turns into

    func testMarginsAreConvertedToMillimetresAndNamedByTheirSide() async throws {
        var settings = PrintSettings()
        settings.margins = PrintMargins(top: Self.pt(10), bottom: Self.pt(30),
                                        leading: Self.pt(40), trailing: Self.pt(20))
        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n",
                                                                   settings: settings))
        XCTAssertEqual(job.marginsMM.top, 10, accuracy: 0.001)
        XCTAssertEqual(job.marginsMM.right, 20, accuracy: 0.001, "trailing is the right edge")
        XCTAssertEqual(job.marginsMM.bottom, 30, accuracy: 0.001)
        XCTAssertEqual(job.marginsMM.left, 40, accuracy: 0.001, "leading is the left edge")
    }

    func testEveryPaperSizeHasTheNameTheRendererKnows() {
        XCTAssertEqual(PrintPaperSize.allCases.map(PrintJob.paperName),
                       ["a4", "a5", "us-letter", "us-legal"])
    }

    func testOrientationBecomesTheFlippedFlag() async throws {
        var landscape = PrintSettings()
        landscape.orientation = .landscape
        let portraitJob = try await PrintPDFRenderer.job(for: Self.request("Body.\n"))
        let landscapeJob = try await PrintPDFRenderer.job(
            for: Self.request("Body.\n", settings: landscape))
        XCTAssertFalse(portraitJob.flipped)
        XCTAssertTrue(landscapeJob.flipped)
    }

    /// Leading is the app's line height minus the cap height of the face that
    /// will set the text — the renderer adds the cap height back.
    func testLeadingIsTheLineHeightLessTheCapHeightOfTheChosenFace() async throws {
        let capHeight = try XCTUnwrap(PrintFontLoader.capHeightEm(of: "New York"))
        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n"))
        XCTAssertEqual(job.bodyFont, "New York")
        XCTAssertEqual(job.leadingEm,
                       Double(PrintSettings().lineHeight) - capHeight,
                       accuracy: 0.0001)
        // Never negative, whatever the settings say.
        XCTAssertEqual(PrintJob.leadingEm(for: 0.5, capHeightEm: 0.71), 0)
    }

    /// A user's face that the machine no longer has falls back to the theme's
    /// text face — not to whatever came next in the set.
    ///
    /// Whatever came next is the monospaced face: mono sits ahead of the coverage
    /// faces in the set, so "first family that resolved" prints the body of the
    /// document in Menlo. The fallback lives in the *set*, so what Settings shows
    /// stays what gets printed.
    func testAVanishedUserFamilyFallsBackToTheThemeFaceAndNotToTheMonoOne() async throws {
        var settings = PrintSettings()
        settings.fontFamily = "No Such Family At All"
        XCTAssertNil(PrintFontLoader.capHeightEm(of: settings.fontFamily))

        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n",
                                                                   settings: settings))
        XCTAssertNil(job.fonts.first { $0.family == settings.fontFamily },
                     "a family with no file must not be handed over")
        XCTAssertEqual(job.bodyFont, "New York")
        XCTAssertNotEqual(job.bodyFont, job.monoFont)

        // And the bytes arrive in that order too: naming a face the renderer
        // only meets after the monospaced one would still print monospaced if
        // the name were ever dropped.
        let newYork = job.fonts.firstIndex { $0.family == "New York" }
        let menlo = job.fonts.firstIndex { $0.family == "Menlo" }
        XCTAssertNotNil(newYork)
        XCTAssertNotNil(menlo)
        XCTAssertLessThan(try XCTUnwrap(newYork), try XCTUnwrap(menlo))

        // The leading follows the face that will actually set the text.
        XCTAssertEqual(job.leadingEm,
                       Double(settings.lineHeight)
                           - (try XCTUnwrap(PrintFontLoader.capHeightEm(of: "New York"))),
                       accuracy: 0.0001)
        // Settings shows the list the page is printed from, fallback included.
        XCTAssertEqual(settings.fontSet.first, settings.fontFamily)
        XCTAssertTrue(settings.fontSet.contains("New York"), "\(settings.fontSet)")
    }

    /// The stated fallback is still what a face with no measurable cap height
    /// gets. Nothing in the default themes reaches it, so it is asserted here
    /// rather than left to be discovered wrong.
    func testTheCapHeightFallbackIsUsedWhenNoFaceCanBeMeasured() {
        XCTAssertEqual(PrintJob.leadingEm(for: 1.45, capHeightEm: printTypstCapHeightFallbackEm),
                       1.45 - printTypstCapHeightFallbackEm, accuracy: 0.0001)
        XCTAssertEqual(printTypstCapHeightFallbackEm, 0.71)
    }

    /// Every field the boundary is asked about is filled in, including the ones
    /// whose value happens to match the renderer's own default. A field left out
    /// here is a default that could move underneath the app without a diff.
    func testTheStandardOptionsAreStatedInTheJob() async throws {
        let job = try await PrintPDFRenderer.job(for: Self.request("Body.\n"))
        XCTAssertNil(job.title)
        XCTAssertTrue(job.links.isEmpty)
        XCTAssertFalse(job.outline)
        XCTAssertTrue(job.pageNumbers)
        XCTAssertFalse(job.runningHeader)
        XCTAssertFalse(job.justify)
        XCTAssertFalse(job.pdfUA)
        XCTAssertEqual(job.paper, "a4")
        XCTAssertEqual(job.fontSizePt, Double(PrintSettings().fontSize))
    }

    func testAGeometryThatLeavesNoPageIsRefusedBeforeAnythingIsPrinted() async {
        var settings = PrintSettings()
        settings.margins = PrintMargins(top: 400, bottom: 400, leading: 40, trailing: 40)
        do {
            _ = try await PrintPDFRenderer.render(Self.request("Body.\n", settings: settings))
            XCTFail("printed a page that cannot exist")
        } catch let error as PrintRenderError {
            guard case .geometry(let problem) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(problem, .marginsExceedPage)
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: - The boundary itself

    /// An empty document is an ordinary state of the pane, not an error — and it
    /// is also the case in which the markdown pointer is most likely to be null.
    func testAnEmptyDocumentPrintsOneEmptySheet() async throws {
        let result = try await PrintPDFRenderer.render(Self.request(""))
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertFalse(result.pdf.isEmpty)
    }

    /// Markdown is handed over as bytes and a length. Handed over as a C string
    /// it would stop at the NUL, and the tail of the document would disappear
    /// with nothing said.
    func testTextAfterANULByteStillPrints() async throws {
        let markdown = "Before\u{0}AfterTheNul\n"
        let result = try await PrintPDFRenderer.render(Self.request(markdown))
        let page = try XCTUnwrap(PDFDocument(data: result.pdf)?.page(at: 0))
        XCTAssertEqual(page.string?.contains("AfterTheNul"), true, "\(page.string ?? "")")
    }

    /// Warnings survive the boundary instead of being dropped with the result
    /// handle. A remote image is the cheapest one to provoke: the renderer has no
    /// network and does not ask the app for such a file.
    func testWarningsAreCopiedOutOfTheResult() async throws {
        let result = try await PrintPDFRenderer.render(
            Self.request("![alt](https://example.com/nothing.png)\n"))
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.warnings.allSatisfy { !$0.message.isEmpty })
    }

    // MARK: - Assets

    /// A picture next to the document reaches the page, and one outside its
    /// folder does not — the renderer says so instead of silently printing it.
    func testALocalPictureIsSuppliedAndAnEscapingOneIsNot() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("doc")

        let inside = try await PrintPDFRenderer.render(
            Self.request("![alt](pic.png)\n", baseDir: folder))
        XCTAssertTrue(inside.warnings.isEmpty, "\(inside.warnings)")

        let outside = try await PrintPDFRenderer.render(
            Self.request("![alt](../secret.png)\n", baseDir: folder))
        XCTAssertFalse(outside.warnings.isEmpty, "an escaping path was supplied")
    }

    func testTheAssetLoaderRefusesEverythingOutsideItsFolder() throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = PrintAssetLoader(baseDir: root.appendingPathComponent("doc"))

        XCTAssertNotNil(loader.bytes(forAssetNamed: "pic.png"))
        XCTAssertNotNil(loader.bytes(forAssetNamed: "sub/../pic.png"))
        XCTAssertNotNil(loader.bytes(forAssetNamed: "sub/nested.png"))

        XCTAssertNil(loader.bytes(forAssetNamed: "../secret.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: "sub/../../secret.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: "/etc/passwd"))
        XCTAssertNil(loader.bytes(forAssetNamed: "~/secret.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: "file:///etc/passwd"))
        XCTAssertNil(loader.bytes(forAssetNamed: "https://example.com/a.png"))
        XCTAssertNil(loader.bytes(forAssetNamed: ""))
        // A link inside the folder that leads out of it. Folding `..` away
        // without following links leaves this looking like an ordinary child.
        XCTAssertNil(loader.bytes(forAssetNamed: "escape.png"))
        // Not an image the app opens anywhere else.
        XCTAssertNil(loader.bytes(forAssetNamed: "notes.md"))
        // A directory named like a picture.
        XCTAssertNil(loader.bytes(forAssetNamed: "folder.png"))
        // Bigger than what Preview will inline.
        XCTAssertNil(loader.bytes(forAssetNamed: "huge.png"))
    }

    /// A sibling folder whose name merely starts with the same characters is a
    /// different folder. Compared as strings, `doc-other` is "inside" `doc`.
    func testAFolderWithASharedNamePrefixIsOutside() throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let loader = PrintAssetLoader(baseDir: root.appendingPathComponent("doc"))
        XCTAssertNil(loader.bytes(forAssetNamed: "../doc-other/pic.png"))
        XCTAssertTrue(PrintAssetLoader.path(root.appendingPathComponent("doc/pic.png"),
                                            isInside: root.appendingPathComponent("doc")))
        XCTAssertFalse(PrintAssetLoader.path(root.appendingPathComponent("doc-other/pic.png"),
                                             isInside: root.appendingPathComponent("doc")))
        // A folder is not inside itself: there is no file there to read.
        XCTAssertFalse(PrintAssetLoader.path(root.appendingPathComponent("doc"),
                                             isInside: root.appendingPathComponent("doc")))
    }

    func testAnUnsavedDocumentHasNoAssetsAtAll() {
        let loader = PrintAssetLoader(baseDir: nil)
        XCTAssertNil(loader.bytes(forAssetNamed: "pic.png"))
    }

    // MARK: - Measured on the sheet, not recomputed from our own formula

    /// The line grid on paper is the line height the Settings panel asks for.
    ///
    /// `testLeadingIsTheLineHeightLessTheCapHeightOfTheChosenFace` cannot say
    /// this: it builds its expectation with the same `capHeightEm` it is
    /// checking, so a change inside that function moves both sides at once and
    /// stays green. Here the expected answer is `lineHeight × fontSize` — two
    /// numbers a person set — and the measured one comes off the printed sheet.
    func testTheLineGridOnPaperIsTheLineHeightTheSettingsAskFor() async throws {
        let paragraph = String(repeating:
            "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod "
            + "tempor incididunt ut labore et dolore magna aliqua. ", count: 8)

        let settings = PrintSettings()
        let normal = try await PrintPDFRenderer.render(
            Self.request(paragraph, settings: settings))
        let measured = try XCTUnwrap(
            Self.modeLineAdvance(XCTUnwrap(PDFDocument(data: normal.pdf)?.page(at: 0))))
        let expected = Double(settings.lineHeight * settings.fontSize)
        print("line advance at \(settings.fontSize) pt: measured \(measured) pt, "
              + "settings ask \(expected) pt")
        XCTAssertEqual(measured, expected, accuracy: expected * 0.05,
                       "the line grid on paper is not the one in Settings")

        // Twice the type, same line height. Leading travels in em, so a print
        // that never received the size would keep the old grid.
        var large = settings
        large.fontSize = settings.fontSize * 2
        let doubled = try await PrintPDFRenderer.render(
            Self.request(paragraph, settings: large))
        let measuredLarge = try XCTUnwrap(
            Self.modeLineAdvance(XCTUnwrap(PDFDocument(data: doubled.pdf)?.page(at: 0))))
        let expectedLarge = Double(large.lineHeight * large.fontSize)
        print("line advance at \(large.fontSize) pt: measured \(measuredLarge) pt, "
              + "settings ask \(expectedLarge) pt")
        XCTAssertEqual(measuredLarge, expectedLarge, accuracy: expectedLarge * 0.05,
                       "the type size did not reach the renderer")
        XCTAssertEqual(measuredLarge / measured, 2, accuracy: 0.1)
    }

    /// Every value stated at the boundary is one the renderer acted on.
    ///
    /// The oracle is the boundary's own promise: one document printed twice comes
    /// back byte-identical, there being no clock in the pipeline. So a field
    /// whose flip leaves the bytes alone is a field that never arrived — which is
    /// how a page flag with a matching default in the renderer hides a missing
    /// call. The control run comes first: without it this is green for a
    /// renderer that merely produces noise.
    func testFlippingAnyStatedValueChangesTheBytes() async throws {
        let markdown = """
        # Heading

        Body text long enough to wrap across the measure of the page more than
        once, so that justification has something to do with it.

        ## Second heading

        More body text, also long enough to run past the end of a line and wrap.
        """
        let request = Self.request(markdown)
        let base = try await PrintPDFRenderer.render(request)
        let repeated = try await PrintPDFRenderer.render(request)
        XCTAssertEqual(base.pdf, repeated.pdf,
                       "one document printed twice differs; nothing below can mean anything")

        var variants: [(field: String, options: PrintPageOptions)] = []
        func vary(_ field: String, _ change: (inout PrintPageOptions) -> Void) {
            var options = PrintPageOptions.standard
            change(&options)
            variants.append((field, options))
        }
        vary("outline") { $0.outline = true }
        vary("pageNumbers") { $0.pageNumbers = false }
        vary("runningHeader") { $0.runningHeader = true }
        vary("justify") { $0.justify = true }
        vary("pdfUA") { $0.pdfUA = true }
        vary("lang") { $0.lang = "de" }

        for variant in variants {
            let printed = try await PrintPDFRenderer.render(request, options: variant.options)
            XCTAssertNotEqual(
                printed.pdf, base.pdf,
                "flipping \(variant.field) left the PDF byte-identical: it never arrived")
        }
    }

    /// A warning is identified by its kind and its line, not merely counted.
    ///
    /// Without this, swapping the kind and the line while copying a result out is
    /// invisible: every other probe only asks whether warnings exist at all.
    func testAMissingPictureIsReportedByKindAndLine() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        // 1: heading · 2: blank · 3: body · 4: blank · 5: the picture
        let markdown = "# Heading\n\nBody.\n\n![alt](gone.png)\n"
        let result = try await PrintPDFRenderer.render(
            Self.request(markdown, baseDir: root.appendingPathComponent("doc")))

        XCTAssertEqual(result.warnings.count, 1, "\(result.warnings)")
        let warning = try XCTUnwrap(result.warnings.first)
        XCTAssertEqual(warning.rawKind, Self.missingAssetWarning)
        XCTAssertEqual(warning.line, 5, "1-based line of the picture")
        XCTAssertTrue(warning.message.contains("gone.png"), warning.message)
    }

    /// The fallback chain of one family is fixed: sorted by path, each file once.
    ///
    /// Order is what the renderer falls back through, and two prints of one
    /// document have to agree byte for byte — so an order that depends on how the
    /// host felt like enumerating today is a defect even when the page looks the
    /// same.
    func testTheFaceChainOfAFamilyIsSortedAndCarriesEachFileOnce() {
        for family in ["New York", "Times New Roman"] {
            let files = PrintFontLoader.faceFiles(of: family)
            XCTAssertFalse(files.isEmpty, "\(family) resolved to nothing")
            XCTAssertEqual(files, files.sorted { $0.path < $1.path }, family)
            XCTAssertEqual(Set(files).count, files.count, "\(family) repeats a file")
        }
    }

    /// A family named twice — the user's choice equal to the theme's — still
    /// reaches the renderer once.
    ///
    /// The file-level half of this is weaker than it looks, and saying so is
    /// better than leaving it to be discovered: deleting the global URL
    /// deduplication outright leaves it green (measured 25 Aug 2026), because no
    /// two families of the default set share a face file on this system. It
    /// stands for the day one does — a collection named by two families — while
    /// the name-level duplicate above is what actually bites today.
    func testAFamilyNamedTwiceIsHandedOverOnce() {
        XCTAssertEqual(PrintTheme.standard.bodyFamilies.first, "New York",
                       "this fixture needs the user's choice to match the theme's face")
        var settings = PrintSettings()
        settings.fontFamily = "New York"
        let selection = PrintFontLoader.selection(for: settings)

        XCTAssertEqual(selection.files.filter { $0.family == "New York" }.count,
                       PrintFontLoader.faceFiles(of: "New York").count)
        let distinct = Set(settings.fontSet.flatMap { PrintFontLoader.faceFiles(of: $0) })
        XCTAssertEqual(selection.files.count, distinct.count,
                       "a face file reached the renderer more than once")
    }

    /// The pane keeps what the print survived.
    ///
    /// Nothing displays warnings yet, which is exactly why this is asserted: a
    /// warning dropped here cannot be shown by whatever displays them later.
    @MainActor
    func testThePaneKeepsTheWarningsOfItsLastPrint() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = PrintPaneModel()
        await model.render(Self.request("# Heading\n\n![alt](gone.png)\n",
                                        baseDir: root.appendingPathComponent("doc")),
                           debounced: false)
        XCTAssertNotNil(model.document)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.warnings.count, 1, "\(model.warnings)")
    }

    // MARK: - What the renderer was actually handed

    /// The result accounts for every file the renderer asked for, in its order,
    /// and says what went over.
    ///
    /// Two prints whose jobs compare equal can still differ in their pages,
    /// because the pictures beside the two documents differ. Without this record
    /// that difference has no name anywhere, and the next reader of a mismatch
    /// has only the bytes of two PDFs to work from.
    func testTheResultRecordsEveryFileTheRendererAskedFor() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("doc")
        let onDisk = try Data(contentsOf: folder.appendingPathComponent("pic.png"))

        let result = try await PrintPDFRenderer.render(
            Self.request("![here](pic.png)\n\n![gone](missing.png)\n", baseDir: folder))

        XCTAssertEqual(result.assets.map(\.name), ["pic.png", "missing.png"],
                       "document order, as the renderer asked")

        let supplied = try XCTUnwrap(result.assets.first)
        XCTAssertTrue(supplied.supplied)
        XCTAssertEqual(supplied.byteCount, onDisk.count)
        XCTAssertEqual(supplied.digest,
                       SHA256.hash(data: onDisk).map { String(format: "%02x", $0) }.joined())

        let absent = try XCTUnwrap(result.assets.last)
        XCTAssertFalse(absent.supplied)
        XCTAssertEqual(absent.byteCount, 0)
        XCTAssertNil(absent.digest)
    }

    /// A document with no pictures asks for nothing, and says so.
    func testADocumentWithNoPicturesRecordsNoAssets() async throws {
        let result = try await PrintPDFRenderer.render(Self.request("Body.\n"))
        XCTAssertTrue(result.assets.isEmpty)
    }

    /// The picture beside the document decides the digest, so the record can tell
    /// two otherwise identical prints apart.
    func testTheSameJobWithADifferentPictureRecordsADifferentDigest() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let markdown = "![x](pic.png)\n"
        let here = try await PrintPDFRenderer.render(
            Self.request(markdown, baseDir: root.appendingPathComponent("doc")))
        let there = try await PrintPDFRenderer.render(
            Self.request(markdown, baseDir: root.appendingPathComponent("doc-other")))

        // The jobs are equal — same markdown, same settings — and the pages are
        // not. Only the record says why.
        let hereJob = try await PrintPDFRenderer.job(
            for: Self.request(markdown, baseDir: root.appendingPathComponent("doc")))
        let thereJob = try await PrintPDFRenderer.job(
            for: Self.request(markdown, baseDir: root.appendingPathComponent("doc-other")))
        XCTAssertEqual(hereJob, thereJob)
        XCTAssertNotEqual(here.pdf, there.pdf)
        XCTAssertNotEqual(here.assets.first?.digest, there.assets.first?.digest)
        XCTAssertEqual(here.assets.map(\.name), there.assets.map(\.name))
    }

    /// Pictures macOS reads and the renderer does not still print.
    ///
    /// These three went onto the page before the move, drawn by a web view.
    /// HEIC is what the cameras on these machines write by default, so a
    /// document that shows its photographs on screen and prints blank squares
    /// would be an ordinary experience, not an edge case.
    func testFormatsTheRendererCannotReadArePrintedAnyway() async throws {
        let root = try Self.makeTemporaryVault()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("doc")

        for (name, type) in [("shot.heic", UTType.heic),
                             ("scan.tiff", UTType.tiff),
                             ("old.bmp", UTType.bmp)] {
            let encoded = try XCTUnwrap(Self.image(as: type), "cannot write \(name) here")
            try encoded.write(to: folder.appendingPathComponent(name))

            let result = try await PrintPDFRenderer.render(
                Self.request("![alt](\(name))\n", baseDir: folder))
            XCTAssertEqual(result.warnings.filter {
                $0.rawKind == Self.missingAssetWarning
                    || $0.rawKind == Self.unreadableAssetWarning
            }.map(\.message), [], "\(name) did not reach the page")

            let record = try XCTUnwrap(result.assets.first, name)
            XCTAssertTrue(record.supplied, name)
            XCTAssertEqual(record.name, name, "the key must stay the document's own name")
            XCTAssertGreaterThan(record.byteCount, 0, name)
        }
    }

    /// Something that is not a picture at all under a picture's name is not
    /// smuggled through the converter — nothing is handed over and the renderer
    /// reports it, which is the truth from its side.
    func testAFileThatIsNotAPictureIsNotConverted() throws {
        XCTAssertNil(PrintAssetLoader.pngEncoded(Data("not an image".utf8)))
    }

    /// A small picture encoded in one of the formats macOS writes.
    ///
    /// Generated rather than committed: a binary fixture in the repository is a
    /// thing nobody can read in a diff, and the encoder is the same one the
    /// loader decodes with.
    private static func image(as type: UTType) -> Data? {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 64, height: 48,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { return nil }
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// `doc/` with a picture, a nested one, a link out, a decoy directory, an
    /// oversized file, a non-image, and a sibling sharing its name prefix.
    private static func makeTemporaryVault() throws -> URL {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintCoreRenderTests-\(UUID().uuidString)")
        let doc = root.appendingPathComponent("doc")
        for path in ["doc/sub", "doc-other", "doc/folder.png"] {
            try fm.createDirectory(at: root.appendingPathComponent(path),
                                   withIntermediateDirectories: true)
        }
        // 1×1 transparent PNG.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: doc.appendingPathComponent("pic.png"))
        try png.write(to: doc.appendingPathComponent("sub/nested.png"))
        try png.write(to: root.appendingPathComponent("secret.png"))
        // Deliberately *different* bytes under the same name: the sibling folder
        // is what shows that the record, not the job, is what tells two prints
        // of one document apart.
        try (Self.image(as: .png) ?? png)
            .write(to: root.appendingPathComponent("doc-other/pic.png"))
        try Data("# Notes\n".utf8).write(to: doc.appendingPathComponent("notes.md"))
        try Data(count: maxInlineImageBytes + 1).write(to: doc.appendingPathComponent("huge.png"))
        try fm.createSymbolicLink(at: doc.appendingPathComponent("escape.png"),
                                  withDestinationURL: root.appendingPathComponent("secret.png"))
        return root
    }
}
