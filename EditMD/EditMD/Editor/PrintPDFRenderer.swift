import Foundation

/// Everything a print render needs, as a value: the pane re-renders when this
/// changes and only then.
struct PrintRenderRequest: Equatable, Sendable {
    var markdown: String
    /// Folder relative image sources resolve against (the package itself for a
    /// textbundle), exactly as Preview resolves them. nil for an unsaved
    /// document — local images then do not appear.
    var baseDir: URL?
    var settings: PrintSettings
    /// Kept for the shape of the request, but code on paper is highlighted
    /// either way: the page renderer offers no switch for it, and the setting
    /// belongs to Source and Preview.
    var syntaxHighlighting: Bool
}

/// What one warning from the page renderer says.
struct PrintWarning: Equatable, Sendable {
    /// The kind, as the frozen number the boundary hands over. Not an enum: a
    /// kind this app predates has to survive as "something we do not know",
    /// which an exhaustive Swift type cannot express without losing it.
    var rawKind: Int32
    var message: String
    /// 1-based line in the markdown, when the warning has one.
    var line: Int64?
}

/// One print: the pages, how many of them, and what the renderer survived.
struct PrintRenderResult: Equatable, Sendable {
    var pdf: Data
    var pageCount: Int
    var warnings: [PrintWarning]
}

enum PrintRenderError: Error, LocalizedError {
    /// The page cannot be laid out at all — caught before anything is printed,
    /// because the Settings panel has to say so while the finger is still on the
    /// slider.
    case geometry(PrintGeometryProblem)
    /// The page renderer refused.
    case core(PDMCore.CoreError)
    /// Pages came back that PDFKit would not open.
    case noOutput

    var errorDescription: String? {
        switch self {
        case .geometry(let problem): return problem.message
        case .core(let error):       return error.errorDescription
        case .noOutput:              return String(localized: "The renderer produced no pages.")
        }
    }
}

/// The Print pane's pages: markdown handed to the page renderer, a paginated
/// tagged PDF back.
///
/// This is the translation layer and nothing else — it knows what the app means
/// by a page and turns it into a `PrintJob`; it knows no C name. What it decides
/// is exactly what a printed page cannot be asked about afterwards: which faces
/// may be drawn with, which files the document may reach, and which of the
/// renderer's own defaults are being accepted on purpose.
///
/// Two things reach paper that never reached the pane before: real sheets of the
/// declared size, and the internal anchors and bookmarks the previous source
/// dropped. Two things stopped reaching it: remote images, which the renderer
/// does not fetch because it has no network at all — and a print that quietly
/// went to the network for a picture is not a property worth keeping — and the
/// theme's heading face, for which the boundary has no setter.
enum PrintPDFRenderer {

    /// The pages for a request, printed with the values the pane prints with.
    ///
    /// `options` has a production default so the pane calls this with one
    /// argument and a probe calls the *same* function with a changed one. There
    /// is no separate path for tests: a defect planted in here fails the pane
    /// and the probes together, which is the only arrangement in which a green
    /// probe means anything.
    static func render(_ request: PrintRenderRequest,
                       options: PrintPageOptions = .standard) async throws -> PrintRenderResult {
        try await PrintRenderService.shared.render(request, options: options)
    }

    /// The job a request comes to — the whole of what the renderer is told.
    ///
    /// Exposed because it is the only place the app's intent is observable
    /// without a PDF in the way: what got sent is a different question from what
    /// came back, and answering them separately is what tells a translation
    /// mistake here from a rendering mistake there.
    static func job(for request: PrintRenderRequest,
                    options: PrintPageOptions = .standard) async throws -> PrintJob {
        try await PrintRenderService.shared.job(for: request, options: options)
    }
}

/// Where a print actually happens.
///
/// An actor, and a single one for the whole app, for two reasons that do not
/// overlap. The first is the boundary's: a document handle is not thread-safe,
/// and the render call is synchronous with no cancellation, so it must run
/// somewhere that is not the main actor and not two places at once. The second
/// is ours: font lookup and reading font and image files are disk work, which
/// has no business on the main actor either.
///
/// One instance app-wide means a second window's print waits for the first. That
/// is the deliberate trade: the alternative is several prints competing for the
/// typesetter's process-wide cache, which the header describes as trimmed after
/// every print — i.e. shared, and not per handle.
actor PrintRenderService {
    static let shared = PrintRenderService()

    func job(for request: PrintRenderRequest, options: PrintPageOptions) throws -> PrintJob {
        try checkGeometry(request)
        return PrintJob(request: request,
                        options: options,
                        fonts: PrintFontLoader.selection(for: request.settings))
    }

    func render(_ request: PrintRenderRequest,
                options: PrintPageOptions) throws -> PrintRenderResult {
        let job = try job(for: request, options: options)
        let assets = PrintAssetLoader(baseDir: request.baseDir)
        do {
            return try PDMCore.render(job) { assets.bytes(forAssetNamed: $0) }
        } catch let error as PDMCore.CoreError {
            throw PrintRenderError.core(error)
        }
    }

    /// Refused here rather than by the renderer, because the Settings panel
    /// shows the same verdict for the same values before anything is printed and
    /// the two must not be able to disagree.
    private func checkGeometry(_ request: PrintRenderRequest) throws {
        if case .failure(let problem) = request.settings.geometry {
            throw PrintRenderError.geometry(problem)
        }
    }
}
