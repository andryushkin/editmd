import AppKit

// MARK: - ViewController

final class MarkdownEditorViewController: NSViewController {

    private let document: MarkdownDocument
    private var textView: NSTextView!
    private var statusLabel: NSTextField!
    private var isApplyingHighlight = false

    init(document: MarkdownDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
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
        textView.font = NSFont.monospacedSystemFont(ofSize: EditorFontSettings.shared.fontSize, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 48, height: 24)

        scrollView.documentView = textView
        self.textView = textView
        textView.delegate = self
        textView.string = document.content

        let label = NSTextField(labelWithString: "")
        label.alignment = .right
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        label.translatesAutoresizingMaskIntoConstraints = false
        self.statusLabel = label

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(label)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: label.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            label.heightAnchor.constraint(equalToConstant: 18),
        ])

        rehighlight()
        updateStats()
        view = container

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(fontSizeDidChange),
            name: .editorFontSizeDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Font size actions

    @objc private func fontSizeDidChange() {
        let size = EditorFontSettings.shared.fontSize
        textView.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        rehighlight()
    }

    @objc func makeFontBigger() {
        EditorFontSettings.shared.fontSize += 1
    }

    @objc func makeFontSmaller() {
        EditorFontSettings.shared.fontSize -= 1
    }

    // MARK: - Stats

    private func updateStats() {
        let (words, chars) = wordAndCharCount(in: textView.string)
        statusLabel.stringValue = "\(words) words  \(chars) chars"
    }

    // MARK: - Formatting

    @objc func toggleBold()   { wrapSelection(with: "**") }
    @objc func toggleItalic() { wrapSelection(with: "*") }

    private func wrapSelection(with marker: String) {
        let range = textView.selectedRange()
        let (_, newSelection) = applyWrap(marker: marker, to: textView.string, selection: range)
        let selected = (textView.string as NSString).substring(with: range)
        let wrapped = marker + selected + marker
        guard textView.shouldChangeText(in: range, replacementString: wrapped) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: wrapped)
        textView.didChangeText()
        textView.setSelectedRange(newSelection)
    }

    // Recomputes active line from current selection and re-applies highlighting.
    private func rehighlight() {
        guard !isApplyingHighlight, let storage = textView?.textStorage else { return }
        let sel = textView.selectedRange()
        let len = storage.length
        let activeLine: NSRange? = len > 0
            ? (storage.string as NSString).lineRange(
                for: NSRange(location: min(sel.location, max(len - 1, 0)), length: 0))
            : nil
        isApplyingHighlight = true
        applyHighlighting(to: storage, in: NSRange(location: 0, length: len), activeLine: activeLine)
        isApplyingHighlight = false
    }
}

// MARK: - NSTextViewDelegate

extension MarkdownEditorViewController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        document.content = tv.string
        document.updateChangeCount(.changeDone)
        rehighlight()
        updateStats()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Guard against recursive calls triggered by attribute-only changes.
        guard !isApplyingHighlight else { return }
        rehighlight()
    }
}


// MARK: - Syntax Highlighting

extension MarkdownEditorViewController {

    /// Applies syntax highlighting using a cmark AST instead of regex patterns.
    /// Markers (*, **, #, >, etc.) outside `activeLine` are painted `.clear`
    /// to implement cursor-proximity Live Preview.
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

        // Reset to base style
        storage.setAttributes([
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ], range: range)

        for s in spans {
            // Skip spans fully outside the requested range
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

// MARK: - NSMenuItemValidation

extension MarkdownEditorViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(makeFontBigger): return EditorFontSettings.shared.canIncrease
        case #selector(makeFontSmaller): return EditorFontSettings.shared.canDecrease
        case #selector(toggleBold), #selector(toggleItalic): return true
        default: return true
        }
    }
}

private extension NSFont {
    func withSymbolicTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
