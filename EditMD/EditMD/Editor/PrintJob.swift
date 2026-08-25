import Foundation

// MARK: - Fonts on the wire

/// One font file on its way to the page renderer: the family it belongs to and
/// its bytes.
///
/// The file's path is deliberately absent. What decides the printed page is the
/// family and the bytes, and the same face lives at a different path depending
/// on who looked it up — so a path here would make two jobs that print
/// identically compare unequal. The path stays with the loader, for diagnosis.
struct PrintFontFile: Equatable, Sendable {
    var family: String
    var bytes: Data
}

// MARK: - Page geometry on the wire

/// Page margins in millimetres, named in the order the renderer takes them.
///
/// The app describes a page as top/bottom/leading/trailing in points; the
/// renderer takes top/right/bottom/left in millimetres. Both halves of that
/// translation are silent when wrong — swapped sides look like a page with
/// unequal margins, unconverted points look like a wider page — so the order is
/// spelled out in the type rather than left to the argument list of one call.
struct PrintMarginsMM: Equatable, Sendable {
    var top: Double
    var right: Double
    var bottom: Double
    var left: Double
}

// MARK: - Values chosen at the boundary

/// Page-level choices the Print pane has no control for.
///
/// A value with a production default rather than constants buried in the
/// boundary: a probe changes one field and calls the *same* function the pane
/// calls, so nothing has to grow a test-only path, and a defect planted in the
/// render is a defect every probe walks through.
struct PrintPageOptions: Equatable, Sendable {
    /// BCP-47 tag written into the PDF's `/Lang`.
    var lang: String
    /// Ask the renderer to enforce PDF/UA-1.
    var pdfUA: Bool
    /// Print a table of contents *page*. Not the PDF bookmarks, which are
    /// written either way.
    var outline: Bool
    var pageNumbers: Bool
    var runningHeader: Bool
    var justify: Bool
    /// nil lets the renderer take the frontmatter `title:`, then the first H1.
    var title: String?

    /// What the Print pane prints with.
    ///
    /// `outline` is off because it adds a contents *page* to the document —
    /// measured 25 Aug 2026, a three-line document becomes two pages — while the
    /// pane's own table of contents comes from the PDF bookmarks, which are
    /// written whether this is on or off. `runningHeader` is off because a
    /// header changes the look of the page more than anything else here.
    /// `justify` is off because the pane has never justified. `pageNumbers` is
    /// on because this is paper.
    static let standard = PrintPageOptions(
        lang: PrintJob.defaultLanguage,
        pdfUA: false,
        outline: false,
        pageNumbers: true,
        runningHeader: false,
        justify: false,
        title: nil)
}

// MARK: - The job

/// Everything one print consists of, as a value.
///
/// There is a field for every setter the boundary makes, and the boundary makes
/// every one of them on every print — a default inside the renderer is never
/// left to stand in. Two reasons, and neither is tidiness: a default that moves
/// in the renderer would move the printed page here without a diff, and a job
/// built by this app has to be comparable field by field with the job the
/// command line builds from the same document. That comparison is what tells
/// "the app prints differently" from "the renderer prints differently", and it
/// only works if both sides say everything out loud.
///
/// Assets are not here and cannot be: their names are known only after the
/// markdown has been parsed, i.e. after the document handle exists, and the
/// boundary requires them to be set on that same handle.
struct PrintJob: Equatable, Sendable {
    var markdown: String
    /// nil = the renderer takes the frontmatter title, then the first H1.
    var title: String?
    /// Paper name as the renderer spells it: `a4`, `a5`, `us-letter`,
    /// `us-legal`. Bare `letter` and `legal` are refused by it.
    var paper: String
    /// Landscape, in the renderer's own word for it: the sheet keeps its size
    /// and swaps width for height.
    var flipped: Bool
    var marginsMM: PrintMarginsMM
    var fontSizePt: Double
    /// Extra space between lines, in em — see `PrintJob.leadingEm(for:capHeightEm:)`.
    var leadingEm: Double
    var justify: Bool
    /// nil = not named at all, which is not the same as naming a family the
    /// renderer has no bytes for.
    var bodyFont: String?
    var monoFont: String?
    var lang: String
    var outline: Bool
    var runningHeader: Bool
    var pageNumbers: Bool
    var pdfUA: Bool
    /// Fallback chain, in order — see `PrintFontLoader`.
    var fonts: [PrintFontFile]
    /// Wiki-link target → destination. Empty here until the vault index is
    /// wired in; the field is written out rather than assumed so that an empty
    /// table is a stated fact and not a missing call.
    var links: [String: String]

    /// The language every print declares while nothing chooses one.
    ///
    /// Named rather than left out: the renderer writes `/Lang(en)` on its own
    /// when nobody says otherwise, so an omitted call is invisible in the
    /// output. A constant that has to be moved on purpose is the difference
    /// between a decision and an accident.
    static let defaultLanguage = "en"
}

// MARK: - Building one from print intent

extension PrintJob {

    /// Millimetres per PostScript point.
    static let mmPerPoint = 25.4 / 72.0

    /// The renderer's name for a paper size.
    static func paperName(_ paper: PrintPaperSize) -> String {
        switch paper {
        case .a4:     return "a4"
        case .a5:     return "a5"
        case .letter: return "us-letter"
        case .legal:  return "us-legal"
        }
    }

    /// The renderer's `leading` for a line height the app expresses as a
    /// multiple of the font size.
    ///
    /// The two are not the same quantity. Measured 25 Aug 2026 against the
    /// renderer: baseline-to-baseline distance comes out as `leading` plus the
    /// **cap height** of the body face, not as `leading` alone — so a CSS-style
    /// 1.45× handed over unchanged prints roughly two thirds of a line too
    /// loose. Subtracting the cap height of the face that will actually be used
    /// (not of the first family that was asked for) puts the baselines where the
    /// app's other three modes put them, within 0.6 %.
    static func leadingEm(for lineHeight: CGFloat, capHeightEm: Double) -> Double {
        max(0, Double(lineHeight) - capHeightEm)
    }

    /// The job a request and a set of boundary choices come to, given what the
    /// host's fonts answered.
    ///
    /// Pure: the fonts have already been looked up, so this can be printed and
    /// compared in a test without a renderer anywhere near it.
    init(request: PrintRenderRequest, options: PrintPageOptions, fonts: PrintFontSelection) {
        let settings = request.settings
        let margins = settings.margins
        self.init(
            markdown: request.markdown,
            title: options.title,
            paper: Self.paperName(settings.paper),
            flipped: settings.orientation == .landscape,
            // leading/trailing are the app's words for the left and right edge
            // of the sheet; there is no bound-edge logic anywhere above this.
            marginsMM: PrintMarginsMM(
                top: Double(margins.top) * Self.mmPerPoint,
                right: Double(margins.trailing) * Self.mmPerPoint,
                bottom: Double(margins.bottom) * Self.mmPerPoint,
                left: Double(margins.leading) * Self.mmPerPoint),
            fontSizePt: Double(settings.fontSize),
            leadingEm: Self.leadingEm(for: settings.lineHeight,
                                      capHeightEm: fonts.bodyCapHeightEm),
            justify: options.justify,
            bodyFont: fonts.bodyFont,
            monoFont: fonts.monoFont,
            lang: options.lang,
            outline: options.outline,
            runningHeader: options.runningHeader,
            pageNumbers: options.pageNumbers,
            pdfUA: options.pdfUA,
            fonts: fonts.files,
            links: [:])
    }
}
