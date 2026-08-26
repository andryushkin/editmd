import XCTest
import PDFKit
@testable import EditMD

/// What a built-in plugin token comes out as on paper, and what the print
/// report says about it.
///
/// The subject is deliberately the **printed page** and not the job. A token
/// becomes nodes inside the renderer, whose vocabulary this app cannot see, so
/// a probe reading what was sent proves nothing about what was drawn — measured
/// on this project twice over: an oracle reading the declaration is blind to a
/// call that was removed, and an oracle reading the bytes is blind to a wrong
/// declaration that reached both sides. Neither covers the other, which is why
/// both kinds appear below and are named as such.
///
/// The instrument is the page's text, not the file's bytes: the pages are
/// compressed streams, and a marker that is plainly on paper is not findable by
/// searching the file for it. Bytes are used for exactly one question — whether
/// an image was embedded — because an image dictionary is not compressed, and
/// that use is controlled by a document that does carry a picture.
final class PrintPluginTokenTests: XCTestCase {

    // MARK: - Fixtures

    /// Four declared states, tokens in prose and at the head of list items, an
    /// undeclared marker and an escaped one.
    ///
    /// Two of the four states declare strikethrough and two declare an icon
    /// that is not their marker — that is what makes the difference between the
    /// screen and the paper observable at all.
    private static let markdown = """
        ---
        title: The Token Note
        editmd:
          plugins:
            multi-checkbox:
              states:
                - marker: " "
                  label: To do
                  icon: "sf:square"
                - marker: "x"
                  label: Done
                  icon: "sf:checkmark.square"
                  strikethrough: true
                - marker: "~"
                  label: Dropped
                  icon: "emoji:🗑"
                  strikethrough: true
                - marker: ">"
                  label: Deferred
                  icon: "sf:arrow.right"
        ---

        # The Token Note

        A plugin token in prose: status [x] here, and a dropped one [~] there.

        - [ ] A list item in the first state
        - [x] A list item that is done
        - [~] A list item that was dropped
        - [>] A list item deferred

        Marker that no state declares: [?] stays literal.

        Ordinary prose after the tokens.
        """

    private static func request(_ markdown: String) -> PrintRenderRequest {
        PrintRenderRequest(markdown: markdown, baseDir: nil,
                           settings: PrintSettings(), syntaxHighlighting: false)
    }

    private func text(of pdf: Data) throws -> String {
        let document = try XCTUnwrap(PDFDocument(data: pdf), "the pages do not open")
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    // MARK: - What a token comes out as

    /// The two outcomes R-08 has to tell apart, plus the ones that mean the
    /// probe itself is looking at the wrong page.
    ///
    /// `emptySpace` is not a shade of `other`: "the token printed as something
    /// else" and "the token did not print at all" are the two answers the
    /// requirement names, and a probe that reports "did not match" for both is
    /// the probe this one exists instead of.
    enum PrintedForm: Equatable, CustomStringConvertible {
        /// The marker's own text, as the markdown spells it.
        case marker(String)
        /// GFM's box: the renderer read the item as a task.
        case checkbox(String)
        /// The line is on paper and the token is not.
        case emptySpace
        /// Something else entirely stands where the token was.
        case other(String)
        /// The line itself never reached the page — nothing is being measured.
        case lineMissing

        var description: String {
            switch self {
            case .marker(let text):   "the marker itself (\(text))"
            case .checkbox(let box):  "a checkbox glyph (\(box))"
            case .emptySpace:         "empty space — the token did not print"
            case .other(let text):    "something else: \(text.debugDescription)"
            case .lineMissing:        "the line is not on the page at all"
            }
        }
    }

    /// What stands before `tail` on the page — the token's printed form.
    ///
    /// The list bullet is dropped first: the renderer keeps it for a list whose
    /// items are not all tasks, and it belongs to the list rather than to the
    /// token.
    private func printedForm(before tail: String, in text: String) -> PrintedForm {
        guard let line = text.split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.contains(tail) }) else { return .lineMissing }
        let prefix = String(line[line.startIndex..<(line.range(of: tail)?.lowerBound
                                                    ?? line.endIndex)])
        let stripped = prefix
            .replacingOccurrences(of: "•", with: "")
            .trimmingCharacters(in: .whitespaces)
        if stripped.isEmpty { return .emptySpace }
        if stripped == "☐" || stripped == "☑" { return .checkbox(stripped) }
        if stripped.hasPrefix("["), stripped.hasSuffix("]") { return .marker(stripped) }
        return .other(stripped)
    }

    /// Every declared state reaches paper as a declarative form of its own: the
    /// marker's own text, and GFM's box where the markdown gives GFM one.
    func testEveryDeclaredStateReachesPaperAsADeclarativeForm() async throws {
        let result = try await PrintPDFRenderer.render(Self.request(Self.markdown))
        let page = try text(of: result.pdf)

        let expected: [(tail: String, form: PrintedForm)] = [
            ("A list item in the first state", .checkbox("☐")),
            ("A list item that is done",       .checkbox("☑")),
            ("A list item that was dropped",   .marker("[~]")),
            ("A list item deferred",           .marker("[>]")),
        ]
        for (tail, form) in expected {
            XCTAssertEqual(printedForm(before: tail, in: page), form,
                           "\(tail): \(printedForm(before: tail, in: page))")
        }

        // In prose there is no list item to be a task of, so every state is its
        // own text — including the two that become boxes above.
        XCTAssertTrue(page.contains("status [x] here"), page)
        XCTAssertTrue(page.contains("dropped one [~] there"), page)
        // An undeclared marker is not a token and prints as what it is.
        XCTAssertTrue(page.contains("[?] stays literal"), page)
    }

    /// No interactive form reaches paper — in the text or as an image.
    ///
    /// The image half is asserted against the bytes and controlled by a
    /// document that does embed one: without that control this assertion is
    /// also true of a probe looking for a string the format never writes.
    func testNoInteractiveFormReachesPaper() async throws {
        let result = try await PrintPDFRenderer.render(Self.request(Self.markdown))
        let page = try text(of: result.pdf)

        for needle in ["button", "multi-checkbox", "Change status", "Current status",
                       "aria-label", "data-plugin-offset"] {
            XCTAssertFalse(page.contains(needle), "\(needle) is on paper:\n\(page)")
        }

        let image = Data("/Subtype/Image".utf8)
        XCTAssertNil(result.pdf.range(of: image),
                     "an image was embedded where a plugin token is drawn")

        // The control: the same instrument on a document that has a picture.
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintPluginTokenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let png = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        try png.write(to: root.appendingPathComponent("pic.png"))
        var withPicture = Self.request("![alt](pic.png)\n")
        withPicture.baseDir = root
        let control = try await PrintPDFRenderer.render(withPicture)
        XCTAssertNotNil(control.pdf.range(of: image),
                        "the instrument cannot see an embedded image at all")
    }

    /// The app hands the document over unchanged: nothing turns a token into
    /// something else on the way out.
    ///
    /// This is the job-side probe, and it catches what the page-side one cannot:
    /// a substitution that produced a page which happens to look right. It does
    /// not catch a renderer that draws the markdown differently, which is what
    /// the page-side probe is for.
    func testThePrintedDocumentIsTheDocumentItself() async throws {
        let job = try await PrintPDFRenderer.job(for: Self.request(Self.markdown))
        XCTAssertEqual(job.markdown, Self.markdown,
                       "the markdown was rewritten on its way to the renderer")
    }

    /// The control the others are read against: one input, printed twice, is one
    /// file. Without it "the page changed" says nothing about what changed it.
    func testTheSameDocumentPrintsTheSameBytesTwice() async throws {
        let first = try await PrintPDFRenderer.render(Self.request(Self.markdown))
        let second = try await PrintPDFRenderer.render(Self.request(Self.markdown))
        XCTAssertEqual(first.pdf, second.pdf, "printing is not reproducible")
    }

    // MARK: - The print report

    /// The report says which tokens print differently from the way the editor
    /// draws them, and how many of each.
    func testTheReportCountsTheTokensThatPrintDifferently() throws {
        let notes = PrintReport.tokenNotes(in: Self.markdown)

        let boxes = try XCTUnwrap(notes.first { $0.kind == .printedAsCheckbox }, "\(notes)")
        XCTAssertEqual(boxes.count, 2, "the two list items GFM reads as tasks")
        let struck = try XCTUnwrap(notes.first { $0.kind == .strikethroughNotPrinted },
                                   "\(notes)")
        XCTAssertEqual(struck.count, 4, "two states declare it, each written twice")

        XCTAssertFalse(notes.contains { $0.title.isEmpty || $0.detail.isEmpty })
    }

    /// A marker glued to the text of its item is not a task to the renderer,
    /// and the note must not count it as one.
    ///
    /// Measured against the renderer: `- [x]glued` prints as its own text and
    /// `- [x] spaced` prints as a box. The editor calls both list markers,
    /// because to the editor they are — this is the one place the two readings
    /// differ, and a note that counted both would be telling the reader about a
    /// box that is not on the page.
    func testAMarkerGluedToItsTextIsNotCountedAsACheckbox() throws {
        let markdown = """
            ---
            editmd:
              plugins:
                multi-checkbox:
                  states:
                    - marker: "x"
                      label: Done
                      icon: "sf:checkmark.square"
            ---

            - [x]glued item
            - [x] spaced item
            """
        let notes = PrintReport.tokenNotes(in: markdown)
        let boxes = try XCTUnwrap(notes.first { $0.kind == .printedAsCheckbox }, "\(notes)")
        XCTAssertEqual(boxes.count, 1, "only the spaced one becomes a box on paper")
    }

    /// A document that declares no plugin has nothing to say.
    func testADocumentWithoutThePluginHasNoNotes() {
        XCTAssertEqual(PrintReport.tokenNotes(in: "# Heading\n\n- [x] a task\n"), [])
    }

    /// A warning is named by its kind and placed by its line, and the two are
    /// different fields of the report.
    ///
    /// The kind and the line swapped is the defect this exists for: counted
    /// warnings look identical either way.
    func testTheReportNamesAWarningByKindAndPlacesItByLine() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintPluginTokenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // 1: heading · 2: blank · 3: body · 4: blank · 5: the picture
        var request = Self.request("# Heading\n\nBody.\n\n![alt](gone.png)\n")
        request.baseDir = root
        let result = try await PrintPDFRenderer.render(request)
        let report = PrintReport(warnings: result.warnings, tokenNotes: [])

        XCTAssertEqual(report.count, 1, "\(report)")
        let warning = try XCTUnwrap(report.warnings.first)
        XCTAssertEqual(warning.line, 5, "1-based line of the picture")
        XCTAssertEqual(warning.rawKind, 1, "the missing-asset kind")
        XCTAssertTrue(warning.isRecognisedKind)
        XCTAssertEqual(warning.kindTitle, String(localized: "Picture not supplied"))
        XCTAssertTrue(warning.message.contains("gone.png"), warning.message)
    }

    /// A kind this build predates is shown as unknown, never dropped.
    func testAWarningKindThisBuildDoesNotKnowIsStillNamed() {
        let future = PrintWarning(rawKind: 9_999, message: "from a newer library", line: 3)
        XCTAssertFalse(future.isRecognisedKind)
        XCTAssertFalse(future.kindTitle.isEmpty)
        XCTAssertNotEqual(future.kindTitle, String(localized: "Picture not supplied"))
        XCTAssertEqual(PrintReport(warnings: [future], tokenNotes: []).count, 1)
    }

    /// Every kind the boundary declares has a name of its own — a `switch` that
    /// fell through to the fallback for a real kind would be invisible.
    func testEveryDeclaredWarningKindIsNamedDistinctly() {
        let titles = (1...14).map { PrintWarning(rawKind: Int32($0), message: "", line: nil) }
            .map(\.kindTitle)
        XCTAssertEqual(Set(titles).count, titles.count, "\(titles)")
        let fallback = PrintWarning(rawKind: 0, message: "", line: nil).kindTitle
        XCTAssertFalse(titles.contains(fallback), "a declared kind falls through to the fallback")
    }

    /// The pane has the report of its last print, and still answers the older
    /// question — what the print survived.
    @MainActor
    func testThePaneHoldsTheReportOfItsLastPrint() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintPluginTokenTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let model = PrintPaneModel()
        var request = Self.request(Self.markdown + "\n\n![alt](gone.png)\n")
        request.baseDir = root
        await model.render(request, debounced: false)

        XCTAssertNotNil(model.document)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.warnings.count, 1, "\(model.warnings)")
        XCTAssertEqual(model.report.warnings, model.warnings)
        XCTAssertEqual(model.report.tokenNotes.count, 2, "\(model.report.tokenNotes)")
        XCTAssertEqual(model.report.count, 3)
        XCTAssertFalse(model.report.isEmpty)
    }
}
