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

// MARK: - Pure editing helpers (unit-tested)

/// Autoformat trigger: paragraph text prefix → block kind + consumed chars.
/// `currentKind` supplies list depth context ("[] " inside a bullet keeps depth).
func autoformatKind(for text: String, currentKind: MDBlock.Kind) -> (kind: MDBlock.Kind, consumed: Int)? {
    let depth: Int
    switch currentKind {
    case .bulletItem(let d), .orderedItem(let d, _), .taskItem(let d, _):
        depth = d
    case .paragraph:
        depth = 0
    default:
        return nil  // headings/code/raw don't autoformat
    }

    if text.hasPrefix("[] ") || text.hasPrefix("[ ] ") {
        return (.taskItem(depth: depth, done: false), text.hasPrefix("[] ") ? 3 : 4)
    }
    if text.hasPrefix("[x] ") {
        return (.taskItem(depth: depth, done: true), 4)
    }

    // The remaining triggers only convert plain paragraphs.
    guard case .paragraph = currentKind else { return nil }

    if text.hasPrefix("- ") || text.hasPrefix("* ") || text.hasPrefix("+ ") {
        return (.bulletItem(depth: 0), 2)
    }
    let hashes = text.prefix(while: { $0 == "#" })
    if (1...6).contains(hashes.count),
       text.dropFirst(hashes.count).first == " " {
        return (.heading(hashes.count), hashes.count + 1)
    }
    let digits = text.prefix(while: { $0.isNumber })
    if !digits.isEmpty, digits.count <= 9,
       let number = Int(digits),
       text.dropFirst(digits.count).hasPrefix(". ") {
        return (.orderedItem(depth: 0, number: number), digits.count + 2)
    }
    return nil
}

/// Block kind for the next paragraph after pressing Enter at the end of `kind`.
/// nil → plain paragraph.
func continuationKind(after kind: MDBlock.Kind) -> MDBlock.Kind? {
    switch kind {
    case .bulletItem(let depth):
        return .bulletItem(depth: depth)
    case .orderedItem(let depth, let number):
        return .orderedItem(depth: depth, number: number + 1)
    case .taskItem(let depth, _):
        return .taskItem(depth: depth, done: false)
    case .listContinuation(let indent):
        return .listContinuation(indent: indent)
    case .codeBlock:
        return kind
    default:
        return nil
    }
}

/// Tab navigation order inside a table; nil = past the edge (forward: caller
/// appends a row; backward: stay put).
func nextTableCellPosition(row: Int, column: Int, columns: Int, rows: Int,
                           forward: Bool) -> (row: Int, column: Int)? {
    if forward {
        if column + 1 < columns { return (row, column + 1) }
        if row + 1 < rows { return (row + 1, 0) }
        return nil
    }
    if column > 0 { return (row, column - 1) }
    if row > 0 { return (row - 1, columns - 1) }
    return nil
}

/// Kind after Tab / Shift+Tab on a list item; nil when not applicable.
func indentedKind(_ kind: MDBlock.Kind, by delta: Int) -> MDBlock.Kind? {
    func clamp(_ d: Int) -> Int? {
        let next = d + delta
        return next >= 0 && next <= 5 ? next : nil
    }
    switch kind {
    case .bulletItem(let d):
        return clamp(d).map { .bulletItem(depth: $0) }
    case .orderedItem(let d, let n):
        return clamp(d).map { .orderedItem(depth: $0, number: n) }
    case .taskItem(let d, let done):
        return clamp(d).map { .taskItem(depth: $0, done: done) }
    default:
        return nil
    }
}

/// Conservative clipboard heuristic: format text only when it carries
/// unambiguous Markdown structure. Ordinary prose (including punctuation and
/// underscores in identifiers) must keep the normal plain-text paste path.
func looksLikeMarkdownForVisualPaste(_ text: String) -> Bool {
    guard !text.isEmpty else { return false }
    let ns = text as NSString
    let full = NSRange(location: 0, length: ns.length)
    let patterns = [
        #"(?m)^\s{0,3}#{1,6}\s+\S"#,             // heading
        #"(?m)^\s{0,3}(?:[-+*]|\d+[.)])\s+\S"#, // list
        #"(?m)^\s{0,3}>\s?\S"#,                 // quote
        #"(?m)^\s*```[^\n]*$"#,                 // fenced code
        #"(?m)^\s*(?:---+|\*\*\*+)\s*$"#,      // thematic break
        #"(?m)^\s*\|?.+\|.+\n\s*\|?\s*:?-{3}"#, // table
        #"!\[[^\]\n]*\]\([^\)\n]+\)"#,        // image
        #"\[[^\]\n]+\]\([^\)\n]+\)"#,         // link
        #"\[\[[^\]\n]+\]\]"#,                 // wiki-link
        #"(?:\*\*|~~|==)[^\n]+?(?:\*\*|~~|==)"#,
        #"(?<!\*)\*[^*\n]+\*(?!\*)"#,          // emphasis
        #"`[^`\n]+`"#,                           // inline code
    ]
    return patterns.contains { pattern in
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: full) != nil
    }
}

/// Code blocks are literal by definition: Markdown-looking clipboard text
/// pasted there must keep every marker instead of being rendered.
func shouldFormatVisualPaste(_ text: String, in blockKind: MDBlock.Kind) -> Bool {
    if case .codeBlock = blockKind { return false }
    return looksLikeMarkdownForVisualPaste(text)
}

// MARK: - SwiftUI wrapper

struct VisualMarkdownView: NSViewRepresentable {

    let document: MarkdownDocument
    var theme: EditorTheme = .system
    var fileURL: URL? = nil
    var positionStore: EditorPositionStore? = nil
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void
    /// B6: active md.inline styles at caret.
    var onActiveFormats: ((ActiveInlineFormats) -> Void)? = nil
    /// Fractional markdown offset at the bottom of the viewport, for
    /// split-preview scroll sync.
    var onVisibleOffset: ((Double) -> Void)? = nil
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
        coordinator.loadDocument()
        coordinator.publishActions()
        coordinator.refreshGutter()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollOrBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)
        coordinator.scheduleVisibleOffsetPublish()

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
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.followPreviewScroll),
                name: .editMDEditorScrollSync,
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
        textView.textContainerInset = readingInset(forWidth: scrollView.contentView.bounds.width)
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
        coordinator.scheduleVisibleOffsetPublish()
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
        /// One NSTextAttachment per image source — reused across presentation
        /// passes so layout doesn't churn on every keystroke.
        var imageAttachments: [String: NSTextAttachment] = [:]

        var visualStyle: VisualStyle {
            let settings = EditorSettings.shared.visual
            return VisualStyle(baseSize: settings.fontSize,
                               bodyFamily: settings.fontFamily,
                               bodyWeight: settings.fontWeight.nsWeight,
                               elements: settings.elements)
        }

        init(parent: VisualMarkdownView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func loadDocument() {
            guard let textView, let storage = textView.textStorage else { return }
            textView.finishActiveTableEditing(commit: true)
            isLoadingDocument = true
            let rendered = renderMarkdownToAttributed(parent.document.content, style: visualStyle)
            storage.setAttributedString(rendered)
            lastSerialized = parent.document.content
            lastParagraphRanges = serializeAttributedToMarkdownDetailed(storage).paragraphRanges
            rebuildParagraphMaps()   // stays parallel to the map above
            textView.typingAttributes = defaultTypingAttributes()
            applyPresentation()
            updateStats()
            applyReviewHighlights()
            isLoadingDocument = false
            restoreCursor()
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

        /// Display ranges of the paragraphs, parallel to `lastParagraphRanges`
        /// (same index — both are "the Nth display paragraph"). Split sync reads
        /// the two tables side by side and interpolates, which is exactly what
        /// Preview does with its DOM anchors, so the two panes agree on where a
        /// fractional markdown offset lives.
        ///
        /// Going through `markdownOffset(atDisplayLocation:)` instead added the
        /// block's marker length to one end of the paragraph and, at its far
        /// end, landed in the NEXT block — a per-paragraph error that made
        /// Preview lag further behind the further Visual scrolled. It also cost
        /// two O(offset) scans per frame.
        private var displayParagraphRanges: [NSRange] = []
        /// Markdown start of each display paragraph, strictly increasing.
        ///
        /// NOT just `lastParagraphRanges[i].location`: the serializer emits a
        /// code block (or a table) as ONE piece and gives every display
        /// paragraph inside it that whole piece's range. Reading the location
        /// straight out means every line of a code block reports the same
        /// position — the follow froze at the top of the block and only resumed
        /// once the block was scrolled past. Here a group's range is shared out
        /// among its paragraphs, weighted by their lengths.
        private var paragraphMarkdownStarts: [Double] = []

        func rebuildParagraphMaps() {
            guard let textView else { return }
            let text = textView.string as NSString
            var ranges: [NSRange] = []
            var start = 0
            for i in 0..<text.length where text.character(at: i) == 0x0A {
                ranges.append(NSRange(location: start, length: i - start + 1))
                start = i + 1
            }
            ranges.append(NSRange(location: start, length: text.length - start))
            displayParagraphRanges = ranges

            var starts = [Double](repeating: 0, count: lastParagraphRanges.count)
            var index = 0
            while index < lastParagraphRanges.count {
                let piece = lastParagraphRanges[index]
                var last = index
                while last + 1 < lastParagraphRanges.count,
                      lastParagraphRanges[last + 1].location == piece.location,
                      lastParagraphRanges[last + 1].length == piece.length {
                    last += 1
                }
                // Display lengths give the split its shape — a long code line
                // covers more source than a short one.
                let weights: [Double] = (index...last).map { paragraph in
                    paragraph < ranges.count ? Double(max(1, ranges[paragraph].length)) : 1
                }
                let total = weights.reduce(0, +)
                var consumed = 0.0
                for (offset, paragraph) in (index...last).enumerated() {
                    starts[paragraph] = Double(piece.location)
                        + Double(piece.length) * (consumed / total)
                    consumed += weights[offset]
                }
                index = last + 1
            }
            paragraphMarkdownStarts = starts
        }

        /// Markdown start of display paragraph `index`, and of the one after it
        /// — the bracket a fractional position is interpolated in.
        private func markdownSpan(ofParagraph index: Int) -> (start: Double, next: Double)? {
            guard index >= 0, index < paragraphMarkdownStarts.count else { return nil }
            let start = paragraphMarkdownStarts[index]
            let next = index + 1 < paragraphMarkdownStarts.count
                ? paragraphMarkdownStarts[index + 1]
                : Double(NSMaxRange(lastParagraphRanges[index]))
            return (start, max(next, start + 1))
        }

        /// Last paragraph starting at or before `position` (binary search —
        /// `paragraphMarkdownStarts` is increasing).
        private func paragraphIndex(forMarkdownPosition position: Double) -> Int? {
            guard !paragraphMarkdownStarts.isEmpty else { return nil }
            guard paragraphMarkdownStarts[0] <= position else { return 0 }
            var low = 0, high = paragraphMarkdownStarts.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if paragraphMarkdownStarts[mid] <= position { low = mid } else { high = mid }
            }
            return paragraphMarkdownStarts[high] <= position ? high : low
        }

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

        /// Reverse split sync maps markdown back into Visual display space and
        /// scrolls only the viewport, preserving caret and first responder.
        @objc func followPreviewScroll() {
            guard let store = parent.positionStore, let textView else { return }
            let position = store.editorScrollPosition
            let markdownLength = (parent.document.content as NSString).length
            var paragraph = NSRange(location: 0, length: 0)
            var fraction = 0.0
            let edge: SplitScrollSync.Edge?
            if position <= 0 {
                edge = .top
            } else if position >= Double(markdownLength) {
                edge = .bottom
            } else {
                edge = nil
                // Inverse of `visibleMarkdownPosition`: the paragraph whose
                // SOURCE span brackets the position, then the same fraction of
                // that paragraph's DISPLAY height.
                guard let index = paragraphIndex(forMarkdownPosition: position),
                      let span = markdownSpan(ofParagraph: index),
                      index < displayParagraphRanges.count
                else { return }  // no paragraph map yet — leave the viewport alone
                paragraph = displayParagraphRanges[index]
                fraction = (position - span.start) / (span.next - span.start)
            }

            // Same ring guard as Source: our own scroll posts boundsDidChange,
            // and republishing from it would push Preview past where the user
            // left it.
            isFollowingPreviewScroll = true
            SplitScrollSync.scrollViewport(textView, toParagraph: paragraph,
                                           fraction: fraction, edge: edge)
            DispatchQueue.main.async { [weak self] in
                self?.isFollowingPreviewScroll = false
            }
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
            runAutoformat()
            applyPresentation()
            syncToDocument()
            parent.document.noteContentEdited()
            DocumentRegistry.shared.noteUserEdit(parent.fileURL)
            LineChangeTracker.shared.noteContent(url: parent.fileURL,
                                                 content: parent.document.content)
            updateStats()
            // Review wash re-aligns via the model's debounced recompute
            // notification — no per-keystroke quote search here.
            refreshGutter()
            scheduleVisibleOffsetPublish()
        }

        /// Visual gutter shows **source** line numbers (via paragraph→md map), not 1…N of the WYSIWYG buffer.
        func refreshGutter() {
            guard let textView else { return }
            let md = parent.document.content
            textView.gutterState = GutterState(
                settings: EditorSettings.shared.gutter,
                dirtySourceLines: LineChangeTracker.shared.dirtyLines(for: parent.fileURL),
                // Visual shows SOURCE line numbers: paragraphs → markdown lines.
                displayToSourceLine: displayToSourceLineMap(paragraphRanges: lastParagraphRanges,
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
        private var scrollSyncPublishScheduled = false
        /// See the identical flag in SourceTextView: Preview's scroll lands
        /// here as a `clip.scroll`, whose bounds notification must not be
        /// published straight back to Preview.
        private var isFollowingPreviewScroll = false

        @objc func scrollOrBoundsChanged(_ note: Notification) {
            textView?.needsDisplay = true
            scheduleVisibleOffsetPublish()
        }

        /// Publish at most once per main-loop turn. This is a throttle rather
        /// than a debounce, so Preview follows while the gesture is in flight.
        func scheduleVisibleOffsetPublish() {
            guard parent.onVisibleOffset != nil, !isFollowingPreviewScroll,
                  !scrollSyncPublishScheduled else { return }
            scrollSyncPublishScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scrollSyncPublishScheduled = false
                guard !self.isFollowingPreviewScroll, let textView = self.textView,
                      let position = self.visibleMarkdownPosition(in: textView) else { return }
                self.parent.onVisibleOffset?(position)
            }
        }

        /// Fractional markdown offset at the bottom of the viewport. Visual's
        /// display text is not the markdown, so the anchor paragraph is looked
        /// up in the two parallel tables and the fraction spends the SOURCE
        /// characters between this paragraph and the next.
        private func visibleMarkdownPosition(in textView: NSTextView) -> Double? {
            switch SplitScrollSync.position(of: textView) {
            case .unscrollable:
                return nil
            case .atEdge(.top):
                return 0
            case .atEdge(.bottom):
                return Double((parent.document.content as NSString).length)
            case .middle:
                guard let anchor = SplitScrollSync.visibleParagraphAnchor(in: textView)
                else { return nil }
                let index = paragraphIndex(at: anchor.range.location,
                                           in: textView.string as NSString).index
                guard let span = markdownSpan(ofParagraph: index) else { return nil }
                return span.start + anchor.fraction * (span.next - span.start)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep custom attrs out of typing attributes only where harmful:
            // links must not extend as the user types after them.
            // Guard: setAttributedString fires selection sync (v22).
            guard !isMutating, let textView else { return }
            var attrs = textView.typingAttributes
            if attrs[.mdLink] != nil || attrs[.mdImage] != nil || attrs[.mdWikiLink] != nil {
                attrs[.mdLink] = nil
                attrs[.mdImage] = nil
                attrs[.mdWikiLink] = nil
                textView.typingAttributes = attrs
            }
            storeCursor()
            publishActiveFormats()
        }

        private var lastPublishedFormats = ActiveInlineFormats()

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
                fmt.checklist = blocks.allSatisfy { if case .taskItem = $0.kind { true } else { false } }
                fmt.quote = blocks.allSatisfy { $0.quoteDepth > 0 }
                fmt.codeBlock = blocks.allSatisfy { if case .codeBlock = $0.kind { true } else { false } }
            }
            emitFormats(fmt)
        }

        private func emitFormats(_ fmt: ActiveInlineFormats) {
            guard fmt != lastPublishedFormats else { return }
            lastPublishedFormats = fmt
            let callback = parent.onActiveFormats
            DispatchQueue.main.async { callback?(fmt) }
        }

        func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
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
            applyPresentation()
            syncToDocument()
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
            let blockKind: MDBlock.Kind
            if storage.length > 0 {
                let probe = min(selection.location, storage.length - 1)
                blockKind = (storage.attribute(.mdBlock, at: probe, effectiveRange: nil) as? MDBlock)?
                    .kind ?? .paragraph
            } else {
                blockKind = .paragraph
            }
            // Table cells are single-line — structured payloads can't land
            // there; the plain path pastes what fits.
            if case .tableCell = blockKind { return false }

            var markdown: String?
            if case .codeBlock = blockKind {
                markdown = nil   // literal context: keep every marker as text
            } else {
                markdown = markdownTableFromPasteboard(
                    html: pasteboard.string(forType: .html), plain: plain)
            }
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

        // MARK: Tables

        /// All cell paragraphs of a table, in document order.
        func tableCells(group: Int, in storage: NSTextStorage)
            -> [(row: Int, column: Int, columns: Int, alignment: Int, range: NSRange)] {
            let nsText = storage.string as NSString
            var cells: [(Int, Int, Int, Int, NSRange)] = []
            var location = 0
            while location < nsText.length {
                let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
                let blockValue = block(at: paragraph, in: storage)
                if case .tableCell(let row, let column, let columns, let alignment) = blockValue.kind,
                   blockValue.group == group {
                    cells.append((row, column, columns, alignment, paragraph))
                }
                if NSMaxRange(paragraph) == location { break }
                location = NSMaxRange(paragraph)
            }
            return cells
        }

        func tableRange(group: Int, in storage: NSTextStorage) -> NSRange {
            let cells = tableCells(group: group, in: storage)
            guard let first = cells.first, let last = cells.last else {
                return NSRange(location: 0, length: 0)
            }
            return NSRange(location: first.range.location,
                           length: NSMaxRange(last.range) - first.range.location)
        }

        func tableIsland(at paragraphLocation: Int) -> (range: NSRange, grid: TableGrid)? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let nsText = storage.string as NSString
            guard nsText.length > 0 else { return nil }
            let paragraph = nsText.paragraphRange(for: NSRange(location: min(paragraphLocation, nsText.length - 1),
                                                               length: 0))
            let block = block(at: paragraph, in: storage)
            guard case .raw(let raw) = block.kind, let grid = parseGFMTable(raw) else { return nil }
            return (paragraph, grid)
        }

        private func tableIslandDisplayText(_ grid: TableGrid) -> String {
            var lines = serializeGFMTable(grid).components(separatedBy: "\n")
            if lines.count >= 2 { lines.remove(at: 1) } // hide delimiter in Visual display
            return lines.joined(separator: mdHardBreak)
        }

        func replaceTableIsland(paragraph: NSRange, oldBlock: MDBlock, grid: TableGrid) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            var block = oldBlock
            block.kind = .raw(serializeGFMTable(grid))
            let replacement = NSAttributedString(string: tableIslandDisplayText(grid) + "\n", attributes: [
                .font: visualStyle.font(for: [], blockKind: block.kind),
                .foregroundColor: NSColor.labelColor,
                .mdBlock: block,
            ])
            guard textView.shouldChangeText(in: paragraph, replacementString: replacement.string) else {
                return false
            }
            isMutating = true
            storage.replaceCharacters(in: paragraph, with: replacement)
            if replacement.length > 0 {
                storage.addAttribute(.mdBlock, value: block,
                                     range: NSRange(location: paragraph.location, length: replacement.length))
            }
            isMutating = false
            textView.didChangeText()
            afterMutation()
            return true
        }

        @discardableResult
        func updateTableIslandCell(paragraphLocation: Int, row: Int, column: Int, value: String) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            grid.updateCell(row: row, column: column, value: value)
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
        }

        @discardableResult
        func insertTableIslandRow(paragraphLocation: Int, atBodyIndex bodyIndex: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            grid.insertRow(at: bodyIndex)
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
        }

        @discardableResult
        func deleteTableIslandRow(paragraphLocation: Int, atBodyIndex bodyIndex: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            guard grid.deleteRow(at: bodyIndex) else { return false }
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
        }

        /// Places the cursor at the end of a cell's text.
        func moveCursor(toCell target: (row: Int, column: Int), group: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let cells = tableCells(group: group, in: storage)
            guard let cell = cells.first(where: { $0.row == target.row && $0.column == target.column })
            else { return }
            let nsText = storage.string as NSString
            var end = NSMaxRange(cell.range)
            if end > cell.range.location, nsText.character(at: end - 1) == 0x0A { end -= 1 }
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// Appends an empty row; returns the new row index.
        @discardableResult
        func appendTableRow(group: Int) -> Int? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let cells = tableCells(group: group, in: storage)
            guard let last = cells.last else { return nil }
            let columns = last.columns
            let newRow = (cells.map(\.row).max() ?? 0) + 1
            var alignmentByColumn: [Int: Int] = [:]
            for cell in cells { alignmentByColumn[cell.column] = cell.alignment }

            let insertion = NSMutableAttributedString()
            for column in 0..<columns {
                var cellBlock = MDBlock(kind: .tableCell(row: newRow, column: column,
                                                         columns: columns,
                                                         alignment: alignmentByColumn[column] ?? 0))
                cellBlock.group = group
                insertion.append(NSAttributedString(string: "\n", attributes: [
                    .font: visualStyle.font(for: [], blockKind: cellBlock.kind),
                    .foregroundColor: NSColor.labelColor,
                    .mdBlock: cellBlock,
                ]))
            }
            let location = NSMaxRange(last.range)
            let insertRange = NSRange(location: location, length: 0)
            isProgrammaticTableEdit = true
            defer { isProgrammaticTableEdit = false }
            guard textView.shouldChangeText(in: insertRange,
                                            replacementString: insertion.string) else { return nil }
            isMutating = true
            storage.replaceCharacters(in: insertRange, with: insertion)
            isMutating = false
            textView.didChangeText()
            afterMutation()
            return newRow
        }

        /// Deletes a table row (used by "Enter on empty last row exits table").
        func deleteTableRow(_ row: Int, group: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let rowCells = tableCells(group: group, in: storage).filter { $0.row == row }
            guard let first = rowCells.first, let last = rowCells.last else { return }
            let range = NSRange(location: first.range.location,
                                length: NSMaxRange(last.range) - first.range.location)
            isProgrammaticTableEdit = true
            defer { isProgrammaticTableEdit = false }
            guard textView.shouldChangeText(in: range, replacementString: "") else { return }
            isMutating = true
            storage.replaceCharacters(in: range, with: "")
            isMutating = false
            textView.didChangeText()
            afterMutation()
        }

        private func handleTableTab(forward: Bool) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let paragraph = paragraphRange(at: textView.selectedRange().location, in: nsText)
            let current = block(at: paragraph, in: storage)
            guard case .tableCell(let row, let column, let columns, _) = current.kind else {
                return false
            }
            let rows = (tableCells(group: current.group, in: storage).map(\.row).max() ?? 0) + 1
            if let next = nextTableCellPosition(row: row, column: column, columns: columns,
                                                rows: rows, forward: forward) {
                moveCursor(toCell: next, group: current.group)
            } else if forward {
                if let newRow = appendTableRow(group: current.group) {
                    moveCursor(toCell: (newRow, 0), group: current.group)
                }
            }
            return true
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
                case .bulletItem, .orderedItem, .taskItem:
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
            case .bulletItem, .orderedItem, .taskItem:
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

        private func syncToDocument() {
            guard let storage = textView?.textStorage else { return }
            let detailed = serializeAttributedToMarkdownDetailed(storage)
            lastParagraphRanges = detailed.paragraphRanges
            rebuildParagraphMaps()   // stays parallel to the map above
            var serialized = detailed.markdown
            // Single trailing newline (POSIX text files). Do not append a second
            // one when the serializer already ended with \n — that grew blank
            // lines on every Visual edit cycle (C4).
            if !serialized.isEmpty, !serialized.hasSuffix("\n") {
                serialized += "\n"
            }
            lastSerialized = serialized
            isInternalUpdate = true
            parent.document.content = serialized
            isInternalUpdate = false
            storeCursor()
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
