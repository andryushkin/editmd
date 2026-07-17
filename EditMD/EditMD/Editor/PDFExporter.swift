import AppKit
import WebKit

/// Offscreen Preview → PDF export (D3). Holds a strong reference to the
/// WKWebView until `createPDF` finishes so the load is not deallocated mid-flight.
@MainActor
enum PDFExporter {

    /// Presents an NSSavePanel and writes a PDF of the markdown rendered via
    /// the same HTML path as Preview. `fileURL` (when the document has one)
    /// anchors relative images exactly like Preview: data: URIs resolved
    /// against the file's folder (or the .textbundle itself).
    static func export(markdown: String, suggestedName: String, fileURL: URL?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName.hasSuffix(".pdf")
            ? suggestedName : suggestedName + ".pdf"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        // Same asset base Preview uses (textbundle = the bundle itself).
        let assetBase: URL? = fileURL.map {
            $0.pathExtension == "textbundle" ? $0 : $0.deletingLastPathComponent()
        }
        let settings = EditorSettings.shared.preview
        let general = EditorSettings.shared.general
        let theme = PreviewTheme.preset(named: EditorSettings.shared.previewTypography.theme)
        let html = previewHTMLPage(
            markdown: markdown,
            fontSize: settings.fontSize,
            insetH: settings.insetH,
            insetV: settings.insetV,
            lineHeight: EditorSettings.shared.previewTypography.lineHeight,
            columnWidth: settings.columnWidth > 0 ? settings.columnWidth : 720,
            fontFamily: theme.cssFontFamily(userFamily: settings.fontFamily),
            fontWeight: settings.fontWeight.cssValue,
            elements: settings.elements,
            textColorHex: general.textColorHex,
            accentColorHex: general.accentColorHex,
            themeCSS: theme.css,
            gutter: .off,
            syntaxHighlighting: general.syntaxHighlighting,
            imageResolver: { MarkdownPreviewView.dataURI(for: $0, baseDir: assetBase) }
        )

        let session = ExportSession(html: html, destination: dest)
        session.start()
    }

    /// Keeps the web view alive until PDF creation completes.
    @MainActor
    private final class ExportSession: NSObject, WKNavigationDelegate {
        private let html: String
        private let destination: URL
        private var webView: WKWebView?
        /// Retain self across the async load/PDF pipeline.
        private var selfRetain: ExportSession?

        init(html: String, destination: URL) {
            self.html = html
            self.destination = destination
        }

        func start() {
            selfRetain = self
            let config = WKWebViewConfiguration()
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1100),
                               configuration: config)
            wv.navigationDelegate = self
            webView = wv
            // Local images arrive embedded as data: URIs — no file baseURL needed.
            wv.loadHTMLString(html, baseURL: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // didFinish covers the main frame only — remote <img> may still be
            // loading. Poll completeness briefly before capturing.
            waitForImages(webView, attemptsLeft: 20)
        }

        /// ~2s cap (20 × 100ms): PDF quality shouldn't hold the export hostage
        /// to a dead image host.
        private func waitForImages(_ webView: WKWebView, attemptsLeft: Int) {
            let js = "Array.from(document.images).every(function (i) { return i.complete; })"
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let done = (result as? Bool) ?? true
                    if done || attemptsLeft <= 0 {
                        self.createPDF(webView)
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                            self?.waitForImages(webView, attemptsLeft: attemptsLeft - 1)
                        }
                    }
                }
            }
        }

        private func createPDF(_ webView: WKWebView) {
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
