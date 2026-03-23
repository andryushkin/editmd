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

        let textView = NSTextView()
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
        var textView: NSTextView?
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
            parent.onStatsUpdate(words, chars)
        }

        // MARK: - Format actions

        func publishActions() {
            parent.onFormatActions(FormatActions(
                toggleBold: { [weak self] in self?.wrapSelection(with: "**") },
                toggleItalic: { [weak self] in self?.wrapSelection(with: "*") },
                makeFontBigger: { EditorFontSettings.shared.fontSize += 1 },
                makeFontSmaller: { EditorFontSettings.shared.fontSize -= 1 },
                canIncreaseFontSize: EditorFontSettings.shared.canIncrease,
                canDecreaseFontSize: EditorFontSettings.shared.canDecrease
            ))
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

            func markerColor(_ r: NSRange, normal: NSColor) -> NSColor {
                guard let activeLine else { return normal }
                return NSIntersectionRange(r, activeLine).length > 0 ? normal : .clear
            }

            let spans = collectSpans(text)

            storage.beginEditing()

            storage.setAttributes([
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ], range: range)

            for s in spans {
                guard NSIntersectionRange(s.range, range).length > 0 || s.range.length == 0 else { continue }

                switch s.kind {
                case .headingBody(let lv):
                    let sz: CGFloat = lv == 1 ? baseSize + 8
                                    : lv == 2 ? baseSize + 5
                                    : lv == 3 ? baseSize + 3
                                    :           baseSize + 1
                    storage.addAttributes([
                        .font: NSFont.systemFont(ofSize: sz, weight: .bold),
                        .foregroundColor: NSColor.labelColor,
                    ], range: s.range)

                case .headingMarker:
                    storage.addAttribute(.foregroundColor,
                                         value: markerColor(s.range, normal: tertiary),
                                         range: s.range)

                case .boldBody:
                    storage.addAttribute(.font,
                                         value: NSFont.systemFont(ofSize: baseSize, weight: .bold),
                                         range: s.range)

                case .boldMarker:
                    storage.addAttribute(.foregroundColor,
                                         value: markerColor(s.range, normal: secondary),
                                         range: s.range)

                case .italicBody:
                    let existing = storage.attribute(.font, at: s.range.location, effectiveRange: nil)
                        as? NSFont ?? baseFont
                    let combined = existing.fontDescriptor.symbolicTraits.union(.italic)
                    if let font = existing.withSymbolicTraits(combined) {
                        storage.addAttribute(.font, value: font, range: s.range)
                    }

                case .italicMarker:
                    storage.addAttribute(.foregroundColor,
                                         value: markerColor(s.range, normal: secondary),
                                         range: s.range)

                case .code:
                    storage.addAttributes([
                        .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                        .backgroundColor: NSColor.controlBackgroundColor,
                        .foregroundColor: NSColor.systemOrange,
                    ], range: s.range)

                case .linkText:
                    storage.addAttribute(.foregroundColor, value: accent, range: s.range)

                case .linkSyntax:
                    storage.addAttribute(.foregroundColor,
                                         value: markerColor(s.range, normal: accent),
                                         range: s.range)

                case .quoteBody:
                    storage.addAttribute(.foregroundColor, value: secondary, range: s.range)

                case .quoteMarker:
                    storage.addAttribute(.foregroundColor,
                                         value: markerColor(s.range, normal: tertiary),
                                         range: s.range)
                }
            }

            storage.endEditing()
        }
    }
}

private extension NSFont {
    func withSymbolicTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
