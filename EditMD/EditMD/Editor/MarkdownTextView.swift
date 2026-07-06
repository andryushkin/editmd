import AppKit
import SwiftUI

struct MarkdownTextView: NSViewRepresentable {

    let document: MarkdownDocument
    var theme: EditorTheme = .system
    /// Source mode: raw markdown, no highlighting and no drawn decorations.
    var plainMode: Bool = false
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = MarkdownNSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(
            ofSize: EditorFontSettings.shared.fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)

        scrollView.documentView = textView
        textView.delegate = context.coordinator
        // Track character edits (range + delta) for incremental re-highlighting.
        textView.textStorage?.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.textView = textView
        textView.theme = theme
        textView.string = document.content

        coordinator.rehighlight()
        coordinator.updateStats()
        coordinator.publishActions()

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.fontSizeDidChange),
            name: .editorFontSizeDidChange,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        guard let textView = coordinator.textView else { return }

        if textView.theme.name != theme.name {
            textView.theme = theme
            textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)
            coordinator.rehighlight(.full)
            return
        }

        // Only update text if changed externally (not from typing)
        if !coordinator.isInternalUpdate, textView.string != document.content {
            textView.string = document.content
            coordinator.rehighlight()
            coordinator.updateStats()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {

        var parent: MarkdownTextView
        fileprivate var textView: MarkdownNSTextView?
        var isApplyingHighlight = false
        var isInternalUpdate = false
        private var cachedText: String = ""
        private var cachedSpans: [Span] = []
        private var cachedQuoteDepths: [(NSRange, Int)] = []
        /// Active region used by the last applyHighlighting pass; selection
        /// changes that keep it identical skip restyling entirely.
        private var lastActiveRegion: NSRange?
        /// Character edit accumulated since the last rehighlight
        /// (range in new-text coordinates). Set by the NSTextStorageDelegate.
        private var pendingEdit: (range: NSRange, delta: Int)?
        private var hasHighlightedOnce = false

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isInternalUpdate = true
            parent.document.content = tv.string
            isInternalUpdate = false
            rehighlight()
            updateStats()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingHighlight else { return }
            rehighlight()
        }

        // MARK: - NSTextStorageDelegate

        nonisolated func textStorage(_ textStorage: NSTextStorage,
                                     didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange,
                                     changeInLength delta: Int) {
            // Attribute-only passes (our own highlighting) are not text edits.
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                // Coalescing multiple edits into one union range is conservative
                // but correct — the dirty region only grows.
                if let existing = pendingEdit {
                    pendingEdit = (NSUnionRange(existing.range, editedRange),
                                   existing.delta + delta)
                } else {
                    pendingEdit = (editedRange, delta)
                }
            }
        }

        // MARK: - Highlighting

        enum RehighlightMode { case auto, full }

        func rehighlight(_ mode: RehighlightMode = .auto) {
            if parent.plainMode {
                pendingEdit = nil
                return
            }
            guard !isApplyingHighlight, let storage = textView?.textStorage else { return }
            let sel = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            let len = storage.length
            let cursorPos = len > 0 ? sel.location : nil
            let fullRange = NSRange(location: 0, length: len)

            isApplyingHighlight = true
            defer { isApplyingHighlight = false }

            let edit = pendingEdit
            pendingEdit = nil

            if let edit, hasHighlightedOnce, mode == .auto {
                // Text changed: reparse, restyle only the affected region.
                let oldSpans = cachedSpans
                let oldActiveRegion = lastActiveRegion
                let text = storage.string
                cachedText = text
                cachedSpans = collectSpans(text)
                cachedQuoteDepths = computeQuoteDepths(cachedSpans)

                let nsText = text as NSString
                let newRegion = computeActiveRegion(cursorPos: cursorPos, in: nsText)
                var dirty = spanDiffDirtyRange(oldSpans: oldSpans, newSpans: cachedSpans,
                                               editedRange: edit.range, delta: edit.delta,
                                               newTextLength: len)
                // Marker visibility flips where active-region membership changed.
                let mappedOld = oldActiveRegion.map {
                    mapRange($0, editStart: edit.range.location, delta: edit.delta, textLength: len)
                }
                if mappedOld != newRegion {
                    if let mappedOld { dirty = NSUnionRange(dirty, mappedOld) }
                    if let newRegion { dirty = NSUnionRange(dirty, newRegion) }
                }
                dirty = expandToAdjacentParagraphs(dirty, in: nsText)
                applyHighlighting(to: storage, in: dirty, activeRegion: newRegion)
            } else if !hasHighlightedOnce || mode == .full || edit != nil {
                // First run, theme/font change, or edit forced full: full restyle.
                let text = storage.string
                if text != cachedText {
                    cachedText = text
                    cachedSpans = collectSpans(text)
                    cachedQuoteDepths = computeQuoteDepths(cachedSpans)
                }
                hasHighlightedOnce = true
                let newRegion = computeActiveRegion(cursorPos: cursorPos, in: text as NSString)
                applyHighlighting(to: storage, in: fullRange, activeRegion: newRegion)
            } else {
                // Selection moved, text unchanged: restyle old + new active regions only.
                if storage.length != (cachedText as NSString).length {
                    // Safety net: a text change slipped past the storage delegate.
                    cachedText = storage.string
                    cachedSpans = collectSpans(cachedText)
                    cachedQuoteDepths = computeQuoteDepths(cachedSpans)
                    let newRegion = computeActiveRegion(cursorPos: cursorPos,
                                                        in: cachedText as NSString)
                    applyHighlighting(to: storage, in: fullRange, activeRegion: newRegion)
                    return
                }
                let newRegion = computeActiveRegion(cursorPos: cursorPos,
                                                    in: cachedText as NSString)
                guard newRegion != lastActiveRegion else { return }
                var dirty: NSRange? = newRegion
                if let last = lastActiveRegion {
                    dirty = dirty.map { NSUnionRange($0, last) } ?? last
                }
                guard let dirty, dirty.length > 0 else {
                    lastActiveRegion = newRegion
                    return
                }
                applyHighlighting(to: storage, in: dirty, activeRegion: newRegion)
            }
        }

        /// Line range of the cursor, expanded to any containing quote / code /
        /// list block (all markers of the block stay visible while editing it).
        private func computeActiveRegion(cursorPos: Int?, in text: NSString) -> NSRange? {
            guard let pos = cursorPos, text.length > 0 else { return nil }
            var region = text.lineRange(
                for: NSRange(location: min(pos, text.length - 1), length: 0))
            for span in cachedSpans {
                switch span.kind {
                case .quoteBody, .codeBlockBody, .listBlock:
                    if NSLocationInRange(pos, span.range) {
                        region = NSUnionRange(region, span.range)
                    }
                default: break
                }
            }
            return region
        }

        /// Shifts a pre-edit range into post-edit coordinates.
        private func mapRange(_ r: NSRange, editStart: Int, delta: Int, textLength: Int) -> NSRange {
            let loc = r.location <= editStart ? r.location : r.location + delta
            let end = NSMaxRange(r) <= editStart ? NSMaxRange(r) : NSMaxRange(r) + delta
            let cLoc = min(max(0, loc), textLength)
            let cEnd = min(max(cLoc, end), textLength)
            return NSRange(location: cLoc, length: cEnd - cLoc)
        }

        /// Expands the dirty range to whole lines plus one line on each side —
        /// adjacent paragraphs carry code-block/list spacing that the reset may
        /// wipe or that a structure change may orphan.
        private func expandToAdjacentParagraphs(_ range: NSRange, in text: NSString) -> NSRange {
            guard text.length > 0 else { return NSRange(location: 0, length: 0) }
            let loc = min(range.location, text.length)
            let len = min(range.length, text.length - loc)
            var r = text.lineRange(for: NSRange(location: loc, length: len))
            if r.location > 0 {
                r = NSUnionRange(r, text.lineRange(for: NSRange(location: r.location - 1, length: 0)))
            }
            if NSMaxRange(r) < text.length {
                r = NSUnionRange(r, text.lineRange(for: NSRange(location: NSMaxRange(r), length: 0)))
            }
            return r
        }

        // MARK: - Stats

        func updateStats() {
            guard let tv = textView else { return }
            let (words, chars) = wordAndCharCount(in: tv.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        // MARK: - Format actions

        func publishActions() {
            let actions = FormatActions(
                toggleBold: { [weak self] in self?.wrapSelection(with: "**") },
                toggleItalic: { [weak self] in self?.wrapSelection(with: "*") },
                makeFontBigger: { EditorFontSettings.shared.fontSize += 1 },
                makeFontSmaller: { EditorFontSettings.shared.fontSize -= 1 },
                canIncreaseFontSize: EditorFontSettings.shared.canIncrease,
                canDecreaseFontSize: EditorFontSettings.shared.canDecrease
            )
            DispatchQueue.main.async { [parent] in
                parent.onFormatActions(actions)
            }
        }

        private func wrapSelection(with marker: String) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let (_, newSelection) = applyWrap(marker: marker, to: textView.string, selection: range)
            let selected = (textView.string as NSString).substring(with: range)
            let wrapped = marker + selected + marker
            guard textView.shouldChangeText(in: range, replacementString: wrapped) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: wrapped)
            textView.didChangeText()
            textView.setSelectedRange(newSelection)
        }

        // MARK: - Font size

        @objc func fontSizeDidChange() {
            guard let textView else { return }
            let size = EditorFontSettings.shared.fontSize
            textView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            rehighlight(.full)
            publishActions()
        }

        // MARK: - Quote depth (O(N) via stack)

        private func computeQuoteDepths(_ spans: [Span]) -> [(NSRange, Int)] {
            let ranges = spans.compactMap { s -> NSRange? in
                if case .quoteBody = s.kind { return s.range }
                return nil
            }
            var result: [(NSRange, Int)] = []
            var stack: [Int] = []
            for r in ranges {
                while let top = stack.last, top < NSMaxRange(r) {
                    stack.removeLast()
                }
                result.append((r, stack.count))
                stack.append(NSMaxRange(r))
            }
            return result
        }

        // MARK: - Syntax Highlighting

        /// Applies text attributes inside `range` (the dirty region) and rebuilds
        /// the overlay entry arrays from the full span list. `activeRegion` must
        /// be precomputed via `computeActiveRegion`.
        private func applyHighlighting(to storage: NSTextStorage, in range: NSRange,
                                       activeRegion: NSRange?) {
            lastActiveRegion = activeRegion
            guard range.length > 0 else {
                if storage.length == 0 {
                    textView?.quoteEntries = []
                    textView?.codeBlockEntries = []
                    textView?.headingDividerRanges = []
                    textView?.bulletEntries = []
                    textView?.taskListEntries = []
                    textView?.linkEntries = []
                    textView?.overlayNeedsUpdate = true
                    textView?.needsDisplay = true
                }
                return
            }
            let text = storage.string
            let theme    = parent.theme
            let baseSize = EditorFontSettings.shared.fontSize
            let baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            let secondary = theme.secondaryColor
            let tertiary  = theme.tertiaryColor
            let accent    = theme.accentColor
            let tinyFont  = NSFont.systemFont(ofSize: 0.01)

            let spans = cachedSpans

            func isOnActive(_ r: NSRange) -> Bool {
                guard let activeRegion else { return true }
                return NSIntersectionRange(r, activeRegion).length > 0
            }

            func applyMarker(_ r: NSRange, normalColor: NSColor) {
                if isOnActive(r) {
                    storage.addAttribute(.foregroundColor, value: normalColor, range: r)
                } else {
                    storage.addAttributes([
                        .foregroundColor: NSColor.clear,
                        .font: tinyFont,
                    ], range: r)
                }
            }

            var codeBlockEntries: [(NSRange, String)] = []
            var headingDividerRanges: [NSRange] = []
            var bulletEntries: [(range: NSRange, depth: Int, shouldDraw: Bool)] = []
            var taskListEntries: [(range: NSRange, done: Bool, shouldDraw: Bool)] = []
            var linkEntries: [(range: NSRange, url: URL)] = []
            // Checkbox start locations ("[ ]"/"[x]") — suppress the visual bullet
            // for task items using span data instead of re-scanning the text.
            var taskMarkerLocs = Set<Int>()
            for s in spans {
                if case .taskListMarker = s.kind { taskMarkerLocs.insert(s.range.location) }
            }
            let tableRowBgVisible = theme.tableRowBackground.cgColor.alpha > 0

            // Overlay entries are rebuilt from the FULL span list on every pass —
            // their shouldDraw flags depend on the new active region and the view
            // arrays are replaced wholesale. Storage attribute writes below are
            // restricted to `range` (the dirty region).
            for s in spans {
                switch s.kind {
                case .headingBody(let lv):
                    if lv <= 2 { headingDividerRanges.append(s.range) }
                case .codeBlockBody(let language):
                    codeBlockEntries.append((s.range, language))
                case .listMarker(let ordered, let depth):
                    if !ordered {
                        let active = isOnActive(s.range)
                        let isTaskList = taskMarkerLocs.contains(NSMaxRange(s.range))
                        bulletEntries.append((range: s.range, depth: depth,
                                              shouldDraw: !active && !isTaskList))
                    }
                case .taskListMarker(let done):
                    taskListEntries.append((range: s.range, done: done,
                                            shouldDraw: !isOnActive(s.range)))
                case .linkText(let destination):
                    if let destination, !destination.isEmpty,
                       let url = URL(string: destination), url.scheme != nil {
                        linkEntries.append((range: s.range, url: url))
                    }
                default: break
                }
            }

            storage.beginEditing()

            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: NSParagraphStyle.default,
            ], range: range)

            for s in spans {
                guard NSIntersectionRange(s.range, range).length > 0 || s.range.length == 0 else { continue }

                switch s.kind {
                case .headingBody(let lv):
                    let offset: CGFloat = lv == 1 ? theme.h1SizeOffset
                                        : lv == 2 ? theme.h2SizeOffset
                                        : lv == 3 ? theme.h3SizeOffset
                                        :           theme.h4PlusSizeOffset
                    let sz = baseSize + offset
                    let para = NSMutableParagraphStyle()
                    para.paragraphSpacingBefore = lv <= 2 ? theme.h1_2SpacingBefore : theme.h3PlusSpacingBefore
                    para.paragraphSpacing = theme.headingSpacingAfter
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: sz, weight: .semibold),
                        .foregroundColor: NSColor.labelColor,
                        .paragraphStyle: para,
                    ], range: s.range)

                case .headingMarker:
                    applyMarker(s.range, normalColor: tertiary)

                case .boldBody:
                    let existing = storage.attribute(.font, at: s.range.location, effectiveRange: nil)
                        as? NSFont ?? baseFont
                    let combined = existing.fontDescriptor.symbolicTraits.union(.bold)
                    if let font = existing.withSymbolicTraits(combined) {
                        storage.addAttribute(.font, value: font, range: s.range)
                    }

                case .boldMarker:
                    applyMarker(s.range, normalColor: secondary)

                case .italicBody:
                    let existing = storage.attribute(.font, at: s.range.location, effectiveRange: nil)
                        as? NSFont ?? baseFont
                    let combined = existing.fontDescriptor.symbolicTraits.union(.italic)
                    if let font = existing.withSymbolicTraits(combined) {
                        storage.addAttribute(.font, value: font, range: s.range)
                    }

                case .italicMarker:
                    applyMarker(s.range, normalColor: secondary)

                case .code:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize + theme.smallFontOffset, weight: .regular),
                        .backgroundColor: theme.inlineCodeBackground,
                        .foregroundColor: theme.inlineCodeColor,
                    ], range: s.range)

                case .codeMarker:
                    applyMarker(s.range, normalColor: secondary)

                case .linkText(let destination):
                    storage.addAttribute(.foregroundColor, value: accent, range: s.range)
                    if let destination, !destination.isEmpty,
                       URL(string: destination)?.scheme != nil {
                        storage.addAttribute(.toolTip, value: destination, range: s.range)
                    }

                case .linkSyntax:
                    applyMarker(s.range, normalColor: accent)

                case .quoteBody:
                    break  // depth + indent applied below from cachedQuoteDepths

                case .listBlock:
                    break  // used only for activeRegion expansion; no direct styling

                case .quoteMarker:
                    applyMarker(s.range, normalColor: tertiary)

                case .codeBlockBody:
                    let para = NSMutableParagraphStyle()
                    para.headIndent = theme.codeBlockHeadIndent
                    para.firstLineHeadIndent = theme.codeBlockHeadIndent
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize + theme.smallFontOffset, weight: .regular),
                        .foregroundColor: secondary,
                        .paragraphStyle: para,
                    ], range: s.range)

                case .codeBlockFence:
                    applyMarker(s.range, normalColor: tertiary)

                case .thematicBreak:
                    if isOnActive(s.range) {
                        storage.addAttribute(.foregroundColor, value: tertiary, range: s.range)
                    } else {
                        storage.addAttributes([
                            .foregroundColor: theme.separatorColor,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: theme.separatorColor,
                        ], range: s.range)
                    }

                case .listMarker(let ordered, _):
                    if ordered {
                        // Ordered markers (1., 2.) stay visible — the number is meaningful
                        storage.addAttribute(.foregroundColor, value: accent, range: s.range)
                    } else if isOnActive(s.range) {
                        storage.addAttribute(.foregroundColor, value: accent, range: s.range)
                    } else {
                        // NSColor.clear keeps layout width but makes char invisible;
                        // the visual bullet is drawn in drawBackground instead
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: s.range)
                    }

                case .imageText:
                    storage.addAttribute(.foregroundColor,
                                         value: theme.imageColor, range: s.range)

                case .imageSyntax:
                    applyMarker(s.range, normalColor: theme.imageColor)

                case .htmlInline:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize + theme.smallFontOffset, weight: .regular),
                        .foregroundColor: tertiary,
                    ], range: s.range)

                case .htmlBlock:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize + theme.smallFontOffset, weight: .regular),
                        .foregroundColor: tertiary,
                    ], range: s.range)

                case .strikethroughBody:
                    storage.addAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: NSColor.labelColor,
                    ], range: s.range)

                case .strikethroughMarker:
                    applyMarker(s.range, normalColor: secondary)

                case .tableDelimiter:
                    storage.addAttribute(.foregroundColor, value: tertiary, range: s.range)

                case .tableHeader:
                    let existing = storage.attribute(.font, at: s.range.location, effectiveRange: nil)
                        as? NSFont ?? baseFont
                    let combined = existing.fontDescriptor.symbolicTraits.union(.bold)
                    if let font = existing.withSymbolicTraits(combined) {
                        storage.addAttribute(.font, value: font, range: s.range)
                    }

                case .listItemBody(let textStartCol):
                    let nsText = text as NSString
                    let firstLineRange = nsText.lineRange(
                        for: NSRange(location: s.range.location, length: 0))
                    let charWidth = baseFont.maximumAdvancement.width
                    let headIndent = CGFloat(textStartCol - 1) * charWidth
                    let existing = storage.attribute(.paragraphStyle, at: firstLineRange.location,
                                                     effectiveRange: nil) as? NSParagraphStyle
                    let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle)
                        ?? NSMutableParagraphStyle()
                    ps.firstLineHeadIndent = 0
                    ps.headIndent = headIndent
                    if theme.listItemSpacing > 0 {
                        ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, theme.listItemSpacing)
                    }
                    storage.addAttribute(.paragraphStyle, value: ps, range: firstLineRange)

                case .tableRow:
                    if tableRowBgVisible {
                        storage.addAttribute(.backgroundColor,
                                             value: theme.tableRowBackground, range: s.range)
                    }

                case .taskListMarker(let done):
                    let active = isOnActive(s.range)
                    if active {
                        // Show raw markdown when cursor is on this line
                        let markerColor = done ? theme.accentColor : theme.secondaryColor
                        storage.addAttribute(.foregroundColor, value: markerColor, range: s.range)
                    } else {
                        // Hide marker text — graphical checkbox drawn in drawBackground
                        storage.addAttribute(.foregroundColor, value: NSColor.clear, range: s.range)
                    }
                    if done {
                        // Strikethrough on the body text following "[x] "
                        let bodyStart = NSMaxRange(s.range) + 1  // skip the space after [x]
                        let lineRange = (text as NSString).lineRange(
                            for: NSRange(location: s.range.location, length: 0))
                        let lineEnd = lineRange.location + lineRange.length
                        if bodyStart < lineEnd {
                            let nsText = text as NSString
                            var bodyEnd = lineEnd
                            if bodyEnd > 0 && nsText.character(at: bodyEnd - 1) == 0x0A {
                                bodyEnd -= 1
                            }
                            let bodyLen = max(0, bodyEnd - bodyStart)
                            if bodyLen > 0 {
                                storage.addAttributes([
                                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                    .strikethroughColor: theme.secondaryColor,
                                    .foregroundColor:    theme.secondaryColor,
                                ], range: NSRange(location: bodyStart, length: bodyLen))
                            }
                        }
                    }
                }
            }

            // Apply depth-based indent + foreground color using precomputed depths.
            let quoteEntries = cachedQuoteDepths
            for (r, depth) in quoteEntries {
                // paragraphStyle must start at the paragraph (line) beginning so that
                // NSLayoutManager picks it up for the whole paragraph. Nested blockquotes
                // start at column >1, but their containing paragraph starts at column 1.
                let lineStart = (text as NSString).lineRange(
                    for: NSRange(location: r.location, length: 0)).location
                let paraRange = NSRange(location: lineStart, length: NSMaxRange(r) - lineStart)
                guard NSIntersectionRange(paraRange, range).length > 0 else { continue }
                let indent = CGFloat(depth) * theme.quoteIndentStep
                let para = NSMutableParagraphStyle()
                para.headIndent = indent
                para.firstLineHeadIndent = indent
                // foregroundColor applies to quoteBody range only
                storage.addAttribute(.foregroundColor, value: secondary, range: r)
                storage.addAttribute(.paragraphStyle, value: para, range: paraRange)
            }

            // Add spacing around code blocks on the adjacent paragraphs.
            // Cannot use paragraphSpacingBefore on the fence line itself — tinyFont (0.01pt)
            // causes NSLayoutManager to ignore spacing on near-zero-height paragraphs.
            let nsCodeText = text as NSString
            let nsCodeLen = nsCodeText.length
            for (codeRange, _) in codeBlockEntries {
                if codeRange.location > 0 {
                    let prevRange = nsCodeText.lineRange(
                        for: NSRange(location: codeRange.location - 1, length: 0))
                    if NSIntersectionRange(prevRange, range).length > 0 {
                        let existing = storage.attribute(.paragraphStyle, at: prevRange.location,
                                                         effectiveRange: nil) as? NSParagraphStyle
                        let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                        ps.paragraphSpacing = max(ps.paragraphSpacing, theme.codeBlockOuterSpacing)
                        storage.addAttribute(.paragraphStyle, value: ps, range: prevRange)
                    }
                }
                let afterLoc = NSMaxRange(codeRange)
                if afterLoc < nsCodeLen {
                    let nextRange = nsCodeText.lineRange(
                        for: NSRange(location: afterLoc, length: 0))
                    if NSIntersectionRange(nextRange, range).length > 0 {
                        let existing = storage.attribute(.paragraphStyle, at: nextRange.location,
                                                         effectiveRange: nil) as? NSParagraphStyle
                        let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                        ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, theme.codeBlockOuterSpacing)
                        storage.addAttribute(.paragraphStyle, value: ps, range: nextRange)
                    }
                }
            }

            storage.endEditing()
            textView?.quoteEntries = quoteEntries
            textView?.codeBlockEntries = codeBlockEntries
            textView?.headingDividerRanges = headingDividerRanges
            textView?.bulletEntries = bulletEntries
            textView?.taskListEntries = taskListEntries
            textView?.linkEntries = linkEntries
            textView?.overlayNeedsUpdate = true
            textView?.needsDisplay = true
        }
    }
}

// MARK: - Copy button for code blocks

private final class CodeCopyButton: NSButton {
    var codeRange: NSRange = .init()
    var fillColor: NSColor = NSColor(white: 0.5, alpha: 0.12)

    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

// MARK: - Custom NSTextView with blockquote left-border and code block panel drawing

fileprivate final class MarkdownNSTextView: NSTextView, NSLayoutManagerDelegate {
    var theme: EditorTheme = .system
    /// Each entry: (character range of the blockquote, nesting depth 0-based)
    var quoteEntries: [(NSRange, Int)] = []
    /// Each entry: (full range of the fenced code block, language identifier)
    var codeBlockEntries: [(range: NSRange, language: String)] = []
    /// Ranges of H1 and H2 headings, for drawing bottom divider lines.
    var headingDividerRanges: [NSRange] = []
    /// Unordered list marker ranges with nesting depth; bullets drawn in drawBackground.
    var bulletEntries: [(range: NSRange, depth: Int, shouldDraw: Bool)] = []
    /// Task list marker ranges; graphical checkboxes drawn in drawBackground.
    var taskListEntries: [(range: NSRange, done: Bool, shouldDraw: Bool)] = []
    /// Link text ranges with resolved destination URLs; opened via Cmd+click.
    var linkEntries: [(range: NSRange, url: URL)] = []
    private var codeOverlayButtons: [CodeCopyButton] = []
    /// Set to true after codeBlockEntries change; cleared once overlays are updated.
    var overlayNeedsUpdate = false

    func updateCodeBlockOverlays() {
        guard let layoutManager else { return }
        let inset = textContainerInset
        let fullWidth = bounds.width - inset.width * 2
        let totalLen = (string as NSString).length

        // Force layout only up to the last code block (TextKit 1 lays out
        // sequentially) instead of the entire document; documents without
        // code blocks skip forced layout entirely.
        if let lastEnd = codeBlockEntries.map({ NSMaxRange($0.range) }).max() {
            layoutManager.ensureLayout(
                forCharacterRange: NSRange(location: 0, length: min(lastEnd, totalLen)))
        }

        // Pool: remove excess buttons
        while codeOverlayButtons.count > codeBlockEntries.count {
            codeOverlayButtons.popLast()?.removeFromSuperview()
        }
        // Pool: add missing buttons
        while codeOverlayButtons.count < codeBlockEntries.count {
            let btn = CodeCopyButton(frame: .zero)
            btn.isBordered = false
            btn.fillColor = theme.copyButtonBackground
            btn.contentTintColor = theme.secondaryColor
            btn.target = self
            btn.action = #selector(copyCodeBlock(_:))
            addSubview(btn)
            codeOverlayButtons.append(btn)
        }

        // Update frame/isHidden of existing buttons (safe from layout(), no subview churn)
        for (index, entry) in codeBlockEntries.enumerated() {
            let btn = codeOverlayButtons[index]
            btn.codeRange = entry.range
            btn.title = entry.language.isEmpty ? "⎘" : entry.language
            btn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            btn.sizeToFit()

            guard entry.range.location < totalLen else { btn.isHidden = true; continue }
            let safe = NSRange(location: entry.range.location,
                               length: min(entry.range.length, totalLen - entry.range.location))
            guard safe.length > 0 else { btn.isHidden = true; continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            var blockRect = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [inset, fullWidth] fr, _, _, _, _ in
                let lr = NSRect(x: inset.width, y: fr.minY + inset.height, width: fullWidth, height: fr.height)
                blockRect = blockRect.isNull ? lr : blockRect.union(lr)
            }

            guard !blockRect.isNull else { btn.isHidden = true; continue }
            btn.isHidden = false
            let paddedRect = blockRect.insetBy(dx: 0, dy: -theme.codeBlockPanelInset)
            let w = btn.frame.width + 10
            let h: CGFloat = 18
            let newFrame = NSRect(x: paddedRect.maxX - w - 6, y: paddedRect.minY + 6, width: w, height: h)
            if btn.frame != newFrame { btn.frame = newFrame }
        }
    }

    @objc private func copyCodeBlock(_ sender: CodeCopyButton) {
        let raw = (string as NSString).substring(with: sender.codeRange)
        var lines = raw.components(separatedBy: "\n")
        if lines.first?.hasPrefix("`") == true { lines.removeFirst() }
        if lines.last?.hasPrefix("`") == true { lines.removeLast() }
        while lines.last == "" { lines.removeLast() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // MARK: - Mouse interaction (checkbox toggle, Cmd+click links)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Plain click on a drawn checkbox toggles [ ] <-> [x]
        if let entry = taskListEntry(at: point) {
            toggleCheckbox(entry)
            return
        }

        // Cmd+click on a link opens its destination
        if event.modifierFlags.contains(.command), let url = linkURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }

        super.mouseDown(with: event)
    }

    /// Character index under the view-coordinate point, or nil when the point
    /// falls outside any glyph (e.g. trailing whitespace / empty area).
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

    private func linkURL(at point: NSPoint) -> URL? {
        guard let idx = characterIndex(at: point) else { return nil }
        return linkEntries.first { NSLocationInRange(idx, $0.range) }?.url
    }

    private func taskListEntry(at point: NSPoint) -> (range: NSRange, done: Bool)? {
        for entry in taskListEntries where entry.shouldDraw {
            if let box = checkboxRect(for: entry.range),
               box.insetBy(dx: -2, dy: -2).contains(point) {
                return (entry.range, entry.done)
            }
        }
        return nil
    }

    private func toggleCheckbox(_ entry: (range: NSRange, done: Bool)) {
        // entry.range covers "[ ]"/"[x]" — replace the state char between the brackets
        let stateRange = NSRange(location: entry.range.location + 1, length: 1)
        let replacement = entry.done ? " " : "x"
        guard shouldChangeText(in: stateRange, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: stateRange, with: replacement)
        didChangeText()
    }

    /// View-coordinate rect of the drawn checkbox for a "[ ]"/"[x]" marker range.
    /// Shared by drawBackground and mouseDown hit-testing.
    private func checkboxRect(for range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let totalLen = (string as NSString).length
        guard range.location < totalLen else { return nil }
        let safe = NSRange(location: range.location,
                           length: min(range.length, totalLen - range.location))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { return nil }
        let markerRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard markerRect.width > 0, markerRect.height > 0 else { return nil }
        let boxSize: CGFloat = 14.0
        return NSRect(x: textContainerInset.width + markerRect.minX + 2,
                      y: textContainerInset.height + markerRect.midY - boxSize / 2,
                      width: boxSize, height: boxSize)
    }

    override func layout() {
        super.layout()
        updateCodeBlockOverlays()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            layoutManager?.delegate = self
            DispatchQueue.main.async { [weak self] in
                self?.updateCodeBlockOverlays()
            }
        }
    }

    nonisolated func layoutManager(_ layoutManager: NSLayoutManager,
                                  didCompleteLayoutFor textContainer: NSTextContainer?,
                                  atEnd layoutFinishedFlag: Bool) {
        guard layoutFinishedFlag else { return }
        MainActor.assumeIsolated {
            guard overlayNeedsUpdate else { return }
            overlayNeedsUpdate = false
            updateCodeBlockOverlays()
        }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager else { return }
        let inset = textContainerInset
        let totalLen = (string as NSString).length
        let fullWidth = bounds.width - inset.width * 2

        // Code block background panels
        if !codeBlockEntries.isEmpty {
            let codeBackground = theme.codeBlockBackground
            let cornerRadius = theme.codeBlockCornerRadius
            for entry in codeBlockEntries {
                let range = entry.range
                guard range.location < totalLen else { continue }
                let safe = NSRange(location: range.location,
                                   length: min(range.length, totalLen - range.location))
                guard safe.length > 0 else { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
                var blockRect = NSRect.null
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [inset, fullWidth] fragRect, _, _, _, _ in
                    let lineRect = NSRect(x: inset.width, y: fragRect.minY + inset.height,
                                         width: fullWidth, height: fragRect.height)
                    blockRect = blockRect.isNull ? lineRect : blockRect.union(lineRect)
                }
                if !blockRect.isNull && blockRect.intersects(rect) {
                    let padded = blockRect.insetBy(dx: 0, dy: -theme.codeBlockPanelInset)
                    codeBackground.setFill()
                    if cornerRadius > 0 {
                        NSBezierPath(roundedRect: padded, xRadius: cornerRadius, yRadius: cornerRadius).fill()
                    } else {
                        padded.fill()
                    }
                }
            }
        }

        // Blockquote: optional background fill + left-border bars
        if !quoteEntries.isEmpty {
            let baseBarX = max(0, inset.width - theme.quoteBarXOffset)
            let hasQuoteBg = theme.quoteBackground.cgColor.alpha > 0

            for (range, depth) in quoteEntries {
                guard range.location < totalLen else { continue }
                let safe = NSRange(location: range.location,
                                   length: min(range.length, totalLen - range.location))
                guard safe.length > 0 else { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)

                // Single pass: collect bg union rect and per-line bar rects
                let barX = baseBarX + CGFloat(depth) * theme.quoteIndentStep
                let barWidth = theme.quoteBarWidth
                var bgRect = NSRect.null
                var barRects: [NSRect] = []
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [inset, fullWidth, barX, barWidth] fragRect, _, _, _, _ in
                    let lineY = fragRect.minY + inset.height
                    let lr = NSRect(x: inset.width, y: lineY, width: fullWidth, height: fragRect.height)
                    bgRect = bgRect.isNull ? lr : bgRect.union(lr)
                    barRects.append(NSRect(x: barX, y: lineY, width: barWidth, height: fragRect.height))
                }
                // Background first (bars drawn on top)
                if hasQuoteBg && !bgRect.isNull && bgRect.intersects(rect) {
                    theme.quoteBackground.setFill()
                    bgRect.fill()
                }
                theme.separatorColor.setFill()
                for barRect in barRects where barRect.intersects(rect) { barRect.fill() }
            }
        }

        // Unordered list bullets — drawn as shapes (NSBezierPath).
        // Uses boundingRect(forGlyphRange:in:) which forces glyph generation and returns
        // the exact character rect — more reliable than lineFragmentRect + location(forGlyphAt:)
        // in TextKit 2 compatibility mode.
        if !bulletEntries.isEmpty {
            guard let textContainer = self.textContainer else { return }

            for (range, depth, shouldDraw) in bulletEntries {
                guard shouldDraw, range.location < totalLen else { continue }

                let charRange = NSRange(location: range.location, length: 1)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: charRange,
                                                          actualCharacterRange: nil)
                guard glyphRange.location != NSNotFound, glyphRange.length > 0 else { continue }

                let bulletRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                guard bulletRect.width > 0, bulletRect.height > 0 else { continue }

                let cx = inset.width + bulletRect.midX
                let cy = inset.height + bulletRect.midY
                let r  = bulletRect.height * 0.22   // 22% of line height — visible at any font size
                let drawRect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)

                theme.accentColor.setFill()
                theme.accentColor.setStroke()
                switch depth % 3 {
                case 0:   // • filled circle
                    NSBezierPath(ovalIn: drawRect).fill()
                case 1:   // ◦ hollow circle
                    let path = NSBezierPath(ovalIn: drawRect)
                    path.lineWidth = max(1.5, r * 0.4)
                    path.stroke()
                default:  // ▪ small square
                    let s = r * 0.85
                    NSBezierPath(rect: NSRect(x: cx - s, y: cy - s, width: s * 2, height: s * 2)).fill()
                }
            }
        }

        // Task list checkboxes — drawn as rounded squares with optional checkmark
        if !taskListEntries.isEmpty {
            for (range, done, shouldDraw) in taskListEntries {
                guard shouldDraw, let boxRect = checkboxRect(for: range) else { continue }
                let boxSize = boxRect.height
                let path = NSBezierPath(roundedRect: boxRect, xRadius: 3.5, yRadius: 3.5)
                path.lineWidth = 1.5

                if done {
                    // Filled box with white checkmark
                    theme.accentColor.setFill()
                    path.fill()

                    let check = NSBezierPath()
                    check.move(to: NSPoint(x: boxRect.minX + 3.5, y: boxRect.minY + boxSize * 0.45))
                    check.line(to: NSPoint(x: boxRect.minX + boxSize * 0.45, y: boxRect.minY + boxSize * 0.75))
                    check.line(to: NSPoint(x: boxRect.maxX - 3.5, y: boxRect.minY + boxSize * 0.25))
                    check.lineWidth = 2.0
                    check.lineCapStyle = .round
                    check.lineJoinStyle = .round
                    NSColor.white.setStroke()
                    check.stroke()
                } else {
                    // Empty box outline
                    theme.secondaryColor.setStroke()
                    path.stroke()
                }
            }
        }

        // H1/H2 heading divider lines
        if !headingDividerRanges.isEmpty && theme.headingDividerColor.cgColor.alpha > 0 {
            theme.headingDividerColor.setFill()
            for range in headingDividerRanges {
                guard range.location < totalLen else { continue }
                let safe = NSRange(location: range.location,
                                   length: min(range.length, totalLen - range.location))
                guard safe.length > 0 else { continue }
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
                var lastBottom: CGFloat = 0
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [inset] fragRect, _, _, _, _ in
                    lastBottom = fragRect.maxY + inset.height
                }
                guard lastBottom > 0 else { continue }
                let lineRect = NSRect(x: inset.width, y: lastBottom - 1,
                                     width: fullWidth, height: 1)
                if lineRect.intersects(rect) { lineRect.fill() }
            }
        }
    }
}

private extension NSFont {
    func withSymbolicTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
