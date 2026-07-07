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

/// Tab navigation order inside a table; nil = past the edge (forward: caller
/// appends a row; backward: stay put).
func nextTableCellPosition(row: Int, column: Int, columns: Int, rows: Int,
                           forward: Bool) -> (row: Int, column: Int)? {
    if forward {
        if column + 1 < columns { return (row, column + 1) }
        if row + 1 < rows { return (row + 1, 0) }
        return nil
    }
    if column > 0 { return (row, column - 1) }
    if row > 0 { return (row - 1, columns - 1) }
    return nil
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
    var fileURL: URL? = nil
    var positionStore: EditorPositionStore? = nil
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
        textView.textContainerInset = EditorSettings.shared.visual.textContainerInset(forWidth: scrollView.contentView.bounds.width)
        textView.theme = theme
        // Edit ▸ Find menu (⌘F & co.) drives the standard find bar; replaces
        // go through shouldChangeTextIn, so island/table guards still apply.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        scrollView.documentView = textView
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.textView = textView
        coordinator.loadDocument()
        coordinator.publishActions()

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil)
        // Outline-sidebar jumps, object-scoped to this window's store (a nil
        // object would subscribe to every window's jumps).
        if let store = positionStore {
            NotificationCenter.default.addObserver(
                coordinator,
                selector: #selector(Coordinator.jumpToStoredOffset),
                name: .editMDJumpToOffset,
                object: store)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.textContainerInset = EditorSettings.shared.visual.textContainerInset(forWidth: scrollView.contentView.bounds.width)
        if textView.theme.name != theme.name {
            textView.theme = theme
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
        /// setAttributedString during (re)load resets the selection; the
        /// callback must not clobber the cross-mode cursor store.
        private var isLoadingDocument = false
        /// Row append / row delete restructure tables legally — bypass the
        /// cell-integrity guard in shouldChangeTextIn.
        private var isProgrammaticTableEdit = false
        /// Display-paragraph → markdown-range map from the last serialization.
        private var lastParagraphRanges: [NSRange] = []
        /// One NSTextAttachment per image source — reused across presentation
        /// passes so layout doesn't churn on every keystroke.
        private var imageAttachments: [String: NSTextAttachment] = [:]

        var visualStyle: VisualStyle {
            let settings = EditorSettings.shared.visual
            return VisualStyle(baseSize: settings.fontSize,
                               bodyFamily: settings.fontFamily,
                               bodyWeight: settings.fontWeight.nsWeight,
                               elements: settings.elements)
        }

        init(parent: VisualMarkdownView) {
            self.parent = parent
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func loadDocument() {
            guard let textView, let storage = textView.textStorage else { return }
            isLoadingDocument = true
            let rendered = renderMarkdownToAttributed(parent.document.content, style: visualStyle)
            storage.setAttributedString(rendered)
            lastSerialized = parent.document.content
            lastParagraphRanges = serializeAttributedToMarkdownDetailed(storage).paragraphRanges
            textView.typingAttributes = defaultTypingAttributes()
            applyPresentation()
            updateStats()
            isLoadingDocument = false
            restoreCursor()
        }

        // MARK: Cursor continuity across modes

        /// (display paragraph index, its start offset) for a text location.
        private func paragraphIndex(at location: Int, in nsText: NSString) -> (index: Int, start: Int) {
            var index = 0, start = 0
            var i = 0
            let limit = min(location, nsText.length)
            while i < limit {
                if nsText.character(at: i) == 0x0A {
                    index += 1
                    start = i + 1
                }
                i += 1
            }
            return (index, start)
        }

        func storeCursor() {
            guard !isLoadingDocument, let store = parent.positionStore, let textView,
                  let storage = textView.textStorage,
                  !lastParagraphRanges.isEmpty else { return }
            let nsText = textView.string as NSString
            let location = textView.selectedRange().location
            let (index, start) = paragraphIndex(at: location, in: nsText)
            guard index < lastParagraphRanges.count else { return }
            let mdRange = lastParagraphRanges[index]
            // Compensate for the markdown prefix ("# ", "- [x] ", "> " …) the
            // serializer emits before the display text.
            let blockValue = block(at: NSRange(location: start, length: 0), in: storage)
            let prefixLength = markdownPrefixLength(for: blockValue)
            store.markdownOffset = min(mdRange.location + prefixLength + (location - start),
                                       NSMaxRange(mdRange))
        }

        /// Outline-sidebar jump: `restoreCursor` maps the store's markdown
        /// offset through the paragraph map, so the cursor lands correctly
        /// even though Visual's display text differs from the source.
        @objc func jumpToStoredOffset() {
            restoreCursor()
        }

        private func restoreCursor() {
            guard let store = parent.positionStore, let textView,
                  let storage = textView.textStorage,
                  !lastParagraphRanges.isEmpty else { return }
            let target = store.markdownOffset
            var index = 0
            var within = 0
            for (i, range) in lastParagraphRanges.enumerated() where range.location <= target {
                index = i
                within = target - range.location
            }
            // Paragraph start in the display text.
            let nsText = textView.string as NSString
            var start = 0, seen = 0, end = nsText.length
            var i = 0
            while i < nsText.length {
                if nsText.character(at: i) == 0x0A {
                    if seen == index { end = i; break }
                    seen += 1
                    start = i + 1
                }
                i += 1
            }
            let blockValue = block(at: NSRange(location: start, length: 0), in: storage)
            within = max(0, within - markdownPrefixLength(for: blockValue))
            let cursor = min(start + within, end)
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            DispatchQueue.main.async { [weak textView] in
                guard let textView else { return }
                textView.scrollRangeToVisible(textView.selectedRange())
                textView.centerSelectionInVisibleArea(nil)
                textView.window?.makeFirstResponder(textView)
            }
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
            storeCursor()
        }

        func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            guard !isProgrammaticTableEdit, let storage = view.textStorage else { return true }
            let nsText = storage.string as NSString
            guard nsText.length > 0 else { return true }
            var allowed = true
            let probe = affectedRange.length == 0
                ? NSRange(location: min(affectedRange.location, max(0, nsText.length - 1)), length: min(1, nsText.length))
                : affectedRange
            storage.enumerateAttribute(.mdBlock, in: probe) { value, range, stop in
                guard let block = value as? MDBlock else { return }
                switch block.kind {
                // Islands are read-only unless the change swallows them whole.
                case .raw:
                    let paragraph = nsText.paragraphRange(for: range)
                    if affectedRange.location > paragraph.location
                        || NSMaxRange(affectedRange) < NSMaxRange(paragraph) {
                        allowed = false
                        stop.pointee = true
                    }
                // Table cells: edits stay inside one cell's text (its trailing
                // \n is structure), or replace the entire table.
                case .tableCell:
                    let paragraph = nsText.paragraphRange(for: range)
                    var cellTextEnd = NSMaxRange(paragraph)
                    if cellTextEnd > paragraph.location,
                       nsText.character(at: cellTextEnd - 1) == 0x0A {
                        cellTextEnd -= 1
                    }
                    let insideCell = affectedRange.location >= paragraph.location
                        && NSMaxRange(affectedRange) <= cellTextEnd
                    if insideCell {
                        if replacementString?.contains("\n") == true {
                            allowed = false
                            stop.pointee = true
                        }
                        return
                    }
                    let whole = self.tableRange(group: block.group, in: storage)
                    if affectedRange.location <= whole.location
                        && NSMaxRange(affectedRange) >= NSMaxRange(whole) {
                        return
                    }
                    allowed = false
                    stop.pointee = true
                default:
                    break
                }
            }
            return allowed
        }

        func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return handleNewline()
            case #selector(NSResponder.insertTab(_:)):
                return handleTableTab(forward: true) || changeIndent(by: 1)
            case #selector(NSResponder.insertBacktab(_:)):
                return handleTableTab(forward: false) || changeIndent(by: -1)
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

        // MARK: Tables

        /// All cell paragraphs of a table, in document order.
        private func tableCells(group: Int, in storage: NSTextStorage)
            -> [(row: Int, column: Int, columns: Int, alignment: Int, range: NSRange)] {
            let nsText = storage.string as NSString
            var cells: [(Int, Int, Int, Int, NSRange)] = []
            var location = 0
            while location < nsText.length {
                let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
                let blockValue = block(at: paragraph, in: storage)
                if case .tableCell(let row, let column, let columns, let alignment) = blockValue.kind,
                   blockValue.group == group {
                    cells.append((row, column, columns, alignment, paragraph))
                }
                if NSMaxRange(paragraph) == location { break }
                location = NSMaxRange(paragraph)
            }
            return cells
        }

        private func tableRange(group: Int, in storage: NSTextStorage) -> NSRange {
            let cells = tableCells(group: group, in: storage)
            guard let first = cells.first, let last = cells.last else {
                return NSRange(location: 0, length: 0)
            }
            return NSRange(location: first.range.location,
                           length: NSMaxRange(last.range) - first.range.location)
        }

        /// Places the cursor at the end of a cell's text.
        private func moveCursor(toCell target: (row: Int, column: Int), group: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let cells = tableCells(group: group, in: storage)
            guard let cell = cells.first(where: { $0.row == target.row && $0.column == target.column })
            else { return }
            let nsText = storage.string as NSString
            var end = NSMaxRange(cell.range)
            if end > cell.range.location, nsText.character(at: end - 1) == 0x0A { end -= 1 }
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(textView.selectedRange())
        }

        /// Appends an empty row; returns the new row index.
        @discardableResult
        private func appendTableRow(group: Int) -> Int? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let cells = tableCells(group: group, in: storage)
            guard let last = cells.last else { return nil }
            let columns = last.columns
            let newRow = (cells.map(\.row).max() ?? 0) + 1
            var alignmentByColumn: [Int: Int] = [:]
            for cell in cells { alignmentByColumn[cell.column] = cell.alignment }

            let insertion = NSMutableAttributedString()
            for column in 0..<columns {
                var cellBlock = MDBlock(kind: .tableCell(row: newRow, column: column,
                                                         columns: columns,
                                                         alignment: alignmentByColumn[column] ?? 0))
                cellBlock.group = group
                insertion.append(NSAttributedString(string: "\n", attributes: [
                    .font: visualStyle.font(for: [], blockKind: cellBlock.kind),
                    .foregroundColor: NSColor.labelColor,
                    .mdBlock: cellBlock,
                ]))
            }
            let location = NSMaxRange(last.range)
            let insertRange = NSRange(location: location, length: 0)
            isProgrammaticTableEdit = true
            defer { isProgrammaticTableEdit = false }
            guard textView.shouldChangeText(in: insertRange,
                                            replacementString: insertion.string) else { return nil }
            isMutating = true
            storage.replaceCharacters(in: insertRange, with: insertion)
            isMutating = false
            textView.didChangeText()
            afterMutation()
            return newRow
        }

        /// Deletes a table row (used by "Enter on empty last row exits table").
        private func deleteTableRow(_ row: Int, group: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let rowCells = tableCells(group: group, in: storage).filter { $0.row == row }
            guard let first = rowCells.first, let last = rowCells.last else { return }
            let range = NSRange(location: first.range.location,
                                length: NSMaxRange(last.range) - first.range.location)
            isProgrammaticTableEdit = true
            defer { isProgrammaticTableEdit = false }
            guard textView.shouldChangeText(in: range, replacementString: "") else { return }
            isMutating = true
            storage.replaceCharacters(in: range, with: "")
            isMutating = false
            textView.didChangeText()
            afterMutation()
        }

        private func handleTableTab(forward: Bool) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let paragraph = paragraphRange(at: textView.selectedRange().location, in: nsText)
            let current = block(at: paragraph, in: storage)
            guard case .tableCell(let row, let column, let columns, _) = current.kind else {
                return false
            }
            let rows = (tableCells(group: current.group, in: storage).map(\.row).max() ?? 0) + 1
            if let next = nextTableCellPosition(row: row, column: column, columns: columns,
                                                rows: rows, forward: forward) {
                moveCursor(toCell: next, group: current.group)
            } else if forward {
                if let newRow = appendTableRow(group: current.group) {
                    moveCursor(toCell: (newRow, 0), group: current.group)
                }
            }
            return true
        }

        // MARK: Enter

        private func handleNewline() -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            let paragraph = paragraphRange(at: selection.location, in: nsText)
            let current = block(at: paragraph, in: storage)

            // Table: Enter moves down a column; on an all-empty last row it
            // removes that row and exits below the table.
            if case .tableCell(let row, let column, _, _) = current.kind {
                let cells = tableCells(group: current.group, in: storage)
                let rows = (cells.map(\.row).max() ?? 0) + 1
                let lastRowCells = cells.filter { $0.row == rows - 1 }
                let lastRowEmpty = lastRowCells.allSatisfy {
                    var text = nsText.substring(with: $0.range)
                    if text.hasSuffix("\n") { text.removeLast() }
                    return text.isEmpty
                }
                if row == rows - 1 {
                    if lastRowEmpty && rows > 2 {
                        // Exit: drop the empty row, add a paragraph after the table.
                        deleteTableRow(row, group: current.group)
                        let tableEnd = NSMaxRange(tableRange(group: current.group, in: storage))
                        insertParagraph(at: tableEnd)
                    } else if let newRow = appendTableRow(group: current.group) {
                        moveCursor(toCell: (newRow, column), group: current.group)
                    }
                } else {
                    moveCursor(toCell: (row + 1, column), group: current.group)
                }
                return true
            }

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

        /// Inserts an empty plain paragraph at `location` and puts the cursor there.
        private func insertParagraph(at location: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let insertRange = NSRange(location: min(location, storage.length), length: 0)
            guard textView.shouldChangeText(in: insertRange, replacementString: "\n") else { return }
            isMutating = true
            storage.replaceCharacters(in: insertRange, with: NSAttributedString(
                string: "\n", attributes: defaultTypingAttributes()))
            isMutating = false
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: insertRange.location, length: 0))
            textView.typingAttributes = defaultTypingAttributes()
            afterMutation()
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
            case .tableCell(let row, let column, let columns, _):
                // Never merge cells: hop to the end of the previous cell.
                let rows = (tableCells(group: current.group, in: storage).map(\.row).max() ?? 0) + 1
                if let previous = nextTableCellPosition(row: row, column: column,
                                                        columns: columns, rows: rows,
                                                        forward: false) {
                    moveCursor(toCell: previous, group: current.group)
                }
                return true
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
                makeFontBigger: { EditorSettings.shared.adjustFontSize(\.visual, by: 1) },
                makeFontSmaller: { EditorSettings.shared.adjustFontSize(\.visual, by: -1) },
                canIncreaseFontSize: EditorSettings.shared.visual.fontSize < ModeSettings.fontSizeRange.upperBound,
                canDecreaseFontSize: EditorSettings.shared.visual.fontSize > ModeSettings.fontSizeRange.lowerBound,
                toggleChecklist: { [weak self] in self?.toggleChecklist() },
                editLink: { [weak self] in self?.editLink() },
                toggleStrikethrough: { [weak self] in self?.toggleInlineStyle(.strike) },
                toggleCodeSpan: { [weak self] in self?.toggleInlineStyle(.code) },
                setHeading: { [weak self] level in self?.setHeading(level) },
                toggleBulletList: { [weak self] in self?.toggleListKind(
                    isTarget: { if case .bulletItem = $0 { return true }; return false },
                    makeKind: { .bulletItem(depth: $0) }) },
                toggleNumberedList: { [weak self] in self?.toggleListKind(
                    isTarget: { if case .orderedItem = $0 { return true }; return false },
                    makeKind: { .orderedItem(depth: $0, number: 1) }) },
                toggleQuote: { [weak self] in self?.toggleQuote() },
                toggleCodeBlock: { [weak self] in self?.toggleCodeBlock() }
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
            toggleListKind(
                isTarget: { if case .taskItem = $0 { return true }; return false },
                makeKind: { .taskItem(depth: $0, done: false) })
        }

        /// Paragraph ranges the selection touches (skipping none); table
        /// cells and raw islands are excluded — block restamps would corrupt
        /// them.
        private func selectedParagraphs() -> [NSRange] {
            guard let textView, let storage = textView.textStorage else { return [] }
            let nsText = storage.string as NSString
            let selection = textView.selectedRange()
            var location = paragraphRange(at: selection.location, in: nsText).location
            let selectionEnd = max(NSMaxRange(selection), location + 1)

            var paragraphs: [NSRange] = []
            while location < selectionEnd && location <= nsText.length {
                let paragraph = paragraphRange(at: location, in: nsText)
                switch block(at: paragraph, in: storage).kind {
                case .tableCell, .raw:
                    break
                default:
                    paragraphs.append(paragraph)
                }
                if NSMaxRange(paragraph) == location { break }
                location = NSMaxRange(paragraph)
            }
            return paragraphs
        }

        /// Shared list toggle (bullet/ordered/task): if every selected
        /// paragraph already is the target kind, all flatten to paragraphs;
        /// otherwise each becomes the target kind — existing list depth
        /// survives, plain paragraphs enter at depth 0 in one new group.
        func toggleListKind(isTarget: (MDBlock.Kind) -> Bool,
                            makeKind: (Int) -> MDBlock.Kind) {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraphs = selectedParagraphs()
            guard !paragraphs.isEmpty else { return }

            let allTarget = paragraphs.allSatisfy { isTarget(block(at: $0, in: storage).kind) }
            let group = uniqueGroup(in: storage)
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                if allTarget {
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
                    if !isTarget(target.kind) {
                        target.kind = makeKind(depth)
                        if target.group < 0 { target.group = group }
                    }
                }
                restamp(paragraph, to: target, in: textView)
            }
        }

        /// Heading level 1…6 on the selected paragraphs; the same level again
        /// turns them back into plain paragraphs.
        func setHeading(_ level: Int) {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraphs = selectedParagraphs()
            guard !paragraphs.isEmpty else { return }

            let allMatch = paragraphs.allSatisfy {
                block(at: $0, in: storage).kind == .heading(level)
            }
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                target.kind = allMatch ? .paragraph : .heading(level)
                target.group = -1
                restamp(paragraph, to: target, in: textView)
            }
        }

        /// Quote is orthogonal to the block kind (quoteDepth/quoteGroup):
        /// unquoted paragraphs join one new quote group, fully quoted
        /// selections lose the quote.
        func toggleQuote() {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraphs = selectedParagraphs()
            guard !paragraphs.isEmpty else { return }

            let allQuoted = paragraphs.allSatisfy { block(at: $0, in: storage).quoteDepth > 0 }
            let group = uniqueGroup(in: storage)
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                if allQuoted {
                    target.quoteDepth = 0
                    target.quoteGroup = -1
                } else if target.quoteDepth == 0 {
                    target.quoteDepth = 1
                    target.quoteGroup = group
                }
                restamp(paragraph, to: target, in: textView)
            }
        }

        /// Code block: the selected paragraphs become lines of ONE fenced
        /// block (shared group — the serializer merges same-group codeBlock
        /// paragraphs into a single fence); a fully-code selection reverts to
        /// paragraphs.
        func toggleCodeBlock() {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraphs = selectedParagraphs()
            guard !paragraphs.isEmpty else { return }

            let allCode = paragraphs.allSatisfy {
                if case .codeBlock = block(at: $0, in: storage).kind { return true }
                return false
            }
            let group = uniqueGroup(in: storage)
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                if allCode {
                    target.kind = .paragraph
                    target.group = -1
                } else {
                    target.kind = .codeBlock(language: "")
                    target.group = group
                }
                restamp(paragraph, to: target, in: textView)
            }
        }

        /// ⌘K: add a link on the selection, or edit/remove the link under the
        /// cursor. Empty selection with no existing link inserts the URL text.
        func editLink() {
            guard let textView, let storage = textView.textStorage else { return }
            var selection = textView.selectedRange()
            var existingURL = ""

            // Expand to the full run of an existing link under the cursor.
            if storage.length > 0 {
                let probe = min(selection.location, storage.length - 1)
                var effective = NSRange(location: 0, length: 0)
                if let dest = storage.attribute(.mdLink, at: probe,
                                                longestEffectiveRange: &effective,
                                                in: NSRange(location: 0, length: storage.length)) as? String {
                    existingURL = dest
                    selection = effective
                }
            }

            let alert = NSAlert()
            alert.messageText = existingURL.isEmpty ? "Add Link" : "Edit Link"
            alert.informativeText = "URL:"
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.stringValue = existingURL
            field.placeholderString = "https://"
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            if !existingURL.isEmpty { alert.addButton(withTitle: "Remove Link") }

            let response = alert.runModal()
            let url = field.stringValue.trimmingCharacters(in: .whitespaces)

            switch response {
            case .alertFirstButtonReturn where !url.isEmpty:
                if selection.length == 0 {
                    // Nothing selected: insert the URL itself as linked text.
                    guard textView.shouldChangeText(in: selection, replacementString: url) else { return }
                    isMutating = true
                    var attrs = textView.typingAttributes
                    attrs[.mdLink] = url
                    storage.replaceCharacters(in: selection,
                                              with: NSAttributedString(string: url, attributes: attrs))
                    isMutating = false
                    textView.didChangeText()
                    textView.setSelectedRange(
                        NSRange(location: selection.location + (url as NSString).length, length: 0))
                } else {
                    guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
                    isMutating = true
                    storage.addAttribute(.mdLink, value: url, range: selection)
                    isMutating = false
                    textView.didChangeText()
                }
                afterMutation()
            case .alertThirdButtonReturn:
                guard textView.shouldChangeText(in: selection, replacementString: nil) else { return }
                isMutating = true
                storage.removeAttribute(.mdLink, range: selection)
                isMutating = false
                textView.didChangeText()
                afterMutation()
            default:
                break
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
            // One shared NSTextTable per table group — cells of one table must
            // reference the same instance or layout falls apart.
            var textTables: [Int: NSTextTable] = [:]
            let theme = textView.theme

            let spacingScale = EditorSettings.shared.visualSpacing.scale
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
                style.paragraphSpacing = 6 * spacingScale
                var markerIndent: CGFloat = 0

                switch blockValue.kind {
                case .heading(let level):
                    style.paragraphSpacingBefore = (level <= 2 ? 14 : 10) * spacingScale
                    style.paragraphSpacing = 8 * spacingScale
                    if level <= 2 { headingDividers.append(paragraph) }
                case .bulletItem(let depth):
                    markerIndent = 24 + CGFloat(depth) * 22
                    bullets.append((paragraph, depth))
                    style.paragraphSpacing = 2 * spacingScale
                    lastListGroupDepth = (blockValue.group, depth)
                case .taskItem(let depth, let done):
                    markerIndent = 24 + CGFloat(depth) * 22
                    tasks.append((paragraph, depth, done))
                    style.paragraphSpacing = 2 * spacingScale
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
                    style.paragraphSpacing = 2 * spacingScale
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
                case .tableCell(let row, let column, let columns, let alignment):
                    let table: NSTextTable
                    if let existing = textTables[blockValue.group] {
                        table = existing
                    } else {
                        table = NSTextTable()
                        table.numberOfColumns = columns
                        table.setContentWidth(100, type: .percentageValueType)
                        textTables[blockValue.group] = table
                    }
                    let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                                startingColumn: column, columnSpan: 1)
                    cell.setBorderColor(theme.separatorColor)
                    cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                    cell.setWidth(6, type: .absoluteValueType, for: .padding)
                    if row == 0 {
                        cell.backgroundColor = NSColor(white: 0.5, alpha: 0.08)
                    }
                    style.textBlocks = [cell]
                    style.paragraphSpacing = 0
                    switch alignment {
                    case 2: style.alignment = .center
                    case 3: style.alignment = .right
                    default: break
                    }
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
            attachImages(storage)
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
            var isHeaderCell = false
            if case .tableCell(0, _, _, _) = block.kind { isHeaderCell = true }
            var headingLevel = 0
            if case .heading(let level) = block.kind { headingLevel = level }
            var isBodyCode = false
            if case .codeBlock = block.kind { isBodyCode = true }
            if case .raw = block.kind { isBodyCode = true }
            let isQuote = block.quoteDepth > 0
            // Colors are honest here: theme (preset + General overrides) plus
            // per-element overrides — no hardcoded system colors.
            let theme = textView?.theme ?? .system
            let elements = EditorSettings.shared.visual.elements

            storage.enumerateAttributes(in: paragraph) { attrs, range, _ in
                let styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
                if isHeaderCell {
                    // Header row is bold — derived, not stored in .mdInline.
                    storage.addAttribute(.font,
                                         value: self.visualStyle.font(for: styles.union(.bold),
                                                                      blockKind: block.kind),
                                         range: range)
                }
                let strike = styles.contains(.strike) || isDone
                if strike {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: range)
                } else {
                    storage.removeAttribute(.strikethroughStyle, range: range)
                }
                if attrs[.mdLink] != nil {
                    storage.addAttributes([
                        .foregroundColor: elements.link.color ?? theme.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
                } else if isDone {
                    storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                         range: range)
                    storage.removeAttribute(.underlineStyle, range: range)
                    storage.removeAttribute(.backgroundColor, range: range)
                } else if styles.contains(.code) {
                    storage.addAttributes([
                        .foregroundColor: elements.inlineCode.color ?? theme.inlineCodeColor,
                        .backgroundColor: NSColor(white: 0.5, alpha: 0.12),
                    ], range: range)
                    storage.removeAttribute(.underlineStyle, range: range)
                } else {
                    let color: NSColor
                    if headingLevel > 0 {
                        color = elements.heading(headingLevel).color ?? theme.textColor
                    } else if isBodyCode {
                        color = theme.secondaryColor
                    } else if isQuote {
                        color = elements.quote.color ?? theme.textColor
                    } else if styles.contains(.bold), let bold = elements.bold.color {
                        color = bold
                    } else {
                        color = theme.textColor
                    }
                    storage.addAttribute(.foregroundColor, value: color, range: range)
                    storage.removeAttribute(.underlineStyle, range: range)
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
        }

        // MARK: Images

        /// Attaches NSTextAttachments to image placeholders (U+FFFC + .mdImage).
        private func attachImages(_ storage: NSTextStorage) {
            let full = NSRange(location: 0, length: storage.length)
            guard full.length > 0 else { return }
            storage.enumerateAttribute(.mdImage, in: full) { value, range, _ in
                guard let info = value as? [String: String] else { return }
                if storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil {
                    return
                }
                storage.addAttribute(.attachment,
                                     value: attachment(forSource: info["src"] ?? ""),
                                     range: range)
            }
        }

        private func attachment(forSource src: String) -> NSTextAttachment {
            if let cached = imageAttachments[src] { return cached }
            let result = NSTextAttachment()
            if let url = resolveImageURL(src), let image = NSImage(contentsOf: url),
               image.size.width > 0 {
                result.image = image
                let maxWidth: CGFloat = 420
                let scale = image.size.width > maxWidth ? maxWidth / image.size.width : 1
                result.bounds = CGRect(x: 0, y: 0,
                                       width: image.size.width * scale,
                                       height: image.size.height * scale)
            } else {
                // Missing/remote file: visible placeholder instead of nothing.
                result.image = NSImage(systemSymbolName: "photo",
                                       accessibilityDescription: src)
                result.bounds = CGRect(x: 0, y: -3, width: 18, height: 15)
            }
            imageAttachments[src] = result
            return result
        }

        private func resolveImageURL(_ src: String) -> URL? {
            guard URL(string: src)?.scheme == nil, let fileURL = parent.fileURL else { return nil }
            let baseDir = fileURL.pathExtension == "textbundle"
                ? fileURL
                : fileURL.deletingLastPathComponent()
            let path = src.removingPercentEncoding ?? src
            return baseDir.appendingPathComponent(path).standardizedFileURL
        }

        // MARK: Sync

        private func syncToDocument() {
            guard let storage = textView?.textStorage else { return }
            let detailed = serializeAttributedToMarkdownDetailed(storage)
            lastParagraphRanges = detailed.paragraphRanges
            var serialized = detailed.markdown
            if !serialized.isEmpty { serialized += "\n" }
            lastSerialized = serialized
            isInternalUpdate = true
            parent.document.content = serialized
            isInternalUpdate = false
            storeCursor()
        }

        func updateStats() {
            guard let textView else { return }
            let (words, chars) = wordAndCharCount(in: textView.string)
            DispatchQueue.main.async { [parent] in
                parent.onStatsUpdate(words, chars)
            }
        }

        @objc func settingsDidChange() {
            // A color-override change keeps the preset name, so updateNSView's
            // name gate wouldn't refresh the theme — source it here directly.
            textView?.theme = EditorSettings.shared.effectiveTheme
            imageAttachments.removeAll()
            loadDocument()  // restoreCursor keeps the place via the position store
            if let textView {
                textView.textContainerInset = EditorSettings.shared.visual.textContainerInset(
                    forWidth: textView.enclosingScrollView?.contentView.bounds.width ?? 0)
            }
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
