import AppKit
import cmark_gfm

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

// MARK: - Line Index

/// Maps cmark's 1-based (line, UTF-8 column) positions to UTF-16 NSRange offsets.
private struct LineIndex {
    /// utf8To16[byteOffset] = UTF-16 unit offset at the start of that byte.
    private let utf8To16: [Int]
    /// 0-indexed: entry n = UTF-8 byte start of line n+1.
    private let lineU8: [Int]
    /// 0-indexed: entry n = UTF-16 offset start of line n+1.
    private let lineU16: [Int]

    init(_ string: String) {
        var u8 = [0], u16 = [0]
        var map = [Int]()
        var c16 = 0
        for scalar in string.unicodeScalars {
            let nb = scalar.utf8.count
            for _ in 0..<nb { map.append(c16) }
            c16 += scalar.utf16.count
            if scalar.value == 0x0A {
                u8.append(map.count)
                u16.append(c16)
            }
        }
        map.append(c16)  // sentinel: one past the end
        self.utf8To16 = map
        self.lineU8 = u8
        self.lineU16 = u16
    }

    var lineCount: Int { lineU8.count }

    /// 1-based line + 1-based UTF-8 byte column → UTF-16 unit offset.
    func offset(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        return b < utf8To16.count ? utf8To16[b] : utf8To16.last ?? 0
    }

    /// UTF-16 offset AFTER the character at (1-based line, 1-based UTF-8 col).
    func offsetAfter(_ line: Int, _ col: Int) -> Int {
        guard line >= 1, line <= lineU8.count else { return utf8To16.count - 1 }
        let b = lineU8[line - 1] + col - 1
        guard b < utf8To16.count else { return utf8To16.last ?? 0 }
        let v = utf8To16[b]
        var n = b + 1
        while n < utf8To16.count, utf8To16[n] == v { n += 1 }
        return n < utf8To16.count ? utf8To16[n] : utf8To16.last ?? 0
    }

    /// NSRange for cmark node positions (1-based, endCol inclusive).
    func range(_ sl: Int, _ sc: Int, _ el: Int, _ ec: Int) -> NSRange? {
        let loc = offset(sl, sc)
        let end = offsetAfter(el, ec)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    /// UTF-16 start offset of a line (1-based line number).
    func lineStart(_ line: Int) -> Int {
        guard line >= 1, line <= lineU16.count else { return utf8To16.count - 1 }
        return lineU16[line - 1]
    }
}

// MARK: - Highlight Span

private struct Span {
    enum Kind {
        case headingBody(Int), headingMarker
        case boldBody, boldMarker
        case italicBody, italicMarker
        case code
        case linkText, linkSyntax
        case quoteBody, quoteMarker
    }
    var range: NSRange
    var kind: Kind
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

    /// Parses the markdown text with cmark and returns highlight spans.
    private func collectSpans(_ text: String) -> [Span] {
        guard !text.isEmpty else { return [] }
        let lineIdx = LineIndex(text)
        let nsText  = text as NSString

        guard let doc  = cmark_parse_document(text, text.utf8.count, CMARK_OPT_DEFAULT) else { return [] }
        defer { cmark_node_free(doc) }
        guard let iter = cmark_iter_new(doc) else { return [] }
        defer { cmark_iter_free(iter) }

        var spans = [Span]()

        while true {
            let ev = cmark_iter_next(iter)
            if ev == CMARK_EVENT_DONE { break }
            if ev != CMARK_EVENT_ENTER { continue }
            guard let node = cmark_iter_get_node(iter) else { continue }

            let sl = Int(cmark_node_get_start_line(node))
            let sc = Int(cmark_node_get_start_column(node))
            let el = Int(cmark_node_get_end_line(node))
            let ec = Int(cmark_node_get_end_column(node))
            let nt = cmark_node_get_type(node)

            if nt == CMARK_NODE_HEADING {
                guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
                let lv = Int(cmark_node_get_heading_level(node))
                spans.append(Span(range: r, kind: .headingBody(lv)))
                // Marker = the '#' characters + one space (level + 1 chars)
                let markerLen = min(lv + 1, r.length)
                spans.append(Span(range: NSRange(location: r.location, length: markerLen), kind: .headingMarker))

            } else if nt == CMARK_NODE_STRONG {
                guard let r = lineIdx.range(sl, sc, el, ec), r.length >= 4 else { continue }
                spans.append(Span(range: r, kind: .boldBody))
                spans.append(Span(range: NSRange(location: r.location, length: 2),             kind: .boldMarker))
                spans.append(Span(range: NSRange(location: r.upperBound - 2, length: 2),       kind: .boldMarker))

            } else if nt == CMARK_NODE_EMPH {
                guard let r = lineIdx.range(sl, sc, el, ec), r.length >= 2 else { continue }
                spans.append(Span(range: r, kind: .italicBody))
                spans.append(Span(range: NSRange(location: r.location, length: 1),             kind: .italicMarker))
                spans.append(Span(range: NSRange(location: r.upperBound - 1, length: 1),       kind: .italicMarker))

            } else if nt == CMARK_NODE_CODE {
                // cmark positions for CMARK_NODE_CODE span only the content (no backticks).
                // Expand the range to include opening and closing backticks.
                let bt = Int(cmark_node_get_backtick_count(node))
                guard sc > bt else { continue }
                let fullLoc = lineIdx.offset(sl, sc - bt)
                // Content end (exclusive) + bt closing backticks (ASCII = 1 UTF-16 each)
                let fullEnd = lineIdx.offsetAfter(el, ec) + bt
                guard fullEnd > fullLoc else { continue }
                spans.append(Span(range: NSRange(location: fullLoc, length: fullEnd - fullLoc), kind: .code))

            } else if nt == CMARK_NODE_LINK {
                guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
                let fc = cmark_node_first_child(node)
                let lc = cmark_node_last_child(node)
                if let fc, let lc,
                   let textRange = lineIdx.range(
                       Int(cmark_node_get_start_line(fc)), Int(cmark_node_get_start_column(fc)),
                       Int(cmark_node_get_end_line(lc)),   Int(cmark_node_get_end_column(lc))) {
                    spans.append(Span(range: textRange, kind: .linkText))
                    let beforeLen = textRange.location - r.location
                    if beforeLen > 0 {
                        spans.append(Span(range: NSRange(location: r.location, length: beforeLen), kind: .linkSyntax))
                    }
                    let afterLen = r.upperBound - textRange.upperBound
                    if afterLen > 0 {
                        spans.append(Span(range: NSRange(location: textRange.upperBound, length: afterLen), kind: .linkSyntax))
                    }
                } else {
                    spans.append(Span(range: r, kind: .linkSyntax))
                }

            } else if nt == CMARK_NODE_BLOCK_QUOTE {
                guard let r = lineIdx.range(sl, sc, el, ec) else { continue }
                spans.append(Span(range: r, kind: .quoteBody))
                // Emit a marker for each line in the blockquote that starts with '>'
                for line in sl...el {
                    let ls = lineIdx.lineStart(line)
                    guard ls >= r.location, ls < r.upperBound, ls < nsText.length else { continue }
                    if nsText.substring(with: NSRange(location: ls, length: 1)) == ">" {
                        let mLen = min(2, r.upperBound - ls)
                        spans.append(Span(range: NSRange(location: ls, length: mLen), kind: .quoteMarker))
                    }
                }
            }
        }

        return spans
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
