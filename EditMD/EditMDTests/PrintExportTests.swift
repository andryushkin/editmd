import CryptoKit
import XCTest
@testable import EditMD

/// File ▸ Export as PDF and the Print pane are one producer of pages, or the
/// app has two again.
///
/// The pane's request is read **off the pane** rather than rebuilt here. A probe
/// that assembles the request itself compares two copies of one guess and stays
/// green through exactly the mistake it exists for: the pane deciding one thing
/// and the export another.
///
/// What these do not reach is the single line inside the menu closure that
/// names which function the item calls. Nothing a unit test can call goes
/// through a menu, and the guard over the sources answers that half — a second
/// producer of PDFs cannot exist in this tree without a call these probes never
/// see and that guard always does.
@MainActor
final class PrintExportTests: XCTestCase {

    /// A picture, a link to a heading, a task list and a code block: enough
    /// that a moved setting shows up as different bytes, and enough that the
    /// renderer asks for a file on the way.
    private static let markdown = """
        # Export

        Body with a [link to a heading](#export) and a picture.

        ![alt](pic.png)

        - [x] a task
        - a plain item

        ```swift
        let x = 1
        ```
        """

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    // MARK: - Harness

    /// A folder holding the document and the picture it names.
    private func documentFolder() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PrintExportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try XCTUnwrap(Data(base64Encoded: Self.onePixelPNG))
            .write(to: root.appendingPathComponent("pic.png"))
        return root
    }

    private func pane(at file: URL) -> PrintPane {
        let document = MarkdownDocument()
        document.content = Self.markdown
        return PrintPane(document: document, fileURL: file, findModel: PaneFindModel())
    }

    /// The actions the File menu would hand the command for this document.
    private func actions(at file: URL) -> DocumentActions {
        DocumentActions(save: {}, saveAs: {}, hasURL: true,
                        markdownContent: { Self.markdown }, fileURL: file)
    }

    /// A flag two closures can share on the main actor.
    @MainActor private final class Flag {
        var raised = false
    }

    private func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    /// A print, with the third outcome named apart from the second.
    ///
    /// "The two files differ" and "nothing printed at all" are different
    /// answers. A host that cannot print makes every comparison below vacuous,
    /// and it has to say so in those words instead of arriving as an inequality
    /// somebody will read as a divergence.
    private func printed(_ request: PrintRenderRequest,
                         _ who: String) async throws -> PrintRenderResult {
        do {
            let result = try await PrintPDFRenderer.render(request)
            XCTAssertFalse(result.pdf.isEmpty, "\(who) produced an empty file")
            return result
        } catch {
            XCTFail("\(who) printed nothing at all — nothing below is being compared: \(error)")
            throw error
        }
    }

    private func exported(at file: URL) async throws -> PDFExportRun {
        do {
            return try await PDFExport.run(markdown: Self.markdown, fileURL: file)
        } catch {
            XCTFail("the export printed nothing at all — nothing below is being compared: \(error)")
            throw error
        }
    }

    /// The first field two manifests disagree on, spelled as a path, or nil.
    ///
    /// The manifest is the comparison format the command line is read against,
    /// so this asks the same question of the same values: not "are the files
    /// equal" but "which decision moved". Keys are walked in sorted order so
    /// two runs name the same field first.
    private func firstDifference(_ mine: Any, _ theirs: Any, at path: String = "") -> String? {
        switch (mine, theirs) {
        case let (a as [String: Any], b as [String: Any]):
            for key in Set(a.keys).union(b.keys).sorted() {
                let here = path.isEmpty ? key : "\(path).\(key)"
                switch (a[key], b[key]) {
                case (nil, nil): continue
                case (let x?, let y?):
                    if let found = firstDifference(x, y, at: here) { return found }
                case (nil, _): return "\(here): missing on the pane's side"
                case (_, nil): return "\(here): missing on the export's side"
                }
            }
            return nil
        case let (a as [Any], b as [Any]):
            if a.count != b.count { return "\(path): \(a.count) vs \(b.count) entries" }
            for (index, pair) in zip(a, b).enumerated() {
                if let found = firstDifference(pair.0, pair.1, at: "\(path)[\(index)]") {
                    return found
                }
            }
            return nil
        default:
            let a = mine as? NSObject
            let b = theirs as? NSObject
            if let a, let b, a.isEqual(b) { return nil }
            return "\(path): \(mine) (pane) vs \(theirs) (export)"
        }
    }

    // MARK: - One producer

    /// The export writes the bytes the pane prints, for the same document.
    func testTheExportWritesTheBytesThePanePrints() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")

        let fromPane = try await printed(pane(at: file).request, "the pane")
        let fromExport = try await exported(at: file)

        let difference = firstDifference(
            PrintComparisonWire.jobManifest(
                try await PrintPDFRenderer.job(for: pane(at: file).request),
                assets: fromPane.assets),
            PrintComparisonWire.jobManifest(
                try await PrintPDFRenderer.job(for: fromExport.request),
                assets: fromExport.assets))

        let field = difference ?? "none — the difference is not in the job"
        XCTAssertEqual(digest(fromExport.pdf), digest(fromPane.pdf),
                       "the export and the pane produced different files "
                       + "(\(fromExport.pdf.count) vs \(fromPane.pdf.count) bytes); "
                       + "first field they disagree on: \(field)")
    }

    /// And they decide every field of the job the same way.
    ///
    /// Its own probe rather than a line in the one above: bytes and fields fail
    /// differently. Two jobs can agree field by field and still print different
    /// files — that is a defect in the renderer, not here — and a field can
    /// move without moving a byte, which is a defect nothing else sees.
    func testTheExportAndThePaneDecideEveryFieldTheSameWay() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")

        let paneRequest = pane(at: file).request
        let fromPane = try await printed(paneRequest, "the pane")
        let fromExport = try await exported(at: file)

        let difference = firstDifference(
            PrintComparisonWire.jobManifest(
                try await PrintPDFRenderer.job(for: paneRequest), assets: fromPane.assets),
            PrintComparisonWire.jobManifest(
                try await PrintPDFRenderer.job(for: fromExport.request),
                assets: fromExport.assets))
        XCTAssertNil(difference, "the export and the pane disagree at \(difference ?? "")")
    }

    /// The menu command writes that same file where it was told to.
    ///
    /// This one drives the command itself — the buffer it takes, the name it
    /// suggests, the bytes that land on disk — with the two parts that need a
    /// person replaced: a destination instead of a save panel, and nothing
    /// instead of a Finder window.
    func testTheCommandWritesThePanesPagesToTheChosenFile() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")
        let target = root.appendingPathComponent("out.pdf")

        var suggested: String?
        let outcome = await PDFExport.command(actions(at: file),
                                              destination: { name in
                                                  suggested = name
                                                  return target
                                              },
                                              reveal: { _ in })
        guard case .wrote(let written) = outcome else {
            return XCTFail("the command did not write a file: \(outcome)")
        }
        XCTAssertEqual(written, target)
        XCTAssertEqual(suggested, "note", "the suggested name is the document's")

        let onDisk = try Data(contentsOf: target)
        let fromPane = try await printed(pane(at: file).request, "the pane")
        XCTAssertEqual(digest(onDisk), digest(fromPane.pdf),
                       "the file the command wrote is not the page the pane shows")
    }

    /// Nothing focused is not an empty export.
    func testTheCommandWithNoFocusedDocumentWritesNothing() async {
        var asked = false
        let outcome = await PDFExport.command(nil,
                                              destination: { _ in asked = true; return nil },
                                              reveal: { _ in })
        guard case .noDocument = outcome else {
            return XCTFail("expected no document, got \(outcome)")
        }
        XCTAssertFalse(asked, "a command with nothing focused asked where to put it")
    }

    /// A cancelled panel prints nothing at all — the seconds of layout are not
    /// spent on a file nobody chose.
    func testACancelledDestinationPrintsNothing() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")
        let outcome = await PDFExport.command(actions(at: file),
                                              destination: { _ in nil },
                                              reveal: { _ in })
        guard case .cancelled = outcome else {
            return XCTFail("expected a cancelled export, got \(outcome)")
        }
        XCTAssertEqual(try FileManager.default
            .contentsOfDirectory(atPath: root.path).sorted(), ["pic.png"])
    }

    /// What the one constructor decides, stated apart from either caller.
    ///
    /// The pane and the export now both read this, which is the point of it —
    /// and also the one thing the comparisons above cannot see: a mistake made
    /// here moves both sides by the same amount and leaves every one of them
    /// green. This probe is the one that is not blind to it.
    func testTheRequestForADocumentTakesItsFolderAndThePrintSettings() {
        let file = URL(fileURLWithPath: "/vault/notes/note.md")
        let plain = PrintRenderRequest.forDocument(markdown: "x", fileURL: file)
        XCTAssertEqual(plain.baseDir?.path, "/vault/notes",
                       "pictures resolve against the document's folder")

        let bundle = URL(fileURLWithPath: "/vault/notes/pack.textbundle")
        XCTAssertEqual(PrintRenderRequest.forDocument(markdown: "x", fileURL: bundle).baseDir?.path,
                       "/vault/notes/pack.textbundle",
                       "a textbundle resolves them against itself, not its parent")

        XCTAssertNil(PrintRenderRequest.forDocument(markdown: "x", fileURL: nil).baseDir,
                     "a document with no path has no folder to resolve against")

        // Spelled in capitals, the package is still a package. The file reader
        // has always thought so; three copies of this rule, this one among
        // them, did not — a review found them, and the answer now comes from
        // one function that every render path calls.
        let shouted = URL(fileURLWithPath: "/vault/notes/PACK.TEXTBUNDLE")
        XCTAssertEqual(PrintRenderRequest.forDocument(markdown: "x", fileURL: shouted).baseDir?.path,
                       "/vault/notes/PACK.TEXTBUNDLE",
                       "the package itself, whatever case its name is written in")

        // The print settings and not Preview's. The two have fields of the same
        // names and different values, and a page laid out from the wrong one
        // looks almost right.
        XCTAssertEqual(plain.settings, EditorSettings.shared.print)
        XCTAssertEqual(plain.syntaxHighlighting,
                       EditorSettings.shared.general.syntaxHighlighting)
        XCTAssertEqual(plain.markdown, "x")
    }

    /// Two exports at once are one export.
    ///
    /// Laying out pages takes seconds during which nothing on screen says so,
    /// so a second ⇧⌘E is what a person does when they think the first did
    /// nothing. Before this, the answer was a second panel and a second print
    /// of the same document.
    func testASecondExportWhileOneIsRunningIsRefused() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")
        let target = root.appendingPathComponent("out.pdf")

        let firstAsked = Flag()
        let first = Task { @MainActor in
            await PDFExport.command(self.actions(at: file),
                                    destination: { _ in firstAsked.raised = true; return target },
                                    reveal: { _ in })
        }
        var spins = 0
        while !firstAsked.raised, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(firstAsked.raised, "the first export never got as far as asking")

        let secondAsked = Flag()
        let second = await PDFExport.command(actions(at: file),
                                             destination: { _ in
                                                 secondAsked.raised = true
                                                 return target
                                             },
                                             reveal: { _ in })
        guard case .alreadyRunning = second else {
            _ = await first.value
            return XCTFail("the second export was not refused: \(second)")
        }
        XCTAssertFalse(secondAsked.raised,
                       "the second export asked where to put a file it was never going to write")

        // And the first one still finishes, unaffected by having been asked twice.
        guard case .wrote(let written) = await first.value else {
            return XCTFail("the first export did not write its file")
        }
        XCTAssertEqual(written, target)
    }

    /// The control the others are read against: one document exported twice is
    /// one file. Without it, "the export and the pane differ" says nothing
    /// about which of them moved — or whether anything did.
    func testTheSameDocumentExportsTheSameBytesTwice() async throws {
        let root = try documentFolder()
        let file = root.appendingPathComponent("note.md")
        let first = try await exported(at: file)
        let second = try await exported(at: file)
        XCTAssertEqual(digest(first.pdf), digest(second.pdf),
                       "exporting is not reproducible; nothing below compares anything")
    }
}
