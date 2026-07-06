import SwiftUI
import WebKit

/// Read-only rendered preview (mode 3). Local images are inlined as data:
/// URIs — WKWebView does not grant file:// subresource access to HTML loaded
/// via loadHTMLString, and unsaved documents have no base directory anyway.
struct MarkdownPreviewView: NSViewRepresentable {

    let document: MarkdownDocument
    let fileURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        render(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        render(in: webView, coordinator: context.coordinator)
    }

    private func render(in webView: WKWebView, coordinator: Coordinator) {
        let content = document.content
        guard coordinator.lastRenderedContent != content else { return }
        coordinator.lastRenderedContent = content

        let baseDir = assetBaseDir
        let html = previewHTMLPage(
            markdown: content,
            fontSize: EditorFontSettings.shared.fontSize,
            imageResolver: { Self.dataURI(for: $0, baseDir: baseDir) }
        )
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Directory that relative image paths resolve against: the .textbundle
    /// package root (sources reference "assets/…"), or the .md file's folder.
    private var assetBaseDir: URL? {
        guard let fileURL else { return nil }
        return fileURL.pathExtension == "textbundle"
            ? fileURL
            : fileURL.deletingLastPathComponent()
    }

    private static let imageMIMETypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "svg": "image/svg+xml", "webp": "image/webp",
        "heic": "image/heic", "tiff": "image/tiff", "tif": "image/tiff",
        "bmp": "image/bmp",
    ]
    private static let maxInlineImageBytes = 8_000_000

    /// data: URI for a relative local image path, or nil to keep the original
    /// source (remote URLs, anchors, unknown types, oversized/missing files).
    static func dataURI(for source: String, baseDir: URL?) -> String? {
        guard !source.hasPrefix("#"), URL(string: source)?.scheme == nil,
              let baseDir else { return nil }
        let path = source.removingPercentEncoding ?? source
        let fileURL = baseDir.appendingPathComponent(path).standardizedFileURL
        guard let mime = imageMIMETypes[fileURL.pathExtension.lowercased()],
              let data = try? Data(contentsOf: fileURL),
              data.count <= maxInlineImageBytes
        else { return nil }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastRenderedContent: String?

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Clicked links open in the default browser; the preview itself
            // only ever displays the generated page.
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
