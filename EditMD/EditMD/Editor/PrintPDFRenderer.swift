import Dispatch
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

extension PrintRenderRequest {

    /// The request for one document, built the one way this app builds it.
    ///
    /// Both places that print — the pane and File ▸ Export as PDF — come here,
    /// and that is the whole reason it exists: two callers assembling the same
    /// four fields would agree on the day they were written and drift after it,
    /// silently, because nothing about a printed page says which settings it
    /// was printed from. With one constructor the two can only differ if one of
    /// them changes the value afterwards, which is a thing a probe can see.
    @MainActor
    static func forDocument(markdown: String, fileURL: URL?,
                            settings: EditorSettings = .shared) -> PrintRenderRequest {
        PrintRenderRequest(
            markdown: markdown,
            // The same folder Preview and Visual resolve pictures against, and
            // by the same function: a print that looked somewhere else would
            // differ from the screen with nothing to explain it.
            baseDir: documentAssetBaseDir(for: fileURL),
            settings: settings.print,
            syntaxHighlighting: settings.general.syntaxHighlighting)
    }
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

/// One file the renderer asked this app for, and what it got.
///
/// Recorded on the result rather than declared on the job, and the choice is not
/// arbitrary. A job is what the app decides *before* anything is parsed, and the
/// names of the files a document refers to do not exist until after — they come
/// out of the parsed markdown, from the same handle that will print it. So the
/// job cannot carry them without a second parse of the same text, and the
/// symmetry that would buy is false: two prints whose jobs compare equal can
/// still differ in their pages, because the pictures next to the two documents
/// differ. That difference has to be visible somewhere, and here it is —
/// alongside the pages it explains, in the order the renderer asked.
///
/// `digest` is the SHA-256 of the bytes handed over, and only of those: for a
/// file that was not supplied there is nothing to hash and `supplied` says so.
/// The digest is what lets a second producer of the same document be compared
/// without shipping the pictures around.
struct PrintAssetRecord: Equatable, Sendable {
    /// The name the renderer asked for, percent-decoded by it and brought to
    /// one Unicode form by `PrintAssetLoader.canonicalName` on the way in.
    /// Canonical rather than verbatim because this name is compared and
    /// written out: two spellings of one file must not read as two files.
    var name: String
    var supplied: Bool
    /// Bytes handed over. 0 when nothing was.
    var byteCount: Int
    /// Lowercase hex SHA-256 of the bytes handed over, or nil when none were.
    var digest: String?

    /// Nothing went over for this name — it was not found, or it was refused.
    static func notSupplied(_ name: String) -> PrintAssetRecord {
        PrintAssetRecord(name: name, supplied: false, byteCount: 0, digest: nil)
    }
}

/// One print: the pages, how many of them, what the renderer survived, and which
/// files it asked for on the way.
struct PrintRenderResult: Equatable, Sendable {
    var pdf: Data
    var pageCount: Int
    var warnings: [PrintWarning]
    /// In the order the renderer asked, which is document order without
    /// duplicates.
    var assets: [PrintAssetRecord]
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

    /// A queue of this actor's own, rather than a slice of the cooperative pool.
    ///
    /// One print is a synchronous call with no cancellation that runs for
    /// seconds, plus ~199 MB of file reads. On the shared pool that occupies a
    /// worker thread for the whole of it, and the pool is sized for work that
    /// yields. The serial queue keeps exactly the property this actor exists
    /// for — one print at a time, app-wide — and keeps it off everyone else's
    /// threads.
    private let queue = DispatchSerialQueue(label: "andryushkin.EditMD.print")

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The job for a request. No boundary call, so no contract check: this is
    /// the value the app would send, and it is answerable whatever the linked
    /// library turns out to speak.
    func job(for request: PrintRenderRequest, options: PrintPageOptions) throws -> PrintJob {
        try checkGeometry(request)
        return PrintJob(request: request,
                        options: options,
                        fonts: PrintFontLoader.selection(for: request.settings))
    }

    func render(_ request: PrintRenderRequest,
                options: PrintPageOptions) throws -> PrintRenderResult {
        // Checked twice, and the second time is the one that matters. The pane
        // cancels its render task on every settings keystroke, but a cancelled
        // task that is already queued on this actor still runs to completion —
        // hundreds of megabytes of fonts read and a superseded revision printed,
        // while the current one waits behind it. One actor for the app spreads
        // that wait to every window.
        //
        // What this deliberately does *not* do is coalesce the queue down to
        // "the one running plus the newest waiting". That needs a request
        // generation and somewhere to drop the ones in between, which is
        // machinery of its own and not this change. Written down so the next
        // reader knows it was declined rather than overlooked.
        //
        // There is no deterministic probe for either check: provoking one would
        // need a stand-in for the renderer, which does not exist here. Claiming
        // otherwise in a test name would be worse than saying this.
        try Task.checkCancellation()
        // The gate that reads the vendored files runs before the build; this is
        // the half that asks the library itself, and it belongs on the path
        // that calls it. Without it a core built against another contract is
        // logged at launch and then called anyway — the assertion at startup
        // compiles to nothing in a shipping build, and every other link in the
        // vendoring chain exists to make exactly this refusal possible.
        //
        // `PDMCore.contract` and not a check of this actor's own: one verdict,
        // reached once per process, is what makes the refusal the same fact
        // here and at launch. Two evaluations of one contract are two things
        // that can be changed apart.
        if case .failure(let mismatch) = PDMCore.contract {
            throw PrintRenderError.core(mismatch)
        }
        let job = try job(for: request, options: options)
        try Task.checkCancellation()
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
