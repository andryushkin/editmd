import Foundation
import CoreGraphics

// MARK: - Page geometry

/// Page margins in PostScript points (72 per inch) — the unit the app measures
/// a page in everywhere else. The page renderer takes millimetres and names the
/// four sides in a different order, so both are converted in one place on the
/// way out (`PrintJob`).
struct PrintMargins: Codable, Equatable, Sendable {
    var top: CGFloat
    var bottom: CGFloat
    var leading: CGFloat
    var trailing: CGFloat

    init(top: CGFloat, bottom: CGFloat, leading: CGFloat, trailing: CGFloat) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    init(uniform: CGFloat) {
        self.init(top: uniform, bottom: uniform, leading: uniform, trailing: uniform)
    }

    static let range: ClosedRange<CGFloat> = 0...216   // 0 … 3 inches
}

/// Named paper sizes, portrait, in points.
enum PrintPaperSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4
    case a5
    case letter
    case legal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4:     return "A4"
        case .a5:     return "A5"
        case .letter: return String(localized: "US Letter")
        case .legal:  return String(localized: "US Legal")
        }
    }

    var size: CGSize {
        switch self {
        case .a4:     return CGSize(width: 595, height: 842)
        case .a5:     return CGSize(width: 420, height: 595)
        case .letter: return CGSize(width: 612, height: 792)
        case .legal:  return CGSize(width: 612, height: 1008)
        }
    }
}

enum PrintOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait
    case landscape

    var id: String { rawValue }

    var title: String {
        switch self {
        case .portrait:  return String(localized: "Portrait")
        case .landscape: return String(localized: "Landscape")
        }
    }
}

/// Why a page could not be laid out. Checked before anything is handed to a
/// renderer: measured 4 Aug 2026, a non-finite margin becomes an infinite text
/// frame deep inside layout and takes the process with it, so this must be a
/// value returned to the caller and never a trap.
enum PrintGeometryProblem: Error, Equatable, Sendable {
    case nonFinite
    case pageTooSmall
    case marginsExceedPage

    var message: String {
        switch self {
        case .nonFinite:
            return String(localized: "Page size and margins must be finite numbers.")
        case .pageTooSmall:
            return String(localized: "The page is too small to lay out text.")
        case .marginsExceedPage:
            return String(localized: "The margins leave no room for text on the page.")
        }
    }
}

/// A validated page: size, margins and the text frame they leave. Only
/// `PrintPageGeometry.resolve` makes one, so a geometry that exists is a
/// geometry that lays out.
struct PrintPageGeometry: Equatable, Sendable {
    let pageSize: CGSize
    let margins: PrintMargins
    let textFrame: CGSize

    /// Smallest text frame worth laying out — below this a line of body text
    /// cannot fit a single word at the smallest allowed size.
    static let minimumTextFrame = CGSize(width: 72, height: 72)

    static func resolve(paper: PrintPaperSize,
                        orientation: PrintOrientation,
                        margins: PrintMargins) -> Result<PrintPageGeometry, PrintGeometryProblem> {
        let portrait = paper.size
        let pageSize = orientation == .portrait
            ? portrait
            : CGSize(width: portrait.height, height: portrait.width)

        let values = [pageSize.width, pageSize.height,
                      margins.top, margins.bottom, margins.leading, margins.trailing]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return .failure(.nonFinite) }
        guard pageSize.width >= minimumTextFrame.width,
              pageSize.height >= minimumTextFrame.height else { return .failure(.pageTooSmall) }

        let textFrame = CGSize(width: pageSize.width - margins.leading - margins.trailing,
                               height: pageSize.height - margins.top - margins.bottom)
        guard textFrame.width >= minimumTextFrame.width,
              textFrame.height >= minimumTextFrame.height else { return .failure(.marginsExceedPage) }

        return .success(PrintPageGeometry(pageSize: pageSize, margins: margins, textFrame: textFrame))
    }
}

// MARK: - Font set

/// Families the print font set always carries, whatever the theme or the
/// user's choice.
///
/// Measured 4 Aug 2026: a glyph with no font behind it is an *export error* on
/// a tagged, accessible PDF, not a warning — the document does not print at
/// all. A page of prose with one emoji in it renders fine in Preview, where the
/// web view silently substitutes, and then fails to print. So coverage is part
/// of the call contract rather than a preference: it cannot be switched off in
/// Settings and it cannot be dropped by a theme.
let printCoverageFontFamilies = ["Apple Color Emoji", "Apple Symbols"]

/// The complete family list handed to the page renderer, in fallback order:
/// the user's or theme's text faces first, monospace for code, then coverage.
/// Duplicates are removed keeping the first (highest-priority) position.
///
/// The order is the fallback chain the renderer walks, so it is part of what a
/// print *is* — `PrintFontLoader` hands the files over in exactly this order.
func printFontSet(bodyFamilies: [String],
                  headingFamilies: [String],
                  monoFamilies: [String]) -> [String] {
    var seen = Set<String>()
    var out: [String] = []
    for family in bodyFamilies + headingFamilies + monoFamilies + printCoverageFontFamilies {
        let name = family.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, seen.insert(name).inserted else { continue }
        out.append(name)
    }
    return out
}

// MARK: - Settings

/// Print-mode knobs. Deliberately not `ModeSettings`: the other three modes
/// describe a scrolling canvas (insets, an optional reading column), Print
/// describes paper. The overlap is only the base font.
struct PrintSettings: Codable, Equatable, Sendable {
    var paper: PrintPaperSize
    var orientation: PrintOrientation
    var margins: PrintMargins
    var fontSize: CGFloat
    /// Empty = the theme's stack.
    var fontFamily: String
    var lineHeight: CGFloat
    /// `PrintTheme` id.
    var theme: String

    init(paper: PrintPaperSize = .a4,
         orientation: PrintOrientation = .portrait,
         margins: PrintMargins = PrintMargins(uniform: 56),
         fontSize: CGFloat = 11,
         fontFamily: String = "",
         lineHeight: CGFloat = 1.45,
         theme: String = PrintTheme.standard.id) {
        self.paper = paper
        self.orientation = orientation
        self.margins = margins
        self.fontSize = fontSize
        self.fontFamily = fontFamily
        self.lineHeight = lineHeight
        self.theme = theme
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PrintSettings()
        paper = try c.decodeIfPresent(PrintPaperSize.self, forKey: .paper) ?? defaults.paper
        orientation = try c.decodeIfPresent(PrintOrientation.self, forKey: .orientation)
            ?? defaults.orientation
        margins = try c.decodeIfPresent(PrintMargins.self, forKey: .margins) ?? defaults.margins
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? defaults.fontSize
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? defaults.fontFamily
        lineHeight = try c.decodeIfPresent(CGFloat.self, forKey: .lineHeight) ?? defaults.lineHeight
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? defaults.theme
    }

    static let fontSizeRange: ClosedRange<CGFloat> = 7...24
    static let lineHeightRange: ClosedRange<CGFloat> = 1.0...2.2

    var resolvedTheme: PrintTheme { PrintTheme.preset(named: theme) }

    /// Validated geometry, or the reason there isn't one.
    var geometry: Result<PrintPageGeometry, PrintGeometryProblem> {
        PrintPageGeometry.resolve(paper: paper, orientation: orientation, margins: margins)
    }

    /// Font set for this document's render — see `printFontSet`.
    var fontSet: [String] {
        let theme = resolvedTheme
        return printFontSet(bodyFamilies: theme.resolvedBodyFamilies(userFamily: fontFamily),
                            headingFamilies: theme.resolvedHeadingFamilies(userFamily: fontFamily),
                            monoFamilies: theme.monoFamilies)
    }
}
