import AppKit

// MARK: - ViewController

final class MarkdownEditorViewController: NSViewController {

    private let document: MarkdownDocument
    private var textView: NSTextView!

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
        textView.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.backgroundColor = NSColor.textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        // Comfortable reading margins
        textView.textContainerInset = NSSize(width: 48, height: 24)

        scrollView.documentView = textView
        self.textView = textView

        textView.delegate = self
        textView.string = document.content

        applyHighlighting(to: textView.textStorage!, in: NSRange(location: 0, length: (document.content as NSString).length))

        view = scrollView
    }
}

// MARK: - NSTextViewDelegate

extension MarkdownEditorViewController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        guard let tv = notification.object as? NSTextView else { return }
        document.content = tv.string
        document.updateChangeCount(.changeDone)

        if let storage = tv.textStorage {
            applyHighlighting(to: storage, in: NSRange(location: 0, length: storage.length))
        }
    }
}

// MARK: - Syntax highlighting

extension MarkdownEditorViewController {

    private static let headingPattern = try! NSRegularExpression(pattern: #"^(#{1,6})\s.*$"#, options: .anchorsMatchLines)
    private static let boldPattern    = try! NSRegularExpression(pattern: #"(\*\*|__).+?\1"#)
    private static let italicPattern  = try! NSRegularExpression(pattern: #"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#)
    private static let codePattern    = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private static let linkPattern    = try! NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]*\)"#)
    private static let blockquotePattern = try! NSRegularExpression(pattern: #"^>\s.*$"#, options: .anchorsMatchLines)

    func applyHighlighting(to storage: NSTextStorage, in range: NSRange) {
        let text = storage.string
        let nsText = text as NSString

        // Reset to base style
        storage.beginEditing()
        storage.setAttributes([
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.labelColor,
        ], range: range)

        let secondaryColor = NSColor.secondaryLabelColor
        let tertiaryColor = NSColor.tertiaryLabelColor
        let accentColor = NSColor.linkColor

        // Headings: larger font, bold
        Self.headingPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            let line = nsText.substring(with: matchRange)
            let level = line.prefix(while: { $0 == "#" }).count
            let size: CGFloat = switch level {
                case 1: 22; case 2: 19; case 3: 17; default: 15
            }
            storage.addAttributes([
                .font: NSFont.systemFont(ofSize: size, weight: .bold),
                .foregroundColor: NSColor.labelColor,
            ], range: matchRange)
            // dim the # markers
            let markerLen = min(level + 1, matchRange.length)
            let markerRange = NSRange(location: matchRange.location, length: markerLen)
            storage.addAttribute(.foregroundColor, value: tertiaryColor, range: markerRange)
        }

        // Bold markers
        Self.boldPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 14, weight: .bold), range: matchRange)
            // dim ** markers (first and last 2 chars)
            if matchRange.length >= 4 {
                let open = NSRange(location: matchRange.location, length: 2)
                let close = NSRange(location: matchRange.location + matchRange.length - 2, length: 2)
                storage.addAttribute(.foregroundColor, value: secondaryColor, range: open)
                storage.addAttribute(.foregroundColor, value: secondaryColor, range: close)
            }
        }

        // Italic markers
        Self.italicPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            let traits: NSFontDescriptor.SymbolicTraits = .italic
            if let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
                .withSymbolicTraits(traits) {
                storage.addAttribute(.font, value: font, range: matchRange)
            }
            // dim * markers
            let open = NSRange(location: matchRange.location, length: 1)
            let close = NSRange(location: matchRange.location + matchRange.length - 1, length: 1)
            storage.addAttribute(.foregroundColor, value: secondaryColor, range: open)
            storage.addAttribute(.foregroundColor, value: secondaryColor, range: close)
        }

        // Inline code
        Self.codePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .backgroundColor: NSColor.controlBackgroundColor,
                .foregroundColor: NSColor.systemOrange,
            ], range: matchRange)
        }

        // Links
        Self.linkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: accentColor, range: matchRange)
        }

        // Blockquotes
        Self.blockquotePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let matchRange = match?.range else { return }
            storage.addAttribute(.foregroundColor, value: secondaryColor, range: matchRange)
        }

        storage.endEditing()
    }
}

private extension NSFont {
    func withSymbolicTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let descriptor = fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: pointSize)
    }
}
