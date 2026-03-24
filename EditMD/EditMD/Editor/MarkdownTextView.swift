import AppKit
import SwiftUI

struct MarkdownTextView: NSViewRepresentable {

    let document: MarkdownDocument
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
        textView.textContainerInset = NSSize(width: 48, height: 24)

        scrollView.documentView = textView
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.textView = textView
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
            isApplyingHighlight = true
            applyHighlighting(to: storage, in: NSRange(location: 0, length: len),
                              cursorPos: len > 0 ? sel.location : nil)
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

        // MARK: - Syntax Highlighting

        private func applyHighlighting(to storage: NSTextStorage, in range: NSRange, cursorPos: Int?) {
            guard range.length > 0 else { return }
            let text = storage.string
            let baseSize = EditorFontSettings.shared.fontSize
            let baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            let secondary = NSColor.secondaryLabelColor
            let tertiary  = NSColor.tertiaryLabelColor
            let accent    = NSColor.linkColor
            let tinyFont  = NSFont.systemFont(ofSize: 0.01)

            let spans = collectSpans(text)

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

            var quoteBodyRanges: [NSRange] = []
            var codeBlockEntries: [(NSRange, String)] = []

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
                    let sz: CGFloat = lv == 1 ? baseSize + 8
                                    : lv == 2 ? baseSize + 5
                                    : lv == 3 ? baseSize + 3
                                    :           baseSize + 1
                    let para = NSMutableParagraphStyle()
                    para.paragraphSpacingBefore = lv <= 2 ? 12 : 8
                    para.paragraphSpacing = 4
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: sz, weight: .bold),
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
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                        .backgroundColor: NSColor.controlBackgroundColor,
                        .foregroundColor: NSColor.systemOrange,
                    ], range: s.range)

                case .linkText:
                    storage.addAttribute(.foregroundColor, value: accent, range: s.range)

                case .linkSyntax:
                    applyMarker(s.range, normalColor: accent)

                case .quoteBody:
                    quoteBodyRanges.append(s.range)

                case .quoteMarker:
                    applyMarker(s.range, normalColor: tertiary)

                case .codeBlockBody(let language):
                    codeBlockEntries.append((s.range, language))
                    let para = NSMutableParagraphStyle()
                    para.headIndent = 12
                    para.firstLineHeadIndent = 12
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
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
                            .foregroundColor: NSColor.separatorColor,
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .strikethroughColor: NSColor.separatorColor,
                        ], range: s.range)
                    }

                case .listMarker:
                    applyMarker(s.range, normalColor: accent)

                case .imageText:
                    storage.addAttribute(.foregroundColor,
                                         value: NSColor.systemGreen, range: s.range)

                case .imageSyntax:
                    applyMarker(s.range, normalColor: NSColor.systemGreen)

                case .htmlInline:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                        .foregroundColor: tertiary,
                    ], range: s.range)

                case .htmlBlock:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
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
                    applyMarker(s.range, normalColor: tertiary)

                case .tableHeader:
                    let existing = storage.attribute(.font, at: s.range.location, effectiveRange: nil)
                        as? NSFont ?? baseFont
                    let combined = existing.fontDescriptor.symbolicTraits.union(.bold)
                    if let font = existing.withSymbolicTraits(combined) {
                        storage.addAttribute(.font, value: font, range: s.range)
                    }
                }
            }

            // Compute depth for each quoteBody range (how many other ranges fully contain it)
            // and apply depth-based indent + foreground color.
            let indentStep: CGFloat = 20
            var quoteEntries: [(NSRange, Int)] = []
            for i in quoteBodyRanges.indices {
                let r = quoteBodyRanges[i]
                let depth = quoteBodyRanges.indices.filter { j in
                    j != i
                    && quoteBodyRanges[j].location <= r.location
                    && NSMaxRange(quoteBodyRanges[j]) >= NSMaxRange(r)
                }.count
                quoteEntries.append((r, depth))
                let indent = CGFloat(depth) * indentStep
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

            storage.endEditing()
            textView?.quoteEntries = quoteEntries
            textView?.codeBlockEntries = codeBlockEntries
            textView?.overlayNeedsUpdate = true
            textView?.needsDisplay = true
        }
    }
}

// MARK: - Copy button for code blocks

private final class CodeCopyButton: NSButton {
    var codeRange: NSRange = .init()

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        super.draw(dirtyRect)
    }
}

// MARK: - Custom NSTextView with blockquote left-border and code block panel drawing

fileprivate final class MarkdownNSTextView: NSTextView, NSLayoutManagerDelegate {
    /// Each entry: (character range of the blockquote, nesting depth 0-based)
    var quoteEntries: [(NSRange, Int)] = []
    /// Each entry: (full range of the fenced code block, language identifier)
    var codeBlockEntries: [(range: NSRange, language: String)] = []
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
            btn.contentTintColor = NSColor.secondaryLabelColor
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
            let paddedRect = blockRect.insetBy(dx: 0, dy: -8)
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

        // Code block background panels
        if !codeBlockEntries.isEmpty {
            let codeBackground = NSColor(white: 0.5, alpha: 0.07)
            let fullWidth = bounds.width - inset.width * 2
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
                    let padded = blockRect.insetBy(dx: 0, dy: -8)
                    codeBackground.setFill()
                    padded.fill()
                }
            }
        }

        // Blockquote left-border bars
        if !quoteEntries.isEmpty {
            let baseBarX = max(0, inset.width - 12)
            let indentStep: CGFloat = 20
            NSColor.separatorColor.setFill()
            for (range, depth) in quoteEntries {
                guard range.location < totalLen else { continue }
                let safe = NSRange(location: range.location,
                                   length: min(range.length, totalLen - range.location))
                guard safe.length > 0 else { continue }
                let barX = baseBarX + CGFloat(depth) * indentStep
                let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
                layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { [inset, barX] fragRect, _, _, _, _ in
                    let barRect = NSRect(x: barX, y: fragRect.minY + inset.height, width: 3, height: fragRect.height)
                    if barRect.intersects(rect) { barRect.fill() }
                }
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
