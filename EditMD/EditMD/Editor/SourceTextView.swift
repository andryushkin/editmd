import AppKit
import SwiftUI

// Source mode (v23): raw markdown in a plain monospaced NSTextView.
// No syntax highlighting or drawn decorations — the only intelligence here is
// the lint engine (MarkdownLint.swift): dotted underlines via layout-manager
// temporary attributes, quick-fixes in the context menu, a status-bar badge.
//
// Until v23 this lived in MarkdownTextView.swift together with the v17 hybrid
// live-preview engine; the hybrid died when Visual became true WYSIWYG (v21).

/// Lint state published to the status bar (Source mode).
struct LintSummary {
    var errorCount: Int
    var warningCount: Int
    var jumpToNext: () -> Void
    /// Snapshot for the status-bar popover (D2). Ranges are UTF-16.
    var diagnostics: [LintDiagnostic] = []
    /// Jump caret to a diagnostic's range (popover row click).
    var jumpTo: ((LintDiagnostic) -> Void)? = nil
    /// Apply the first available fix, if any.
    var applyFirstFix: ((LintDiagnostic) -> Void)? = nil
}

struct SourceTextView: NSViewRepresentable {

    let document: MarkdownDocument
    /// For session dirty-line marks (nil = untitled).
    var fileURL: URL? = nil
    /// Cursor continuity across modes (markdown offsets are native here).
    var positionStore: EditorPositionStore? = nil
    /// Reading-field insets from Settings ▸ Source. Passed explicitly so
    /// SwiftUI calls `updateNSView` when the user drags Vertical/Horizontal
    /// (otherwise only a debounced notification refreshed them).
    var insetH: CGFloat = EditorSettings.shared.source.insetH
    var insetV: CGFloat = EditorSettings.shared.source.insetV
    var columnWidth: CGFloat = EditorSettings.shared.source.columnWidth
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void
    var onLintUpdate: ((LintSummary) -> Void)? = nil
    /// B6: active inline styles at caret (from cached spans — no re-parse).
    var onActiveFormats: ((ActiveInlineFormats) -> Void)? = nil
    /// Last-visible-line markdown offset for split-preview scroll sync.
    var onVisibleOffset: ((Int) -> Void)? = nil
    /// Left edge of the text (incl. the reserved gutter margin) — the action
    /// strip and the gutter toggle line up with it.
    var onTextLeading: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Room the numbers need beside the text — reserved whether or not they're
    /// shown, so toggling them doesn't move the column.
    private var gutterReserve: CGFloat {
        GutterMetrics.reserve(lineCountHint: max(1, countDiffLines(document.content)))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Match the text view so the vertical contentInsets band (Settings ▸
        // Vertical) is the same white/dark page color, not window chrome.
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.automaticallyAdjustsContentInsets = false

        let textView = SourceNSTextView()
        // Rich text so per-element highlighting (heading size/weight, colors)
        // renders. The document's source of truth is still the plain `.string`;
        // paste is forced to plain text so external rich content can't leak in.
        textView.isRichText = true
        // Document-scoped undo (MarkdownDocument.contentUndoManager) — not the
        // view-local stack, so ⌘Z survives mode switches.
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = EditorSettings.shared.source.resolvedFont(defaultMono: true)
        textView.textColor = EditorSettings.shared.effectiveTheme.textColor
        textView.insertionPointColor = EditorSettings.shared.effectiveTheme.textColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Unbounded growth — without this, vertical inset/contentInsets can
        // clip or refuse to reflow when Settings ▸ Vertical changes.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude)
        // Large documents: lay out only the ranges TextKit needs, not the whole
        // storage up front (Apple's recommended big-document win).
        textView.layoutManager?.allowsNonContiguousLayout = true
        // Edit ▸ Find menu (⌘F & co.) drives the standard find bar.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        Self.applyReadingInsets(textView: textView, scrollView: scrollView,
                                insetH: insetH, insetV: insetV, columnWidth: columnWidth,
                                gutterReserve: gutterReserve)

        let coordinator = context.coordinator
        coordinator.textView = textView
        // Capture the cross-mode offset BEFORE any text/delegate wiring:
        // setting the string resets the selection, and the selection-change
        // callback would clobber the stored value with 0.
        let restoreOffset = positionStore?.markdownOffset
        textView.string = document.content
        textView.delegate = coordinator

        coordinator.updateStats()
        coordinator.publishActions()
        coordinator.highlightSource()
        coordinator.scheduleLint(delaySeconds: 0)
        coordinator.refreshGutter()
        // Scroll/bounds → redraw line numbers.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollOrBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true

        if let store = positionStore, let restoreOffset {
            store.markdownOffset = restoreOffset
            let offset = min(restoreOffset, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: offset, length: 0))
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
                textView.centerSelectionInVisibleArea(nil)
                textView.window?.makeFirstResponder(textView)
            }
        }

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.lineMarksDidChange),
            name: .lineChangeMarksDidChange,
            object: nil
        )
        // A big code block highlighted off main — repaint now that its runs are
        // cached (the pass itself is a cache hit, no JS).
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.codeHighlightingDidWarm),
            name: .codeHighlightingDidWarm,
            object: nil
        )
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        // Outline-sidebar jumps, object-scoped to this window's store (a nil
        // object would subscribe to every window's jumps).
        if let store = positionStore {
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.jumpToStoredOffset),
                name: .editMDJumpToOffset,
                object: store
            )
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.followPreviewScroll),
                name: .editMDEditorScrollSync,
                object: store
            )
        }
        // Claude `openFile` reveal. The bridge hands the range to whichever
        // editor claims the URL, so a nil object scope is correct here.
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.applyClaudeReveal),
            name: .claudeIDERevealRequested,
            object: nil
        )
        // The file may have been opened BY that reveal: claim it on mount too.
        coordinator.applyClaudeReveal()
        // Review-mark anchor wash (v37).
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.reviewMarksDidChange),
            name: .reviewMarksDidChange,
            object: nil
        )
        coordinator.applyReviewHighlights()
        coordinator.scheduleVisibleOffsetPublish()

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let textView = coordinator.textView else { return }
        Self.applyReadingInsets(textView: textView, scrollView: scrollView,
                                insetH: insetH, insetV: insetV, columnWidth: columnWidth,
                                gutterReserve: gutterReserve)

        // External change (Revert, or another window editing the shared
        // document). A background window defers the reload until it becomes key
        // so its cursor/scroll survive edits made elsewhere.
        if !coordinator.isInternalUpdate, textView.string != document.content {
            if textView.window?.isKeyWindow ?? true {
                coordinator.reloadFromDocument()
            } else {
                coordinator.pendingExternalReload = true
            }
        }
        coordinator.refreshGutter()
        coordinator.scheduleVisibleOffsetPublish()
    }

    /// Horizontal via `textContainerInset` (column wrap). Vertical via the
    /// scroll view's `contentInsets` so the strip→text gap tracks Settings ▸
    /// Vertical immediately — `textContainerInset.height` alone often kept
    /// stale line-fragment origins until a window resize.
    fileprivate static func applyReadingInsets(textView: NSTextView,
                                               scrollView: NSScrollView,
                                               insetH: CGFloat,
                                               insetV: CGFloat,
                                               columnWidth: CGFloat,
                                               gutterReserve: CGFloat = 0) {
        let width = scrollView.contentView.bounds.width
        var mode = EditorSettings.shared.source
        mode.insetH = insetH
        mode.insetV = insetV
        mode.columnWidth = columnWidth
        let inset = mode.textContainerInset(forWidth: width)
        // Numbers live in this margin; reserving it unconditionally keeps the
        // text still when they're toggled.
        let leading = max(inset.width, gutterReserve)

        textView.textContainerInset = NSSize(width: leading, height: 0)
        scrollView.automaticallyAdjustsContentInsets = false
        let v = inset.height
        let current = scrollView.contentInsets
        if current.top != v || current.bottom != v || current.left != 0 || current.right != 0 {
            scrollView.contentInsets = NSEdgeInsets(top: v, left: 0, bottom: v, right: 0)
        }
        scrollView.backgroundColor = textView.backgroundColor

        if let tc = textView.textContainer {
            textView.layoutManager?.textContainerChangedGeometry(tc)
        }
        textView.needsDisplay = true
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: SourceTextView
        fileprivate var textView: SourceNSTextView?
        var isInternalUpdate = false
        /// A background window sets this when the shared document changes under
        /// it; the reload is applied when the window next becomes key.
        var pendingExternalReload = false
        /// Last `collectSpans` result — selection only reads this (B6).
        var cachedSpans: [Span] = []
        /// `==…==` runs of the last highlighted text — recomputed with the
        /// spans cache, NEVER on selection change (no O(text) per caret move).
        var cachedHighlightMarks: [HighlightMarkMatch] = []
        var lastPublishedFormats = ActiveInlineFormats()

        init(parent: SourceTextView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            parent.document.beginContentEdit()
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            guard !isInternalUpdate else { return }
            isInternalUpdate = true
            parent.document.content = tv.string
            isInternalUpdate = false
            parent.document.noteContentEdited()
            DocumentRegistry.shared.noteUserEdit(parent.fileURL)
            LineChangeTracker.shared.noteContent(url: parent.fileURL, content: tv.string)
            updateStats()
            highlightSource()
            scheduleLint()
            // Review wash re-aligns via the model's debounced recompute
            // notification — no per-keystroke repaint here.
            refreshGutter()
            scheduleVisibleOffsetPublish()
        }

        func refreshGutter() {
            guard let textView = textView as? SourceNSTextView else { return }
            // Source: display line ≡ source line (identity map).
            textView.gutterState = GutterState(
                settings: EditorSettings.shared.gutter,
                dirtySourceLines: LineChangeTracker.shared.dirtyLines(for: parent.fileURL),
                displayToSourceLine: [])
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
        private var scrollSyncPublishScheduled = false

        @objc func scrollOrBoundsChanged(_ note: Notification) {
            textView?.needsDisplay = true
            scheduleVisibleOffsetPublish()
        }

        /// Coalesce AppKit's burst of bounds notifications once per run-loop
        /// turn. Unlike the old 120 ms debounce this keeps publishing during a
        /// continuous trackpad gesture instead of waiting for it to stop.
        func scheduleVisibleOffsetPublish() {
            guard parent.onVisibleOffset != nil, !scrollSyncPublishScheduled else { return }
            scrollSyncPublishScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollSyncPublishScheduled = false
                guard let textView = self.textView else { return }
                let offset = self.visibleMarkdownOffset(in: textView)
                self.parent.onVisibleOffset?(offset)
            }
        }

        /// Character index at the bottom of the visible rect (UTF-16). Split
        /// sync uses the last visible source line as its anchor: matching the
        /// top accumulates drift when Preview blocks have different heights.
        private func visibleMarkdownOffset(in textView: NSTextView) -> Int {
            guard let scroll = textView.enclosingScrollView else {
                return textView.selectedRange().location
            }
            let length = (textView.string as NSString).length
            // Preserve the document edges exactly. Without the top sentinel,
            // opening split at scroll position zero aligns the first screen's
            // bottom line and hides Preview's heading/top content.
            let scrollPosition = scroll.verticalScroller?.doubleValue ?? 0
            if scrollPosition <= 0.0001 { return 0 }
            if scrollPosition >= 0.9999 { return length }
            let visible = scroll.contentView.bounds
            // Convert to textView coordinates.
            let point = textView.convert(NSPoint(x: visible.minX + 4, y: visible.maxY - 4),
                                         from: scroll.contentView)
            let idx = textView.characterIndexForInsertion(at: point)
            return max(0, min(idx, length))
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // textView.string = … fires this synchronously (v22) — skip during
            // internal reloads so we don't thrash the strip.
            guard !isInternalUpdate, let textView else { return }
            parent.positionStore?.markdownOffset = textView.selectedRange().location
            // Don't let the virtual-alignment .kern bleed into typed text —
            // the char before the caret may carry a pad; re-highlight will
            // recompute it, but typing attributes must start clean.
            if textView.typingAttributes[.kern] != nil {
                textView.typingAttributes[.kern] = nil
            }
            // Source coordinates are the markdown's own — no mapping needed.
            ClaudeIDEBridge.shared.noteSelection(url: parent.fileURL,
                                                 markdownRange: textView.selectedRange(),
                                                 markdown: parent.document.content)
            publishActiveFormats()
        }

        /// Active formats from `cachedSpans` only — never re-runs collectSpans.
        private func publishActiveFormats() {
            guard let textView else { return }
            let pos = textView.selectedRange().location
            let probe = max(0, min(pos, max(0, (textView.string as NSString).length - 1)))
            var fmt = ActiveInlineFormats()
            for span in cachedSpans {
                guard NSLocationInRange(probe, span.range)
                        || (span.range.length > 0
                            && pos == NSMaxRange(span.range)
                            && pos > span.range.location) else { continue }
                switch span.kind {
                case .boldBody, .boldMarker: fmt.bold = true
                case .italicBody, .italicMarker: fmt.italic = true
                case .code, .codeMarker: fmt.code = true
                case .strikethroughBody, .strikethroughMarker: fmt.strikethrough = true
                default: break
                }
            }
            let selection = textView.selectedRange()
            let highlightProbe = selection.length == 0
                ? NSRange(location: pos, length: 0) : selection
            fmt.highlight = cachedHighlightMarks.contains { mark in
                let body = NSRange(location: mark.range.location + 2,
                                   length: max(0, mark.range.length - 4))
                if highlightProbe.length == 0 {
                    return highlightProbe.location >= body.location
                        && highlightProbe.location <= NSMaxRange(body)
                }
                return highlightProbe.location >= body.location
                    && NSMaxRange(highlightProbe) <= NSMaxRange(body)
            }
            guard fmt != lastPublishedFormats else { return }
            lastPublishedFormats = fmt
            let callback = parent.onActiveFormats
            DispatchQueue.main.async { callback?(fmt) }
        }

        /// The shared caret dance: clamp to the current text, select, reveal
        /// centered, focus. Claude reveals and outline jumps must not drift.
        @discardableResult
        private func selectAndReveal(_ range: NSRange) -> NSRange {
            guard let textView else { return range }
            let length = (textView.string as NSString).length
            let location = min(range.location, length)
            let clamped = NSRange(location: location,
                                  length: min(range.length, length - location))
            textView.setSelectedRange(clamped)
            textView.scrollRangeToVisible(clamped)
            textView.centerSelectionInVisibleArea(nil)
            textView.window?.makeFirstResponder(textView)
            return clamped
        }

        /// Claude's `openFile` with `startText` / `endText`: select the resolved
        /// range. Fired both on mount (file just opened) and on notification
        /// (file already on screen).
        @objc func applyClaudeReveal() {
            guard textView != nil,
                  let range = ClaudeIDEBridge.shared.takeReveal(for: parent.fileURL)
            else { return }
            let clamped = selectAndReveal(range)
            parent.positionStore?.markdownOffset = clamped.location
        }

        /// Outline-sidebar jump: markdown offsets are native here — place the
        /// cursor at the store's offset and reveal it (the same dance as the
        /// mode-switch restore in makeNSView).
        @objc func jumpToStoredOffset() {
            guard let store = parent.positionStore else { return }
            selectAndReveal(NSRange(location: store.markdownOffset, length: 0))
        }

        /// Reverse split sync: align the requested source character with the
        /// bottom of the viewport without touching selection or focus.
        @objc func followPreviewScroll() {
            guard let store = parent.positionStore else { return }
            scrollViewport(to: store.editorScrollOffset)
        }

        private func scrollViewport(to target: Int) {
            guard let textView, let scroll = textView.enclosingScrollView,
                  let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let length = (textView.string as NSString).length
            let clip = scroll.contentView
            var proposed = clip.bounds
            if target <= 0 {
                proposed.origin.y = -1_000_000_000
            } else if target >= length {
                proposed.origin.y = 1_000_000_000
            } else {
                let range = NSRange(location: min(target, length - 1), length: 1)
                layout.ensureLayout(forCharacterRange: range)
                let glyphs = layout.glyphRange(forCharacterRange: range,
                                               actualCharacterRange: nil)
                var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
                rect.origin.y += textView.textContainerOrigin.y
                proposed.origin.y = rect.maxY - proposed.height + 8
            }
            let constrained = clip.constrainBoundsRect(proposed)
            clip.scroll(to: constrained.origin)
            scroll.reflectScrolledClipView(clip)
        }

        /// Reloads from the shared document (external change), preserving the
        /// cursor offset (clamped) across the swap.
        func reloadFromDocument() {
            guard let textView else { return }
            pendingExternalReload = false
            let sel = textView.selectedRange()
            isInternalUpdate = true
            textView.string = parent.document.content
            isInternalUpdate = false
            let len = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            // Baseline already reset by DocumentRegistry; refresh marks display.
            updateStats()
            highlightSource()
            scheduleLint(delaySeconds: 0)
            applyReviewHighlights()
            refreshGutter()
        }


        /// When a deferred external change is pending, apply it once the window
        /// regains focus (see updateNSView's background-window gate).
        @objc func windowBecameKey(_ note: Notification) {
            guard pendingExternalReload, let tv = textView,
                  (note.object as? NSWindow) === tv.window else { return }
            reloadFromDocument()
        }

        // MARK: Review-mark anchors (v37)

        @objc func reviewMarksDidChange() {
            applyReviewHighlights()
        }

        /// Temporary background wash on open-mark anchors. Ranges come from
        /// ReviewModel's shared anchor cache (one off-main pass, debounced
        /// behind typing) — Source runs no text search of its own. During a
        /// typing burst the wash may trail the buffer briefly; apply() clamps
        /// ranges and the post-recompute notification re-aligns it.
        func applyReviewHighlights() {
            guard let textView else { return }
            // Heavy docs stay plain (same gate as lint/highlight).
            guard !parent.document.isHeavy else {
                ReviewHighlight.apply(to: textView, highlights: [])
                return
            }
            // Only the main-window active review file paints marks.
            guard parent.fileURL?.standardizedFileURL == ReviewModel.shared.fileURL
            else {
                ReviewHighlight.apply(to: textView, highlights: [])
                return
            }
            ReviewHighlight.apply(to: textView,
                                  highlights: ReviewModel.shared.openAnchorHighlights())
        }

        // MARK: Lint

        private var lintTask: Task<Void, Never>?
        private var lintDiagnostics: [LintDiagnostic] = []

        func scheduleLint(delaySeconds: Double = 0.3) {
            lintTask?.cancel()
            lintTask = Task { [weak self] in
                if delaySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                self?.runLint()
            }
        }

        private func runLint() {
            guard let textView else { return }
            // Skip linting heavy documents — lint() is O(n) over the whole text
            // (~1.2s on a 300K table) and would freeze the editor.
            guard !parent.document.isHeavy else {
                lintDiagnostics = []
                textView.lintDiagnostics = []
                applyLintUnderlines([])
                DispatchQueue.main.async { [parent] in
                    parent.onLintUpdate?(LintSummary(errorCount: 0, warningCount: 0, jumpToNext: {}))
                }
                return
            }
            let diags = lint(textView.string)
            lintDiagnostics = diags
            textView.lintDiagnostics = diags
            applyLintUnderlines(diags)
            let errors = diags.filter { $0.severity == .error }.count
            let summary = LintSummary(
                errorCount: errors,
                warningCount: diags.count - errors,
                jumpToNext: { [weak self] in self?.jumpToNextDiagnostic() },
                diagnostics: diags,
                jumpTo: { [weak self] d in self?.jumpToDiagnostic(d) },
                applyFirstFix: { [weak self] d in self?.applyFirstFix(d) }
            )
            DispatchQueue.main.async { [parent] in
                parent.onLintUpdate?(summary)
            }
        }

        private func jumpToDiagnostic(_ d: LintDiagnostic) {
            selectAndReveal(NSRange(location: d.range.location, length: 0))
        }

        private func applyFirstFix(_ d: LintDiagnostic) {
            guard let textView, let fix = d.fixes.first else { return }
            guard textView.shouldChangeText(in: fix.range, replacementString: fix.replacement)
            else { return }
            textView.textStorage?.replaceCharacters(in: fix.range, with: fix.replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: fix.range.location,
                                              length: (fix.replacement as NSString).length))
        }

        /// Temporary attributes live in the layout manager only — they never
        /// touch NSTextStorage, so the document and undo stack stay clean.
        private func applyLintUnderlines(_ diags: [LintDiagnostic]) {
            guard let textView, let lm = textView.layoutManager else { return }
            let len = (textView.string as NSString).length
            let full = NSRange(location: 0, length: len)
            lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
            lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: full)
            lm.removeTemporaryAttribute(.toolTip, forCharacterRange: full)
            for d in diags {
                guard d.range.location < len else { continue }
                let r = NSRange(location: d.range.location,
                                length: min(d.range.length, len - d.range.location))
                guard r.length > 0 else { continue }
                let color: NSColor = d.severity == .error ? .systemRed : .systemOrange
                lm.addTemporaryAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle([.single, .patternDot]).rawValue,
                    forCharacterRange: r)
                lm.addTemporaryAttribute(.underlineColor, value: color, forCharacterRange: r)
                lm.addTemporaryAttribute(.toolTip, value: d.message, forCharacterRange: r)
            }
        }

        private func jumpToNextDiagnostic() {
            guard let textView, !lintDiagnostics.isEmpty else { return }
            let cursor = textView.selectedRange().location
            let next = lintDiagnostics.first { $0.range.location > cursor } ?? lintDiagnostics[0]
            textView.setSelectedRange(next.range)
            textView.scrollRangeToVisible(next.range)
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: Stats

        func updateStats() {
            guard let tv = textView else { return }
            let (words, chars) = wordAndCharCount(in: tv.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        // MARK: Format actions (marker wrapping — Source works on raw text)

        func publishActions() {
            let actions = FormatActions(
                toggleBold: { [weak self] in self?.wrapSelection(with: "**") },
                toggleItalic: { [weak self] in self?.wrapSelection(with: "*") },
                makeFontBigger: { EditorSettings.shared.adjustFontSize(\.source, by: 1) },
                makeFontSmaller: { EditorSettings.shared.adjustFontSize(\.source, by: -1) },
                canIncreaseFontSize: EditorSettings.shared.source.fontSize < ModeSettings.fontSizeRange.upperBound,
                canDecreaseFontSize: EditorSettings.shared.source.fontSize > ModeSettings.fontSizeRange.lowerBound,
                toggleChecklist: { [weak self] in self?.transformSelectedLines(.checklist) },
                toggleStrikethrough: { [weak self] in self?.wrapSelection(with: "~~") },
                toggleCodeSpan: { [weak self] in self?.wrapSelection(with: "`") },
                toggleHighlight: { [weak self] in self?.wrapSelection(with: "==") },
                setHeading: { [weak self] level in self?.transformSelectedLines(.heading(level)) },
                setBody: { [weak self] in self?.transformSelectedLines(.body) },
                clearInlineFormatting: { [weak self] in self?.clearInlineFormatting() },
                insertDivider: { [weak self] in self?.insertDivider() },
                cycleCase: { [weak self] in self?.cycleSelectionCase() },
                toggleBulletList: { [weak self] in self?.transformSelectedLines(.bullet) },
                toggleNumberedList: { [weak self] in self?.transformSelectedLines(.ordered) },
                toggleQuote: { [weak self] in self?.transformSelectedLines(.quote) },
                toggleCodeBlock: { [weak self] in self?.fenceSelectedLines() },
                copySelection: { [weak self] in self?.copySelection() }
            )
            DispatchQueue.main.async { [parent] in
                parent.onFormatActions(actions)
            }
        }

        private func clearInlineFormatting() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { NSSound.beep(); return }
            let ns = textView.string as NSString
            let selected = ns.substring(with: range)
            let stripped = stripInlineMarkers(selected)
            guard stripped != selected else { return }
            guard textView.shouldChangeText(in: range, replacementString: stripped) else { return }
            textView.replaceCharacters(in: range, with: stripped)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location,
                                              length: (stripped as NSString).length))
        }

        private func insertDivider() {
            guard let textView else { return }
            let range = textView.selectedRange()
            let insert = dividerSnippet(in: textView.string as NSString, replacing: range)
            guard textView.shouldChangeText(in: range, replacementString: insert) else { return }
            textView.replaceCharacters(in: range, with: insert)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location + (insert as NSString).length,
                                              length: 0))
        }

        private func cycleSelectionCase() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { NSSound.beep(); return }
            let ns = textView.string as NSString
            let selected = ns.substring(with: range)
            let next = cycleCase(selected)
            guard next != selected else { return }
            guard textView.shouldChangeText(in: range, replacementString: next) else { return }
            textView.replaceCharacters(in: range, with: next)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: range.location,
                                              length: (next as NSString).length))
        }

        private func wrapSelection(with marker: String) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let ns = textView.string as NSString
            let openLen = (marker as NSString).length
            // Selection includes its own syntax (`~~text~~`): unwrap it
            // directly. The old path wrapped again into `~~~~text~~~~`.
            if range.length >= openLen * 2 {
                let selected = ns.substring(with: range)
                if selected.hasPrefix(marker), selected.hasSuffix(marker) {
                    let selectedNS = selected as NSString
                    let inner = selectedNS.substring(with: NSRange(
                        location: openLen, length: selectedNS.length - openLen * 2))
                    guard textView.shouldChangeText(in: range, replacementString: inner) else { return }
                    textView.replaceCharacters(in: range, with: inner)
                    textView.didChangeText()
                    textView.setSelectedRange(NSRange(location: range.location,
                                                      length: (inner as NSString).length))
                    return
                }
            }
            // Toggle unwrap when markers already surround the selection.
            if range.length > 0, range.location >= openLen {
                let before = ns.substring(with: NSRange(location: range.location - openLen,
                                                        length: openLen))
                let afterLoc = NSMaxRange(range)
                let after = afterLoc + openLen <= ns.length
                    ? ns.substring(with: NSRange(location: afterLoc, length: openLen)) : ""
                if before == marker, after == marker {
                    let full = NSRange(location: range.location - openLen,
                                       length: range.length + openLen * 2)
                    let inner = ns.substring(with: range)
                    guard textView.shouldChangeText(in: full, replacementString: inner) else { return }
                    textView.replaceCharacters(in: full, with: inner)
                    textView.didChangeText()
                    textView.setSelectedRange(NSRange(location: full.location,
                                                      length: (inner as NSString).length))
                    return
                }
            }
            let (_, newSelection) = applyWrap(marker: marker, to: textView.string, selection: range)
            let selected = ns.substring(with: range)
            let wrapped = marker + selected + marker
            guard textView.shouldChangeText(in: range, replacementString: wrapped) else { return }
            textView.replaceCharacters(in: range, with: wrapped)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
        }

        private func copySelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { NSSound.beep(); return }
            let text = (textView.string as NSString).substring(with: range)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        /// Replaces the lines the selection touches with `replacement`,
        /// keeping undo intact, and selects the replaced text.
        private func replaceSelectedLines(with replacement: (String) -> String) {
            guard let textView else { return }
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: textView.selectedRange())
            let replaced = replacement(nsText.substring(with: lineRange))
            guard textView.shouldChangeText(in: lineRange, replacementString: replaced) else { return }
            textView.textStorage?.replaceCharacters(in: lineRange, with: replaced)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: lineRange.location,
                                              length: (replaced as NSString).length))
        }

        private func transformSelectedLines(_ transform: BlockTransform) {
            replaceSelectedLines { transformLines(transform, lines: $0) }
        }

        private func fenceSelectedLines() {
            replaceSelectedLines { fenceLines($0) }
        }

        // MARK: Settings

        @objc func settingsDidChange() {
            guard let textView else { return }
            let settings = EditorSettings.shared.source
            textView.font = settings.resolvedFont(defaultMono: true)
            textView.insertionPointColor = EditorSettings.shared.effectiveTheme.textColor
            if let scrollView = textView.enclosingScrollView {
                SourceTextView.applyReadingInsets(
                    textView: textView, scrollView: scrollView,
                    insetH: settings.insetH, insetV: settings.insetV,
                    columnWidth: settings.columnWidth)
            }
            highlightSource()
            applyReviewHighlights()
            refreshGutter()
            publishActions()
        }

        @objc func lineMarksDidChange() {
            refreshGutter()
        }

        @objc func codeHighlightingDidWarm() {
            guard EditorSettings.shared.general.syntaxHighlighting else { return }
            highlightSource()
        }

        // MARK: Source highlighting

        /// Re-styles the raw markdown from `collectSpans` + the Source mode's
        /// per-element settings. Real text-storage attributes (not temporary
        /// ones) so heading size changes take effect; the plain `.string` — the
        /// document's source of truth — is untouched, and attribute-only edits
        /// don't register undo. Two passes: block-level (heading lines, quotes)
        /// then inline (bold/code/link/italic/strike) so inline overrides win.
        func highlightSource() {
            guard let textView, let storage = textView.textStorage else { return }
            let settings = EditorSettings.shared.source
            let theme = EditorSettings.shared.effectiveTheme
            let els = settings.elements
            let baseFont = settings.resolvedFont(defaultMono: true)
            let nsText = textView.string as NSString
            let full = NSRange(location: 0, length: nsText.length)

            // Heavy documents (a 300K single-table file) stay plain: collectSpans
            // and the per-keystroke re-attribution would freeze on every edit.
            // Base font/color only — same choice FSNotes makes for large notes.
            if parent.document.isHeavy {
                cachedSpans = []
                cachedHighlightMarks = []
                storage.beginEditing()
                storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)
                storage.endEditing()
                return
            }

            let spans = collectSpans(textView.string)
            cachedSpans = spans
            cachedHighlightMarks = scanHighlightMarks(in: textView.string)

            func headingFont(_ level: Int) -> NSFont {
                let e = els.heading(level)
                return sourceFont(size: settings.fontSize * e.sizeScale,
                                  weight: (e.weight ?? .semibold).nsWeight)
            }

            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)

            // Identity of a code block across keystrokes, so a block that is
            // still warming keeps its previous colors instead of flashing plain.
            var codeBlockIndex = 0
            let blockKeyPrefix = "source:\(parent.fileURL?.path ?? "untitled")#"

            // Pass A — block level.
            for span in spans where NSMaxRange(span.range) <= full.length {
                switch span.kind {
                case .headingBody(let level):
                    let line = nsText.lineRange(for: span.range)
                    storage.addAttribute(.font, value: headingFont(level), range: line)
                    if let c = els.heading(level).color {
                        storage.addAttribute(.foregroundColor, value: c, range: line)
                    }
                case .quoteBody, .quoteMarker:
                    if let c = els.quote.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .codeBlockBody(let language):
                    defer { codeBlockIndex += 1 }
                    if EditorSettings.shared.general.syntaxHighlighting,
                       let body = CodeSyntaxHighlighter.shared.fencedBodyRange(in: nsText,
                                                                                blockRange: span.range) {
                        CodeSyntaxHighlighter.shared.apply(
                            to: storage, codeRange: body, language: language,
                            stableKey: blockKeyPrefix + String(codeBlockIndex))
                    }
                default:
                    break
                }
            }

            // Pass B — inline.
            for span in spans where NSMaxRange(span.range) <= full.length {
                switch span.kind {
                case .boldBody, .boldMarker:
                    let existing = storage.attribute(.font, at: span.range.location,
                                                     effectiveRange: nil) as? NSFont ?? baseFont
                    storage.addAttribute(.font, value: sourceFont(
                        size: existing.pointSize, weight: (els.bold.weight ?? .bold).nsWeight),
                                         range: span.range)
                    if let c = els.bold.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .italicBody:
                    let existing = storage.attribute(.font, at: span.range.location,
                                                     effectiveRange: nil) as? NSFont ?? baseFont
                    if let italic = existing.withSourceTraits(.italic) {
                        storage.addAttribute(.font, value: italic, range: span.range)
                    }
                case .code, .codeMarker:
                    if let c = els.inlineCode.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .linkText:
                    if let c = els.link.color {
                        storage.addAttribute(.foregroundColor, value: c, range: span.range)
                    }
                case .strikethroughBody:
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: span.range)
                case .wikiLink:
                    storage.addAttribute(.foregroundColor,
                                         value: els.link.color ?? theme.accentColor, range: span.range)
                case .wikiLinkSyntax:
                    storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
                case .mathBody:
                    storage.addAttribute(.foregroundColor,
                                         value: els.inlineCode.color ?? theme.inlineCodeColor,
                                         range: span.range)
                case .mathMarker:
                    storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
                default:
                    break
                }
            }

            // Pass B.5 — YAML frontmatter (top-of-file ---…---). swift-markdown
            // mis-parses it as a thematic break + setext heading, so Pass A gave
            // the body a big heading font; override the whole block back to the
            // base font and color it like a ```yaml block (fences dimmed).
            if let frontmatter = frontmatterRange(in: textView.string),
               NSMaxRange(frontmatter.full) <= nsText.length {
                storage.addAttribute(.font, value: baseFont, range: frontmatter.full)
                storage.addAttribute(.foregroundColor, value: theme.textColor,
                                     range: frontmatter.full)
                let openLen = frontmatter.body.location - frontmatter.full.location
                if openLen > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                         range: NSRange(location: frontmatter.full.location,
                                                        length: openLen))
                }
                let closeStart = NSMaxRange(frontmatter.body)
                let closeLen = NSMaxRange(frontmatter.full) - closeStart
                if closeLen > 0 {
                    storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                         range: NSRange(location: closeStart, length: closeLen))
                }
                if EditorSettings.shared.general.syntaxHighlighting {
                    CodeSyntaxHighlighter.shared.apply(
                        to: storage, codeRange: frontmatter.body, language: "yaml",
                        stableKey: blockKeyPrefix + "frontmatter")
                }
            }

            // Pass C — virtual table column alignment (display-only .kern; the
            // raw text stays compact, columns just line up visually).
            applyTableAlignment(storage, baseFont: baseFont)

            storage.endEditing()
        }

        /// Pads each table column to a common width using the `.kern` attribute
        /// so pipes line up in the monospaced Source view — WITHOUT inserting
        /// spaces (the file bytes are untouched, so no git churn). Width is
        /// measured from the already-styled substring, so bold/heading cells
        /// count correctly; a per-column cap keeps one long cell from blowing
        /// the table wide (that cell's row just runs ragged past the cap).
        private func applyTableAlignment(_ storage: NSTextStorage, baseFont: NSFont) {
            let tables = scanSourceTables(storage.string)
            guard !tables.isEmpty else { return }
            let length = storage.length
            let charWidth = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
            let maxColumnWidth = charWidth * 40   // cap ≈ 40 characters

            for cells in tables {
                var target: [Int: CGFloat] = [:]
                var measured: [(cell: SourceTableCell, width: CGFloat)] = []
                for cell in cells where NSMaxRange(cell.segmentRange) <= length {
                    let width = cell.segmentRange.length > 0
                        ? storage.attributedSubstring(from: cell.segmentRange).size().width
                        : 0
                    measured.append((cell, width))
                    target[cell.column] = min(max(target[cell.column] ?? 0, width), maxColumnWidth)
                }
                for (cell, width) in measured {
                    guard let goal = target[cell.column], goal > width + 0.5,
                          cell.kernIndex < length else { continue }
                    storage.addAttribute(.kern, value: NSNumber(value: Double(goal - width)),
                                         range: NSRange(location: cell.kernIndex, length: 1))
                }
            }
        }

        /// A Source font honoring the mode's family (else system mono) at an
        /// explicit size/weight.
        private func sourceFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
            let family = EditorSettings.shared.source.fontFamily
            if !family.isEmpty {
                let descriptor = NSFontDescriptor(fontAttributes: [
                    .family: family,
                    .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
                ])
                if let font = NSFont(descriptor: descriptor, size: size) { return font }
            }
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
    }
}

// MARK: - Shared Source highlighting (editor + external-change diff)

/// Renders markdown with the same per-element fonts/colors as Source mode
/// (Settings ▸ Source ▸ Elements + effective theme). No table-kern pass —
/// callers that need alignment run it separately on a live text view.
@MainActor
func makeSourceHighlightedString(_ text: String) -> NSAttributedString {
    let settings = EditorSettings.shared.source
    let theme = EditorSettings.shared.effectiveTheme
    let els = settings.elements
    let baseFont = settings.resolvedFont(defaultMono: true)
    let storage = NSTextStorage(string: text)
    let nsText = storage.string as NSString
    let full = NSRange(location: 0, length: nsText.length)
    guard full.length > 0 else {
        return NSAttributedString(string: text, attributes: [
            .font: baseFont, .foregroundColor: theme.textColor,
        ])
    }

    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let family = settings.fontFamily
        if !family.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let f = NSFont(descriptor: descriptor, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    storage.beginEditing()
    storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)

    let spans = collectSpans(text)
    for span in spans where NSMaxRange(span.range) <= full.length {
        switch span.kind {
        case .headingBody(let level):
            let line = nsText.lineRange(for: span.range)
            let e = els.heading(level)
            storage.addAttribute(.font,
                                 value: font(size: settings.fontSize * e.sizeScale,
                                             weight: (e.weight ?? .semibold).nsWeight),
                                 range: line)
            if let c = e.color {
                storage.addAttribute(.foregroundColor, value: c, range: line)
            }
        case .quoteBody, .quoteMarker:
            if let c = els.quote.color {
                storage.addAttribute(.foregroundColor, value: c, range: span.range)
            }
        case .codeBlockBody(let language):
            // A one-shot render (no view to repaint later) — highlight inline.
            if EditorSettings.shared.general.syntaxHighlighting,
               let body = CodeSyntaxHighlighter.shared.fencedBodyRange(in: nsText,
                                                                        blockRange: span.range) {
                CodeSyntaxHighlighter.shared.apply(to: storage, codeRange: body, language: language,
                                                   blocking: true)
            }
        default:
            break
        }
    }
    for span in spans where NSMaxRange(span.range) <= full.length {
        switch span.kind {
        case .boldBody, .boldMarker:
            let existing = storage.attribute(.font, at: span.range.location,
                                             effectiveRange: nil) as? NSFont ?? baseFont
            storage.addAttribute(.font,
                                 value: font(size: existing.pointSize,
                                             weight: (els.bold.weight ?? .bold).nsWeight),
                                 range: span.range)
            if let c = els.bold.color {
                storage.addAttribute(.foregroundColor, value: c, range: span.range)
            }
        case .italicBody:
            let existing = storage.attribute(.font, at: span.range.location,
                                             effectiveRange: nil) as? NSFont ?? baseFont
            if let italic = existing.withSourceTraits(.italic) {
                storage.addAttribute(.font, value: italic, range: span.range)
            }
        case .code, .codeMarker:
            if let c = els.inlineCode.color {
                storage.addAttribute(.foregroundColor, value: c, range: span.range)
            }
        case .linkText:
            if let c = els.link.color {
                storage.addAttribute(.foregroundColor, value: c, range: span.range)
            }
        case .strikethroughBody:
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue, range: span.range)
        case .wikiLink:
            storage.addAttribute(.foregroundColor,
                                 value: els.link.color ?? theme.accentColor, range: span.range)
        case .wikiLinkSyntax:
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
        case .mathBody:
            storage.addAttribute(.foregroundColor,
                                 value: els.inlineCode.color ?? theme.inlineCodeColor,
                                 range: span.range)
        case .mathMarker:
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
        default:
            break
        }
    }
    if let frontmatter = frontmatterRange(in: text),
       NSMaxRange(frontmatter.full) <= nsText.length {
        storage.addAttribute(.font, value: baseFont, range: frontmatter.full)
        storage.addAttribute(.foregroundColor, value: theme.textColor, range: frontmatter.full)
        let openLen = frontmatter.body.location - frontmatter.full.location
        if openLen > 0 {
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                 range: NSRange(location: frontmatter.full.location, length: openLen))
        }
        let closeStart = NSMaxRange(frontmatter.body)
        let closeLen = NSMaxRange(frontmatter.full) - closeStart
        if closeLen > 0 {
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                 range: NSRange(location: closeStart, length: closeLen))
        }
        if EditorSettings.shared.general.syntaxHighlighting {
            CodeSyntaxHighlighter.shared.apply(to: storage, codeRange: frontmatter.body,
                                               language: "yaml", blocking: true)
        }
    }
    storage.endEditing()
    return NSAttributedString(attributedString: storage)
}

/// One Source-highlighted attributed string per logical line — indices match
/// `splitDiffLines` / `lineDiff` line numbers (1-based → array index 0).
@MainActor
func sourceHighlightedLines(_ text: String) -> [NSAttributedString] {
    let full = makeSourceHighlightedString(text)
    let ns = full.string as NSString
    let plain = splitDiffLines(text)
    var lines: [NSAttributedString] = []
    lines.reserveCapacity(plain.count)
    var loc = 0
    for line in plain {
        let len = (line as NSString).length
        let range = NSRange(location: loc, length: min(len, max(0, ns.length - loc)))
        if range.length > 0, NSMaxRange(range) <= ns.length {
            lines.append(full.attributedSubstring(from: range))
        } else if range.location <= ns.length {
            let attrs: [NSAttributedString.Key: Any] = ns.length > 0
                ? full.attributes(at: min(range.location, ns.length - 1), effectiveRange: nil)
                : [.font: EditorSettings.shared.source.resolvedFont(defaultMono: true)]
            lines.append(NSAttributedString(string: line, attributes: attrs))
        } else {
            lines.append(NSAttributedString(string: line))
        }
        loc += len
        if loc < ns.length, ns.character(at: loc) == 0x0A {
            loc += 1
        }
    }
    return lines
}

// MARK: - Text view with lint quick-fixes in the context menu

extension NSFont {
    func withSourceTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(combined), size: pointSize)
    }
}

fileprivate final class SourceNSTextView: NSTextView {

    /// Line numbers / dirty marks, drawn in the left inset (no NSRulerView —
    /// AppKit would pin it to the pane edge, far from a centred column).
    var gutterState = GutterState()

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGutterNumbers(in: rect, state: gutterState)
    }

    var lintDiagnostics: [LintDiagnostic] = []
    private var menuFixes: [LintFix] = []
    private enum SourceTableOp { case rowAbove, rowBelow, deleteRow, colLeft, colRight, deleteColumn }
    private var menuTableOps: [SourceTableOp] = []
    private var menuTableContext: SourceTableContext?

    // Paste as plain text — rich content from the clipboard would introduce
    // attributes the highlighter doesn't own (isRichText is on only so our
    // own per-element attributes render). Exception: a clipboard TABLE (HTML
    // from web/Word/Excel, or TSV) pastes as pipe-table markdown.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if !caretInsideFence(),
           let markdown = markdownTableFromPasteboard(
            html: pasteboard.string(forType: .html),
            plain: pasteboard.string(forType: .string)) {
            insertPastedTable(markdown)
            return
        }
        pasteAsPlainText(sender)
    }

    /// Fenced code blocks are literal — TSV pasted there must stay TSV.
    /// Fence-marker parity up to the caret (``` / ~~~ at line start).
    private func caretInsideFence() -> Bool {
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        var inside = false
        var location = 0
        while location < caret {
            var lineEnd = 0, contentEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd,
                            for: NSRange(location: location, length: 0))
            let line = ns.substring(with: NSRange(location: location,
                                                  length: contentEnd - location))
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inside.toggle() }
            if lineEnd == location { break }
            location = lineEnd
        }
        return inside
    }

    /// Inserts pipe-table markdown, padding with newlines so the table starts
    /// on its own line and the following text keeps its own.
    private func insertPastedTable(_ markdown: String) {
        let ns = string as NSString
        let selection = selectedRange()
        var text = markdown
        let atLineStart = selection.location == 0
            || (selection.location <= ns.length
                && ns.character(at: selection.location - 1) == 0x0A)
        if !atLineStart { text = "\n" + text }
        let end = NSMaxRange(selection)
        if end >= ns.length || ns.character(at: end) != 0x0A { text += "\n" }
        guard shouldChangeText(in: selection, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: selection, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (text as NSString).length,
                                 length: 0))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu else { return menu }
        let point = convert(event.locationInWindow, from: nil)

        if !lintDiagnostics.isEmpty, let idx = characterIndex(at: point) {
            let hits = lintDiagnostics.filter { NSLocationInRange(idx, $0.range) }
            if !hits.isEmpty {
                menuFixes = []
                var insertAt = 0
                for diagnostic in hits {
                    // action == nil → the item auto-disables; serves as a header.
                    let header = NSMenuItem(title: diagnostic.message, action: nil, keyEquivalent: "")
                    menu.insertItem(header, at: insertAt)
                    insertAt += 1
                    for fix in diagnostic.fixes {
                        let item = NSMenuItem(title: fix.title,
                                              action: #selector(applyLintFix(_:)),
                                              keyEquivalent: "")
                        item.target = self
                        item.tag = menuFixes.count
                        item.indentationLevel = 1
                        menuFixes.append(fix)
                        menu.insertItem(item, at: insertAt)
                        insertAt += 1
                    }
                }
                menu.insertItem(.separator(), at: insertAt)
            }
        }

        // Table structure ops when the click lands inside a pipe table.
        if let idx = nearestCharacterIndex(at: point),
           let context = sourceTableContext(in: string, at: idx) {
            menuTableContext = context
            menuTableOps = []
            var insertAt = 0
            func add(_ title: String, _ op: SourceTableOp, enabled: Bool = true) {
                let item = NSMenuItem(title: title,
                                      action: enabled ? #selector(applySourceTableOp(_:)) : nil,
                                      keyEquivalent: "")
                if enabled { item.target = self }
                item.tag = menuTableOps.count
                menuTableOps.append(op)
                menu.insertItem(item, at: insertAt)
                insertAt += 1
            }
            let onBody = context.bodyIndex != nil
            add("Строка выше", .rowAbove, enabled: onBody)
            add("Строка ниже", .rowBelow)
            add("Удалить строку", .deleteRow, enabled: onBody)
            menu.insertItem(.separator(), at: insertAt); insertAt += 1
            add("Столбец слева", .colLeft)
            add("Столбец справа", .colRight)
            add("Удалить столбец", .deleteColumn, enabled: context.grid.columnCount > 1)
            menu.insertItem(.separator(), at: insertAt)
        }
        return menu
    }

    /// Applies a table structure op by replacing the whole table with the
    /// canonical serialization of the mutated grid (reformatting intended).
    @objc private func applySourceTableOp(_ sender: NSMenuItem) {
        guard let context = menuTableContext,
              sender.tag >= 0, sender.tag < menuTableOps.count,
              NSMaxRange(context.tableRange) <= (string as NSString).length else { return }
        var grid = context.grid
        let ok: Bool
        switch menuTableOps[sender.tag] {
        case .rowAbove:
            guard let body = context.bodyIndex else { return }
            grid.insertRow(at: body); ok = true
        case .rowBelow:
            grid.insertRow(at: context.bodyIndex.map { $0 + 1 } ?? 0); ok = true
        case .deleteRow:
            guard let body = context.bodyIndex else { return }
            ok = grid.deleteRow(at: body)
        case .colLeft:
            grid.insertColumn(at: context.column); ok = true
        case .colRight:
            grid.insertColumn(at: context.column + 1); ok = true
        case .deleteColumn:
            ok = grid.deleteColumn(at: context.column)
        }
        guard ok else { NSSound.beep(); return }
        let replacement = serializeGFMTable(grid)
        guard shouldChangeText(in: context.tableRange, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: context.tableRange, with: replacement)
        didChangeText()
    }

    /// Character index of the glyph nearest to a view point — table ops accept
    /// clicks anywhere on the row, incl. right of the line end.
    private func nearestCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        // Reject vertical misses (clicks above/below the text) — nearest-glyph
        // would otherwise snap them onto the first/last line.
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.y >= lineRect.minY, containerPoint.y <= lineRect.maxY else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < ns.length ? charIndex : nil
    }

    @objc private func applyLintFix(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuFixes.count else { return }
        let fix = menuFixes[sender.tag]
        guard NSMaxRange(fix.range) <= (string as NSString).length else { return }
        guard shouldChangeText(in: fix.range, replacementString: fix.replacement) else { return }
        textStorage?.replaceCharacters(in: fix.range, with: fix.replacement)
        didChangeText()
    }

    /// Character index under the view-coordinate point, or nil when the point
    /// falls outside any glyph.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}
