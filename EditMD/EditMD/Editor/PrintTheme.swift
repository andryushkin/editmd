import Foundation

/// Print-only look, declared as parameters rather than as a stylesheet.
///
/// `PreviewTheme` is a CSS layer because its one consumer is a web view;
/// Print has to describe the same intent to a page renderer that knows nothing
/// about CSS, so a theme here is plain values and each render path translates
/// them itself. Keeping the two types apart is also what protects the Preview
/// settings migration, which is keyed on `PreviewTheme` ids.
///
/// Compiled-in declarations only, matching the plugin model; the selected id
/// persists in `PrintSettings.theme`.
struct PrintTheme: Equatable {
    let id: String
    let title: String
    /// Body families in preference order. Empty = the system serif stack.
    /// A family the user picked in Settings wins over all of these.
    let bodyFamilies: [String]
    /// Heading families; empty = headings inherit the body stack.
    let headingFamilies: [String]
    /// Monospaced families for code blocks and inline code.
    let monoFamilies: [String]
    /// Reference geometry, written into real print settings once at selection
    /// (`EditorSettings.migratedPrintGeometry`) exactly like Preview's themes —
    /// render paths always read plain settings, never the theme.
    let preferredFontSize: CGFloat?
    let preferredLineHeight: CGFloat?
    let preferredMargins: PrintMargins?

    init(id: String, title: String,
         bodyFamilies: [String] = [],
         headingFamilies: [String] = [],
         monoFamilies: [String] = ["SF Mono", "Menlo"],
         preferredFontSize: CGFloat? = nil,
         preferredLineHeight: CGFloat? = nil,
         preferredMargins: PrintMargins? = nil) {
        self.id = id
        self.title = title
        self.bodyFamilies = bodyFamilies
        self.headingFamilies = headingFamilies
        self.monoFamilies = monoFamilies
        self.preferredFontSize = preferredFontSize
        self.preferredLineHeight = preferredLineHeight
        self.preferredMargins = preferredMargins
    }

    /// Body families for a render, honoring an explicit user choice.
    ///
    /// The chosen face goes in front of the theme's stack rather than replacing
    /// it. That is what a font stack is for, and here it is load-bearing: a
    /// family the machine no longer has resolves to no file at all, and with the
    /// theme's faces gone from the list too there is nothing left for the page
    /// but the monospaced face further down. The user's choice still wins
    /// wherever it exists — it is first — and the theme stands behind it.
    func resolvedBodyFamilies(userFamily: String) -> [String] {
        Self.stack(userFamily, over: bodyFamilies)
    }

    /// Heading families. An explicit user family wins here too — a chosen face
    /// that applied to the text but not the headings would read as a bug — and
    /// otherwise a theme without its own heading stack inherits the body one.
    func resolvedHeadingFamilies(userFamily: String) -> [String] {
        Self.stack(userFamily, over: headingFamilies.isEmpty ? bodyFamilies : headingFamilies)
    }

    /// A chosen family in front of a stack, named once.
    private static func stack(_ userFamily: String, over families: [String]) -> [String] {
        let chosen = userFamily.trimmingCharacters(in: .whitespaces)
        guard !chosen.isEmpty else { return families }
        return [chosen] + families.filter { $0 != chosen }
    }
}

// MARK: - Built-in catalog

extension PrintTheme {

    /// Paper defaults: a serif text face at a size that survives being read on
    /// paper rather than on a screen.
    static let standard = PrintTheme(
        id: "default",
        title: String(localized: "Default"),
        bodyFamilies: ["New York", "Times New Roman"],
        preferredFontSize: 11,
        preferredLineHeight: 1.45,
        preferredMargins: PrintMargins(uniform: 56)
    )

    /// Screen-sans on paper: for documents that will mostly be read as a file.
    static let sans = PrintTheme(
        id: "sans",
        title: String(localized: "Sans"),
        bodyFamilies: ["SF Pro Text", "Helvetica Neue"],
        preferredFontSize: 10.5,
        preferredLineHeight: 1.5,
        preferredMargins: PrintMargins(uniform: 56)
    )

    /// Book-like measure: bigger margins, looser leading, fewer characters per
    /// line than the page could physically hold.
    static let book = PrintTheme(
        id: "book",
        title: String(localized: "Book"),
        bodyFamilies: ["New York", "Iowan Old Style", "Georgia"],
        preferredFontSize: 11.5,
        preferredLineHeight: 1.6,
        preferredMargins: PrintMargins(top: 72, bottom: 84, leading: 90, trailing: 90)
    )

    /// Dense technical output: small type, narrow margins, a sans text face that
    /// stays legible small.
    ///
    /// `headingFamilies` is a display cut of the same face and reaches the
    /// screen modes only: the page renderer takes a body family and a mono
    /// family and has no setter for headings, so on paper this theme sets its
    /// headings in the text face.
    static let compact = PrintTheme(
        id: "compact",
        title: String(localized: "Compact"),
        bodyFamilies: ["SF Pro Text", "Helvetica Neue"],
        headingFamilies: ["SF Pro Display", "Helvetica Neue"],
        preferredFontSize: 9.5,
        preferredLineHeight: 1.35,
        preferredMargins: PrintMargins(uniform: 40)
    )

    static let allPresets: [PrintTheme] = [standard, sans, book, compact]

    /// Unknown or empty ids resolve to the default rather than trapping — old
    /// prefs and hand-edited frontmatter both reach this.
    static func preset(named id: String) -> PrintTheme {
        allPresets.first { $0.id == id } ?? .standard
    }
}
