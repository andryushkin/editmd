import SwiftUI
import AppKit
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
    /// Optional strip bridge (full Preview mode). Coordinator installs
    /// format closures on make + update.
    var toolbarActions: EditorStripActions? = nil

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
        userContentController.add(PreviewSelectionHandler(coordinator: coordinator),
                                  name: "previewSelection")
        // Cache selection + source offsets (data-md-lo/hi). Keep last non-empty
        // so a click on the action strip doesn't wipe the range before wrap runs.
        // Report selection in *markdown source* UTF-16 offsets (data-md-lo/hi).
        // Used by the format strip and by Review-mark capture (v37) via the
        // ClaudeIDEBridge — same path as Source/Visual.
        let selectionScript = WKUserScript(
            source: """
            (function () {
              function mdEl(node) {
                var n = node;
                if (n && n.nodeType === 3) n = n.parentElement;
                while (n && n !== document.body) {
                  if (n.getAttribute && n.hasAttribute('data-md-lo')) return n;
                  if (n.getAttribute && n.getAttribute('data-md-code') === '1') return n;
                  n = n.parentElement;
                }
                return null;
              }
              function utf16OffsetIn(el, targetNode, targetOffset) {
                if (targetNode === el) return targetOffset;
                var count = 0;
                var walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
                var n;
                while ((n = walker.nextNode())) {
                  if (n === targetNode) return count + targetOffset;
                  count += n.nodeValue.length;
                }
                return count;
              }
              function report() {
                try {
                  var sel = window.getSelection();
                  if (!sel || sel.rangeCount === 0 || sel.isCollapsed) {
                    window.webkit.messageHandlers.previewSelection.postMessage({text: ''});
                    return;
                  }
                  var range = sel.getRangeAt(0);
                  var text = sel.toString();
                  var a = mdEl(range.startContainer);
                  var b = mdEl(range.endContainer);
                  // Code islands: offsets into rendered code don't match source.
                  if (!a || !b
                      || a.getAttribute('data-md-code') === '1'
                      || b.getAttribute('data-md-code') === '1') {
                    window.webkit.messageHandlers.previewSelection.postMessage({
                      text: text, start: -1, end: -1
                    });
                    return;
                  }
                  var loA = parseInt(a.getAttribute('data-md-lo'), 10);
                  var loB = parseInt(b.getAttribute('data-md-lo'), 10);
                  if (isNaN(loA) || isNaN(loB)) {
                    window.webkit.messageHandlers.previewSelection.postMessage({
                      text: text, start: -1, end: -1
                    });
                    return;
                  }
                  // a and b may differ (selection spans inline runs / lines).
                  var start = loA + utf16OffsetIn(a, range.startContainer, range.startOffset);
                  var end = loB + utf16OffsetIn(b, range.endContainer, range.endOffset);
                  if (end < start) { var t = start; start = end; end = t; }
                  window.webkit.messageHandlers.previewSelection.postMessage({
                    text: text, start: start, end: end
                  });
                } catch (e) {}
              }
              document.addEventListener('selectionchange', report);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        userContentController.addUserScript(selectionScript)
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        let webView = PreviewWebView(frame: .zero, configuration: configuration)
        webView.onReturnKey = onRequestEdit
        webView.documentForUndo = document
        webView.navigationDelegate = coordinator
        webView.underPageBackgroundColor = .textBackgroundColor
        coordinator.webView = webView
        coordinator.positionStore = positionStore
        coordinator.document = document
        coordinator.fileURL = fileURL
        coordinator.bindToolbar(toolbarActions)
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
        // Review-mark wash in Preview (primary review surface, v37).
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.reviewMarksDidChange),
            name: .reviewMarksDidChange,
            object: nil
        )
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
        coordinator.fileURL = fileURL
        coordinator.bindToolbar(toolbarActions)
        (webView as? PreviewWebView)?.onReturnKey = onRequestEdit
        (webView as? PreviewWebView)?.documentForUndo = document
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
        let g = EditorSettings.shared.gutter
        let dirtyHex = g.dirtyMarkColorHex ?? g.dirtyMarkNSColor.hexString
        let gutter = PreviewGutterOptions(
            showLineNumbers: g.showLineNumbers,
            highlightChangedLines: g.highlightChangedLines,
            showDirtyBulletsWhenNoNumbers: g.showDirtyBulletsWhenNoNumbers,
            dirtyLines: LineChangeTracker.shared.dirtyLines(for: fileURL),
            dirtyMarkColorHex: dirtyHex
        )
        let html = previewHTMLPage(
            markdown: content,
            fontSize: settings.fontSize,
            insetH: settings.insetH,
            insetV: settings.insetV,
            lineHeight: EditorSettings.shared.previewTypography.lineHeight,
            columnWidth: settings.columnWidth,
            fontFamily: settings.cssFontFamily,
            fontWeight: settings.fontWeight.cssValue,
            elements: settings.elements,
            textColorHex: general.textColorHex,
            accentColorHex: general.accentColorHex,
            gutter: gutter,
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
        weak var toolbarActions: EditorStripActions?
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
        /// Last usable selection from the page. Empty selectionchange events
        /// do NOT clear this (strip click collapses the WebKit selection).
        var cachedSelection: String = ""
        /// UTF-16 range in the markdown source (`data-md-lo`…`data-md-hi`).
        /// `-1` means offsets unknown (copy still works; wrap beeps).
        var cachedStart: Int = -1
        var cachedEnd: Int = -1

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Installs strip callbacks on the shared actions object (if any).
        /// Does NOT call `objectWillChange` — this runs from `updateNSView` during
        /// SwiftUI view updates; publishing here freezes the app (feedback loop).
        func bindToolbar(_ actions: EditorStripActions?) {
            toolbarActions = actions
            guard let actions else { return }
            actions.copySelection = { [weak self] in self?.copySelection() }
            actions.toggleHighlight = { [weak self] in
                self?.toggleWrap(open: "==", close: "==")
            }
            actions.toggleStrikethrough = { [weak self] in
                self?.toggleWrap(open: "~~", close: "~~")
            }
            actions.toggleBold = { [weak self] in self?.toggleWrap(open: "**", close: "**") }
            actions.toggleItalic = { [weak self] in self?.toggleWrap(open: "*", close: "*") }
            actions.setHeading = { [weak self] level in self?.transformSelectionLines(.heading(level)) }
            actions.setBody = { [weak self] in self?.transformSelectionLines(.body) }
            actions.toggleCodeBlock = { [weak self] in self?.fenceSelectionLines() }
            actions.toggleBulletList = { [weak self] in self?.transformSelectionLines(.bullet) }
            actions.toggleChecklist = { [weak self] in self?.transformSelectionLines(.checklist) }
            actions.toggleNumberedList = { [weak self] in self?.transformSelectionLines(.ordered) }
            actions.toggleQuote = { [weak self] in self?.transformSelectionLines(.quote) }
            // Table / formula only in Visual (UI gated by mode, not these nils).
            actions.insertTable = nil
            actions.tableAddRow = nil
            actions.tableDeleteRow = nil
            actions.formulaStub = nil
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
            document.commitContentEdit()
            document.applyUndoableContent(toggled, actionName: "Toggle Task")
        }

        /// A wiki-link was clicked in the page: resolve its target and open the
        /// file (relative to this document's folder).
        func openWikiLink(target: String) {
            navigateToWikiLink(target: target, from: fileURL)
        }

        /// Accepts a non-empty selection (and optional source offsets). Empty
        /// updates are ignored so toolbar / Review ▸ + clicks keep the last range
        /// after WebKit collapses the selection on focus change.
        func updateCachedSelection(text: String, start: Int, end: Int) {
            guard !text.isEmpty else { return }
            cachedSelection = text
            if start >= 0, end > start {
                cachedStart = start
                cachedEnd = end
            } else if let content = document?.content,
                      let found = Self.locate(text, in: content, hint: cachedStart) {
                // DOM could not map offsets (rare / untagged node) — fall back
                // to locating the selected string in the markdown source so
                // Review marks still get a real quote+prefix+start anchor.
                cachedStart = found.location
                cachedEnd = NSMaxRange(found)
            } else {
                cachedStart = -1
                cachedEnd = -1
            }
            // Feed the IDE/review bridge (same path Source/Visual use). The
            // latest-non-empty snapshot survives the focus hop to Review ▸ +.
            if cachedStart >= 0, cachedEnd > cachedStart, let document {
                let range = NSRange(location: cachedStart, length: cachedEnd - cachedStart)
                let ns = document.content as NSString
                guard NSMaxRange(range) <= ns.length else { return }
                ClaudeIDEBridge.shared.noteSelection(
                    url: fileURL,
                    markdownRange: range,
                    markdown: document.content)
            }
        }

        /// Locate `text` in `content`, preferring a match near `hint` (last
        /// known source offset) so repeated words don't always pick the first.
        private static func locate(_ text: String, in content: String, hint: Int) -> NSRange? {
            let ns = content as NSString
            guard !text.isEmpty, ns.length > 0 else { return nil }
            if hint >= 0, hint < ns.length {
                let from = max(0, hint - 80)
                let near = ns.range(of: text, options: [],
                                    range: NSRange(location: from, length: ns.length - from))
                if near.location != NSNotFound { return near }
            }
            let global = ns.range(of: text)
            return global.location != NSNotFound ? global : nil
        }

        /// Copy the current page selection (cached — strip click clears WebKit
        /// selection). Beeps when nothing is selected.
        func copySelection() {
            let text = cachedSelection
            guard !text.isEmpty else { NSSound.beep(); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Wrap / unwrap the selected source range with markers (`==` / `~~`).
        /// Uses exact UTF-16 offsets from `data-md-lo/hi` — never a whole-file
        /// plain-text search (that only "inserted symbols" at the wrong place).
        func toggleWrap(open: String, close: String) {
            guard let document else { NSSound.beep(); return }
            guard cachedStart >= 0, cachedEnd > cachedStart else {
                NSSound.beep()
                return
            }
            let range = NSRange(location: cachedStart, length: cachedEnd - cachedStart)
            let ns = document.content as NSString
            guard NSMaxRange(range) <= ns.length else { NSSound.beep(); return }
            // Soft check: DOM text should match the source slice (entities /
            // soft breaks can diverge — still wrap the range if lengths match).
            guard let next = toggleWrapAtRange(in: document.content, range: range,
                                              open: open, close: close)
            else {
                NSSound.beep()
                return
            }
            cachedSelection = ""
            cachedStart = -1
            cachedEnd = -1
            let actionName: String
            switch open {
            case "==": actionName = "Highlight"
            case "~~": actionName = "Strikethrough"
            case "**": actionName = "Bold"
            case "*": actionName = "Italic"
            default: actionName = "Format"
            }
            document.commitContentEdit()
            document.applyUndoableContent(next, actionName: actionName)
        }

        /// Line-level transform for the lines covering the cached selection.
        /// For `.body` / heading toggles, a caret (empty selection) still works
        /// if we have a valid start offset from a previous selectionchange.
        func transformSelectionLines(_ transform: BlockTransform) {
            guard let document else { NSSound.beep(); return }
            let ns = document.content as NSString
            guard ns.length > 0 else { NSSound.beep(); return }

            let loc: Int
            let end: Int
            if cachedStart >= 0, cachedEnd >= cachedStart {
                loc = min(cachedStart, ns.length)
                end = min(max(cachedEnd, cachedStart), ns.length)
            } else if !cachedSelection.isEmpty {
                // Fallback: plain-text locate when data-md offsets were lost.
                let found = ns.range(of: cachedSelection)
                guard found.location != NSNotFound else { NSSound.beep(); return }
                loc = found.location
                end = NSMaxRange(found)
            } else {
                NSSound.beep()
                return
            }
            let lineRange = ns.lineRange(for: NSRange(location: loc,
                                                     length: max(0, end - loc)))
            let lines = ns.substring(with: lineRange)
            let replaced = transformLines(transform, lines: lines)
            guard replaced != lines else {
                // Already plain body — not an error.
                if transform == .body { return }
                NSSound.beep()
                return
            }
            let next = ns.replacingCharacters(in: lineRange, with: replaced)
            cachedSelection = ""
            cachedStart = -1
            cachedEnd = -1
            document.commitContentEdit()
            document.applyUndoableContent(next, actionName: "Format")
        }

        func fenceSelectionLines() {
            guard let document else { NSSound.beep(); return }
            guard cachedStart >= 0, cachedEnd >= cachedStart else {
                NSSound.beep()
                return
            }
            let ns = document.content as NSString
            let loc = min(cachedStart, ns.length)
            let end = min(cachedEnd, ns.length)
            let lineRange = ns.lineRange(for: NSRange(location: loc,
                                                     length: max(0, end - loc)))
            let lines = ns.substring(with: lineRange)
            let replaced = fenceLines(lines)
            let next = ns.replacingCharacters(in: lineRange, with: replaced)
            cachedSelection = ""
            cachedStart = -1
            cachedEnd = -1
            document.commitContentEdit()
            document.applyUndoableContent(next, actionName: "Code Block")
        }

        /// Jump: prefer an exact `data-md-lo` span (Review / outline in Preview),
        /// fall back to proportional scroll when the offset is untagged.
        @objc func jumpToStoredOffset() {
            guard let webView, let store = positionStore,
                  let content = lastRenderedContent else { return }
            let offset = min(store.markdownOffset, (content as NSString).length)
            let total = max(1, (content as NSString).length)
            let fraction = Double(offset) / Double(total)
            // scrollToMdOffset returns true when a tagged span was found.
            webView.evaluateJavaScript("window.scrollToMdOffset(\(offset))") { result, _ in
                let hit = (result as? Bool) ?? false
                if !hit {
                    webView.evaluateJavaScript(Self.scrollJS(fraction: fraction),
                                               completionHandler: nil)
                }
            }
        }

        private static func scrollJS(fraction: Double) -> String {
            "window.scrollTo(0, Math.max(0, "
                + "document.documentElement.scrollHeight * \(fraction) - window.innerHeight * 0.4));"
        }

        // MARK: Review-mark wash (Preview is the primary review surface)

        @objc func reviewMarksDidChange() {
            applyReviewHighlights()
        }

        /// Paints open-mark anchors onto `[data-md-lo]` spans via
        /// `window.applyReviewMarks`. No full HTML reload — marks change
        /// independently of the markdown body.
        func applyReviewHighlights() {
            guard let webView else { return }
            // Only the main-window active review file.
            guard fileURL?.standardizedFileURL == ReviewModel.shared.fileURL else {
                webView.evaluateJavaScript("window.applyReviewMarks && window.applyReviewMarks([])",
                                           completionHandler: nil)
                return
            }
            // Ranges come from ReviewModel's shared anchor cache (recomputed
            // off-main, debounced) — no per-notification text search on main.
            let marks = ReviewModel.shared.doc.marks.compactMap { m -> [String: Any]? in
                guard m.isOpen,
                      let range = ReviewModel.shared.anchor(for: m),
                      range.length > 0
                else { return nil }
                return [
                    "start": range.location,
                    "end": NSMaxRange(range),
                    "type": m.markType?.rawValue ?? m.type,
                    "id": m.id,
                    "tip": m.washTooltip,
                ]
            }
            // JSON for the page script (sorted worklist order already in doc.marks
            // filter order; first hit wins in applyReviewMarks).
            guard let data = try? JSONSerialization.data(withJSONObject: marks),
                  let json = String(data: data, encoding: .utf8)
            else { return }
            webView.evaluateJavaScript(
                "window.applyReviewMarks && window.applyReviewMarks(\(json))",
                completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Fresh DOM — re-paint review washes (loadHTMLString wipes classes).
            applyReviewHighlights()
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
    /// Document for ⌘Z / ⌘⇧Z while the web view is first responder.
    weak var documentForUndo: MarkdownDocument?

    override var undoManager: UndoManager? {
        documentForUndo?.contentUndoManager ?? super.undoManager
    }

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter
        if onReturnKey != nil, event.keyCode == 36 || event.keyCode == 76 {
            onReturnKey?()
            return
        }
        super.keyDown(with: event)
    }

    @objc func undo(_ sender: Any?) {
        documentForUndo?.performUndo()
    }

    @objc func redo(_ sender: Any?) {
        documentForUndo?.performRedo()
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

/// Streams `selectionchange` payloads `{text, start?, end?}` into the
/// coordinator so toolbar actions still see the range after the strip steals
/// focus.
@MainActor
private final class PreviewSelectionHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            let text = body["text"] as? String ?? ""
            let start = (body["start"] as? NSNumber)?.intValue
                ?? (body["start"] as? Int)
                ?? -1
            let end = (body["end"] as? NSNumber)?.intValue
                ?? (body["end"] as? Int)
                ?? -1
            coordinator?.updateCachedSelection(text: text, start: start, end: end)
            return
        }
        // Legacy plain-string messages — text only, no offsets.
        if let text = message.body as? String {
            coordinator?.updateCachedSelection(text: text, start: -1, end: -1)
        }
    }
}
