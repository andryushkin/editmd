import Foundation

/// What one print is worth telling a human about.
///
/// Two kinds of entry, arriving from opposite directions. A **warning** is what
/// the page renderer survived: it is produced by the print itself and this app
/// only carries it across. A **note** is the other way round — something this
/// app knows and the renderer cannot, namely that a construct handed over
/// prints differently from the way the editor's other modes draw it.
///
/// Neither is an error, and that is the point of gathering them in one place:
/// a print that succeeded can still have quietly dropped a picture or flattened
/// a state, and until now the pane had nowhere to say so.
struct PrintReport: Equatable, Sendable {
    /// In the order the renderer produced them.
    var warnings: [PrintWarning]
    /// At most one entry per kind, each carrying how many tokens it is true of.
    var tokenNotes: [PrintTokenNote]

    static let empty = PrintReport(warnings: [], tokenNotes: [])

    var isEmpty: Bool { warnings.isEmpty && tokenNotes.isEmpty }

    /// Entries a reader would count, warnings and notes together.
    var count: Int { warnings.count + tokenNotes.count }
}

// MARK: - Plugin tokens on paper

/// A built-in plugin token whose printed form is not the form the editor draws.
///
/// Paper carries the markdown and nothing but the markdown: the marker's own
/// text, plus the checkbox glyph GFM gives `[ ]` and `[x]` at the head of a list
/// item. The icon, the label and the strikethrough a document declares in its
/// frontmatter live in the editor and reach the renderer nowhere — putting them
/// on paper would mean rewriting the markdown before printing it, after which
/// the app and the command line would be printing two different documents.
///
/// So the divergence is stated rather than removed. Without this it is silent:
/// a document that declares `[x]` to mean "cancelled" prints a ticked box, and
/// nothing anywhere says why.
struct PrintTokenNote: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        /// `[ ]`, `[x]` or `[X]` at the head of a list item. The renderer reads
        /// GFM's task list and prints ☐ or ☑ — the two states GFM has, not the
        /// state this document declares for that marker.
        case printedAsCheckbox
        /// The declared state strikes its line through in the editor; the
        /// markdown does not say so, so paper prints it plain.
        case strikethroughNotPrinted
    }

    var kind: Kind
    /// How many of the document's tokens this is true of.
    var count: Int

    var id: Kind { kind }

    var title: String {
        switch kind {
        case .printedAsCheckbox:
            String(localized: "Printed as a checkbox")
        case .strikethroughNotPrinted:
            String(localized: "Strikethrough is not printed")
        }
    }

    var detail: String {
        switch kind {
        case .printedAsCheckbox:
            String(localized: """
                At the head of a list item the renderer prints ☐ and ☑ for [ ] and [x], \
                not the state this document declares.
                """)
        case .strikethroughNotPrinted:
            String(localized: """
                A state that strikes its line through in the editor prints plain: \
                the markdown carries no strikethrough.
                """)
        }
    }
}

extension PrintReport {

    /// GFM's task-list markers, which are the only ones the renderer turns into
    /// a box. Measured 26 Aug 2026 against the renderer: `[~]` and `[>]` at the
    /// head of a list item print as their own text.
    static let checkboxMarkers: Set<String> = ["[ ]", "[x]", "[X]"]

    /// Whether the renderer will read this token as a task rather than as text.
    ///
    /// Being at the head of a list item is not enough, and the difference is
    /// measured rather than read off the grammar: `- [x]glued` prints as its own
    /// text, `- [x] spaced` and a `- [x]` alone on its line print as a box. The
    /// editor calls all three list markers, because for its own purposes they
    /// are — so this is the one place where counting the editor's tokens would
    /// tell the reader about a box that is not on the page.
    ///
    /// The unit after the marker is read as UTF-16, and a unit that is not a
    /// scalar is half of a character outside the BMP — `- [x]😀item` is the
    /// case. Half a surrogate pair is not whitespace and the renderer prints
    /// that marker as text, so it is answered `false`: reading it as a space
    /// because no scalar could be made is how this told the reader about a box
    /// that is not on the page.
    static func printsAsCheckbox(_ token: BuiltInPluginToken, in markdown: NSString) -> Bool {
        guard token.isListMarker, checkboxMarkers.contains(token.payload.state.source)
        else { return false }
        let after = NSMaxRange(token.range)
        guard after < markdown.length else { return true }
        guard let next = UnicodeScalar(markdown.character(at: after)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(next)
    }

    /// The notes for a document, taken from the plugin tokens it carries.
    ///
    /// Pure, and it re-scans the markdown rather than accepting the editor's
    /// snapshot: a print answers for the text that was printed, and the pane's
    /// snapshot belongs to whatever was last drawn on screen. A document that
    /// declares no plugin costs a frontmatter check and no parse.
    static func tokenNotes(in markdown: String) -> [PrintTokenNote] {
        let tokens = BuiltInPluginRegistry.snapshot(for: markdown).tokens
        guard !tokens.isEmpty else { return [] }

        let ns = markdown as NSString
        let boxes = tokens.filter { printsAsCheckbox($0, in: ns) }
        let struck = tokens.filter(\.payload.state.strikethrough)

        var notes: [PrintTokenNote] = []
        if !boxes.isEmpty {
            notes.append(PrintTokenNote(kind: .printedAsCheckbox, count: boxes.count))
        }
        if !struck.isEmpty {
            notes.append(PrintTokenNote(kind: .strikethroughNotPrinted, count: struck.count))
        }
        return notes
    }
}

// MARK: - Naming a warning

extension PrintWarning {

    /// The kind, named for a human.
    ///
    /// A `switch` over the frozen numbers with a default, rather than an enum:
    /// the boundary's own rule is that a kind the caller does not know is shown
    /// as unknown and never dropped, because a warning nobody displays is a
    /// warning nobody acts on. An exhaustive Swift type cannot hold one.
    ///
    /// The numbers are `printdotmd.h`'s and are frozen there; they are repeated
    /// here as literals because the header's `#define`s do not reach Swift as
    /// constants, and a name invented for one of them would be a second source
    /// of truth about which number means what.
    var kindTitle: String {
        switch rawKind {
        case 1:  String(localized: "Picture not supplied")
        case 2:  String(localized: "Picture in a format the renderer cannot read")
        case 3:  String(localized: "Link to a heading this document does not have")
        case 4:  String(localized: "Wiki-link target not resolved")
        case 5:  String(localized: "Raw HTML dropped")
        case 6:  String(localized: "Formula printed as written")
        case 7:  String(localized: "Picture with no alternative description")
        case 8:  String(localized: "Nesting too deep; printed flattened")
        case 9:  String(localized: "Heading printed as emphasised text")
        case 10: String(localized: "Document language narrowed")
        case 11: String(localized: "Link destination too long; printed as text")
        case 12: String(localized: "Repeated on the page")
        case 13: String(localized: "Message from the typesetter")
        case 14: String(localized: "Link scheme refused; printed as text")
        default: String(localized: "Warning this build does not recognise")
        }
    }

    /// True when `kindTitle` is the name of a kind and not the fallback.
    ///
    /// Kept as its own question rather than compared against the fallback
    /// string: the comparison would go false the day the fallback is
    /// translated, and silently.
    var isRecognisedKind: Bool { (1...14).contains(rawKind) }
}
