import AppKit
import SwiftUI

// Visual (WYSIWYG) mode — v21. NSTextView with isRichText=true showing the
// marker-free attributed model from MarkdownToAttributed.swift. Every edit
// serializes synchronously back to document.content (AttributedToMarkdown),
// so saves and mode switches always see current markdown.
//
// Semantics (block kinds, inline styles) live in the custom md.* attributes;
// fonts/colors/indents are DERIVED by applyPresentation(). Markers (bullets,
// numbers, checkboxes, quote bars, code panels) are drawn in drawBackground —
// they are not text.

// MARK: - SwiftUI wrapper

struct VisualMarkdownView: NSViewRepresentable {

    let document: MarkdownDocument
    var theme: EditorTheme = .editorDefault
    var fileURL: URL? = nil
    var positionStore: EditorPositionStore? = nil
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void
    /// B6: active md.inline styles at caret.
    var onActiveFormats: ((ActiveInlineFormats) -> Void)? = nil
    /// Left edge of the text (incl. the reserved gutter margin) — the action
    /// strip and the gutter toggle line up with it.
    var onTextLeading: ((CGFloat) -> Void)? = nil

    /// Room the numbers need beside the text — reserved whether or not they're
    /// shown, so toggling them doesn't move the column.
    private var gutterReserve: CGFloat {
        GutterMetrics.reserve(lineCountHint: max(1, countDiffLines(document.content)))
    }

    /// Reading inset, widened so the numbers fit in the left margin.
    private func readingInset(forWidth width: CGFloat) -> NSSize {
        let inset = EditorSettings.shared.visual.textContainerInset(forWidth: width)
        return NSSize(width: max(inset.width, gutterReserve), height: inset.height)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = VisualNSTextView()
        textView.isRichText = true
        // Document-scoped undo — survives mode switches (see MarkdownDocument).
        textView.allowsUndo = false
        textView.usesFontPanel = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.backgroundColor = NSColor.textBackgroundColor
        // Accept image drops on top of the view's own drag types; non-image
        // drops still fall through to the default handling.
        textView.registerForDraggedTypes(
            Array(Set(textView.registeredDraggedTypes + imageDragPasteboardTypes)))
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = readingInset(forWidth: scrollView.contentView.bounds.width)
        // Large documents: lay out only the ranges TextKit needs, not the whole
        // storage up front (Apple's recommended big-document win).
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.theme = theme
        // Edit ▸ Find menu (⌘F & co.) drives the standard find bar; replaces
        // go through shouldChangeTextIn, so island/table guards still apply.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.wikiCompletion = coordinator.wikiCompletion
        coordinator.wikiCompletion.attach(to: textView)
        coordinator.loadDocument()
        coordinator.publishActions()
        coordinator.refreshGutter()
        coordinator.wikiCompletion.update(fileURL: fileURL)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollOrBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.lineMarksDidChange),
            name: .lineChangeMarksDidChange,
            object: nil)
        // A big code block highlighted off main — repaint from the warmed cache.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.codeHighlightingDidWarm),
            name: .codeHighlightingDidWarm,
            object: nil)
        // Outline-sidebar jumps, object-scoped to this window's store (a nil
        // object would subscribe to every window's jumps).
        if let store = positionStore {
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.jumpToStoredOffset),
                name: .editMDJumpToOffset,
                object: store)
        }
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)
        // Claude `openFile` reveal (see SourceTextView for the mount rationale).
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.applyClaudeReveal),
            name: .claudeIDERevealRequested,
            object: nil)
        coordinator.applyClaudeReveal()
        // Review-mark anchor wash (v37) — plainText quote search in display.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.reviewMarksDidChange),
            name: .reviewMarksDidChange,
            object: nil)
        coordinator.applyReviewHighlights()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        let nextInset = readingInset(forWidth: scrollView.contentView.bounds.width)
        let insetChanged = textView.textContainerInset != nextInset
        if insetChanged { textView.textContainerInset = nextInset }
        if textView.theme.name != theme.name {
            textView.theme = theme
            coordinator.applyPresentation()
            return
        }
        // External change (Revert, or another window editing the shared
        // document). A background window defers the re-render until it becomes
        // key so its cursor/scroll survive edits made elsewhere.
        if !coordinator.isInternalUpdate, document.content != coordinator.lastSerialized {
            if textView.window?.isKeyWindow ?? true {
                coordinator.loadDocument()
            } else {
                coordinator.pendingExternalReload = true
            }
        }
        coordinator.refreshGutter()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: VisualMarkdownView
        weak var textView: VisualNSTextView?
        var isInternalUpdate = false
        var lastSerialized = ""
        /// A background window sets this when the shared document changes under
        /// it; the re-render is applied when the window next becomes key.
        var pendingExternalReload = false
        var isMutating = false
        /// setAttributedString during (re)load resets the selection; the
        /// callback must not clobber the cross-mode cursor store.
        private var isLoadingDocument = false
        /// Row append / row delete / table rebuild restructure tables legally —
        /// bypass the cell-integrity guard in shouldChangeTextIn.
        var isProgrammaticTableEdit = false
        /// Display-paragraph → markdown-range map from the last serialization.
        private var lastParagraphRanges: [NSRange] = []
        /// Display-buffer ranges paired by index with `lastParagraphRanges`.
        private var lastDisplayParagraphRanges: [NSRange] = []
        /// Gutter source lines from the load-time render (exact for documents
        /// not in normal form); nil once the document adopts the serialized
        /// normal form — from then on the serialize-based map is exact.
        private var gutterSourceLinesFromRender: [Int]?
        /// One NSTextAttachment per image source — reused across presentation
        /// passes so layout doesn't churn on every keystroke.
        var imageAttachments: [String: NSTextAttachment] = [:]
        /// Configuration/state lookup from the last document load. Frontmatter
        /// changes are rare, so presentation reuses this snapshot until the
        /// serialized frontmatter source itself changes.
        var builtInPluginSnapshot: BuiltInPluginSnapshot = .empty
        private var builtInPluginFrontmatter: String?
        /// The document's verbatim frontmatter block (both fences, no trailing
        /// newline) from the last load. Visual does not render frontmatter —
        /// the Properties inspector owns it — so serialization re-attaches
        /// this block (`composeDocumentWithFrontmatter`). Refreshed on every
        /// loadDocument, which runs for any edit Visual did not originate.
        private var frontmatterBlock: String?

        var visualStyle: VisualStyle {
            let settings = EditorSettings.shared.visual
            return VisualStyle(baseSize: settings.fontSize,
                               bodyFamily: settings.fontFamily,
                               bodyWeight: settings.fontWeight.nsWeight,
                               elements: settings.elements)
        }

        /// Wiki `[[` autocomplete (plan 03). Disabled inside code/table/raw.
        lazy var wikiCompletion = WikiCompletionController(
            apply: { [weak self] tv, range, replacement in
                self?.applyWikiCompletion(tv, range: range, replacement: replacement)
            },
            allowsCompletion: { [weak self] tv in
                self?.visualAllowsWikiCompletion(tv) ?? false
            })

        init(parent: VisualMarkdownView) {
            self.parent = parent
        }

        func visualAllowsWikiCompletion(_ tv: NSTextView) -> Bool {
            guard let storage = tv.textStorage else { return true }
            let loc = min(tv.selectedRange().location, max(0, storage.length - 1))
            guard storage.length > 0 else { return true }
            let kind = (storage.attribute(.mdBlock, at: loc, effectiveRange: nil) as? MDBlock)?.kind
                ?? .paragraph
            return visualContextAllowsStructuredPaste(kind)
        }

        func applyWikiCompletion(_ textView: NSTextView, range: NSRange, replacement: String) {
            guard textView.shouldChangeText(in: range, replacementString: replacement)
            else { return }
            isMutating = true
            textView.textStorage?.replaceCharacters(in: range, with: replacement)
            isMutating = false
            textView.didChangeText()
            let end = range.location + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func loadDocument(pluginSnapshot providedPluginSnapshot: BuiltInPluginSnapshot? = nil,
                          restoreCursorAfterLoad: Bool = true) {
            guard let textView, let storage = textView.textStorage else { return }
            textView.finishActiveTableEditing(commit: true)
            isLoadingDocument = true
            let source = parent.document.content
            let pluginSnapshot = providedPluginSnapshot
                ?? BuiltInPluginRegistry.snapshot(for: source)
            builtInPluginSnapshot = pluginSnapshot
            builtInPluginFrontmatter = builtInPluginFrontmatterSource(in: source)
            frontmatterBlock = frontmatterRange(in: source).map {
                (source as NSString).substring(with: $0.full)
            }
            let rendered = renderMarkdownToAttributedDetailed(
                source, style: visualStyle, pluginSnapshot: pluginSnapshot)
            storage.setAttributedString(rendered.attributed)
            lastSerialized = parent.document.content
            let serialized = serializeStorageWithFrontmatter(storage)
            lastParagraphRanges = serialized.paragraphRanges
            lastDisplayParagraphRanges = serialized.displayParagraphRanges
            // Serialize-based ranges live in the buffer's NORMAL form; a fresh
            // file may not be in it (lazy quotes, …), which skews the gutter's
            // source lines. Until the first sync rewrites the document, map
            // display paragraphs through the renderer's exact source offsets.
            gutterSourceLinesFromRender = displayToSourceLineMap(
                paragraphRanges: rendered.paragraphSourceStarts.map {
                    NSRange(location: $0, length: 0)
                },
                markdown: source)
            textView.typingAttributes = defaultTypingAttributes()
            applyPresentation()
            updateStats()
            applyReviewHighlights()
            isLoadingDocument = false
            if restoreCursorAfterLoad { restoreCursor() }
        }

        /// Serializes the storage and re-attaches the frontmatter block that
        /// Visual does not display. Paragraph ranges shift past the prefix so
        /// every display ↔ markdown map stays in document coordinates.
        private func serializeStorageWithFrontmatter(_ storage: NSTextStorage)
            -> MarkdownSerialization {
            let detailed = serializeAttributedToMarkdownDetailed(
                storage, pluginSnapshot: builtInPluginSnapshot)
            guard let frontmatterBlock, !frontmatterBlock.isEmpty else { return detailed }
            let markdown = composeDocumentWithFrontmatter(frontmatterBlock,
                                                          body: detailed.markdown)
            let shift = (markdown as NSString).length
                - (detailed.markdown as NSString).length
            let ranges = detailed.paragraphRanges.map {
                NSRange(location: $0.location + shift, length: $0.length)
            }
            return MarkdownSerialization(
                markdown: markdown,
                paragraphRanges: ranges,
                displayParagraphRanges: detailed.displayParagraphRanges
            )
        }

        // MARK: Review-mark anchors (v37)

        @objc func reviewMarksDidChange() {
            applyReviewHighlights()
        }

        /// Temporary background wash: search each open mark's `quote` in the
        /// display plain text (WYSIWYG has no markdown markers). Runs on the
        /// model's debounced recompute notification, not per keystroke.
        func applyReviewHighlights() {
            guard let textView else { return }
            // Heavy docs skip the O(n × marks) quote search — same gate as Source.
            guard !parent.document.isHeavy else {
                ReviewHighlight.apply(to: textView, highlights: [])
                return
            }
            guard parent.fileURL?.standardizedFileURL == ReviewModel.shared.fileURL
            else {
                ReviewHighlight.apply(to: textView, highlights: [])
                return
            }
            let marks = ReviewModel.shared.openMarksForDisplaySearch()
            // Hints translate raw-markdown starts into display coordinates —
            // a raw hint overshoots (display text is shorter) and could wash
            // a later duplicate of the quote.
            let highlights = ReviewHighlight.displayHighlights(
                marks: marks, displayText: textView.string,
                hintForRawOffset: { [weak self] raw in
                    self?.displayLocation(forMarkdownOffset: raw)
                })
            ReviewHighlight.apply(to: textView, highlights: highlights)
        }

        /// Applies a deferred external change once the window regains focus (see
        /// updateNSView's background-window gate).
        @objc func windowBecameKey(_ note: Notification) {
            guard pendingExternalReload, let tv = textView,
                  (note.object as? NSWindow) === tv.window else { return }
            pendingExternalReload = false
            loadDocument()
        }

        // MARK: Split scroll sync (paragraph-indexed, like Preview's anchors)

        // MARK: Cursor continuity across modes

        /// (display paragraph index, its start offset) for a text location.
        private func paragraphIndex(at location: Int, in nsText: NSString) -> (index: Int, start: Int) {
            var index = 0, start = 0
            var i = 0
            let limit = min(location, nsText.length)
            while i < limit {
                if nsText.character(at: i) == 0x0A {
                    index += 1
                    start = i + 1
                }
                i += 1
            }
            return (index, start)
        }

        /// Display offset → markdown offset, through the serializer's paragraph
        /// map (v22). Visual's text has no markers, so the block's markdown
        /// prefix ("# ", "- [x] ", "> " …) is added back here.
        func markdownOffset(atDisplayLocation location: Int) -> Int? {
            guard let textView, let storage = textView.textStorage,
                  !lastParagraphRanges.isEmpty else { return nil }
            let nsText = textView.string as NSString
            let (index, start) = paragraphIndex(at: location, in: nsText)
            guard index < lastParagraphRanges.count else { return nil }
            let mdRange = lastParagraphRanges[index]
            let blockValue = block(at: NSRange(location: start, length: 0), in: storage)
            let prefixLength = markdownPrefixLength(for: blockValue)
            return min(mdRange.location + prefixLength + (location - start),
                       NSMaxRange(mdRange))
        }

        func storeCursor() {
            guard !isLoadingDocument, let textView else { return }
            let selection = textView.selectedRange()
            guard let start = markdownOffset(atDisplayLocation: selection.location)
            else { return }
            parent.positionStore?.markdownOffset = start
            noteSelectionForClaude(selection: selection, mappedStart: start)
        }

        /// Selection for Claude IDE *and* review-mark anchors (v37). Both ends
        /// go through the paragraph map — never the display text. Always stored
        /// on the bridge (review needs it even when no `/ide` client is
        /// attached); MCP `selection_changed` no-ops when nobody is connected.
        ///
        /// Mapping the selection END costs an O(offset) paragraph-map scan, so
        /// non-empty selections settle behind a short debounce — a drag no
        /// longer pays the scan on every tick (Review ▸ + and Claude both read
        /// the bridge much later than 150 ms).
        private var selectionNoteTask: Task<Void, Never>?

        private func noteSelectionForClaude(selection: NSRange, mappedStart: Int) {
            selectionNoteTask?.cancel()
            guard selection.length > 0 else {
                forwardSelectionToBridge(start: mappedStart, end: mappedStart)
                return
            }
            selectionNoteTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled, let self else { return }
                let end = self.markdownOffset(atDisplayLocation: NSMaxRange(selection))
                    ?? mappedStart
                self.forwardSelectionToBridge(start: mappedStart, end: end)
            }
        }

        private func forwardSelectionToBridge(start: Int, end: Int) {
            ClaudeIDEBridge.shared.noteSelection(
                url: parent.fileURL,
                markdownRange: NSRange(location: start, length: max(0, end - start)),
                markdown: parent.document.content)
        }

        /// Claude's `openFile` reveal. Visual places the caret at the mapped
        /// source offset; it does not extend the selection — display ranges and
        /// source ranges are not the same span.
        @objc func applyClaudeReveal() {
            guard let range = ClaudeIDEBridge.shared.takeReveal(for: parent.fileURL),
                  let store = parent.positionStore else { return }
            store.markdownOffset = range.location
            restoreCursor()
        }

        /// Outline-sidebar jump: `restoreCursor` maps the store's markdown
        /// offset through the paragraph map, so the cursor lands correctly
        /// even though Visual's display text differs from the source.
        @objc func jumpToStoredOffset() {
            restoreCursor()
        }

        /// Markdown offset → display offset (inverse of
        /// `markdownOffset(atDisplayLocation:)`), through the paragraph map.
        func displayLocation(forMarkdownOffset target: Int) -> Int? {
            guard let textView, let storage = textView.textStorage,
                  !lastParagraphRanges.isEmpty else { return nil }
            var index = 0
            var within = 0
            for (i, range) in lastParagraphRanges.enumerated() where range.location <= target {
                index = i
                within = target - range.location
            }
            // Paragraph start in the display text.
            let nsText = textView.string as NSString
            var start = 0, seen = 0, end = nsText.length
            var i = 0
            while i < nsText.length {
                if nsText.character(at: i) == 0x0A {
                    if seen == index { end = i; break }
                    seen += 1
                    start = i + 1
                }
                i += 1
            }
            let blockValue = block(at: NSRange(location: start, length: 0), in: storage)
            within = max(0, within - markdownPrefixLength(for: blockValue))
            return min(start + within, end)
        }

        private func restoreCursor() {
            guard let store = parent.positionStore,
                  let cursor = displayLocation(forMarkdownOffset: store.markdownOffset),
                  let textView else { return }
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
                textView.centerSelectionInVisibleArea(nil)
                textView.window?.makeFirstResponder(textView)
            }
        }

        private func defaultTypingAttributes() -> [NSAttributedString.Key: Any] {
            [
                .font: visualStyle.font(for: [], blockKind: .paragraph),
                .foregroundColor: NSColor.labelColor,
                .mdBlock: MDBlock(kind: .paragraph),
            ]
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            // Load path: setAttributedString can notify; must not rewrite the
            // markdown (would inject trailing newlines / normalize without edit — C4).
            guard !isMutating, !isLoadingDocument else { return }
            // Phase-timed: the Visual path serializes synchronously, so a heavy
            // keystroke usually shows up in the "serialize" phase (see
            // TypingProfiler).
            var profiler = KeystrokeProfiler(.visual)
            // NB: runAutoformat can re-enter textDidChange; that nested cycle is
            // timed under this outer "autoformat" phase, so a fat autoformat
            // number may be the re-entrant edit, not formatting itself.
            profiler.phase("autoformat") { runAutoformat() }
            let reloaded = profiler.phase("serialize") { syncToDocument() }
            profiler.phase("presentation") { if !reloaded { applyPresentation() } }
            profiler.phase("notify") {
                parent.document.noteContentEdited()
                DocumentRegistry.shared.noteUserEdit(parent.fileURL)
                // The caret's markdown offset disambiguates a duplicate-line
                // insertion (same as Source) — without it the dirty mark can
                // land on an identical untouched neighbour. Paragraph-start
                // precision is enough: the tracker only needs the caret's LINE.
                LineChangeTracker.shared.noteContent(
                    url: parent.fileURL, content: parent.document.content,
                    caretUTF16Offset: caretMarkdownOffset())
            }
            profiler.phase("stats") { updateStats() }
            // Review wash re-aligns via the model's debounced recompute
            // notification — no per-keystroke quote search here.
            profiler.phase("gutter") { refreshGutter() }
            profiler.phase("wiki") { wikiCompletion.update(fileURL: parent.fileURL) }
            profiler.finish()
            restoreMinorViewportDrift()
        }

        /// Restore only a layout-sized nudge. A real caret-follow scroll (new
        /// line near the viewport edge) is much larger and must remain intact.
        private func restoreMinorViewportDrift() {
            defer { viewportOriginBeforeEdit = nil }
            guard let original = viewportOriginBeforeEdit,
                  let scroll = textView?.enclosingScrollView else { return }
            let clip = scroll.contentView
            let current = clip.bounds.origin
            let drift = current.y - original.y
            guard SplitScrollSync.isMinorLayoutDrift(drift) else { return }

            var proposed = clip.bounds
            proposed.origin.y = original.y
            let constrained = clip.constrainBoundsRect(proposed)
            // Near the bottom, deletion can make the old origin invalid. That
            // clamp is real geometry, not jitter, so do not fight AppKit.
            guard abs(constrained.origin.y - original.y) <= 0.5 else { return }
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
        }

        /// Visual gutter shows **source** line numbers (via paragraph→md map), not 1…N of the WYSIWYG buffer.
        func refreshGutter() {
            guard let textView else { return }
            let md = parent.document.content
            textView.gutterState = GutterState(
                settings: EditorSettings.shared.gutter,
                dirtySourceLines: LineChangeTracker.shared.dirtyLines(for: parent.fileURL),
                // Visual shows SOURCE line numbers: paragraphs → markdown lines.
                displayToSourceLine: gutterSourceLinesFromRender
                    ?? displayToSourceLineMap(paragraphRanges: lastParagraphRanges,
                                              markdown: md))
            textView.needsDisplay = true
            reportTextLeading(textView.textContainerInset.width)
        }

        /// The strip lines its tools up with the text. Reported async: this runs
        /// from `updateNSView`, and writing SwiftUI state there warns.
        private func reportTextLeading(_ leading: CGFloat) {
            guard abs(lastTextLeading - leading) > 0.5 else { return }
            lastTextLeading = leading
            let report = parent.onTextLeading
            DispatchQueue.main.async { report?(leading) }
        }

        private var lastTextLeading: CGFloat = -1
        /// Viewport before AppKit mutates a Visual line. Inline presentation can
        /// change that line's metrics by a fraction of a point; keep such tiny
        /// layout corrections from showing up as a screen twitch.
        private var viewportOriginBeforeEdit: NSPoint?
        @objc func scrollOrBoundsChanged(_ note: Notification) {
            textView?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep custom attrs out of typing attributes only where harmful:
            // links must not extend as the user types after them.
            // Guard: setAttributedString fires selection sync (v22).
            guard !isMutating, let textView else { return }
            var attrs = textView.typingAttributes
            if attrs[.mdLink] != nil || attrs[.mdImage] != nil || attrs[.mdWikiLink] != nil
                || attrs[.mdBuiltInPluginToken] != nil || attrs[.mdMathTex] != nil {
                attrs[.mdLink] = nil
                attrs[.mdImage] = nil
                attrs[.mdWikiLink] = nil
                // Token/formula runs serialize their PAYLOAD, not their text —
                // typed characters merging into such a run would be dropped or
                // reattached to the wrong occurrence.
                attrs[.mdBuiltInPluginToken] = nil
                attrs[.mdMathTex] = nil
                textView.typingAttributes = attrs
            }
            storeCursor()
            publishActiveFormats()
            textView.updateCaretLinkAffordance()
            wikiCompletion.update(fileURL: parent.fileURL)
        }

        /// nil until the first publish — the first computed value must always
        /// emit, even when it equals the default (it overrides whatever a
        /// previous mode left in the shared state).
        private var lastPublishedFormats: ActiveInlineFormats?

        private func publishActiveFormats() {
            guard let textView, let storage = textView.textStorage else { return }
            let sel = textView.selectedRange()
            let length = storage.length
            guard length > 0 else {
                emitFormats(ActiveInlineFormats())
                return
            }
            let loc = min(sel.location, length - 1)
            var fmt = ActiveInlineFormats()
            if sel.length == 0 {
                // Prefer typingAttributes at caret (covers empty run boundaries).
                let styles = MDInlineStyle(rawValue: textView.typingAttributes[.mdInline] as? Int ?? 0)
                fmt.bold = styles.contains(.bold)
                fmt.italic = styles.contains(.italic)
                fmt.code = styles.contains(.code)
                fmt.strikethrough = styles.contains(.strike)
                fmt.highlight = styles.contains(.highlight)
                // Also sample char under caret for truth when typing attrs lag.
                let sample = MDInlineStyle(rawValue: storage.attribute(.mdInline, at: loc, effectiveRange: nil) as? Int ?? 0)
                if sample.contains(.bold) { fmt.bold = true }
                if sample.contains(.italic) { fmt.italic = true }
                if sample.contains(.code) { fmt.code = true }
                if sample.contains(.strike) { fmt.strikethrough = true }
                if sample.contains(.highlight) { fmt.highlight = true }
            } else {
                var allBold = true, allItalic = true, allCode = true, allStrike = true
                var allHighlight = true
                var any = false
                storage.enumerateAttribute(.mdInline, in: sel) { value, _, _ in
                    any = true
                    let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
                    if !styles.contains(.bold) { allBold = false }
                    if !styles.contains(.italic) { allItalic = false }
                    if !styles.contains(.code) { allCode = false }
                    if !styles.contains(.strike) { allStrike = false }
                    if !styles.contains(.highlight) { allHighlight = false }
                }
                if any {
                    fmt.bold = allBold
                    fmt.italic = allItalic
                    fmt.code = allCode
                    fmt.strikethrough = allStrike
                    fmt.highlight = allHighlight
                }
            }
            let paragraphs = selectedParagraphs()
            if !paragraphs.isEmpty {
                let blocks = paragraphs.map { block(at: $0, in: storage) }
                let levels = blocks.compactMap { b -> Int? in
                    if case .heading(let level) = b.kind { return level }
                    return nil
                }
                if levels.count == blocks.count, Set(levels).count == 1 {
                    fmt.headingLevel = levels[0]
                }
                fmt.bulletList = blocks.allSatisfy { if case .bulletItem = $0.kind { true } else { false } }
                fmt.numberedList = blocks.allSatisfy { if case .orderedItem = $0.kind { true } else { false } }
                fmt.checklist = allBlocksAreChecklists(blocks)
                fmt.quote = blocks.allSatisfy { $0.quoteDepth > 0 }
                fmt.codeBlock = blocks.allSatisfy { if case .codeBlock = $0.kind { true } else { false } }
            }
            emitFormats(fmt)
        }

        private func emitFormats(_ fmt: ActiveInlineFormats) {
            guard fmt != lastPublishedFormats else { return }
            lastPublishedFormats = fmt
            let callback = parent.onActiveFormats
            DispatchQueue.main.async { [weak self] in
                // A publish queued by an outgoing editor must not land after
                // the mode switch reset the shared state (review fix).
                guard self?.textView?.window != nil else { return }
                callback?(fmt)
            }
        }

        func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            // Capture before TextKit mutates/layouts the line so a tiny Visual
            // presentation drift can be restored after the edit.
            viewportOriginBeforeEdit = view.enclosingScrollView?.contentView.bounds.origin
            // Capture document baseline before any mutation (incl. table row ops).
            parent.document.beginContentEdit()
            guard !isProgrammaticTableEdit, let storage = view.textStorage else { return true }
            let nsText = storage.string as NSString
            guard nsText.length > 0 else { return true }
            var allowed = true
            let probe = affectedRange.length == 0
                ? NSRange(location: min(affectedRange.location, max(0, nsText.length - 1)), length: min(1, nsText.length))
                : affectedRange
            storage.enumerateAttribute(.mdBlock, in: probe) { value, range, stop in
                guard let block = value as? MDBlock else { return }
                switch block.kind {
                // Islands are read-only unless the change swallows them whole.
                case .raw:
                    let paragraph = nsText.paragraphRange(for: range)
                    if affectedRange.location > paragraph.location
                        || NSMaxRange(affectedRange) < NSMaxRange(paragraph) {
                        allowed = false
                        stop.pointee = true
                    }
                // Table cells: edits stay inside one cell's text (its trailing
                // \n is structure), or replace the entire table.
                case .tableCell:
                    let paragraph = nsText.paragraphRange(for: range)
                    var cellTextEnd = NSMaxRange(paragraph)
                    if cellTextEnd > paragraph.location,
                       nsText.character(at: cellTextEnd - 1) == 0x0A {
                        cellTextEnd -= 1
                    }
                    let insideCell = affectedRange.location >= paragraph.location
                        && NSMaxRange(affectedRange) <= cellTextEnd
                    if insideCell {
                        if replacementString?.contains("\n") == true {
                            allowed = false
                            stop.pointee = true
                        }
                        return
                    }
                    let whole = self.tableRange(group: block.group, in: storage)
                    if affectedRange.location <= whole.location
                        && NSMaxRange(affectedRange) >= NSMaxRange(whole) {
                        return
                    }
                    allowed = false
                    stop.pointee = true
                default:
                    break
                }
            }
            return allowed
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline()
            case #selector(NSResponder.insertTab(_:)):
                return handleTableTab(forward: true) || changeIndent(by: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleTableTab(forward: false) || changeIndent(by: -1)
            case #selector(NSResponder.deleteBackward(_:)):
                return handleDeleteBackward()
            default:
                return false
            }
        }

        // MARK: Block helpers

        func paragraphRange(at location: Int, in nsText: NSString) -> NSRange {
            nsText.paragraphRange(for: NSRange(location: min(location, nsText.length), length: 0))
        }

        func block(at paragraph: NSRange, in storage: NSTextStorage) -> MDBlock {
            let index = min(paragraph.location, max(0, storage.length - 1))
            guard storage.length > 0 else { return MDBlock(kind: .paragraph) }
            return storage.attribute(.mdBlock, at: index, effectiveRange: nil) as? MDBlock
                ?? MDBlock(kind: .paragraph)
        }

        /// Restamps a paragraph's block kind (undoable attribute-only change).
        func restamp(_ paragraph: NSRange, to newBlock: MDBlock,
                             in textView: VisualNSTextView) {
            guard let storage = textView.textStorage else { return }
            guard textView.shouldChangeText(in: paragraph, replacementString: nil) else { return }
            isMutating = true
            storage.beginEditing()
            let stampRange = paragraph.length > 0 ? paragraph
                : NSRange(location: paragraph.location,
                          length: min(1, storage.length - paragraph.location))
            if stampRange.length > 0 {
                storage.addAttribute(.mdBlock, value: newBlock, range: stampRange)
                // enumerateAttributes (not just .mdInline): plain runs have no
                // .mdInline key, so enumerateAttribute skipped them and left the
                // old heading-sized font after demoting to body.
                storage.enumerateAttributes(in: stampRange) { attrs, range, _ in
                    let styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
                    storage.addAttribute(.font,
                                         value: self.visualStyle.font(for: styles, blockKind: newBlock.kind),
                                         range: range)
                }
            }
            storage.endEditing()
            isMutating = false
            textView.didChangeText()
            var attrs = textView.typingAttributes
            attrs[.mdBlock] = newBlock
            attrs[.font] = visualStyle.font(for: [], blockKind: newBlock.kind)
            textView.typingAttributes = attrs
            afterMutation()
        }

        func afterMutation() {
            let reloaded = syncToDocument()
            if !reloaded { applyPresentation() }
            updateStats()
        }

        /// Visual paste: a clipboard table (HTML from web/Word/Excel, or TSV)
        /// becomes a real table; recognizable Markdown renders through the same
        /// semantic renderer used when opening a document; everything else
        /// keeps NSTextView's plain-text fallback (return false).
        func pasteMarkdownFromPasteboard() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let pasteboard = NSPasteboard.general
            let plain = pasteboard.string(forType: .string)
            let selection = textView.selectedRange()
            let blockKind = pasteBlockKindAtSelection() ?? .paragraph
            // Literal/raw/table contexts keep the ordinary plain-text path.
            guard visualContextAllowsStructuredPaste(blockKind) else { return false }

            var markdown: String?
            markdown = markdownTableFromPasteboard(
                html: pasteboard.string(forType: .html), plain: plain)
            if markdown == nil, let plain, shouldFormatVisualPaste(plain, in: blockKind) {
                markdown = plain
            }
            guard let markdown else { return false }
            let rendered = renderForInsertion(markdown, into: storage)
            guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
            else { return true }
            isMutating = true
            storage.replaceCharacters(in: selection, with: rendered)
            isMutating = false
            textView.didChangeText()
            let caret = selection.location + rendered.length
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            afterMutation()
            return true
        }

        /// Renders a bare-URL clipboard as a link: over a selection the selection
        /// becomes the label (`[text](url)`); with no selection it inserts a
        /// `<url>` autolink (a plain bare URL would not render as a link).
        /// Returns false — so plain paste runs — for a non-URL clipboard or a
        /// literal/table context.
        func pasteURLLinkFromPasteboard() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let url = bareWebURLForPaste(NSPasteboard.general.string(forType: .string))
            else { return false }
            let selection = textView.selectedRange()
            let blockKind = pasteBlockKindAtSelection() ?? .paragraph
            guard visualContextAllowsStructuredPaste(blockKind) else { return false }

            let markdown: String
            if selection.length > 0 {
                let selected = (storage.string as NSString).substring(with: selection)
                guard selectionUsableAsLinkLabel(selected) else { return false }
                markdown = markdownLinkSyntax(text: selected, url: url)
            } else {
                markdown = markdownAutolinkSyntax(url: url)
            }
            let rendered = renderForInsertion(markdown, into: storage)
            guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
            else { return true }
            isMutating = true
            storage.replaceCharacters(in: selection, with: rendered)
            isMutating = false
            textView.didChangeText()
            let caret = selection.location + rendered.length
            textView.setSelectedRange(NSRange(location: caret, length: 0))
            afterMutation()
            return true
        }

        /// Markdown offset (paragraph start) for the display caret, via the
        /// display-paragraph → markdown-range map refreshed by the sync that
        /// just ran. Nil when the map is out of step — the tracker then simply
        /// skips caret disambiguation (old behavior).
        private func caretMarkdownOffset() -> Int? {
            guard let textView,
                  lastDisplayParagraphRanges.count == lastParagraphRanges.count,
                  !lastDisplayParagraphRanges.isEmpty else { return nil }
            let caret = min(textView.selectedRange().location,
                            (textView.string as NSString).length)
            var lo = 0
            var hi = lastDisplayParagraphRanges.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lastDisplayParagraphRanges[mid].location <= caret {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return lastParagraphRanges[lo].location
        }

        /// Semantic block under the Visual selection, shared by every paste
        /// door so their context guards cannot drift apart.
        func pasteBlockKindAtSelection() -> MDBlock.Kind? {
            guard let textView, let storage = textView.textStorage,
                  storage.length > 0 else { return nil }
            let probe = min(textView.selectedRange().location, storage.length - 1)
            return (storage.attribute(.mdBlock, at: probe, effectiveRange: nil) as? MDBlock)?.kind
                ?? .paragraph
        }

        // MARK: Enter

        private func handleNewline() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            let paragraph = paragraphRange(at: selection.location, in: nsText)
            let current = block(at: paragraph, in: storage)

            // Table: Enter moves down a column; on an all-empty last row it
            // removes that row and exits below the table.
            if case .tableCell(let row, let column, _, _) = current.kind {
                let cells = tableCells(group: current.group, in: storage)
                let rows = (cells.map(\.row).max() ?? 0) + 1
                let lastRowCells = cells.filter { $0.row == rows - 1 }
                let lastRowEmpty = lastRowCells.allSatisfy {
                    var text = nsText.substring(with: $0.range)
                    if text.hasSuffix("\n") { text.removeLast() }
                    return text.isEmpty
                }
                if row == rows - 1 {
                    if lastRowEmpty && rows > 2 {
                        // Exit: drop the empty row, add a paragraph after the table.
                        deleteTableRow(row, group: current.group)
                        let tableEnd = NSMaxRange(tableRange(group: current.group, in: storage))
                        insertParagraph(at: tableEnd)
                    } else if let newRow = appendTableRow(group: current.group) {
                        moveCursor(toCell: (newRow, column), group: current.group)
                    }
                } else {
                    moveCursor(toCell: (row + 1, column), group: current.group)
                }
                return true
            }

            var paragraphText = nsText.substring(with: paragraph)
            if paragraphText.hasSuffix("\n") { paragraphText.removeLast() }

            // "```lang" + Enter → empty code block.
            if case .paragraph = current.kind, paragraphText.hasPrefix("```") {
                let language = String(paragraphText.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                let textRange = NSRange(location: paragraph.location,
                                        length: paragraphText.utf16.count)
                guard textView.shouldChangeText(in: textRange, replacementString: "") else { return true }
                isMutating = true
                storage.replaceCharacters(in: textRange, with: "")
                isMutating = false
                textView.didChangeText()
                var block = current
                block.kind = .codeBlock(language: language)
                block.group = uniqueGroup(in: storage)
                restamp(paragraphRange(at: paragraph.location, in: storage.string as NSString),
                        to: block, in: textView)
                return true
            }

            let isEmpty = paragraphText.isEmpty
            let continuation = continuationKind(after: current.kind)

            // Empty structured paragraph + Enter → exit the structure.
            if isEmpty, continuation != nil {
                var plain = current
                plain.kind = .paragraph
                plain.group = -1
                restamp(paragraph, to: plain, in: textView)
                return true
            }

            guard case .raw = current.kind else {
                // Insert the newline, then stamp the NEW paragraph when its
                // kind differs from what it inherits.
                let newBlockKind: MDBlock.Kind?
                let atEnd = selection.location >= NSMaxRange(paragraph)
                    - (nsText.length > 0 && paragraph.length > 0
                       && nsText.character(at: NSMaxRange(paragraph) - 1) == 0x0A ? 1 : 0)
                switch current.kind {
                case .heading:
                    newBlockKind = atEnd ? MDBlock.Kind.paragraph : nil
                case .bulletItem, .orderedItem, .taskItem, .builtInPluginTaskItem:
                    newBlockKind = continuation
                default:
                    newBlockKind = nil
                }

                guard textView.shouldChangeText(in: selection, replacementString: "\n") else { return true }
                isMutating = true
                var newlineAttrs = textView.typingAttributes
                // Leaving a heading: next paragraph is plain — stamp body font
                // on the newline so typingAttributes don't keep the big heading
                // face (C3).
                if case .heading = current.kind, atEnd {
                    newlineAttrs = defaultTypingAttributes()
                } else {
                    newlineAttrs[.mdBlock] = current
                }
                storage.replaceCharacters(in: selection,
                                          with: NSAttributedString(string: "\n", attributes: newlineAttrs))
                isMutating = false
                textView.didChangeText()
                let cursor = selection.location + 1
                textView.setSelectedRange(NSRange(location: cursor, length: 0))

                if let kind = newBlockKind {
                    var newBlock = current
                    newBlock.kind = kind
                    if case .paragraph = kind { newBlock.group = -1 }
                    let newParagraph = paragraphRange(at: cursor, in: storage.string as NSString)
                    restamp(newParagraph, to: newBlock, in: textView)
                    if case .paragraph = kind {
                        textView.typingAttributes = defaultTypingAttributes()
                    }
                } else {
                    afterMutation()
                }
                return true
            }
            return true  // Enter inside an island: ignored
        }

        /// Inserts an empty plain paragraph at `location` and puts the cursor there.
        private func insertParagraph(at location: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let insertRange = NSRange(location: min(location, storage.length), length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: "\n") else { return }
            isMutating = true
            storage.replaceCharacters(in: insertRange, with: NSAttributedString(
                string: "\n", attributes: defaultTypingAttributes()))
            isMutating = false
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: insertRange.location, length: 0))
            textView.typingAttributes = defaultTypingAttributes()
            afterMutation()
        }

        // MARK: Tab / Backspace

        private func changeIndent(by delta: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let paragraph = paragraphRange(at: textView.selectedRange().location, in: nsText)
            let current = block(at: paragraph, in: storage)
            guard let newKind = indentedKind(current.kind, by: delta) else { return false }
            var newBlock = current
            newBlock.kind = newKind
            restamp(paragraph, to: newBlock, in: textView)
            return true
        }

        private func handleDeleteBackward() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let selection = textView.selectedRange()
            guard selection.length == 0 else { return false }
            let nsText = storage.string as NSString
            let paragraph = paragraphRange(at: selection.location, in: nsText)
            guard selection.location == paragraph.location else { return false }
            let current = block(at: paragraph, in: storage)
            switch current.kind {
            case .tableCell(let row, let column, let columns, _):
                // Never merge cells: hop to the end of the previous cell.
                let rows = (tableCells(group: current.group, in: storage).map(\.row).max() ?? 0) + 1
                if let previous = nextTableCellPosition(row: row, column: column,
                                                        columns: columns, rows: rows,
                                                        forward: false) {
                    moveCursor(toCell: previous, group: current.group)
                }
                return true
            case .bulletItem, .orderedItem, .taskItem, .builtInPluginTaskItem:
                // Backspace at item start: outdent, then flatten to paragraph.
                if let outdented = indentedKind(current.kind, by: -1) {
                    var newBlock = current
                    newBlock.kind = outdented
                    restamp(paragraph, to: newBlock, in: textView)
                } else {
                    var plain = current
                    plain.kind = .paragraph
                    plain.group = -1
                    restamp(paragraph, to: plain, in: textView)
                }
                return true
            case .heading:
                var plain = current
                plain.kind = .paragraph
                restamp(paragraph, to: plain, in: textView)
                return true
            default:
                return false
            }
        }

        // MARK: Autoformat

        private func runAutoformat() {
            guard let textView, let storage = textView.textStorage else { return }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            guard selection.length == 0, selection.location > 0 else { return }
            // Trigger only right after a space.
            guard nsText.character(at: selection.location - 1) == 0x20 else { return }
            let paragraph = paragraphRange(at: selection.location, in: nsText)
            let current = block(at: paragraph, in: storage)
            var text = nsText.substring(with: paragraph)
            if text.hasSuffix("\n") { text.removeLast() }
            guard let (kind, consumed) = autoformatKind(for: text, currentKind: current.kind),
                  selection.location == paragraph.location + consumed else { return }

            let prefixRange = NSRange(location: paragraph.location, length: consumed)
            guard textView.shouldChangeText(in: prefixRange, replacementString: "") else { return }
            isMutating = true
            storage.replaceCharacters(in: prefixRange, with: "")
            isMutating = false
            textView.didChangeText()

            var newBlock = current
            newBlock.kind = kind
            if newBlock.group < 0 { newBlock.group = uniqueGroup(in: storage) }
            restamp(paragraphRange(at: paragraph.location, in: storage.string as NSString),
                    to: newBlock, in: textView)
        }

        func uniqueGroup(in storage: NSTextStorage) -> Int {
            var maxGroup = 0
            storage.enumerateAttribute(.mdBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let block = value as? MDBlock {
                    maxGroup = max(maxGroup, block.group)
                    maxGroup = max(maxGroup, block.quoteGroup)
                }
            }
            return maxGroup + 1
        }

        // MARK: Sync

        @discardableResult
        private func syncToDocument() -> Bool {
            guard let storage = textView?.textStorage else { return false }
            let detailed = serializeStorageWithFrontmatter(storage)
            lastParagraphRanges = detailed.paragraphRanges
            lastDisplayParagraphRanges = detailed.displayParagraphRanges
            gutterSourceLinesFromRender = nil
            var serialized = detailed.markdown
            // Single trailing newline (POSIX text files). Do not append a second
            // one when the serializer already ended with \n — that grew blank
            // lines on every Visual edit cycle (C4).
            if !serialized.isEmpty, !serialized.hasSuffix("\n") {
                serialized += "\n"
            }
            let pluginConfigurationChanged = refreshBuiltInPluginSnapshot(
                for: serialized, cachedFrontmatter: &builtInPluginFrontmatter,
                snapshot: &builtInPluginSnapshot)
            lastSerialized = serialized
            isInternalUpdate = true
            parent.document.content = serialized
            isInternalUpdate = false
            storeCursor()
            if pluginConfigurationChanged {
                // Existing inline/list attributes carry the previous plugin
                // payload. Re-render once so removing or editing frontmatter
                // updates the whole Visual semantic model, not only tables.
                loadDocument(pluginSnapshot: builtInPluginSnapshot)
            }
            return pluginConfigurationChanged
        }

        func updateStats() {
            guard let textView else { return }
            let (words, chars) = wordAndCharCount(in: textView.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        @objc func settingsDidChange() {
            // A color-override change keeps the preset name, so updateNSView's
            // name gate wouldn't refresh the theme — source it here directly.
            textView?.theme = EditorSettings.shared.effectiveTheme
            imageAttachments.removeAll()
            loadDocument()  // restoreCursor keeps the place via the position store
            if let textView {
                textView.textContainerInset = EditorSettings.shared.visual.textContainerInset(
                    forWidth: textView.enclosingScrollView?.contentView.bounds.width ?? 0)
            }
            refreshGutter()
            publishActions()
        }

        @objc func lineMarksDidChange() {
            refreshGutter()
        }

        @objc func codeHighlightingDidWarm() {
            guard EditorSettings.shared.general.syntaxHighlighting else { return }
            applyPresentation()
        }
    }
}
