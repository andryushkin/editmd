import AppKit
import WebKit

/// Offscreen Preview → PDF export (D3). Holds a strong reference to the
/// WKWebView until `createPDF` finishes so the load is not deallocated mid-flight.
@MainActor
enum PDFExporter {

    /// Presents an NSSavePanel and writes a PDF of the markdown rendered via
    /// the same HTML path as Preview.
    static func export(markdown: String, suggestedName: String, baseURL: URL?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".pdf")
            ? suggestedName : suggestedName + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let settings = EditorSettings.shared.preview
        let general = EditorSettings.shared.general
        let html = previewHTMLPage(
            markdown: markdown,
            fontSize: settings.fontSize,
            insetH: settings.insetH,
            insetV: settings.insetV,
            lineHeight: EditorSettings.shared.previewTypography.lineHeight,
            columnWidth: settings.columnWidth > 0 ? settings.columnWidth : 720,
            fontFamily: settings.cssFontFamily,
            fontWeight: settings.fontWeight.cssValue,
            elements: settings.elements,
            textColorHex: general.textColorHex,
            accentColorHex: general.accentColorHex,
            gutter: .off,
            imageResolver: nil
        )

        let session = ExportSession(html: html, baseURL: baseURL, destination: dest)
        session.start()
    }

    /// Keeps the web view alive until PDF creation completes.
    @MainActor
    private final class ExportSession: NSObject, WKNavigationDelegate {
        private let html: String
        private let baseURL: URL?
        private let destination: URL
        private var webView: WKWebView?
        /// Retain self across the async load/PDF pipeline.
        private var selfRetain: ExportSession?

        init(html: String, baseURL: URL?, destination: URL) {
            self.html = html
            self.baseURL = baseURL
            self.destination = destination
        }

        func start() {
            selfRetain = self
            let config = WKWebViewConfiguration()
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100),
                               configuration: config)
            wv.navigationDelegate = self
            webView = wv
            wv.loadHTMLString(html, baseURL: baseURL)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let cfg = WKPDFConfiguration()
            // WKPDFConfiguration defaults to CGRect.null, which WebKit defines
            // as the bounds of the full displayed page. A zero-height rect is
            // an empty capture area, not a sentinel for full content.
            webView.createPDF(configuration: cfg) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    defer {
                        self.webView = nil
                        self.selfRetain = nil
                    }
                    switch result {
                    case .success(let data):
                        do {
                            try data.write(to: self.destination, options: .atomic)
                            NSWorkspace.shared.activateFileViewerSelecting([self.destination])
                        } catch {
                            let alert = NSAlert(error: error)
                            alert.runModal()
                        }
                    case .failure(let error):
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            let alert = NSAlert(error: error)
            alert.runModal()
            self.webView = nil
            self.selfRetain = nil
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            let alert = NSAlert(error: error)
            alert.runModal()
            self.webView = nil
            self.selfRetain = nil
        }
    }
}
