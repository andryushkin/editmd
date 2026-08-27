import AppKit

/// One export: the pages, and the request they were printed from.
///
/// The request travels back with the bytes on purpose. It is the whole of what
/// this path decided, and a PDF cannot be asked afterwards which settings made
/// it — so a probe comparing an export with the pane can say *which field*
/// moved rather than only that the files differ. There is no second path here
/// for tests: what `command` writes is exactly these bytes.
struct PDFExportRun: Sendable {
    var pdf: Data
    var request: PrintRenderRequest
    /// The files the renderer asked for on the way, in the order it asked.
    var assets: [PrintAssetRecord]
}

/// File ▸ Export as PDF — the Print pane's pages, written where the person asks.
///
/// This shares the pane's whole path and not merely its renderer: the request
/// comes from `PrintRenderRequest.forDocument`, so a setting that reaches the
/// pane reaches the file and the two cannot print different documents. Until
/// now the app had a second producer of PDFs — an offscreen web view rendering
/// the Preview page — which paginated nothing, dropped the internal anchors and
/// answered to no print setting; two producers of one artefact is one producer
/// too many, whatever either of them draws.
///
/// Deliberately not gated by `FeatureFlags.printMode`. The flag hides the Print
/// *mode* while it is unfinished; this is a File-menu command that has always
/// been there, and putting it behind the flag would take the feature away from
/// everyone rather than move it.
@MainActor
enum PDFExport {

    /// What the command did. Four outcomes and not a `Bool`: "nothing was
    /// focused", "the person cancelled" and "the print failed" are three
    /// different silences, and a caller that cannot tell them apart either
    /// beeps at a cancelled panel or says nothing when a print fails.
    enum CommandOutcome {
        case wrote(URL)
        case cancelled
        case noDocument
        /// One export is already between the panel and the written file.
        case alreadyRunning
        case failed(Error)
    }

    /// True from the moment a command asks where the file goes until it has
    /// written it.
    ///
    /// Laying out pages takes seconds, and while they pass the menu is live and
    /// nothing on screen says a print is happening — so the honest reading of a
    /// second ⇧⌘E is "the first one did nothing", and the app would answer it
    /// with a second panel and a second print of the same document. One print
    /// at a time is already true further down (the renderer is a single actor);
    /// this is the same statement at the level where the person is.
    private static var isRunning = false

    /// The pages for a document, as the pane would print them.
    ///
    /// Separate from the command so what an export produces can be asked for
    /// without a save panel: the bytes are the question, the dialog is not part
    /// of it.
    static func run(markdown: String, fileURL: URL?) async throws -> PDFExportRun {
        let request = PrintRenderRequest.forDocument(markdown: markdown, fileURL: fileURL)
        let result = try await PrintPDFRenderer.render(request)
        return PDFExportRun(pdf: result.pdf, request: request, assets: result.assets)
    }

    /// The whole File ▸ Export as PDF command: the focused buffer, printed and
    /// written where `destination` says.
    ///
    /// The command lives here rather than inside the menu closure so that what
    /// the menu item does is a function that can be called — the buffer it
    /// takes, the name it suggests, the file it writes. The two parts that need
    /// a person are injected with their production defaults, and for one reason
    /// each: a modal save panel would hang a caller that has nobody in front of
    /// it, and revealing in Finder is a window opening on someone's screen.
    ///
    /// Nothing is presented from here. A failure comes back as a value, because
    /// an alert raised inside this function is an alert a caller cannot decline
    /// — and a print that cannot be reported except by blocking is worse than
    /// one that returns its reason.
    @discardableResult
    static func command(_ actions: DocumentActions?,
                        destination: @MainActor (String) -> URL? = askForDestination,
                        reveal: @MainActor (URL) -> Void = revealInFinder) async -> CommandOutcome {
        guard let actions else { return .noDocument }
        guard !isRunning else { return .alreadyRunning }
        isRunning = true
        defer { isRunning = false }

        // Coalesced typing lands in the buffer first; without it the export is
        // of the document as it was a keystroke ago.
        actions.prepareForExport?()
        let markdown = actions.markdownContent()
        let fileURL = actions.fileURL
        let name = fileURL?.deletingPathExtension().lastPathComponent
            ?? String(localized: "Untitled")

        guard let target = destination(name) else { return .cancelled }
        do {
            let pages = try await run(markdown: markdown, fileURL: fileURL).pdf
            try pages.write(to: target, options: .atomic)
            reveal(target)
            return .wrote(target)
        } catch {
            return .failed(error)
        }
    }

    /// The default destination: a save panel, named after the document.
    static func askForDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".pdf")
            ? suggestedName : suggestedName + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
