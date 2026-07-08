import SwiftUI
import WebKit

/// Read-only rendered preview: full-window in Preview mode, or the right
/// pane of the editor+preview split. Local images are inlined as data:
/// URIs — WKWebView does not grant file:// subresource access to HTML loaded
/// via loadHTMLString, and unsaved documents have no base directory anyway.
///
/// Live updates (the split types into document.content on every keystroke)
/// are debounced 250 ms and keep the scroll pixel-stable across the reload;
/// only the FIRST render scrolls to the cross-mode proportional position.
struct MarkdownPreviewView: NSViewRepresentable {

    let document: MarkdownDocument
    let fileURL: URL?
    var positionStore: EditorPositionStore? = nil
    /// Full-preview mode only: Return switches back to editing (FSNotes).
    var onRequestEdit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        // Task checkboxes in the page report their index here; the controller
        // retains its handlers strongly, so the handler holds the coordinator
        // weakly to avoid a retain cycle.
        let userContentController = WKUserContentController()
        userContentController.add(TaskToggleHandler(coordinator: coordinator),
                                  name: "taskToggle")
        userContentController.add(WikiLinkClickHandler(coordinator: coordinator),
                                  name: "wikiLinkClick")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.onReturnKey = onRequestEdit
        webView.navigationDelegate = coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        coordinator.webView = webView
        coordinator.positionStore = positionStore
        coordinator.document = document
        coordinator.fileURL = fileURL
        coordinator.rerender = { [weak coordinator] in
            guard let coordinator else { return }
            coordinator.lastRenderedContent = nil
            if let webView = coordinator.webView {
                self.render(in: webView, coordinator: coordinator)
            }
        }
        // Preview settings changes must re-render: the page bakes font size/
        // insets/line-height/column width into its CSS, so no content change
        // would otherwise trigger an update.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil
        )
        // Outline-sidebar jumps, object-scoped to this window's store.
        if let store = positionStore {
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.jumpToStoredOffset),
                name: .editMDJumpToOffset,
                object: store
            )
        }
        render(in: webView, coordinator: coordinator)
        // Full Preview mode: focus the web view so Return-to-edit works
        // right after the mode switch (async — no window yet in makeNSView).
        if onRequestEdit != nil {
            DispatchQueue.main.async { [weak webView] in
                guard let webView else { return }
                webView.window?.makeFirstResponder(webView)
            }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.document = document
        (webView as? PreviewWebView)?.onReturnKey = onRequestEdit
        guard coordinator.lastRenderedContent != document.content else { return }
        // Debounce: every updateNSView during typing cancels the pending
        // render, so the reload fires ~250 ms after the last keystroke.
        coordinator.renderTask?.cancel()
        let parent = self
        coordinator.renderTask = Task { [weak coordinator] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, let coordinator,
                  let webView = coordinator.webView else { return }
            parent.render(in: webView, coordinator: coordinator)
        }
    }

    private func render(in webView: WKWebView, coordinator: Coordinator) {
        let content = document.content
        guard coordinator.lastRenderedContent != content else { return }
        coordinator.lastRenderedContent = content

        let baseDir = assetBaseDir
        let settings = EditorSettings.shared.preview
        let general = EditorSettings.shared.general
        let html = previewHTMLPage(
            markdown: content,
            fontSize: settings.fontSize,
            insetH: settings.insetH,
            lineHeight: EditorSettings.shared.previewTypography.lineHeight,
            columnWidth: settings.columnWidth,
            fontFamily: settings.cssFontFamily,
            fontWeight: settings.fontWeight.cssValue,
            elements: settings.elements,
            textColorHex: general.textColorHex,
            accentColorHex: general.accentColorHex,
            imageResolver: { Self.dataURI(for: $0, baseDir: baseDir) }
        )

        if coordinator.hasRenderedOnce {
            // Live re-render: capture the current scroll first, restore it in
            // didFinish — loadHTMLString would otherwise snap back to the top
            // on every debounced reload while typing in the split.
            webView.evaluateJavaScript("window.scrollY") { scrollY, _ in
                coordinator.pendingScrollY = (scrollY as? NSNumber)?.doubleValue
                webView.loadHTMLString(html, baseURL: nil)
            }
        } else {
            coordinator.hasRenderedOnce = true
            // First render: land at the cross-mode cursor's proportional spot.
            if let store = positionStore {
                let total = max(1, (content as NSString).length)
                coordinator.pendingScrollFraction =
                    Double(min(store.markdownOffset, total)) / Double(total)
            }
            webView.loadHTMLString(html, baseURL: nil)
        }
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
        weak var webView: WKWebView?
        var positionStore: EditorPositionStore?
        var document: MarkdownDocument?
        var fileURL: URL?
        var lastRenderedContent: String?
        var renderTask: Task<Void, Never>?
        var hasRenderedOnce = false
        /// Forces a full re-render (font size changes: same content,
        /// different CSS).
        var rerender: (() -> Void)?
        /// Proportional scroll target from the shared position store (first
        /// render only).
        var pendingScrollFraction: Double?
        /// Pixel scroll captured before a live reload, restored in didFinish.
        var pendingScrollY: Double?

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func settingsDidChange() {
            rerender?()
        }

        /// A task checkbox was clicked in the page: flip the matching
        /// `[ ]`/`[x]` in the markdown source. The DOM already shows the new
        /// state; the debounced re-render that follows is a visual no-op and
        /// keeps the scroll (pendingScrollY dance in render/didFinish).
        func toggleTask(at index: Int) {
            guard let document,
                  let toggled = toggleTaskListItem(in: document.content, index: index)
            else { return }
            document.content = toggled
        }

        /// A wiki-link was clicked in the page: resolve its target and open the
        /// file (relative to this document's folder).
        func openWikiLink(target: String) {
            navigateToWikiLink(target: target, from: fileURL)
        }

        /// Outline-sidebar jump: scroll to the offset's proportional position
        /// (the preview has no markdown offsets — same mapping as the
        /// cross-mode restore).
        @objc func jumpToStoredOffset() {
            guard let webView, let store = positionStore,
                  let content = lastRenderedContent else { return }
            let total = max(1, (content as NSString).length)
            let fraction = Double(min(store.markdownOffset, total)) / Double(total)
            webView.evaluateJavaScript(Self.scrollJS(fraction: fraction))
        }

        private static func scrollJS(fraction: Double) -> String {
            "window.scrollTo(0, Math.max(0, "
                + "document.documentElement.scrollHeight * \(fraction) - window.innerHeight * 0.4));"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let y = pendingScrollY {
                pendingScrollY = nil
                webView.evaluateJavaScript("window.scrollTo(0, \(y));")
                return
            }
            guard let fraction = pendingScrollFraction, fraction > 0.001 else { return }
            pendingScrollFraction = nil
            webView.evaluateJavaScript(Self.scrollJS(fraction: fraction))
        }

        // The async form: the closure-based signature no longer matches the
        // macOS 26 SDK's @MainActor @Sendable completion type ("nearly
        // matches" warning → the method is silently never called and link
        // clicks navigate the preview itself).
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            // Clicked links open in the default browser; the preview itself
            // only ever displays the generated page.
            if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }
            return .allow
        }
    }
}

// MARK: - Web view with Return-to-edit

/// Return in the read-only preview switches back to editing (FSNotes'
/// MPreviewView.keyDown). Only set in full Preview mode — in the split the
/// editor is already on screen.
final class PreviewWebView: WKWebView {
    var onReturnKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter
        if onReturnKey != nil, event.keyCode == 36 || event.keyCode == 76 {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }
}

/// Bridges the page's checkbox clicks to the coordinator. Held strongly by
/// WKUserContentController, hence the weak coordinator reference.
@MainActor
private final class TaskToggleHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let index = message.body as? Int else { return }
        coordinator?.toggleTask(at: index)
    }
}

/// Bridges the page's wiki-link clicks to the coordinator. Held strongly by
/// WKUserContentController, hence the weak coordinator reference.
@MainActor
private final class WikiLinkClickHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let target = body["target"] as? String, !target.isEmpty else { return }
        coordinator?.openWikiLink(target: target)
    }
}
