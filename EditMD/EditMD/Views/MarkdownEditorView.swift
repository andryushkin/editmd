import AppKit

// MARK: - ViewController

final class MarkdownEditorViewController: NSViewController {

    private let document: MarkdownDocument
    private var textView: NSTextView!
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

        rehighlight()
        view = scrollView

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
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Guard against recursive calls triggered by attribute-only changes.
        guard !isApplyingHighlight else { return }
        rehighlight()
    }
}

// MARK: - Syntax highlighting

extension MarkdownEditorViewController {

    private static let headingPattern    = try! NSRegularExpression(pattern: #"^(#{1,6})\s.*$"#, options: .anchorsMatchLines)
    private static let boldPattern       = try! NSRegularExpression(pattern: #"(\*\*|__).+?\1"#)
    private static let italicPattern     = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
    private static let codePattern       = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let linkPattern       = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]*\)"#)
    private static let blockquotePattern = try! NSRegularExpression(pattern: #"^>\s.*$"#, options: .anchorsMatchLines)

    /// Applies syntax highlighting. Markers (*, **, #, >, etc.) outside `activeLine`
    /// are painted `.clear` to implement cursor-proximity Live Preview.
    func applyHighlighting(to storage: NSTextStorage, in range: NSRange, activeLine: NSRange?) {
        guard range.length > 0 else { return }
        let text = storage.string
        let nsText = text as NSString

        // Returns `normal` color when marker is on the active line, `.clear` otherwise.
        func markerColor(for markerRange: NSRange, normal: NSColor) -> NSColor {
            guard let active = activeLine else { return normal }
            return NSIntersectionRange(markerRange, active).length > 0 ? normal : .clear
        }

        let baseSize = EditorFontSettings.shared.fontSize

        storage.beginEditing()

        // Reset to base style
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ], range: range)

        let secondaryColor = NSColor.secondaryLabelColor
        let tertiaryColor  = NSColor.tertiaryLabelColor
        let accentColor    = NSColor.linkColor

        // Headings — larger font, dim # markers off active line
        Self.headingPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            let line = nsText.substring(with: matchRange)
            let level = line.prefix(while: { $0 == "#" }).count
            let size: CGFloat = switch level {
                case 1: baseSize + 8; case 2: baseSize + 5; case 3: baseSize + 3; default: baseSize + 1
            }
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ], range: matchRange)
            let markerLen = min(level + 1, matchRange.length)
            let markerRange = NSRange(location: matchRange.location, length: markerLen)
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: markerRange, normal: tertiaryColor),
                                 range: markerRange)
        }

        // Bold — hide ** markers off active line
        Self.boldPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.font,
                                 value: NSFont.systemFont(ofSize: baseSize, weight: .bold),
                                 range: matchRange)
            guard matchRange.length >= 4 else { return }
            let open  = NSRange(location: matchRange.location, length: 2)
            let close = NSRange(location: matchRange.location + matchRange.length - 2, length: 2)
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: open, normal: secondaryColor),
                                 range: open)
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: close, normal: secondaryColor),
                                 range: close)
        }

        // Italic — hide * markers off active line
        Self.italicPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            let traits: NSFontDescriptor.SymbolicTraits = .italic
            if let font = NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular)
                .withSymbolicTraits(traits) {
                storage.addAttribute(.font, value: font, range: matchRange)
            }
            let open  = NSRange(location: matchRange.location, length: 1)
            let close = NSRange(location: matchRange.location + matchRange.length - 1, length: 1)
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: open, normal: secondaryColor),
                                 range: open)
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: close, normal: secondaryColor),
                                 range: close)
        }

        // Inline code — always fully visible (backticks are part of the content style)
        Self.codePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: baseSize - 1, weight: .regular),
                .backgroundColor: NSColor.controlBackgroundColor,
                .foregroundColor: NSColor.systemOrange,
            ], range: matchRange)
        }

        // Links — color the whole [text](url); hide brackets/url off active line
        Self.linkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range,
                  let textGroup = match?.range(at: 1) else { return }
            // The link text stays colored; surrounding syntax fades off active line
            storage.addAttribute(.foregroundColor, value: accentColor, range: textGroup)
            // Ranges that are NOT the link text: [, ](url)
            let beforeText = NSRange(location: matchRange.location, length: textGroup.location - matchRange.location)
            let afterText  = NSRange(location: textGroup.location + textGroup.length,
                                     length: matchRange.location + matchRange.length - textGroup.location - textGroup.length)
            if beforeText.length > 0 {
                storage.addAttribute(.foregroundColor,
                                     value: markerColor(for: beforeText, normal: accentColor),
                                     range: beforeText)
            }
            if afterText.length > 0 {
                storage.addAttribute(.foregroundColor,
                                     value: markerColor(for: afterText, normal: accentColor),
                                     range: afterText)
            }
        }

        // Blockquotes — dim > marker off active line
        Self.blockquotePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: secondaryColor, range: matchRange)
            let markerRange = NSRange(location: matchRange.location, length: min(2, matchRange.length))
            storage.addAttribute(.foregroundColor,
                                 value: markerColor(for: markerRange, normal: tertiaryColor),
                                 range: markerRange)
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
