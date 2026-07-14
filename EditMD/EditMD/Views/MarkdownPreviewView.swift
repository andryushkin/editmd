import SwiftUI
import AppKit
import WebKit
import Combine

/// Deterministic revision/throttle state for live Preview updates. Rendering
/// and WebKit stay in the Coordinator; this value type is intentionally pure
/// so latest-only and heavy-document timing can be unit-tested.
struct PreviewRenderScheduler {
    struct Request: Equatable, Sendable {
        let revision: UInt64
        let content: String
    }

    static let normalInterval: TimeInterval = 0.09
    static let heavyInterval: TimeInterval = 0.25

    private(set) var requestedRevision: UInt64 = 0
    private(set) var startedRevision: UInt64 = 0
    private(set) var appliedRevision: UInt64 = 0
    private(set) var requestedContent: String?
    private(set) var lastStartedAt = Date.distantPast

    @discardableResult
    mutating func request(_ content: String, force: Bool = false) -> UInt64? {
        guard force || requestedContent != content else { return nil }
        requestedRevision &+= 1
        requestedContent = content
        return requestedRevision
    }

    func delay(heavy: Bool, now: Date = Date()) -> TimeInterval {
        let interval = heavy ? Self.heavyInterval : Self.normalInterval
        return max(0, interval - now.timeIntervalSince(lastStartedAt))
    }

    mutating func startLatest(now: Date = Date()) -> Request? {
        guard requestedRevision > startedRevision, let requestedContent else { return nil }
        startedRevision = requestedRevision
        lastStartedAt = now
        return Request(revision: requestedRevision, content: requestedContent)
    }

    /// Revisions land strictly forward: a result that lost the race to a newer
    /// one is dropped, and the same revision is never applied twice.
    @discardableResult
    mutating func markApplied(_ request: Request) -> Bool {
        guard request.revision > appliedRevision else { return false }
        appliedRevision = request.revision
        return true
    }

    var hasPendingRequest: Bool { requestedRevision > startedRevision }
}

enum PreviewShellUpdatePolicy {
    static func requiresFullReload(hasMath: Bool, shellHasMathAssets: Bool) -> Bool {
        hasMath && !shellHasMathAssets
    }
}

private struct PreviewFragmentRequest: Sendable {
    let scheduled: PreviewRenderScheduler.Request
    let baseDir: URL?
    let gutter: PreviewGutterOptions
    let syntaxHighlighting: Bool
}

private struct PreviewFragmentResult: Sendable {
    let scheduled: PreviewRenderScheduler.Request
    let body: String
    let hasMath: Bool
}

/// Thread-safe data-URI cache. A live fragment render must not read and
/// base64-encode every local image again at 90 ms intervals.
///
/// NSCache, not a dictionary: it is byte-bounded and purged under memory
/// pressure. Base64 of the 8 MB inline cap is ~10.7 MB per image, so a plain
/// 64-entry map would pin ~680 MB for the life of the process.
private final class PreviewImageDataCache: @unchecked Sendable {
    static let shared = PreviewImageDataCache()

    /// A resolved image: its data: URI, or nil when the file is missing,
    /// unreadable, or over the inline cap. **Misses are cached too** — an
    /// oversized image whose failure isn't remembered gets read from disk in
    /// full on every fragment render, i.e. ~11 times a second while typing.
    private final class Entry {
        let modificationDate: Date?
        let fileSize: Int?
        let dataURI: String?

        init(modificationDate: Date?, fileSize: Int?, dataURI: String?) {
            self.modificationDate = modificationDate
            self.fileSize = fileSize
            self.dataURI = dataURI
        }
    }

    private let cache = NSCache<NSString, Entry>()

    private init() {
        cache.totalCostLimit = 64_000_000
    }

    func dataURI(for url: URL, mime: String, maximumBytes: Int) -> String? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate
        let size = values?.fileSize
        let key = url.path as NSString
        if let cached = cache.object(forKey: key),
           cached.modificationDate == date, cached.fileSize == size {
            return cached.dataURI
        }

        var uri: String?
        // The size is already in hand from the stat above: an oversized file is
        // rejected without ever reading its bytes.
        if size == nil || size! <= maximumBytes,
           let data = try? Data(contentsOf: url), data.count <= maximumBytes {
            uri = "data:\(mime);base64,\(data.base64EncodedString())"
        }
        cache.setObject(Entry(modificationDate: date, fileSize: size, dataURI: uri),
                        forKey: key, cost: uri?.utf8.count ?? 1)
        return uri
    }
}

/// Read-only rendered preview: full-window in Preview mode, or the right
/// pane of the editor+preview split. Local images are inlined as data:
/// URIs — WKWebView does not grant file:// subresource access to HTML loaded
/// via loadHTMLString, and unsaved documents have no base directory anyway.
///
/// Live updates render a latest-only HTML fragment off-main and replace the
/// persistent page's `#preview-content`. Full WebKit navigation is reserved for
/// the first load, CSS/settings changes, KaTeX activation and recovery.
struct MarkdownPreviewView: NSViewRepresentable {

    let document: MarkdownDocument
    let fileURL: URL?
    var positionStore: EditorPositionStore? = nil
    /// Full-preview mode only: Return switches back to editing (FSNotes).
    var onRequestEdit: (() -> Void)? = nil
    /// Optional strip bridge (full Preview mode). Coordinator installs
    /// format closures on make + update.
    var toolbarActions: EditorStripActions? = nil
    /// Inline styles uniformly active at the Preview caret/selection.
    var onActiveFormats: ((ActiveInlineFormats) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let coordinator = context.coordinator
        // Task checkboxes in the page report their index here; the controller
        // retains its handlers strongly, so the handler holds the coordinator
        // weakly to avoid a retain cycle.
        let userContentController = WKUserContentController()
        userContentController.add(TaskToggleHandler(coordinator: coordinator),
                                  name: "taskToggle")
        userContentController.add(BuiltInPluginToggleHandler(coordinator: coordinator),
                                  name: "builtInPluginToggle")
        userContentController.add(WikiLinkClickHandler(coordinator: coordinator),
                                  name: "wikiLinkClick")
        userContentController.add(LocalLinkClickHandler(coordinator: coordinator),
                                  name: "localLinkClick")
        userContentController.add(PreviewSelectionHandler(coordinator: coordinator),
                                  name: "previewSelection")
        userContentController.add(PreviewScrollHandler(coordinator: coordinator),
                                  name: "previewScroll")
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
                  if (!sel || sel.rangeCount === 0) {
                    window.webkit.messageHandlers.previewSelection.postMessage({text: '', formats: {}});
                    return;
                  }
                  var range = sel.getRangeAt(0);
                  function enclosing(node, tags) {
                    var n = node && node.nodeType === 3 ? node.parentElement : node;
                    while (n && n !== document.body) {
                      if (tags.indexOf(n.tagName) >= 0) return n;
                      n = n.parentElement;
                    }
                    return null;
                  }
                  function uniform(tags) {
                    var owner = enclosing(range.startContainer, tags);
                    return !!owner && (sel.isCollapsed || owner.contains(range.endContainer));
                  }
                  var formats = {
                    strikethrough: uniform(['DEL', 'S']),
                    highlight: uniform(['MARK'])
                  };
                  if (sel.isCollapsed) {
                    window.webkit.messageHandlers.previewSelection.postMessage({
                      text: '', formats: formats
                    });
                    return;
                  }
                  var text = sel.toString();
                  var a = mdEl(range.startContainer);
                  var b = mdEl(range.endContainer);
                  // Code islands: offsets into rendered code don't match source.
                  if (!a || !b
                      || a.getAttribute('data-md-code') === '1'
                      || b.getAttribute('data-md-code') === '1') {
                    window.webkit.messageHandlers.previewSelection.postMessage({
                      text: text, start: -1, end: -1, formats: formats
                    });
                    return;
                  }
                  var loA = parseInt(a.getAttribute('data-md-lo'), 10);
                  var loB = parseInt(b.getAttribute('data-md-lo'), 10);
                  if (isNaN(loA) || isNaN(loB)) {
                    window.webkit.messageHandlers.previewSelection.postMessage({
                      text: text, start: -1, end: -1, formats: formats
                    });
                    return;
                  }
                  // a and b may differ (selection spans inline runs / lines).
                  var start = loA + utf16OffsetIn(a, range.startContainer, range.startOffset);
                  var end = loB + utf16OffsetIn(b, range.endContainer, range.endOffset);
                  if (end < start) { var t = start; start = end; end = t; }
                  window.webkit.messageHandlers.previewSelection.postMessage({
                    text: text, start: start, end: end, formats: formats
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
        coordinator.onActiveFormats = onActiveFormats
        coordinator.fileURL = fileURL
        coordinator.reverseScrollEnabled = onRequestEdit == nil
        coordinator.bindToolbar(toolbarActions)
        bindRenderCallbacks(to: coordinator)
        coordinator.observe(document: document)
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
            // D5: editor→preview scroll follow (no Source selection side-effect).
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.followEditorScroll),
                name: .editMDPreviewScrollSync,
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
        _ = coordinator.scheduler.request(document.content, force: true)
        if let initial = coordinator.scheduler.startLatest() {
            loadFullPage(initial, in: webView, coordinator: coordinator)
        }
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
        coordinator.onActiveFormats = onActiveFormats
        coordinator.fileURL = fileURL
        coordinator.reverseScrollEnabled = onRequestEdit == nil
        coordinator.bindToolbar(toolbarActions)
        bindRenderCallbacks(to: coordinator)
        coordinator.observe(document: document)
        (webView as? PreviewWebView)?.onReturnKey = onRequestEdit
        (webView as? PreviewWebView)?.documentForUndo = document
        // A coordinator can be reused while the split turns into full Preview.
        // In that mode manual WebKit scrolling must win on later reloads.
        if onRequestEdit != nil {
            coordinator.lastFollowedPosition = nil
            coordinator.pendingFragmentFollowPosition = nil
        }
        if coordinator.scheduler.request(document.content) != nil {
            scheduleNextRender(coordinator: coordinator)
        }
    }

    /// The coordinator outlives any single `MarkdownPreviewView` value, so it
    /// reaches back into the current one through these. Bound from both
    /// `makeNSView` and `updateNSView` — one place, so the two can't drift.
    private func bindRenderCallbacks(to coordinator: Coordinator) {
        coordinator.scheduleLatest = { [weak coordinator] in
            guard let coordinator else { return }
            self.scheduleNextRender(coordinator: coordinator)
        }
        coordinator.rerender = { [weak coordinator] in
            guard let coordinator else { return }
            self.forceFullReload(coordinator: coordinator)
        }
    }

    private func gutterOptions() -> PreviewGutterOptions {
        let g = EditorSettings.shared.gutter
        let dirtyHex = g.dirtyMarkColorHex ?? g.dirtyMarkNSColor.hexString
        return PreviewGutterOptions(
            showLineNumbers: g.showLineNumbers,
            highlightChangedLines: g.highlightChangedLines,
            showDirtyBulletsWhenNoNumbers: g.showDirtyBulletsWhenNoNumbers,
            dirtyLines: LineChangeTracker.shared.dirtyLines(for: fileURL),
            dirtyMarkColorHex: dirtyHex
        )
    }

    private func fullPageRender(for content: String) -> PreviewPageRender {
        let baseDir = assetBaseDir
        let settings = EditorSettings.shared.preview
        let general = EditorSettings.shared.general
        return previewHTMLPageRender(
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
            gutter: gutterOptions(),
            syntaxHighlighting: general.syntaxHighlighting,
            imageResolver: { Self.dataURI(for: $0, baseDir: baseDir) }
        )
    }

    private func makeFragmentRequest(_ scheduled: PreviewRenderScheduler.Request)
        -> PreviewFragmentRequest {
        PreviewFragmentRequest(
            scheduled: scheduled,
            baseDir: assetBaseDir,
            gutter: gutterOptions(),
            syntaxHighlighting: EditorSettings.shared.general.syntaxHighlighting
        )
    }

    private func scheduleNextRender(coordinator: Coordinator) {
        guard coordinator.renderTask == nil, coordinator.shellReady,
              !coordinator.shellLoading, coordinator.scheduler.hasPendingRequest
        else { return }
        let wait = coordinator.scheduler.delay(heavy: document.isHeavy)
        // Every exit — including cancellation — must release the slot and pick
        // up whatever queued behind it, or one stray return wedges Preview for
        // the rest of the session. The generation stamp is what makes that safe:
        // a task cancelled and replaced by a newer one must not clear the newer
        // one's registration when it finally unwinds.
        coordinator.renderGeneration &+= 1
        let generation = coordinator.renderGeneration
        coordinator.renderTask = Task { @MainActor [weak coordinator] in
            defer {
                if let coordinator, coordinator.renderGeneration == generation {
                    coordinator.renderTask = nil
                    coordinator.scheduleLatest?()
                }
            }
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, let coordinator, coordinator.shellReady,
                  !coordinator.shellLoading,
                  let scheduled = coordinator.scheduler.startLatest()
            else { return }
            let request = makeFragmentRequest(scheduled)
            let result = await Task.detached(priority: .userInitiated) {
                Self.renderFragment(request)
            }.value
            guard !Task.isCancelled else { return }
            await applyFragment(result, coordinator: coordinator)
        }
    }

    nonisolated private static func renderFragment(_ request: PreviewFragmentRequest)
        -> PreviewFragmentResult {
        let rendered = markdownHTMLRender(
            request.scheduled.content,
            imageResolver: { dataURI(for: $0, baseDir: request.baseDir) },
            gutter: request.gutter,
            syntaxHighlighting: request.syntaxHighlighting
        )
        return PreviewFragmentResult(scheduled: request.scheduled,
                                     body: rendered.body,
                                     hasMath: rendered.hasMath)
    }

    private func applyFragment(_ result: PreviewFragmentResult,
                               coordinator: Coordinator) async {
        guard let webView = coordinator.webView else { return }
        if PreviewShellUpdatePolicy.requiresFullReload(
            hasMath: result.hasMath,
            shellHasMathAssets: coordinator.shellHasMathAssets) {
            loadFullPage(result.scheduled, in: webView, coordinator: coordinator)
            return
        }
        // Editor-follow is a one-shot instruction. Once the scroll gesture has
        // landed, ordinary typing preserves Preview's exact pixel viewport;
        // replaying the last semantic anchor on every character causes a nudge.
        let position: Any = coordinator.pendingFragmentFollowPosition
            .map { NSNumber(value: $0) } ?? NSNull()
        coordinator.pendingFragmentFollowPosition = nil
        // The page function is synchronous, so this answers on the next hop. The
        // watchdog is the backstop: a bridge that never answers (a wedged web
        // process, a promise nothing settles) must not hold the single render
        // slot forever — that is exactly how Preview froze on the first edit.
        let watchdog = Task { @MainActor [weak coordinator] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let coordinator else { return }
            forceFullReload(coordinator: coordinator)
        }
        defer { watchdog.cancel() }
        do {
            let applied = try await webView.callAsyncJavaScript(
                "return window.editMDReplacePreview({html: html, revision: revision, position: position});",
                arguments: [
                    "html": result.body,
                    "revision": NSNumber(value: result.scheduled.revision),
                    "position": position,
                ],
                in: nil,
                contentWorld: .page
            )
            guard !Task.isCancelled else { return }
            guard (applied as? Bool) == true else {
                forceFullReload(coordinator: coordinator)
                return
            }
            if coordinator.scheduler.markApplied(result.scheduled) {
                coordinator.lastRenderedContent = result.scheduled.content
            }
            coordinator.applyReviewHighlights()
        } catch {
            guard !Task.isCancelled else { return }
            // A stale/missing/hung JS shell must never leave Preview frozen.
            // Rebuild it; didFinish resumes the latest queued revision.
            forceFullReload(coordinator: coordinator)
        }
    }


    private func forceFullReload(coordinator: Coordinator) {
        guard let webView = coordinator.webView else { return }
        coordinator.renderTask?.cancel()
        // Retire the slot's generation as well: a task abandoned here (one stuck
        // in an unanswered JS call) must not clear its successor's registration
        // if it ever unwinds.
        coordinator.renderGeneration &+= 1
        coordinator.renderTask = nil
        _ = coordinator.scheduler.request(document.content, force: true)
        guard let scheduled = coordinator.scheduler.startLatest() else { return }
        loadFullPage(scheduled, in: webView, coordinator: coordinator)
    }

    private func loadFullPage(_ scheduled: PreviewRenderScheduler.Request,
                              in webView: WKWebView,
                              coordinator: Coordinator) {
        coordinator.shellLoading = true
        coordinator.shellReady = false
        coordinator.pendingShellRequest = scheduled
        // The capability bit comes from the page that was actually built, never
        // from a second scan of the markdown (see `PreviewPageRender`).
        let render = fullPageRender(for: scheduled.content)
        coordinator.shellHasMathAssets = render.hasMathAssets
        let load = {
            // A superseded navigation must not be mistaken for this one:
            // stopLoading fails it, and that failure arrives with no shell
            // navigation on record, so the delegate ignores it.
            coordinator.shellNavigation = nil
            webView.stopLoading()
            coordinator.hasRenderedOnce = true
            coordinator.shellNavigation = webView.loadHTMLString(render.html, baseURL: nil)
        }
        if coordinator.hasRenderedOnce {
            webView.evaluateJavaScript("window.editMDCurrentScrollPosition && window.editMDCurrentScrollPosition()") {
                value, _ in
                coordinator.pendingScrollPosition = (value as? NSNumber)?.doubleValue
                load()
            }
        } else {
            if let store = positionStore {
                let total = max(1, (scheduled.content as NSString).length)
                coordinator.pendingScrollFraction =
                    Double(min(store.markdownOffset, total)) / Double(total)
            }
            load()
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

    nonisolated private static let maxInlineImageBytes = 8_000_000

    /// data: URI for a relative local image path, or nil to keep the original
    /// source (remote URLs, anchors, unknown types, oversized/missing files).
    nonisolated static func dataURI(for source: String, baseDir: URL?) -> String? {
        guard !source.hasPrefix("#"), URL(string: source)?.scheme == nil,
              let baseDir else { return nil }
        let path = source.removingPercentEncoding ?? source
        let fileURL = baseDir.appendingPathComponent(path).standardizedFileURL
        guard let mime = supportedImageMIMETypes[fileURL.pathExtension.lowercased()]
        else { return nil }
        return PreviewImageDataCache.shared.dataURI(
            for: fileURL, mime: mime, maximumBytes: maxInlineImageBytes)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var onActiveFormats: ((ActiveInlineFormats) -> Void)?
        weak var toolbarActions: EditorStripActions?
        var positionStore: EditorPositionStore?
        var document: MarkdownDocument?
        private weak var observedDocument: MarkdownDocument?
        private var documentChangeObservation: AnyCancellable?
        var fileURL: URL?
        /// Content currently present in the DOM. Scroll math must never use a
        /// requested-but-not-yet-applied revision.
        var lastRenderedContent: String?
        var scheduler = PreviewRenderScheduler()
        var renderTask: Task<Void, Never>?
        /// Stamps the task holding the render slot, so a cancelled predecessor
        /// unwinding late cannot clear its successor's registration.
        var renderGeneration: UInt64 = 0
        var hasRenderedOnce = false
        var shellReady = false
        var shellLoading = false
        var shellHasMathAssets = false
        var pendingShellRequest: PreviewRenderScheduler.Request?
        /// The shell navigation in flight. didFinish / didFail must ignore any
        /// other navigation — a superseded load failing is not this load failing.
        var shellNavigation: WKNavigation?
        /// Guards the retry-on-failed-load path against a reload loop.
        var shellReloadAttempts = 0
        static let maxShellReloadAttempts = 3
        var scheduleLatest: (() -> Void)?
        /// Forces a full re-render (font size changes: same content,
        /// different CSS).
        var rerender: (() -> Void)?
        /// Proportional scroll target from the shared position store (first
        /// render only).
        var pendingScrollFraction: Double?
        /// Logical markdown position captured before a rare shell reload.
        var pendingScrollPosition: Double?
        /// Latest editor viewport anchor. When set (split mode), logical
        /// markdown alignment wins over a stale pixel value after a reload.
        var lastFollowedPosition: Double?
        /// One-shot semantic restore for a fragment that races an editor scroll.
        /// Normal content edits leave this nil and preserve exact Preview pixels.
        var pendingFragmentFollowPosition: Double?
        var reverseScrollEnabled = false
        /// Last usable selection from the page. Empty selectionchange events
        /// do NOT clear this (strip click collapses the WebKit selection).
        var cachedSelection: String = ""
        /// UTF-16 range in the markdown source (`data-md-lo`…`data-md-hi`).
        /// `-1` means offsets unknown (copy still works; wrap beeps).
        var cachedStart: Int = -1
        var cachedEnd: Int = -1

        deinit {
            renderTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        /// `NSViewRepresentable.updateNSView` is not a reliable transport for
        /// edits originating in an AppKit text delegate: SwiftUI may coalesce
        /// the enclosing view's invalidation while that delegate/layout pass is
        /// still in flight. Observe the model at the coordinator boundary too,
        /// then read the new value on the next main-loop turn (the publisher is
        /// objectWillChange, so a synchronous read would still see the old one).
        func observe(document: MarkdownDocument) {
            self.document = document
            guard observedDocument !== document else { return }
            observedDocument = document
            documentChangeObservation = document.objectWillChange.sink {
                [weak self, weak document] _ in
                DispatchQueue.main.async {
                    guard let self, let document,
                          self.observedDocument === document else { return }
                    if self.scheduler.request(document.content) != nil {
                        self.scheduleLatest?()
                    }
                }
            }
        }

        /// Installs strip callbacks on the shared actions object (if any).
        /// Does NOT call `objectWillChange` — this runs from `updateNSView` during
        /// SwiftUI view updates; publishing here freezes the app (feedback loop).
        func bindToolbar(_ actions: EditorStripActions?) {
            toolbarActions = actions
            guard let actions else { return }
            actions.toggleHighlight = { [weak self] in
                self?.toggleSelectionMarkers(open: "==", close: "==",
                                             actionName: "Highlight")
            }
            actions.toggleStrikethrough = { [weak self] in
                self?.toggleSelectionMarkers(open: "~~", close: "~~",
                                             actionName: "Strikethrough")
            }
            // Preview is deliberately review-only. Clear callbacks installed
            // by Source/Visual so stale editing actions cannot survive a mode
            // switch even though the strip itself hides their buttons.
            actions.toggleBold = nil
            actions.toggleItalic = nil
            actions.toggleCodeSpan = nil
            actions.setHeading = nil
            actions.setBody = nil
            actions.toggleCodeBlock = nil
            actions.toggleBulletList = nil
            actions.toggleChecklist = nil
            actions.toggleNumberedList = nil
            actions.toggleQuote = nil
            actions.insertImage = nil
            actions.clearInlineFormatting = nil
            actions.cycleCase = nil
            actions.insertDivider = nil
            actions.insertTable = nil
            actions.tableAddRow = nil
            actions.tableDeleteRow = nil
            actions.insertInlineFormula = nil
            actions.insertBlockFormula = nil
        }

        @objc func settingsDidChange() {
            rerender?()
        }

        /// A task checkbox was clicked in the page: flip the matching
        /// `[ ]`/`[x]` in the markdown source. The DOM already shows the new
        /// state; the throttled fragment update that follows is a visual no-op.
        func toggleTask(at index: Int) {
            guard let document,
                  let toggled = toggleTaskListItem(in: document.content, index: index)
            else { return }
            document.commitContentEdit()
            document.applyUndoableContent(toggled, actionName: "Toggle Task")
        }

        /// A compiled-in plugin token was clicked. Source offsets make the
        /// operation deterministic across list, prose and table renderers.
        func toggleBuiltInPlugin(at offset: Int) {
            guard let document,
                  let toggled = BuiltInPluginRegistry.cycleToken(
                      in: document.content, at: offset)
            else { return }
            document.commitContentEdit()
            document.applyUndoableContent(toggled, actionName: "Cycle Status")
        }

        /// A wiki-link was clicked in the page: resolve its target and open the
        /// file (relative to this document's folder).
        func openWikiLink(target: String) {
            navigateToWikiLink(target: target, from: fileURL)
        }

        /// A schemeless `[text](path)` link was clicked: resolve vault-absolute
        /// or file-relative and open (markdown/PDF in EditMD, rest system).
        func openLocalLink(href: String) {
            openMarkdownLink(destination: href, from: fileURL)
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

        func updateActiveFormats(_ formats: ActiveInlineFormats) {
            onActiveFormats?(formats)
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

        /// Apply/remove one of the two review-friendly Preview formats.
        /// Uses exact UTF-16 offsets from `data-md-lo/hi` — never a whole-file
        /// plain-text search (that only "inserted symbols" at the wrong place).
        func toggleSelectionMarkers(open: String, close: String, actionName: String) {
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
            document.commitContentEdit()
            document.applyUndoableContent(next, actionName: actionName)
        }

        /// Jump: prefer an exact `data-md-lo` span (Review / outline in Preview),
        /// fall back to proportional scroll when the offset is untagged.
        @objc func jumpToStoredOffset() {
            guard let store = positionStore else { return }
            scroll(toMarkdownOffset: store.markdownOffset)
        }

        /// D5: split-mode scroll follow reads its own transport field so a
        /// passive scroll never rewrites the caret (`markdownOffset`).
        @objc func followEditorScroll() {
            guard let store = positionStore else { return }
            lastFollowedPosition = store.previewScrollPosition
            pendingFragmentFollowPosition = store.previewScrollPosition
            scroll(toMarkdownPosition: store.previewScrollPosition)
        }

        /// The page pushes this once per frame of a user scroll (programmatic
        /// scrolls are flagged JS-side and never reported), so the editor gets
        /// every frame of the gesture instead of whatever a round trip per wheel
        /// event could keep up with.
        func previewDidScroll(_ payload: [String: Any]) {
            guard reverseScrollEnabled, let store = positionStore else { return }
            lastFollowedPosition = nil
            pendingFragmentFollowPosition = nil
            let length = lastRenderedContent.map { ($0 as NSString).length } ?? 0
            if let edge = payload["edge"] as? String {
                store.requestEditorScroll(
                    toMarkdownPosition: edge == "top" ? 0 : Double(length))
            } else if let position = (payload["position"] as? NSNumber)?.doubleValue {
                store.requestEditorScroll(toMarkdownPosition: position)
            }
        }

        /// Split follow: a fractional markdown offset, aligned to the viewport's
        /// bottom edge (the edges themselves are UX invariants — the start of the
        /// document must be fully visible when the editor is at zero, and both
        /// panes must reach the end together).
        private func scroll(toMarkdownPosition target: Double) {
            guard let webView, let content = lastRenderedContent else { return }
            let length = (content as NSString).length
            if target <= 0 {
                webView.evaluateJavaScript("window.syncScrollToEdge('top')",
                                           completionHandler: nil)
                return
            }
            if target >= Double(length) {
                webView.evaluateJavaScript("window.syncScrollToEdge('bottom')",
                                           completionHandler: nil)
                return
            }
            let fallback = Double(min(target, Double(length))) / Double(max(1, length))
            webView.evaluateJavaScript("window.syncScrollToMdPosition(\(target))") { result, _ in
                let hit = (result as? Bool) ?? false
                if !hit {
                    webView.evaluateJavaScript(Self.syncScrollJS(fraction: fallback),
                                               completionHandler: nil)
                }
            }
        }

        /// Navigation jump (outline, review card): centre + flash, unlike the
        /// split follow, which aligns to the bottom edge and never animates.
        private func scroll(toMarkdownOffset target: Int) {
            guard let webView, let content = lastRenderedContent else { return }
            let offset = min(target, (content as NSString).length)
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

        private static func syncScrollJS(fraction: Double) -> String {
            "window.scrollTo(0, Math.max(0, "
                + "(document.documentElement.scrollHeight - window.innerHeight) * \(fraction)));"
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
            // Ignore a navigation we did not start (or one already superseded);
            // with none on record, the page in front of the user is ours anyway.
            if let current = shellNavigation, navigation !== current { return }
            shellNavigation = nil
            shellLoading = false
            shellReady = true
            shellReloadAttempts = 0
            if let loaded = pendingShellRequest {
                pendingShellRequest = nil
                if scheduler.markApplied(loaded) {
                    lastRenderedContent = loaded.content
                }
                webView.evaluateJavaScript(
                    "window.editMDPreviewRevision = \(loaded.revision)",
                    completionHandler: nil)
            }
            // Fresh shell — re-paint review washes (loadHTMLString wipes classes).
            applyReviewHighlights()
            if let position = lastFollowedPosition {
                pendingScrollPosition = nil
                scroll(toMarkdownPosition: position)
            } else if let position = pendingScrollPosition {
                pendingScrollPosition = nil
                scroll(toMarkdownPosition: position)
            } else if let fraction = pendingScrollFraction, fraction > 0.001 {
                pendingScrollFraction = nil
                webView.evaluateJavaScript(Self.scrollJS(fraction: fraction))
            }
            // Content edits received while loadHTMLString was navigating stayed
            // in scheduler.requestedContent and are rendered only into this DOM.
            scheduleLatest?()
        }

        // A shell that fails to load leaves `shellLoading` pinned, and every
        // later fragment render is gated behind it — Preview would freeze for
        // the rest of the session with nothing to un-stick it. (Before the
        // persistent shell, each render simply issued its own loadHTMLString,
        // so a failure healed itself.) Retry a bounded number of times.
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            handleShellLoadFailure(navigation)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            handleShellLoadFailure(navigation)
        }

        private func handleShellLoadFailure(_ navigation: WKNavigation!) {
            guard let current = shellNavigation, navigation === current else { return }
            shellNavigation = nil
            shellLoading = false
            shellReady = false
            pendingShellRequest = nil
            guard shellReloadAttempts < Self.maxShellReloadAttempts else { return }
            shellReloadAttempts += 1
            let rerender = rerender
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                rerender?()
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            shellReady = false
            shellLoading = false
            shellHasMathAssets = false
            hasRenderedOnce = false
            shellNavigation = nil
            shellReloadAttempts = 0
            pendingShellRequest = nil
            pendingScrollPosition = nil
            pendingScrollFraction = nil
            lastRenderedContent = nil
            rerender?()
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

/// Bridges clicks from compiled-in plugin widgets. The payload is an original
/// markdown UTF-16 offset, verified again before the source is changed.
@MainActor
private final class BuiltInPluginToggleHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let offset = message.body as? Int else { return }
        coordinator?.toggleBuiltInPlugin(at: offset)
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

/// Bridges clicks on schemeless local links (`[pdf](/research_pdf/x.pdf)`) to
/// the coordinator. Held strongly by WKUserContentController, hence the weak
/// coordinator reference.
@MainActor
private final class LocalLinkClickHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let href = body["href"] as? String, !href.isEmpty else { return }
        coordinator?.openLocalLink(href: href)
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
            if let raw = body["formats"] as? [String: Any] {
                func flag(_ key: String) -> Bool {
                    (raw[key] as? NSNumber)?.boolValue ?? (raw[key] as? Bool) ?? false
                }
                coordinator?.updateActiveFormats(ActiveInlineFormats(
                    strikethrough: flag("strikethrough"),
                    highlight: flag("highlight")))
            }
            coordinator?.updateCachedSelection(text: text, start: start, end: end)
            return
        }
        // Legacy plain-string messages — text only, no offsets.
        if let text = message.body as? String {
            coordinator?.updateCachedSelection(text: text, start: -1, end: -1)
        }
    }
}

/// Split-mode reverse follow: the page pushes its bottom-edge anchor once per
/// frame of a user scroll. Programmatic scrolls are flagged in JS, so an
/// editor→Preview follow can never come back as a Preview→editor scroll.
private final class PreviewScrollHandler: NSObject, WKScriptMessageHandler {
    weak var coordinator: MarkdownPreviewView.Coordinator?

    init(coordinator: MarkdownPreviewView.Coordinator) {
        self.coordinator = coordinator
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { coordinator?.previewDidScroll(payload) }
    }
}
