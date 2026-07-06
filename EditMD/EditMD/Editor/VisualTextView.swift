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

// MARK: - SwiftUI wrapper

struct VisualMarkdownView: NSViewRepresentable {

    let document: MarkdownDocument
    var theme: EditorTheme = .system
    var onStatsUpdate: (Int, Int) -> Void
    var onFormatActions: (FormatActions) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = VisualNSTextView()
        textView.isRichText = true
        textView.allowsUndo = true
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
        textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)
        textView.theme = theme

        scrollView.documentView = textView
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.loadDocument()
        coordinator.publishActions()

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.fontSizeDidChange),
            name: .editorFontSizeDidChange,
            object: nil)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        if textView.theme.name != theme.name {
            textView.theme = theme
            textView.textContainerInset = NSSize(width: theme.editorInsetH, height: theme.editorInsetV)
            coordinator.applyPresentation()
            return
        }
        // External change (e.g. Revert): re-render.
        if !coordinator.isInternalUpdate, document.content != coordinator.lastSerialized {
            coordinator.loadDocument()
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: VisualMarkdownView
        weak var textView: VisualNSTextView?
        var isInternalUpdate = false
        var lastSerialized = ""
        private var isMutating = false

        var visualStyle: VisualStyle {
            VisualStyle(baseSize: EditorFontSettings.shared.fontSize + 1)
        }

        init(parent: VisualMarkdownView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func loadDocument() {
            guard let textView, let storage = textView.textStorage else { return }
            let rendered = renderMarkdownToAttributed(parent.document.content, style: visualStyle)
            storage.setAttributedString(rendered)
            lastSerialized = parent.document.content
            textView.typingAttributes = defaultTypingAttributes()
            applyPresentation()
            updateStats()
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
            guard !isMutating else { return }
            runAutoformat()
            applyPresentation()
            syncToDocument()
            updateStats()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep custom attrs out of typing attributes only where harmful:
            // links must not extend as the user types after them.
            guard let textView else { return }
            var attrs = textView.typingAttributes
            if attrs[.mdLink] != nil || attrs[.mdImage] != nil {
                attrs[.mdLink] = nil
                attrs[.mdImage] = nil
                textView.typingAttributes = attrs
            }
        }

        func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard let storage = view.textStorage else { return true }
            // Islands are read-only unless the change swallows them whole.
            let nsText = storage.string as NSString
            var allowed = true
            let probe = affectedRange.length == 0
                ? NSRange(location: min(affectedRange.location, max(0, nsText.length - 1)), length: min(1, nsText.length))
                : affectedRange
            guard nsText.length > 0 else { return true }
            storage.enumerateAttribute(.mdBlock, in: probe) { value, range, stop in
                guard let block = value as? MDBlock, case .raw = block.kind else { return }
                let paragraph = nsText.paragraphRange(for: range)
                if affectedRange.location > paragraph.location
                    || NSMaxRange(affectedRange) < NSMaxRange(paragraph) {
                    allowed = false
                    stop.pointee = true
                }
            }
            return allowed
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline()
            case #selector(NSResponder.insertTab(_:)):
                return changeIndent(by: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return changeIndent(by: -1)
            case #selector(NSResponder.deleteBackward(_:)):
                return handleDeleteBackward()
            default:
                return false
            }
        }

        // MARK: Block helpers

        private func paragraphRange(at location: Int, in nsText: NSString) -> NSRange {
            nsText.paragraphRange(for: NSRange(location: min(location, nsText.length), length: 0))
        }

        private func block(at paragraph: NSRange, in storage: NSTextStorage) -> MDBlock {
            let index = min(paragraph.location, max(0, storage.length - 1))
            guard storage.length > 0 else { return MDBlock(kind: .paragraph) }
            return storage.attribute(.mdBlock, at: index, effectiveRange: nil) as? MDBlock
                ?? MDBlock(kind: .paragraph)
        }

        /// Restamps a paragraph's block kind (undoable attribute-only change).
        private func restamp(_ paragraph: NSRange, to newBlock: MDBlock,
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
                storage.enumerateAttribute(.mdInline, in: stampRange) { value, range, _ in
                    let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
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

        private func afterMutation() {
            applyPresentation()
            syncToDocument()
            updateStats()
        }

        // MARK: Enter

        private func handleNewline() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            let paragraph = paragraphRange(at: selection.location, in: nsText)
            let current = block(at: paragraph, in: storage)

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
                newlineAttrs[.mdBlock] = current
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
                } else {
                    afterMutation()
                }
                return true
            }
            return true  // Enter inside an island: ignored
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

        private func uniqueGroup(in storage: NSTextStorage) -> Int {
            var maxGroup = 0
            storage.enumerateAttribute(.mdBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                if let block = value as? MDBlock {
                    maxGroup = max(maxGroup, block.group)
                    maxGroup = max(maxGroup, block.quoteGroup)
                }
            }
            return maxGroup + 1
        }

        // MARK: Format actions

        func publishActions() {
            let actions = FormatActions(
                toggleBold: { [weak self] in self?.toggleInlineStyle(.bold) },
                toggleItalic: { [weak self] in self?.toggleInlineStyle(.italic) },
                makeFontBigger: { EditorFontSettings.shared.fontSize += 1 },
                makeFontSmaller: { EditorFontSettings.shared.fontSize -= 1 },
                canIncreaseFontSize: EditorFontSettings.shared.canIncrease,
                canDecreaseFontSize: EditorFontSettings.shared.canDecrease,
                toggleChecklist: { [weak self] in self?.toggleChecklist() }
            )
            DispatchQueue.main.async { [parent] in
                parent.onFormatActions(actions)
            }
        }

        private func toggleInlineStyle(_ style: MDInlineStyle) {
            guard let textView, let storage = textView.textStorage else { return }
            let selection = textView.selectedRange()
            if selection.length == 0 {
                var attrs = textView.typingAttributes
                var styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
                styles.formSymmetricDifference(style)
                attrs[.mdInline] = styles.isEmpty ? nil : styles.rawValue
                let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
                attrs[.font] = visualStyle.font(for: styles, blockKind: blockAttr.kind)
                textView.typingAttributes = attrs
                return
            }

            // Add the style unless every character already has it.
            var allHave = true
            storage.enumerateAttribute(.mdInline, in: selection) { value, _, stop in
                let styles = MDInlineStyle(rawValue: value as? Int ?? 0)
                if !styles.contains(style) { allHave = false; stop.pointee = true }
            }
            guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
            isMutating = true
            storage.beginEditing()
            storage.enumerateAttributes(in: selection) { attrs, range, _ in
                var styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
                if allHave { styles.remove(style) } else { styles.insert(style) }
                if styles.isEmpty {
                    storage.removeAttribute(.mdInline, range: range)
                } else {
                    storage.addAttribute(.mdInline, value: styles.rawValue, range: range)
                }
                let blockAttr = attrs[.mdBlock] as? MDBlock ?? MDBlock(kind: .paragraph)
                storage.addAttribute(.font,
                                     value: self.visualStyle.font(for: styles, blockKind: blockAttr.kind),
                                     range: range)
            }
            storage.endEditing()
            isMutating = false
            textView.didChangeText()
            afterMutation()
        }

        func toggleChecklist() {
            guard let textView, let storage = textView.textStorage else { return }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            var location = paragraphRange(at: selection.location, in: nsText).location
            let selectionEnd = max(NSMaxRange(selection), location + 1)

            // Collect target paragraphs.
            var paragraphs: [NSRange] = []
            while location < selectionEnd && location <= nsText.length {
                let paragraph = paragraphRange(at: location, in: nsText)
                paragraphs.append(paragraph)
                if NSMaxRange(paragraph) == location { break }
                location = NSMaxRange(paragraph)
            }
            guard !paragraphs.isEmpty else { return }

            let allTasks = paragraphs.allSatisfy {
                if case .taskItem = block(at: $0, in: storage).kind { return true }
                return false
            }
            let group = uniqueGroup(in: storage)
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                if allTasks {
                    target.kind = .paragraph
                    target.group = -1
                } else {
                    let depth: Int
                    switch target.kind {
                    case .bulletItem(let d), .orderedItem(let d, _), .taskItem(let d, _):
                        depth = d
                    default:
                        depth = 0
                    }
                    if case .taskItem = target.kind {} else {
                        target.kind = .taskItem(depth: depth, done: false)
                        if target.group < 0 { target.group = group }
                    }
                }
                restamp(paragraph, to: target, in: textView)
            }
        }

        func toggleTaskDone(at paragraph: NSRange) {
            guard let textView, let storage = textView.textStorage else { return }
            var target = block(at: paragraph, in: storage)
            guard case .taskItem(let depth, let done) = target.kind else { return }
            target.kind = .taskItem(depth: depth, done: !done)
            restamp(paragraph, to: target, in: textView)
        }

        // MARK: Presentation (derived visuals + decoration entries)

        func applyPresentation() {
            guard let textView, let storage = textView.textStorage else { return }
            let nsText = storage.string as NSString
            var bullets: [(range: NSRange, depth: Int)] = []
            var numbers: [(range: NSRange, depth: Int, number: Int)] = []
            var tasks: [(range: NSRange, depth: Int, done: Bool)] = []
            var quotes: [(range: NSRange, depth: Int)] = []
            var codeGroups: [Int: NSRange] = [:]
            var ruleRanges: [NSRange] = []
            var headingDividers: [NSRange] = []

            var orderedCounters: [String: Int] = [:]
            var lastListGroupDepth: (group: Int, depth: Int)? = nil

            isMutating = true
            storage.beginEditing()
            var location = 0
            while location < nsText.length {
                let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
                defer { location = NSMaxRange(paragraph) == location ? location + 1 : NSMaxRange(paragraph) }
                var blockValue = storage.attribute(.mdBlock, at: paragraph.location,
                                                   effectiveRange: nil) as? MDBlock
                    ?? MDBlock(kind: .paragraph)

                let style = NSMutableParagraphStyle()
                style.paragraphSpacing = 6
                var markerIndent: CGFloat = 0

                switch blockValue.kind {
                case .heading(let level):
                    style.paragraphSpacingBefore = level <= 2 ? 14 : 10
                    style.paragraphSpacing = 8
                    if level <= 2 { headingDividers.append(paragraph) }
                case .bulletItem(let depth):
                    markerIndent = 24 + CGFloat(depth) * 22
                    bullets.append((paragraph, depth))
                    style.paragraphSpacing = 2
                    lastListGroupDepth = (blockValue.group, depth)
                case .taskItem(let depth, let done):
                    markerIndent = 24 + CGFloat(depth) * 22
                    tasks.append((paragraph, depth, done))
                    style.paragraphSpacing = 2
                    lastListGroupDepth = (blockValue.group, depth)
                case .orderedItem(let depth, _):
                    markerIndent = 28 + CGFloat(depth) * 22
                    // Renumber sequentially within the same group+depth run.
                    let key = "\(blockValue.group)/\(depth)"
                    let next: Int
                    if let last = lastListGroupDepth, last.group == blockValue.group {
                        next = (orderedCounters[key] ?? 0) + 1
                    } else {
                        orderedCounters = [:]
                        if case .orderedItem(_, let n) = blockValue.kind { next = max(1, n) } else { next = 1 }
                    }
                    orderedCounters[key] = next
                    if case .orderedItem(let d, let n) = blockValue.kind, n != next {
                        blockValue.kind = .orderedItem(depth: d, number: next)
                        let stamp = paragraph.length > 0 ? paragraph
                            : NSRange(location: paragraph.location,
                                      length: min(1, nsText.length - paragraph.location))
                        if stamp.length > 0 {
                            storage.addAttribute(.mdBlock, value: blockValue, range: stamp)
                        }
                    }
                    numbers.append((paragraph, depth, {
                        if case .orderedItem(_, let n) = blockValue.kind { return n }
                        return 1
                    }()))
                    style.paragraphSpacing = 2
                    lastListGroupDepth = (blockValue.group, depth)
                case .listContinuation(let indent):
                    markerIndent = 24 + CGFloat(max(0, indent - 2) / 4) * 22
                case .codeBlock:
                    markerIndent = 10
                    style.paragraphSpacing = 0
                    let existing = codeGroups[blockValue.group]
                    codeGroups[blockValue.group] = existing.map { NSUnionRange($0, paragraph) } ?? paragraph
                case .thematicBreak:
                    ruleRanges.append(paragraph)
                case .raw:
                    markerIndent = 10
                case .paragraph:
                    break
                }

                if !isListKind(blockValue.kind) { lastListGroupDepth = nil }

                if blockValue.quoteDepth > 0 {
                    markerIndent += CGFloat(blockValue.quoteDepth) * 18
                    quotes.append((paragraph, blockValue.quoteDepth))
                }
                style.firstLineHeadIndent = markerIndent
                style.headIndent = markerIndent

                if paragraph.length > 0 {
                    storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                    applyDerivedInlineDecorations(storage, paragraph: paragraph, block: blockValue)
                }
            }
            storage.endEditing()
            isMutating = false

            textView.bulletEntries = bullets
            textView.numberEntries = numbers
            textView.taskEntries = tasks
            textView.quoteEntries = quotes
            textView.codePanelRanges = Array(codeGroups.values)
            textView.ruleRanges = ruleRanges
            textView.headingDividerRanges = headingDividers
            textView.needsDisplay = true
        }

        private func isListKind(_ kind: MDBlock.Kind) -> Bool {
            switch kind {
            case .bulletItem, .orderedItem, .taskItem, .listContinuation:
                return true
            default:
                return false
            }
        }

        /// Strikethrough and colors are derived: .mdInline strike ∪ done-task
        /// paragraphs get strikethrough; links get link color + underline.
        private func applyDerivedInlineDecorations(_ storage: NSTextStorage,
                                                   paragraph: NSRange, block: MDBlock) {
            var isDone = false
            if case .taskItem(_, true) = block.kind { isDone = true }
            storage.enumerateAttributes(in: paragraph) { attrs, range, _ in
                let styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
                let strike = styles.contains(.strike) || isDone
                if strike {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: range)
                } else {
                    storage.removeAttribute(.strikethroughStyle, range: range)
                }
                if attrs[.mdLink] != nil {
                    storage.addAttributes([
                        .foregroundColor: NSColor.linkColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
                } else if isDone {
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                         range: range)
                } else if styles.contains(.code) {
                    storage.addAttributes([
                        .foregroundColor: NSColor.systemOrange,
                        .backgroundColor: NSColor(white: 0.5, alpha: 0.12),
                    ], range: range)
                    storage.removeAttribute(.underlineStyle, range: range)
                } else {
                    var isRawOrCode = false
                    if case .codeBlock = block.kind { isRawOrCode = true }
                    if case .raw = block.kind { isRawOrCode = true }
                    storage.addAttribute(.foregroundColor,
                                         value: isRawOrCode ? NSColor.secondaryLabelColor : NSColor.labelColor,
                                         range: range)
                    storage.removeAttribute(.underlineStyle, range: range)
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
        }

        // MARK: Sync

        private func syncToDocument() {
            guard let storage = textView?.textStorage else { return }
            var serialized = serializeAttributedToMarkdown(storage)
            if !serialized.isEmpty { serialized += "\n" }
            lastSerialized = serialized
            isInternalUpdate = true
            parent.document.content = serialized
            isInternalUpdate = false
        }

        func updateStats() {
            guard let textView else { return }
            let (words, chars) = wordAndCharCount(in: textView.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        @objc func fontSizeDidChange() {
            guard let textView else { return }
            let cursor = textView.selectedRange()
            loadDocument()
            textView.setSelectedRange(NSRange(location: min(cursor.location, textView.string.utf16.count),
                                              length: 0))
            publishActions()
        }
    }
}

// MARK: - Text view with drawn markers

final class VisualNSTextView: NSTextView {
    var theme: EditorTheme = .system
    var bulletEntries: [(range: NSRange, depth: Int)] = []
    var numberEntries: [(range: NSRange, depth: Int, number: Int)] = []
    var taskEntries: [(range: NSRange, depth: Int, done: Bool)] = []
    var quoteEntries: [(range: NSRange, depth: Int)] = []
    var codePanelRanges: [NSRange] = []
    var ruleRanges: [NSRange] = []
    var headingDividerRanges: [NSRange] = []

    private var visualCoordinator: VisualMarkdownView.Coordinator? {
        delegate as? VisualMarkdownView.Coordinator
    }

    // Paste always as plain text — outside rich content would corrupt the model.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let paragraph = taskParagraph(at: point) {
            visualCoordinator?.toggleTaskDone(at: paragraph)
            return
        }
        if event.modifierFlags.contains(.command),
           let url = linkURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    private func linkURL(at point: NSPoint) -> URL? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length,
              let dest = storage.attribute(.mdLink, at: charIndex, effectiveRange: nil) as? String,
              let url = URL(string: dest), url.scheme != nil else { return nil }
        return url
    }

    private func taskParagraph(at point: NSPoint) -> NSRange? {
        for entry in taskEntries {
            if let rect = markerRect(forParagraph: entry.range),
               rect.insetBy(dx: -3, dy: -3).contains(point) {
                return entry.range
            }
        }
        return nil
    }

    /// Rect of the drawn marker (bullet/checkbox/number) for a paragraph:
    /// in the indent margin, on the first line fragment.
    private func markerRect(forParagraph range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let totalLength = (string as NSString).length
        guard range.location < totalLength else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: range.location, length: 1),
            actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard lineRect.height > 0 else { return nil }
        let boxSize: CGFloat = 15
        // The marker sits left of the text indent (paragraph firstLineHeadIndent).
        let indent = (textStorage?.attribute(.paragraphStyle, at: range.location,
                                             effectiveRange: nil) as? NSParagraphStyle)?
            .firstLineHeadIndent ?? 0
        return NSRect(x: textContainerInset.width + indent - 21,
                      y: textContainerInset.height + lineRect.midY - boxSize / 2,
                      width: boxSize, height: boxSize)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let inset = textContainerInset
        let totalLength = (string as NSString).length
        let fullWidth = bounds.width - inset.width * 2

        func unionRect(for range: NSRange) -> NSRect? {
            guard range.location < totalLength else { return nil }
            let safe = NSRange(location: range.location,
                               length: min(range.length, totalLength - range.location))
            guard safe.length > 0 else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            var union = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
                let line = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                  width: fullWidth, height: fragment.height)
                union = union.isNull ? line : union.union(line)
            }
            return union.isNull ? nil : union
        }

        // Code panels
        for range in codePanelRanges {
            guard let rectUnion = unionRect(for: range) else { continue }
            let padded = rectUnion.insetBy(dx: 0, dy: -6)
            guard padded.intersects(rect) else { continue }
            theme.codeBlockBackground.setFill()
            NSBezierPath(roundedRect: padded, xRadius: 6, yRadius: 6).fill()
        }

        // Quote bars
        for (range, depth) in quoteEntries {
            guard let rectUnion = unionRect(for: range), rectUnion.intersects(rect) else { continue }
            theme.separatorColor.setFill()
            for level in 0..<depth {
                NSRect(x: inset.width + CGFloat(level) * 18, y: rectUnion.minY,
                       width: 3, height: rectUnion.height).fill()
            }
        }

        // Bullets
        for (range, _) in bulletEntries {
            guard let marker = markerRect(forParagraph: range) else { continue }
            let radius = marker.height * 0.18
            let center = NSPoint(x: marker.midX, y: marker.midY)
            theme.accentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2)).fill()
        }

        // Ordered numbers
        for (range, _, number) in numberEntries {
            guard let marker = markerRect(forParagraph: range) else { continue }
            let label = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: theme.accentColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: marker.maxX - size.width,
                                   y: marker.midY - size.height / 2))
        }

        // Task checkboxes
        for (range, _, done) in taskEntries {
            guard let box = markerRect(forParagraph: range) else { continue }
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            path.lineWidth = 1.5
            if done {
                theme.accentColor.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.minY + box.height * 0.45))
                check.line(to: NSPoint(x: box.minX + box.width * 0.45, y: box.minY + box.height * 0.75))
                check.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + box.height * 0.25))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                theme.secondaryColor.setStroke()
                path.stroke()
            }
        }

        // Thematic breaks
        for range in ruleRanges {
            guard let rectUnion = unionRect(for: range), rectUnion.intersects(rect) else { continue }
            theme.separatorColor.setFill()
            NSRect(x: inset.width, y: rectUnion.midY - 1, width: fullWidth, height: 2).fill()
        }

        // H1/H2 dividers
        if theme.headingDividerColor.cgColor.alpha > 0 {
            theme.headingDividerColor.setFill()
            for range in headingDividerRanges {
                guard let rectUnion = unionRect(for: range) else { continue }
                let line = NSRect(x: inset.width, y: rectUnion.maxY - 1, width: fullWidth, height: 1)
                if line.intersects(rect) { line.fill() }
            }
        }
    }
}
