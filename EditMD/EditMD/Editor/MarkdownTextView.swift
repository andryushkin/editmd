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
            let activeLine: NSRange? = len > 0
                ? (storage.string as NSString).lineRange(
                    for: NSRange(location: min(sel.location, max(len - 1, 0)), length: 0))
                : nil
            isApplyingHighlight = true
            applyHighlighting(to: storage, in: NSRange(location: 0, length: len), activeLine: activeLine)
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

        private func applyHighlighting(to storage: NSTextStorage, in range: NSRange, activeLine: NSRange?) {
            guard range.length > 0 else { return }
            let text = storage.string
            let baseSize = EditorFontSettings.shared.fontSize
            let baseFont = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
            let secondary = NSColor.secondaryLabelColor
            let tertiary  = NSColor.tertiaryLabelColor
            let accent    = NSColor.linkColor
            let tinyFont  = NSFont.systemFont(ofSize: 0.01)

            func isOnActive(_ r: NSRange) -> Bool {
                guard let activeLine else { return true }
                return NSIntersectionRange(r, activeLine).length > 0
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

            let spans = collectSpans(text)
            var quoteBodyRanges: [NSRange] = []

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

                case .codeBlockBody:
                    let para = NSMutableParagraphStyle()
                    para.headIndent = 12
                    para.firstLineHeadIndent = 12
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                        .backgroundColor: NSColor.controlBackgroundColor,
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
                storage.addAttributes([
                    .foregroundColor: secondary,
                    .paragraphStyle: para,
                ], range: r)
            }

            storage.endEditing()
            textView?.quoteEntries = quoteEntries
            textView?.needsDisplay = true
        }
    }
}

// MARK: - Custom NSTextView with blockquote left-border drawing

fileprivate final class MarkdownNSTextView: NSTextView {
    /// Each entry: (character range of the blockquote, nesting depth 0-based)
    var quoteEntries: [(NSRange, Int)] = []

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, !quoteEntries.isEmpty else { return }
        let inset = textContainerInset
        let baseBarX = max(0, inset.width - 12)
        let indentStep: CGFloat = 20
        NSColor.separatorColor.setFill()
        let totalLen = (string as NSString).length
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

private extension NSFont {
    func withSymbolicTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
