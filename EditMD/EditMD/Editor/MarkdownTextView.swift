import AppKit
import SwiftUI

struct MarkdownTextView: NSViewRepresentable {

    let document: MarkdownDocument
    var theme: EditorTheme = .system
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
            coordinator.rehighlight()
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
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: MarkdownTextView
        fileprivate var textView: MarkdownNSTextView?
        var isApplyingHighlight = false
        var isInternalUpdate = false
        private var cachedText: String = ""
        private var cachedSpans: [Span] = []
        private var cachedQuoteDepths: [(NSRange, Int)] = []

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

        // MARK: - Highlighting

        func rehighlight() {
            guard !isApplyingHighlight, let storage = textView?.textStorage else { return }
            let sel = textView?.selectedRange() ?? NSRange(location: 0, length: 0)
            let len = storage.length
            let cursorPos = len > 0 ? sel.location : nil
            let text = storage.string

            isApplyingHighlight = true

            if text != cachedText {
                cachedText = text
                cachedSpans = collectSpans(text)
                cachedQuoteDepths = computeQuoteDepths(cachedSpans)
            }
            applyHighlighting(to: storage, in: NSRange(location: 0, length: len),
                              cursorPos: cursorPos)
            isApplyingHighlight = false
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
            rehighlight()
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

        private func applyHighlighting(to storage: NSTextStorage, in range: NSRange, cursorPos: Int?) {
            guard range.length > 0 else { return }
            let text = storage.string
            let theme    = parent.theme
            let baseSize = EditorFontSettings.shared.fontSize
            let baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            let secondary = theme.secondaryColor
            let tertiary  = theme.tertiaryColor
            let accent    = theme.accentColor
            let tinyFont  = NSFont.systemFont(ofSize: 0.01)

            let spans = cachedSpans

            // Block-aware active region: when cursor is inside a quoteBody or codeBlockBody,
            // expand the active region to the entire block so all markers become visible.
            let activeLine: NSRange? = cursorPos.flatMap { pos in
                let len = storage.length
                guard len > 0 else { return nil }
                return (text as NSString).lineRange(
                    for: NSRange(location: min(pos, len - 1), length: 0))
            }
            var activeRegion: NSRange? = activeLine
            if let pos = cursorPos {
                for span in spans {
                    switch span.kind {
                    case .quoteBody, .codeBlockBody:
                        if NSLocationInRange(pos, span.range) {
                            activeRegion = activeRegion.map { NSUnionRange($0, span.range) } ?? span.range
                        }
                    default: break
                    }
                }
            }

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
            let tableRowBgVisible = theme.tableRowBackground.cgColor.alpha > 0

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
                    if lv <= 2 {
                        headingDividerRanges.append(s.range)
                    }

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

                case .linkText:
                    storage.addAttribute(.foregroundColor, value: accent, range: s.range)

                case .linkSyntax:
                    applyMarker(s.range, normalColor: accent)

                case .quoteBody:
                    break  // depth + indent applied below from cachedQuoteDepths

                case .quoteMarker:
                    applyMarker(s.range, normalColor: tertiary)

                case .codeBlockBody(let language):
                    codeBlockEntries.append((s.range, language))
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

                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: accent, range: s.range)

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

                case .listItemBody:
                    guard theme.listItemSpacing > 0 else { break }
                    let existing = storage.attribute(.paragraphStyle, at: s.range.location,
                                                     effectiveRange: nil) as? NSParagraphStyle
                    let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, theme.listItemSpacing)
                    let lineStart = (text as NSString).lineRange(
                        for: NSRange(location: s.range.location, length: 0)).location
                    let paraRange = NSRange(location: lineStart, length: NSMaxRange(s.range) - lineStart)
                    storage.addAttribute(.paragraphStyle, value: ps, range: paraRange)

                case .tableRow:
                    if tableRowBgVisible {
                        storage.addAttribute(.backgroundColor,
                                             value: theme.tableRowBackground, range: s.range)
                    }

                case .taskListMarker(let done):
                    let markerColor = done ? theme.accentColor : theme.secondaryColor
                    storage.addAttribute(.foregroundColor, value: markerColor, range: s.range)
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
                let indent = CGFloat(depth) * theme.quoteIndentStep
                let para = NSMutableParagraphStyle()
                para.headIndent = indent
                para.firstLineHeadIndent = indent
                // foregroundColor applies to quoteBody range only
                storage.addAttribute(.foregroundColor, value: secondary, range: r)
                // paragraphStyle must start at the paragraph (line) beginning so that
                // NSLayoutManager picks it up for the whole paragraph. Nested blockquotes
                // start at column >1, but their containing paragraph starts at column 1.
                let lineStart = (text as NSString).lineRange(
                    for: NSRange(location: r.location, length: 0)).location
                let paraRange = NSRange(location: lineStart, length: NSMaxRange(r) - lineStart)
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
                    let existing = storage.attribute(.paragraphStyle, at: prevRange.location,
                                                     effectiveRange: nil) as? NSParagraphStyle
                    let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    ps.paragraphSpacing = max(ps.paragraphSpacing, theme.codeBlockOuterSpacing)
                    storage.addAttribute(.paragraphStyle, value: ps, range: prevRange)
                }
                let afterLoc = NSMaxRange(codeRange)
                if afterLoc < nsCodeLen {
                    let nextRange = nsCodeText.lineRange(
                        for: NSRange(location: afterLoc, length: 0))
                    let existing = storage.attribute(.paragraphStyle, at: nextRange.location,
                                                     effectiveRange: nil) as? NSParagraphStyle
                    let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                    ps.paragraphSpacingBefore = max(ps.paragraphSpacingBefore, theme.codeBlockOuterSpacing)
                    storage.addAttribute(.paragraphStyle, value: ps, range: nextRange)
                }
            }

            storage.endEditing()
            textView?.quoteEntries = quoteEntries
            textView?.codeBlockEntries = codeBlockEntries
            textView?.headingDividerRanges = headingDividerRanges
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
    private var codeOverlayButtons: [CodeCopyButton] = []
    /// Set to true after codeBlockEntries change; cleared once overlays are updated.
    var overlayNeedsUpdate = false

    func updateCodeBlockOverlays() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let inset = textContainerInset
        let fullWidth = bounds.width - inset.width * 2
        let totalLen = (string as NSString).length

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
