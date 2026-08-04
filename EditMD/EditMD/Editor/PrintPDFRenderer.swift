import AppKit
import WebKit

/// Everything a print render needs, as a value: the pane re-renders when this
/// changes and only then.
struct PrintRenderRequest: Equatable {
    var markdown: String
    /// Folder relative image sources resolve against (the package itself for a
    /// textbundle), exactly as Preview resolves them. nil for an unsaved
    /// document — local images then do not appear.
    var baseDir: URL?
    var settings: PrintSettings
    var syntaxHighlighting: Bool
}

enum PrintRenderError: Error, LocalizedError {
    case geometry(PrintGeometryProblem)
    case load(String)
    case layoutFailed
    case noOutput
    case timedOut

    var errorDescription: String? {
        switch self {
        case .geometry(let problem): return problem.message
        case .load(let message):     return message
        case .layoutFailed:          return String(localized: "The page could not be laid out.")
        case .noOutput:              return String(localized: "The renderer produced no pages.")
        case .timedOut:              return String(localized: "Rendering the pages took too long.")
        }
    }
}

/// Interim source of the Print pane's pages: the Preview HTML put through
/// WebKit's `createPDF`.
///
/// **This does not paginate onto paper, and that is a known holding state.**
/// Measured 4 Aug 2026: `createPDF` returns the whole document as strips of up
/// to 800 × 14400 pt rather than sheets, keeps external link annotations, drops
/// internal anchors, and writes no document outline. The page width and the
/// margins in `PrintSettings` therefore do not reach the output yet; only the
/// typography does. `NSPrintOperation`, which does paginate, cannot be used
/// here — it takes the process down with a dispatch-queue assertion
/// (EXC_BREAKPOINT in `_dispatch_assert_queue_fail`) whether the job is given
/// an offscreen host window or the app's own, and whether or not it is allowed
/// to spawn a thread.
///
/// The whole enum is scaffolding: it exists so the Print pane can be built and
/// judged before the page renderer that will replace it arrives. Nothing above
/// it knows how the pages were made.
@MainActor
enum PrintPDFRenderer {

    /// Hard cap on one render. Print is allowed to be slow — it is not allowed
    /// to leave the pane spinning forever because a remote image never answers.
    static let timeout: Duration = .seconds(30)

    static func render(_ request: PrintRenderRequest) async throws -> Data {
        // Validated even though the interim source ignores the page box: a
        // margin that is not a finite number must be refused at the top of the
        // call, not discovered inside a layout engine.
        guard case .success(let geometry) = request.settings.geometry else {
            if case .failure(let problem) = request.settings.geometry {
                throw PrintRenderError.geometry(problem)
            }
            throw PrintRenderError.layoutFailed
        }
        let session = Session(html: html(for: request), geometry: geometry)
        defer { session.tearDown() }
        return try await session.run()
    }

    static func html(for request: PrintRenderRequest) -> String {
        let settings = request.settings
        let theme = settings.resolvedTheme
        let baseDir = request.baseDir
        return previewHTMLPage(
            markdown: request.markdown,
            fontSize: settings.fontSize,
            insetH: 0,
            insetV: 0,
            lineHeight: settings.lineHeight,
            columnWidth: 0,
            fontFamily: PrintHTMLBridge.fontStack(
                theme.resolvedBodyFamilies(userFamily: settings.fontFamily), generic: "serif"),
            // Print styling is the print theme's alone: the per-element colors
            // and accents in Settings belong to the screen modes.
            elements: ElementStyles(),
            themeCSS: PrintHTMLBridge.pageCSS(settings: settings, theme: theme),
            gutter: .off,
            syntaxHighlighting: request.syntaxHighlighting,
            imageResolver: { MarkdownPreviewView.dataURI(for: $0, baseDir: baseDir) }
        )
    }

    /// One render: a web view with no window, and a PDF capture. The web view
    /// is torn down whatever happens — a leaked one keeps a web content process
    /// alive per render.
    @MainActor
    private final class Session: NSObject, WKNavigationDelegate {
        private let html: String
        private let geometry: PrintPageGeometry
        private let webView: WKWebView
        /// Resumed exactly once: by the capture, by either failure callback, or
        /// by the timeout. `finish` enforces the once.
        private var continuation: CheckedContinuation<Data, Error>?
        private var finished = false

        init(html: String, geometry: PrintPageGeometry) {
            self.html = html
            self.geometry = geometry
            // `createPDF` maps one CSS pixel to one PDF point, so the view is
            // sized in points: the text frame the settings ask for, whatever
            // the source then does with the page height.
            webView = WKWebView(frame: NSRect(origin: .zero,
                                              size: CGSize(width: geometry.pageSize.width,
                                                           height: geometry.pageSize.height)))
            super.init()
            // The page prints black on white; a dark-appearance web view would
            // resolve system colors the other way around inside the controls
            // and images the CSS does not reach.
            webView.appearance = NSAppearance(named: .aqua)
            webView.navigationDelegate = self
        }

        func run() async throws -> Data {
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: PrintPDFRenderer.timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(PrintRenderError.timedOut))
            }
            defer { timeoutTask.cancel() }
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // Local images arrive as data: URIs — no file baseURL needed,
                // and none is granted: the page must not read the disk.
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func tearDown() {
            webView.navigationDelegate = nil
            webView.stopLoading()
        }

        private func finish(_ result: Result<Data, Error>) {
            guard !finished else { return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            continuation?.resume(with: result)
        }

        // MARK: Navigation

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            waitForImages(attemptsLeft: 20)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            finish(.failure(PrintRenderError.load(error.localizedDescription)))
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            finish(.failure(PrintRenderError.load(error.localizedDescription)))
        }

        /// `didFinish` covers the main frame only — a remote `<img>` may still
        /// be in flight, and a page captured mid-load loses it. ~2 s cap: the
        /// pages must not stay hostage to a dead image host.
        private func waitForImages(attemptsLeft: Int) {
            let js = "Array.from(document.images).every(function (i) { return i.complete; })"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                Task { @MainActor in
                    guard let self, !self.finished else { return }
                    let done = (result as? Bool) ?? true
                    if done || attemptsLeft <= 0 {
                        self.capture()
                    } else {
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !self.finished else { return }
                        self.waitForImages(attemptsLeft: attemptsLeft - 1)
                    }
                }
            }
        }

        private func capture() {
            // A null rect means the whole displayed page; a zero-height one is
            // an empty capture area, not a sentinel for the full content.
            webView.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let data) where !data.isEmpty:
                        self.finish(.success(data))
                    case .success:
                        self.finish(.failure(PrintRenderError.noOutput))
                    case .failure(let error):
                        self.finish(.failure(PrintRenderError.load(error.localizedDescription)))
                    }
                }
            }
        }
    }
}
