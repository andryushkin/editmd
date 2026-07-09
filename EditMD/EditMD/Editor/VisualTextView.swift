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
        // Document-scoped undo — survives mode switches (see MarkdownDocument).
        textView.allowsUndo = false
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
        // Large documents: lay out only the ranges TextKit needs, not the whole
        // storage up front (Apple's recommended big-document win).
        textView.layoutManager?.allowsNonContiguousLayout = true
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
        coordinator.refreshGutter()
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollOrBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView)

        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.settingsDidChange),
            name: .editorSettingsDidChange,
            object: nil)
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.lineMarksDidChange),
            name: .lineChangeMarksDidChange,
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
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.windowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil)
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
        // External change (Revert, or another window editing the shared
        // document). A background window defers the re-render until it becomes
        // key so its cursor/scroll survive edits made elsewhere.
        if !coordinator.isInternalUpdate, document.content != coordinator.lastSerialized {
            if textView.window?.isKeyWindow ?? true {
                coordinator.loadDocument()
            } else {
                coordinator.pendingExternalReload = true
            }
        }
        coordinator.refreshGutter()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: VisualMarkdownView
        weak var textView: VisualNSTextView?
        var isInternalUpdate = false
        var lastSerialized = ""
        /// A background window sets this when the shared document changes under
        /// it; the re-render is applied when the window next becomes key.
        var pendingExternalReload = false
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
            textView.finishActiveTableEditing(commit: true)
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

        /// Applies a deferred external change once the window regains focus (see
        /// updateNSView's background-window gate).
        @objc func windowBecameKey(_ note: Notification) {
            guard pendingExternalReload, let tv = textView,
                  (note.object as? NSWindow) === tv.window else { return }
            pendingExternalReload = false
            loadDocument()
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
            parent.document.noteContentEdited()
            DocumentRegistry.shared.noteUserEdit(parent.fileURL)
            LineChangeTracker.shared.noteContent(url: parent.fileURL,
                                                 content: parent.document.content)
            updateStats()
            refreshGutter()
        }

        /// Visual gutter shows **source** line numbers (via paragraph→md map), not 1…N of the WYSIWYG buffer.
        func refreshGutter() {
            guard let textView else { return }
            let settings = EditorSettings.shared.gutter
            let md = parent.document.content
            let sourceDirty = LineChangeTracker.shared.dirtyLines(for: parent.fileURL)
            let map = displayToSourceLineMap(paragraphRanges: lastParagraphRanges, markdown: md)
            let font = EditorSettings.shared.visual.resolvedFont(defaultMono: false)
            let sourceLines = max(1, splitDiffLines(md).count)
            textView.installOrUpdateLineNumberRuler(
                fileURL: parent.fileURL,
                dirtySourceLines: sourceDirty,
                settings: settings,
                bodyFont: font,
                displayToSourceLine: map,
                sourceLineCountHint: sourceLines)
        }

        @objc func scrollOrBoundsChanged(_ note: Notification) {
            (textView?.enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?
                .needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep custom attrs out of typing attributes only where harmful:
            // links must not extend as the user types after them.
            guard let textView else { return }
            var attrs = textView.typingAttributes
            if attrs[.mdLink] != nil || attrs[.mdImage] != nil || attrs[.mdWikiLink] != nil {
                attrs[.mdLink] = nil
                attrs[.mdImage] = nil
                attrs[.mdWikiLink] = nil
                textView.typingAttributes = attrs
            }
            storeCursor()
        }

        func textView(_ view: NSTextView, shouldChangeTextIn affectedRange: NSRange,
                      replacementString: String?) -> Bool {
            // Capture document baseline before any mutation (incl. table row ops).
            parent.document.beginContentEdit()
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
                // enumerateAttributes (not just .mdInline): plain runs have no
                // .mdInline key, so enumerateAttribute skipped them and left the
                // old heading-sized font after demoting to body.
                storage.enumerateAttributes(in: stampRange) { attrs, range, _ in
                    let styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
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

        private func tableIsland(at paragraphLocation: Int) -> (range: NSRange, grid: TableGrid)? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let nsText = storage.string as NSString
            guard nsText.length > 0 else { return nil }
            let paragraph = nsText.paragraphRange(for: NSRange(location: min(paragraphLocation, nsText.length - 1),
                                                               length: 0))
            let block = block(at: paragraph, in: storage)
            guard case .raw(let raw) = block.kind, let grid = parseGFMTable(raw) else { return nil }
            return (paragraph, grid)
        }

        private func tableIslandDisplayText(_ grid: TableGrid) -> String {
            var lines = serializeGFMTable(grid).components(separatedBy: "\n")
            if lines.count >= 2 { lines.remove(at: 1) } // hide delimiter in Visual display
            return lines.joined(separator: mdHardBreak)
        }

        private func replaceTableIsland(paragraph: NSRange, oldBlock: MDBlock, grid: TableGrid) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            var block = oldBlock
            block.kind = .raw(serializeGFMTable(grid))
            let replacement = NSAttributedString(string: tableIslandDisplayText(grid) + "\n", attributes: [
                .font: visualStyle.font(for: [], blockKind: block.kind),
                .foregroundColor: NSColor.labelColor,
                .mdBlock: block,
            ])
            guard textView.shouldChangeText(in: paragraph, replacementString: replacement.string) else {
                return false
            }
            isMutating = true
            storage.replaceCharacters(in: paragraph, with: replacement)
            if replacement.length > 0 {
                storage.addAttribute(.mdBlock, value: block,
                                     range: NSRange(location: paragraph.location, length: replacement.length))
            }
            isMutating = false
            textView.didChangeText()
            afterMutation()
            return true
        }

        @discardableResult
        func updateTableIslandCell(paragraphLocation: Int, row: Int, column: Int, value: String) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            grid.updateCell(row: row, column: column, value: value)
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
        }

        @discardableResult
        func insertTableIslandRow(paragraphLocation: Int, atBodyIndex bodyIndex: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            grid.insertRow(at: bodyIndex)
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
        }

        @discardableResult
        func deleteTableIslandRow(paragraphLocation: Int, atBodyIndex bodyIndex: Int) -> Bool {
            guard let textView, let storage = textView.textStorage else { return false }
            guard let island = tableIsland(at: paragraphLocation) else { return false }
            var grid = island.grid
            guard grid.deleteRow(at: bodyIndex) else { return false }
            let oldBlock = block(at: island.range, in: storage)
            return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
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
                toggleHighlight: { [weak self] in self?.toggleInlineStyle(.highlight) },
                setHeading: { [weak self] level in self?.setHeading(level) },
                setBody: { [weak self] in self?.setBodyParagraph() },
                toggleBulletList: { [weak self] in self?.toggleListKind(
                    isTarget: { if case .bulletItem = $0 { return true }; return false },
                    makeKind: { .bulletItem(depth: $0) }) },
                toggleNumberedList: { [weak self] in self?.toggleListKind(
                    isTarget: { if case .orderedItem = $0 { return true }; return false },
                    makeKind: { .orderedItem(depth: $0, number: 1) }) },
                toggleQuote: { [weak self] in self?.toggleQuote() },
                toggleCodeBlock: { [weak self] in self?.toggleCodeBlock() },
                copySelection: { [weak self] in self?.copySelection() },
                insertTable: { [weak self] in self?.insertEmptyTable() },
                tableAddRow: { [weak self] in self?.tableAddRowAtCursor() },
                tableDeleteRow: { [weak self] in self?.tableDeleteRowAtCursor() },
                formulaStub: {
                    NSSound.beep()
                    let alert = NSAlert()
                    alert.messageText = "Формулы"
                    alert.informativeText = "Редактирование формул появится позже."
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            )
            DispatchQueue.main.async { [parent] in
                parent.onFormatActions(actions)
            }
        }

        private func copySelection() {
            guard let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else { NSSound.beep(); return }
            let text = (textView.string as NSString).substring(with: range)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }

        private func setBodyParagraph() {
            guard let textView, let storage = textView.textStorage else { return }
            var paragraphs = selectedParagraphs()
            // Caret with empty selection still demotes the current paragraph.
            if paragraphs.isEmpty, storage.length > 0 {
                let nsText = storage.string as NSString
                let p = paragraphRange(at: textView.selectedRange().location, in: nsText)
                switch block(at: p, in: storage).kind {
                case .tableCell, .raw: break
                default: paragraphs = [p]
                }
            }
            guard !paragraphs.isEmpty else { NSSound.beep(); return }
            for paragraph in paragraphs {
                var target = block(at: paragraph, in: storage)
                target.kind = .paragraph
                target.group = -1
                target.quoteDepth = 0
                target.quoteGroup = -1
                restamp(paragraph, to: target, in: textView)
            }
        }

        private func insertEmptyTable() {
            guard let textView, let storage = textView.textStorage else { return }
            let md = """
            |   |   |   |
            | --- | --- | --- |
            |   |   |   |
            |   |   |   |

            """
            let rendered = renderMarkdownToAttributed(md, style: visualStyle)
            let selection = textView.selectedRange()
            guard textView.shouldChangeText(in: selection, replacementString: rendered.string)
            else { return }
            isMutating = true
            storage.replaceCharacters(in: selection, with: rendered)
            isMutating = false
            textView.didChangeText()
            afterMutation()
        }

        private func tableAddRowAtCursor() {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraph = paragraphRange(at: textView.selectedRange().location,
                                           in: storage.string as NSString)
            let current = block(at: paragraph, in: storage)
            if case .tableCell = current.kind {
                if let newRow = appendTableRow(group: current.group) {
                    moveCursor(toCell: (newRow, 0), group: current.group)
                }
                return
            }
            // Large-table island: append a body row.
            if let island = tableIsland(at: paragraph.location) {
                let at = island.grid.rows.count
                if insertTableIslandRow(paragraphLocation: paragraph.location, atBodyIndex: at) {
                    return
                }
            }
            NSSound.beep()
        }

        private func tableDeleteRowAtCursor() {
            guard let textView, let storage = textView.textStorage else { return }
            let paragraph = paragraphRange(at: textView.selectedRange().location,
                                           in: storage.string as NSString)
            let current = block(at: paragraph, in: storage)
            if case .tableCell(let row, _, _, _) = current.kind {
                deleteTableRow(row, group: current.group)
                return
            }
            if let island = tableIsland(at: paragraph.location), !island.grid.rows.isEmpty {
                let last = island.grid.rows.count - 1
                if deleteTableIslandRow(paragraphLocation: paragraph.location, atBodyIndex: last) {
                    return
                }
            }
            NSSound.beep()
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

        /// Cmd+click on a wiki-link: resolve its target against the workspace
        /// and open the file (relative to this document's folder).
        func openWikiLink(_ payload: MDWikiLinkPayload) {
            navigateToWikiLink(target: payload.target, from: parent.fileURL)
        }

        /// Absolute x edges (left→right, including the right edge) for a large
        /// table's columns. Widths come from the header plus a sample of body
        /// rows (measuring every row of a 9000-row table would be wasteful),
        /// clamped to a sane min/max so one long cell can't blow out the grid.
        private func tableColumnEdges(_ grid: TableGrid, font: NSFont, headerFont: NSFont,
                                      originX: CGFloat) -> [CGFloat] {
            let columns = grid.columnCount
            guard columns > 0 else { return [originX] }
            let cellPadding: CGFloat = 12   // 6pt on each side
            let minWidth: CGFloat = 44
            let maxWidth: CGFloat = 260
            // Measure *rendered* inline markdown (not raw `**bold**` markers) so
            // column widths match what drawTableRow actually paints.
            func measure(_ s: String, _ f: NSFont) -> CGFloat {
                renderTableCellAttributed(s, baseFont: f,
                                          textColor: .labelColor,
                                          linkColor: .linkColor,
                                          codeColor: .systemOrange).size().width
            }
            var widths = [CGFloat](repeating: minWidth, count: columns)
            for (c, header) in grid.headers.enumerated() where c < columns {
                widths[c] = max(widths[c], measure(header, headerFont) + cellPadding)
            }
            for row in grid.rows.prefix(60) {
                for (c, cell) in row.enumerated() where c < columns {
                    widths[c] = max(widths[c], measure(cell, font) + cellPadding)
                }
            }
            var edges: [CGFloat] = [originX]
            for w in widths { edges.append((edges.last ?? originX) + min(w, maxWidth)) }
            return edges
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
            var tableIslands: [TableIslandEntry] = []
            var propertiesPanels: [NSRange] = []

            var orderedCounters: [String: Int] = [:]
            var lastListGroupDepth: (group: Int, depth: Int)? = nil
            // One shared NSTextTable per table group — cells of one table must
            // reference the same instance or layout falls apart.
            var textTables: [Int: NSTextTable] = [:]
            let theme = textView.theme

            let spacingScale = EditorSettings.shared.visualSpacing.scale
            // Pre-scan: which paragraphs are first/last line of each code group,
            // so margin can be applied in the same pass as other styles (a
            // follow-up attribute write was easy to lose / override).
            var codeGroupFirst = Set<Int>()  // paragraph.location
            var codeGroupLast = Set<Int>()
            var codeGroupsTmp: [Int: (first: Int, last: Int)] = [:]  // group → (firstLoc, lastLoc)
            var scanLoc = 0
            while scanLoc < nsText.length {
                let para = nsText.paragraphRange(for: NSRange(location: scanLoc, length: 0))
                defer { scanLoc = NSMaxRange(para) == scanLoc ? scanLoc + 1 : NSMaxRange(para) }
                guard let block = storage.attribute(.mdBlock, at: para.location,
                                                    effectiveRange: nil) as? MDBlock,
                      case .codeBlock = block.kind else { continue }
                if var ends = codeGroupsTmp[block.group] {
                    ends.last = para.location
                    codeGroupsTmp[block.group] = ends
                } else {
                    codeGroupsTmp[block.group] = (para.location, para.location)
                }
            }
            for ends in codeGroupsTmp.values {
                codeGroupFirst.insert(ends.first)
                codeGroupLast.insert(ends.last)
            }

            // Margin = white between cards. Independent of panel padding.
            // Must be large enough that even if pad steals ~6pt each side, a
            // clear gap remains (and neighboring lines stay unpainted).
            let codeBlockMargin: CGFloat = max(24, 24 * spacingScale)

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
                var isTableIsland = false
                var isFrontmatter = false
                // Document-leading block: top gap is `textContainerInset.height`
                // (Settings ▸ Vertical). Extra paragraphSpacingBefore here would
                // stack on insetV and make Vertical look broken at 0.
                let isDocumentStart = paragraph.location == 0

                switch blockValue.kind {
                case .heading(let level):
                    style.paragraphSpacingBefore = isDocumentStart
                        ? 0
                        : (level <= 2 ? 14 : 10) * spacingScale
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
                    // Tight lines inside one fence. Margin only on group edges.
                    style.paragraphSpacing = 0
                    style.paragraphSpacingBefore = 0
                    if codeGroupFirst.contains(paragraph.location), !isDocumentStart {
                        style.paragraphSpacingBefore = codeBlockMargin
                    }
                    if codeGroupLast.contains(paragraph.location) {
                        style.paragraphSpacing = codeBlockMargin
                    }
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
                case .raw(let rawText):
                    // A large table stored as a raw island (renderTable falls
                    // back to `.raw` above maxNativeTableCells). Draw it as a
                    // virtualized grid instead of monospace pipe text: hide the
                    // text, pin a fixed row height, register a draw entry. Other
                    // raw islands (HTML) keep the monospace fallback.
                    if let grid = parseGFMTable(rawText) {
                        let bodyFont = visualStyle.font(for: [], blockKind: .paragraph)
                        let headerFont = visualStyle.font(for: .bold, blockKind: .paragraph)
                        let rowHeight = ceil(bodyFont.ascender - bodyFont.descender) + 12
                        style.minimumLineHeight = rowHeight
                        style.maximumLineHeight = rowHeight
                        style.lineBreakMode = .byClipping
                        style.paragraphSpacing = 8 * spacingScale
                        let edges = tableColumnEdges(grid, font: bodyFont, headerFont: headerFont,
                                                     originX: textView.textContainerInset.width)
                        tableIslands.append(TableIslandEntry(range: paragraph, grid: grid,
                                                             columnEdges: edges, rowHeight: rowHeight,
                                                             font: bodyFont, headerFont: headerFont))
                        isTableIsland = true
                    } else if frontmatterRange(in: rawText) != nil {
                        // Frontmatter properties card: a subtle panel (drawn in
                        // drawBackground) with colored keys (colorYAMLIsland).
                        // Leading frontmatter sits flush under the strip via insetV.
                        style.paragraphSpacingBefore = isDocumentStart ? 0 : 4 * spacingScale
                        style.paragraphSpacing = 12 * spacingScale
                        markerIndent = 14
                        propertiesPanels.append(paragraph)
                        isFrontmatter = true
                    } else {
                        markerIndent = 10
                    }
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
                    if isTableIsland {
                        // The pipe text only reserves layout height; the grid is
                        // drawn in drawBackground. Hide the characters.
                        storage.addAttribute(.foregroundColor, value: NSColor.clear,
                                             range: paragraph)
                    } else if isFrontmatter {
                        colorYAMLIsland(storage, paragraph: paragraph)
                    } else {
                        applyDerivedInlineDecorations(storage, paragraph: paragraph, block: blockValue)
                    }
                }
            }

            attachImages(storage)
            storage.endEditing()
            isMutating = false

            // Ensure paragraphSpacing (code-block margin) is laid out before the
            // next draw — otherwise panels still paint against stale geometry.
            if let lm = textView.layoutManager, let tc = textView.textContainer {
                lm.ensureLayout(for: tc)
            }

            textView.bulletEntries = bullets
            textView.numberEntries = numbers
            textView.taskEntries = tasks
            textView.quoteEntries = quotes
            textView.codePanelRanges = Array(codeGroups.values)
            textView.ruleRanges = ruleRanges
            textView.headingDividerRanges = headingDividers
            textView.tableIslandEntries = tableIslands
            textView.propertiesPanelRanges = propertiesPanels
            textView.needsDisplay = true
        }

        /// Colors a frontmatter island's display text: keys muted + semibold,
        /// typed values (numbers/booleans/null/quoted strings) tinted, comments
        /// dimmed. Segment offsets come from `yamlLineSegments`, whose texts
        /// concatenate back to each display line. Display lines are joined by
        /// the hard-break char (one UTF-16 unit) inside one paragraph.
        private func colorYAMLIsland(_ storage: NSTextStorage, paragraph: NSRange) {
            guard let textView else { return }
            let theme = textView.theme
            let nsText = storage.string as NSString
            storage.addAttribute(.foregroundColor, value: theme.textColor, range: paragraph)
            let keyFont = NSFont.monospacedSystemFont(ofSize: max(1, visualStyle.baseSize - 1),
                                                      weight: .semibold)
            var lineStart = paragraph.location
            for line in nsText.substring(with: paragraph).components(separatedBy: mdHardBreak) {
                var col = lineStart
                for (segText, kind) in yamlLineSegments(line) {
                    let length = (segText as NSString).length
                    let range = NSRange(location: col, length: length)
                    if NSMaxRange(range) <= NSMaxRange(paragraph) {
                        if let color = yamlColor(kind, theme) {
                            storage.addAttribute(.foregroundColor, value: color, range: range)
                        }
                        if kind == .key {
                            storage.addAttribute(.font, value: keyFont, range: range)
                        }
                    }
                    col += length
                }
                lineStart += (line as NSString).length + 1   // + hard-break char
            }
        }

        private func yamlColor(_ kind: YAMLTokenKind, _ theme: EditorTheme) -> NSColor? {
            switch kind {
            case .key, .comment: return theme.secondaryColor
            case .punctuation: return theme.tertiaryColor
            case .number, .bool, .null: return theme.accentColor
            case .string: return theme.inlineCodeColor
            case .plain: return nil
            }
        }

        private func isListKind(_ kind: MDBlock.Kind) -> Bool {
            switch kind {
            case .bulletItem, .orderedItem, .taskItem, .listContinuation:
                return true
            default:
                return false
            }
        }

        /// Obsidian-style highlight fill — matches Preview `mark` CSS.
        private static let highlightMarkColor = NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return NSColor(red: 1, green: 0.77, blue: 0, alpha: 0.35)
            default:
                return NSColor(red: 1, green: 0.83, blue: 0, alpha: 0.45)
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
                // Always re-derive font from block kind so demoting a heading
                // to body (or promoting body → H1) updates size/weight even on
                // runs that never carried .mdInline.
                let fontStyles: MDInlineStyle = isHeaderCell ? styles.union(.bold) : styles
                storage.addAttribute(.font,
                                     value: self.visualStyle.font(for: fontStyles, blockKind: block.kind),
                                     range: range)
                let strike = styles.contains(.strike) || isDone
                if strike {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue, range: range)
                } else {
                    storage.removeAttribute(.strikethroughStyle, range: range)
                }
                if attrs[.mdWikiLink] != nil {
                    // Wiki-links look like links; navigation is Cmd+click (resolver).
                    storage.addAttributes([
                        .foregroundColor: elements.link.color ?? theme.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
                    storage.removeAttribute(.backgroundColor, range: range)
                } else if attrs[.mdLink] != nil {
                    storage.addAttributes([
                        .foregroundColor: elements.link.color ?? theme.accentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ], range: range)
                    storage.removeAttribute(.backgroundColor, range: range)
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
                    if styles.contains(.highlight) {
                        // Match Preview `<mark>` (light / dark).
                        storage.addAttribute(.backgroundColor,
                                             value: Self.highlightMarkColor,
                                             range: range)
                    } else {
                        storage.removeAttribute(.backgroundColor, range: range)
                    }
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
            refreshGutter()
            publishActions()
        }

        @objc func lineMarksDidChange() {
            refreshGutter()
        }
    }
}

// MARK: - Text view with drawn markers

/// A large table drawn as a virtualized, read-only grid rather than laid out as
/// NSTextTable cells (which peg the CPU past a few thousand cells). `range` is
/// the island paragraph whose (hidden) pipe text reserves the vertical space;
/// `columnEdges` are absolute x positions left→right including the right edge;
/// `rowHeight` is the fixed height each display line was pinned to, so row rects
/// are computed arithmetically — no full line-fragment enumeration, which is
/// what keeps a 9000-row table cheap to draw.
struct TableIslandEntry {
    let range: NSRange
    let grid: TableGrid
    let columnEdges: [CGFloat]
    let rowHeight: CGFloat
    let font: NSFont
    let headerFont: NSFont
}

private final class TableCellEditorField: NSTextField {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onMove: ((Bool) -> Void)?      // true: forward, false: backward
    var onDeleteRow: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            onCancel?()
        case 48: // Tab
            onCommit?(stringValue)
            onMove?(!event.modifierFlags.contains(.shift))
        case 51 where event.modifierFlags.contains(.command): // Cmd+Backspace
            onDeleteRow?()
        case 36, 76: // Enter/Return
            onCommit?(stringValue)
        default:
            super.keyDown(with: event)
        }
    }
}

private final class TableCellEditorCell: NSTextFieldCell {
    var insets: NSSize = .zero

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        rect.insetBy(dx: insets.width, dy: insets.height)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        rect.insetBy(dx: insets.width, dy: insets.height)
    }

    override func select(withFrame frame: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate anObject: Any?, start selStart: Int, length selLength: Int) {
        let rect = frame.insetBy(dx: insets.width, dy: insets.height)
        super.select(withFrame: rect, in: controlView, editor: textObj,
                     delegate: anObject, start: selStart, length: selLength)
    }
}

final class VisualNSTextView: NSTextView {
    var theme: EditorTheme = .system
    var bulletEntries: [(range: NSRange, depth: Int)] = []
    var numberEntries: [(range: NSRange, depth: Int, number: Int)] = []
    var taskEntries: [(range: NSRange, depth: Int, done: Bool)] = []
    var quoteEntries: [(range: NSRange, depth: Int)] = []
    var codePanelRanges: [NSRange] = []
    var ruleRanges: [NSRange] = []
    var headingDividerRanges: [NSRange] = []
    var tableIslandEntries: [TableIslandEntry] = [] {
        didSet { tableCellAttrCache.removeAll(keepingCapacity: true) }
    }
    var propertiesPanelRanges: [NSRange] = []
    private var islandHorizontalOffsets: [Int: CGFloat] = [:]
    private var focusedIslandCell: (paragraphLocation: Int, row: Int, column: Int)?
    private var activeEditor: TableCellEditorField?
    private var activeEditorCell: (paragraphLocation: Int, row: Int, column: Int)?
    /// Cache of rendered cell attributed strings for the current island set
    /// (invalidated when `tableIslandEntries` is reassigned).
    private var tableCellAttrCache: [String: NSAttributedString] = [:]

    private var visualCoordinator: VisualMarkdownView.Coordinator? {
        delegate as? VisualMarkdownView.Coordinator
    }
    private var editorSettings: VisualTableEditorSettings { EditorSettings.shared.visualTableEditor }

    // Paste always as plain text — outside rich content would corrupt the model.
    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if activeEditor != nil, let hit = tableCellHit(at: point) {
            // Fast path: switch editor directly to another cell.
            finishActiveTableEditing(commit: true)
            focusedIslandCell = (hit.entry.range.location, hit.row, hit.column)
            _ = startEditingTableCell(paragraphLocation: hit.entry.range.location,
                                      row: hit.row, column: hit.column)
            return
        }
        if let editor = activeEditor,
           !editor.frame.insetBy(dx: -editorSettings.editorCellInset, dy: -editorSettings.editorCellInset).contains(point) {
            finishActiveTableEditing(commit: true)
        }
        if event.clickCount >= 2, startEditingTableCell(at: point) {
            return
        }
        if let hit = tableCellHit(at: point) {
            focusedIslandCell = (hit.entry.range.location, hit.row, hit.column)
        } else {
            focusedIslandCell = nil
        }
        if let paragraph = taskParagraph(at: point) {
            visualCoordinator?.toggleTaskDone(at: paragraph)
            return
        }
        if event.modifierFlags.contains(.command),
           let payload = wikiPayload(at: point) {
            visualCoordinator?.openWikiLink(payload)
            return
        }
        if event.modifierFlags.contains(.command),
           let url = linkURL(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 120, beginEditingFocusedTableCell() { // F2
            return
        }
        if (event.keyCode == 36 || event.keyCode == 76), beginEditingFocusedTableCell() {
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = tableCellHit(at: point) else {
            super.scrollWheel(with: event)
            return
        }
        let wantsHorizontal = event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
        guard wantsHorizontal else {
            super.scrollWheel(with: event)
            return
        }
        let key = hit.entry.range.location
        let current = islandHorizontalOffsets[key] ?? 0
        let maxOffset = max(0, (hit.entry.columnEdges.last ?? 0) - textContainerInset.width - (bounds.width - textContainerInset.width * 2))
        let next = min(max(0, current + event.scrollingDeltaX + event.scrollingDeltaY), maxOffset)
        if abs(next - current) > 0.5 {
            islandHorizontalOffsets[key] = next
            needsDisplay = true
        }
    }

    private func wikiPayload(at point: NSPoint) -> MDWikiLinkPayload? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        return storage.attribute(.mdWikiLink, at: charIndex, effectiveRange: nil) as? MDWikiLinkPayload
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

    private func tableCellHit(at point: NSPoint) -> (entry: TableIslandEntry, row: Int, column: Int, rect: NSRect)? {
        guard let layoutManager else { return nil }
        let totalLength = (string as NSString).length
        for entry in tableIslandEntries {
            guard entry.range.location < totalLength, entry.columnEdges.count >= 2 else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let firstRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let top = firstRect.minY + textContainerInset.height
            let totalRows = entry.grid.rows.count + 1
            let height = CGFloat(totalRows) * entry.rowHeight
            let islandRect = NSRect(x: textContainerInset.width, y: top, width: bounds.width - textContainerInset.width * 2, height: height)
            guard islandRect.contains(point) else { continue }
            let offset = islandHorizontalOffsets[entry.range.location] ?? 0
            let row = min(totalRows - 1, max(0, Int((point.y - top) / entry.rowHeight)))
            let x = point.x + offset
            var column = 0
            while column + 1 < entry.columnEdges.count, x >= entry.columnEdges[column + 1] {
                column += 1
            }
            column = min(max(0, column), entry.grid.columnCount - 1)
            let left = entry.columnEdges[column] - offset
            let right = entry.columnEdges[column + 1] - offset
            let rect = NSRect(x: left, y: top + CGFloat(row) * entry.rowHeight, width: right - left, height: entry.rowHeight)
            return (entry, row, column, rect)
        }
        return nil
    }

    private func beginEditingFocusedTableCell() -> Bool {
        guard activeEditor == nil, let focus = focusedIslandCell else { return false }
        return startEditingTableCell(paragraphLocation: focus.paragraphLocation, row: focus.row, column: focus.column)
    }

    private func startEditingTableCell(at point: NSPoint) -> Bool {
        guard let hit = tableCellHit(at: point) else { return false }
        focusedIslandCell = (hit.entry.range.location, hit.row, hit.column)
        return startEditingTableCell(paragraphLocation: hit.entry.range.location, row: hit.row, column: hit.column)
    }

    private func startEditingTableCell(paragraphLocation: Int, row: Int, column: Int) -> Bool {
        if let current = activeEditorCell {
            if current.paragraphLocation == paragraphLocation && current.row == row && current.column == column {
                return true
            }
            finishActiveTableEditing(commit: true)
        }
        guard activeEditor == nil else { return false }
        guard let entry = tableIslandEntries.first(where: { $0.range.location == paragraphLocation }) else { return false }
        let offset = islandHorizontalOffsets[paragraphLocation] ?? 0
        guard column >= 0, column < entry.grid.columnCount else { return false }
        let totalRows = entry.grid.rows.count + 1
        guard row >= 0, row < totalRows else { return false }
        let cells = row == 0 ? entry.grid.headers : entry.grid.rows[row - 1]
        let value = column < cells.count ? cells[column] : ""
        guard let layoutManager else { return false }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return false }
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let top = firstRect.minY + textContainerInset.height
        let left = entry.columnEdges[column] - offset
        let right = entry.columnEdges[column + 1] - offset
        let cellInset = editorSettings.editorCellInset
        let cellFrame = NSRect(x: left + cellInset, y: top + CGFloat(row) * entry.rowHeight + cellInset,
                               width: max(32, right - left - cellInset * 2),
                               height: max(20, entry.rowHeight - cellInset * 2))
        let frame = expandedEditorFrame(for: value, cellFrame: cellFrame, font: row == 0 ? entry.headerFont : entry.font)
        let editor = TableCellEditorField(frame: frame)
        let cell = TableCellEditorCell()
        cell.insets = NSSize(width: editorSettings.editorTextInsetH, height: editorSettings.editorTextInsetV)
        editor.cell = cell
        editor.font = row == 0 ? entry.headerFont : entry.font
        editor.isBezeled = false
        editor.isBordered = false
        editor.drawsBackground = true
        editor.stringValue = value
        editor.focusRingType = .none
        editor.backgroundColor = editorSettings.editorBackgroundColor
        editor.textColor = editorSettings.editorTextColor
        editor.lineBreakMode = .byWordWrapping
        editor.usesSingleLineMode = false
        editor.onCommit = { [weak self] text in
            guard let self else { return }
            _ = self.visualCoordinator?.updateTableIslandCell(
                paragraphLocation: paragraphLocation, row: row, column: column, value: text)
            self.endCellEditing()
            self.focusedIslandCell = (paragraphLocation, row, column)
        }
        editor.onCancel = { [weak self] in
            self?.endCellEditing()
        }
        editor.onMove = { [weak self] forward in
            guard let self else { return }
            guard let current = self.focusedIslandCell,
                  current.paragraphLocation == paragraphLocation else { return }
            guard let currentEntry = self.tableIslandEntries.first(where: { $0.range.location == paragraphLocation }) else { return }
            let rows = currentEntry.grid.rows.count + 1
            if let next = nextTableCellPosition(row: row, column: column, columns: currentEntry.grid.columnCount,
                                                rows: rows, forward: forward) {
                self.focusedIslandCell = (paragraphLocation, next.row, next.column)
                _ = self.startEditingTableCell(paragraphLocation: paragraphLocation, row: next.row, column: next.column)
            } else if forward {
                if self.visualCoordinator?.insertTableIslandRow(paragraphLocation: paragraphLocation,
                                                                atBodyIndex: currentEntry.grid.rows.count) == true {
                    let nextRow = rows
                    self.focusedIslandCell = (paragraphLocation, nextRow, 0)
                    _ = self.startEditingTableCell(paragraphLocation: paragraphLocation, row: nextRow, column: 0)
                }
            }
        }
        editor.onDeleteRow = { [weak self] in
            guard let self else { return }
            guard row > 0 else { return }
            if self.visualCoordinator?.deleteTableIslandRow(paragraphLocation: paragraphLocation,
                                                            atBodyIndex: row - 1) == true {
                self.endCellEditing()
                let nextRow = max(1, row - 1)
                self.focusedIslandCell = (paragraphLocation, nextRow, column)
            }
        }
        editor.onTextChange = { [weak self, weak editor] text in
            guard let self, let editor else { return }
            let resized = self.expandedEditorFrame(for: text, cellFrame: cellFrame,
                                                   font: editor.font ?? NSFont.systemFont(ofSize: 13))
            if editor.frame != resized {
                editor.frame = resized
            }
        }
        addSubview(editor)
        activeEditor = editor
        activeEditorCell = (paragraphLocation, row, column)
        needsDisplay = true
        window?.makeFirstResponder(editor)
        editor.selectText(nil)
        return true
    }

    private func expandedEditorFrame(for text: String, cellFrame: NSRect, font: NSFont) -> NSRect {
        let visible = enclosingScrollView?.contentView.documentVisibleRect ?? bounds
        let s = editorSettings
        let margin = s.editorViewportMargin
        let maxUsableWidth = max(220, visible.width - margin * 2)
        let expandedWidth = min(max(cellFrame.width + s.editorWidthExtra, s.editorMinWidth),
                                min(max(260, bounds.width * s.editorMaxWidthRatio), maxUsableWidth))
        let minHeight = max(cellFrame.height + s.editorTextInsetV * 2, s.editorMinHeight)
        let maxHeight = max(56, min(bounds.height * s.editorMaxHeightRatio, visible.height - margin * 2))
        let measureRect = NSRect(x: 0, y: 0,
                                 width: max(80, expandedWidth - (s.editorTextInsetH * 2 + 8)),
                                 height: .greatestFiniteMagnitude)
        let measured = (text as NSString).boundingRect(
            with: measureRect.size,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let targetHeight = min(max(minHeight, ceil(measured.height) + s.editorHeightExtra), maxHeight)
        var x = cellFrame.minX + s.editorXOffset
        var y = cellFrame.midY - targetHeight / 2
        let minX = visible.minX + margin
        let maxX = visible.maxX - margin - expandedWidth
        let minY = visible.minY + margin
        let maxY = visible.maxY - margin - targetHeight
        x = min(max(x, minX), max(minX, maxX))
        y = min(max(y, minY), max(minY, maxY))
        return NSRect(x: x,
                      y: y,
                      width: expandedWidth,
                      height: targetHeight)
    }

    private func endCellEditing() {
        activeEditor?.removeFromSuperview()
        activeEditor = nil
        activeEditorCell = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func finishActiveTableEditing(commit: Bool) {
        guard let editor = activeEditor, let cell = activeEditorCell else { return }
        if commit {
            let currentValue = tableCellCurrentValue(paragraphLocation: cell.paragraphLocation,
                                                     row: cell.row, column: cell.column)
            if currentValue != editor.stringValue {
                _ = visualCoordinator?.updateTableIslandCell(
                    paragraphLocation: cell.paragraphLocation,
                    row: cell.row,
                    column: cell.column,
                    value: editor.stringValue
                )
            }
        }
        endCellEditing()
    }

    private func tableCellCurrentValue(paragraphLocation: Int, row: Int, column: Int) -> String? {
        guard let entry = tableIslandEntries.first(where: { $0.range.location == paragraphLocation }) else {
            return nil
        }
        if row == 0 {
            guard column >= 0, column < entry.grid.headers.count else { return nil }
            return entry.grid.headers[column]
        }
        let bodyIndex = row - 1
        guard bodyIndex >= 0, bodyIndex < entry.grid.rows.count else { return nil }
        let cells = entry.grid.rows[bodyIndex]
        guard column >= 0, column < cells.count else { return nil }
        return cells[column]
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
        if activeEditor != nil {
            editorSettings.overlayColor.setFill()
            (enclosingScrollView?.contentView.documentVisibleRect ?? bounds).fill()
        }
        guard let layoutManager else { return }
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

        // Code panels.
        // padding = gray around glyphs only (fixed).
        // margin = enforced white gap between panel outer edges + clamp so a
        // panel never paints over a neighboring (non-member) line fragment.
        let codePanelPadding: CGFloat = 6
        let codeBlockMargin: CGFloat = 12
        var panelRects: [NSRect] = []
        panelRects.reserveCapacity(codePanelRanges.count)
        for range in codePanelRanges {
            guard var box = unionRect(for: range) else { continue }
            // Internal padding around the text of THIS fence only.
            box = box.insetBy(dx: 0, dy: -codePanelPadding)
            // Clamp to neighbors outside the character range so pad cannot
            // bleed onto the previous/next paragraph (quote, list, other code).
            if range.location > 0 {
                let prevIdx = range.location - 1
                let prevGlyph = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: prevIdx, length: 1),
                    actualCharacterRange: nil)
                if prevGlyph.location != NSNotFound {
                    var prevFrag = NSRect.null
                    layoutManager.enumerateLineFragments(forGlyphRange: prevGlyph) { fragment, _, _, _, _ in
                        let r = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                       width: fullWidth, height: fragment.height)
                        prevFrag = prevFrag.isNull ? r : prevFrag.union(r)
                    }
                    if !prevFrag.isNull {
                        box.origin.y = max(box.minY, prevFrag.maxY + codeBlockMargin)
                        box.size.height = max(0, box.maxY - box.minY)
                    }
                }
            }
            let after = NSMaxRange(range)
            if after < totalLength {
                let nextGlyph = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: after, length: 1),
                    actualCharacterRange: nil)
                if nextGlyph.location != NSNotFound {
                    var nextFrag = NSRect.null
                    layoutManager.enumerateLineFragments(forGlyphRange: nextGlyph) { fragment, _, _, _, _ in
                        let r = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                       width: fullWidth, height: fragment.height)
                        nextFrag = nextFrag.isNull ? r : nextFrag.union(r)
                    }
                    if !nextFrag.isNull {
                        let maxY = nextFrag.minY - codeBlockMargin
                        if maxY < box.maxY {
                            box.size.height = max(0, maxY - box.minY)
                        }
                    }
                }
            }
            if box.height > 0 { panelRects.append(box) }
        }
        // Resolve panel–panel overlap (adjacent fences): keep margin between
        // outer edges by shrinking into the gap, never by expanding gray.
        panelRects.sort { $0.minY < $1.minY }
        if panelRects.count > 1 {
            for i in 1..<panelRects.count {
                let prev = panelRects[i - 1]
                var cur = panelRects[i]
                let minTop = prev.maxY + codeBlockMargin
                if cur.minY < minTop {
                    let shrink = minTop - cur.minY
                    cur.origin.y += shrink
                    cur.size.height = max(0, cur.height - shrink)
                    panelRects[i] = cur
                }
            }
        }
        theme.codeBlockBackground.setFill()
        for box in panelRects where box.intersects(rect) && box.height > 1 {
            NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        }

        // Frontmatter properties cards (Obsidian-style metadata panel)
        for range in propertiesPanelRanges {
            guard let rectUnion = unionRect(for: range) else { continue }
            let padded = rectUnion.insetBy(dx: 0, dy: -8)
            guard padded.intersects(rect) else { continue }
            let path = NSBezierPath(roundedRect: padded, xRadius: 7, yRadius: 7)
            NSColor(white: 0.5, alpha: 0.06).setFill()
            path.fill()
            path.lineWidth = 1
            theme.separatorColor.withAlphaComponent(0.6).setStroke()
            path.stroke()
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

        // Bullets — depth cycles • (fill) / ◦ (stroke) / ▪ (square), like Source.
        for (range, depth) in bulletEntries {
            guard let marker = markerRect(forParagraph: range) else { continue }
            let radius = marker.height * 0.18
            let center = NSPoint(x: marker.midX, y: marker.midY)
            let box = NSRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)
            switch depth % 3 {
            case 0:
                theme.accentColor.setFill()
                NSBezierPath(ovalIn: box).fill()
            case 1:
                theme.accentColor.setStroke()
                let ring = NSBezierPath(ovalIn: box)
                ring.lineWidth = max(1.25, radius * 0.35)
                ring.stroke()
            default:
                theme.accentColor.setFill()
                let side = radius * 1.7
                let square = NSRect(x: center.x - side / 2, y: center.y - side / 2,
                                    width: side, height: side)
                NSBezierPath(rect: square).fill()
            }
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

        // Large tables (drawn as virtualized read-only grids)
        for entry in tableIslandEntries {
            drawTableIsland(entry, dirty: rect, inset: inset, layoutManager: layoutManager)
        }
    }

    /// Draws only the rows of a large table that intersect `dirty`. Row rects
    /// are derived from the island's first line-fragment origin plus a fixed
    /// `rowHeight` (arithmetic, not a full fragment walk), so cost scales with
    /// the viewport, not with table size. The island's display text drops the
    /// `---` delimiter, so display line 0 = header and lines 1… = data rows.
    private func drawTableIsland(_ entry: TableIslandEntry, dirty: NSRect, inset: NSSize,
                                 layoutManager: NSLayoutManager) {
        let totalLength = (string as NSString).length
        guard entry.range.location < totalLength, entry.columnEdges.count >= 2 else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location,
                                                       effectiveRange: nil)
        let top = firstRect.minY + inset.height
        let rowH = entry.rowHeight
        let grid = entry.grid
        let edges = entry.columnEdges
        let horizontalOffset = islandHorizontalOffsets[entry.range.location] ?? 0
        let left = (edges.first ?? inset.width) - horizontalOffset
        let right = (edges.last ?? inset.width) - horizontalOffset
        let width = right - left
        let totalLines = grid.rows.count + 1   // header + data rows (no delimiter)
        let bottom = top + CGFloat(totalLines) * rowH

        let firstVisible = max(0, Int(floor((dirty.minY - top) / rowH)))
        let lastVisible = min(totalLines - 1, Int(ceil((dirty.maxY - top) / rowH)))
        guard firstVisible <= lastVisible else { return }

        let border = theme.separatorColor
        for i in firstVisible...lastVisible {
            let rowY = top + CGFloat(i) * rowH
            let rowRect = NSRect(x: left, y: rowY, width: width, height: rowH)
            if i == 0 {
                NSColor(white: 0.5, alpha: 0.08).setFill()
                rowRect.fill()
                border.setFill()
                NSRect(x: left, y: top, width: width, height: 0.5).fill()   // table top
                drawTableRow(grid.headers, in: rowRect, font: entry.headerFont,
                             color: theme.textColor, edges: edges, alignments: grid.alignments,
                             horizontalOffset: horizontalOffset)
            } else {
                let dataIndex = i - 1
                if dataIndex < grid.rows.count {
                    drawTableRow(grid.rows[dataIndex], in: rowRect, font: entry.font,
                                 color: theme.textColor, edges: edges, alignments: grid.alignments,
                                 horizontalOffset: horizontalOffset)
                }
            }
            border.setFill()
            NSRect(x: left, y: rowY + rowH - 0.5, width: width, height: 0.5).fill()   // row rule
        }

        // Vertical column separators across the visible span.
        let visTop = max(dirty.minY, top)
        let visBottom = min(dirty.maxY, bottom)
        if visBottom > visTop {
            border.setFill()
            for x in edges {
                NSRect(x: x - horizontalOffset - 0.25, y: visTop, width: 0.5, height: visBottom - visTop).fill()
            }
        }
    }

    private func drawTableRow(_ cells: [String], in rowRect: NSRect, font: NSFont,
                              color: NSColor, edges: [CGFloat],
                              alignments: [TableGrid.Alignment], horizontalOffset: CGFloat) {
        let columns = edges.count - 1
        let lineHeight = font.ascender - font.descender
        let textY = rowRect.minY + (rowRect.height - lineHeight) / 2
        let elements = EditorSettings.shared.visual.elements
        let linkColor = elements.link.color ?? theme.accentColor
        let codeColor = elements.inlineCode.color ?? theme.inlineCodeColor
        let boldColor = elements.bold.color
        for c in 0..<columns where c < cells.count {
            let text = cells[c]
            guard !text.isEmpty else { continue }
            let cellW = edges[c + 1] - edges[c]
            guard cellW > 12 else { continue }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            switch (c < alignments.count ? alignments[c] : .leading) {
            case .leading: para.alignment = .left
            case .center: para.alignment = .center
            case .trailing: para.alignment = .right
            }
            let drawRect = NSRect(x: edges[c] - horizontalOffset + 6, y: textY,
                                  width: cellW - 12, height: lineHeight)
            let attr = attributedTableCell(text, font: font, textColor: color,
                                           linkColor: linkColor, codeColor: codeColor,
                                           boldColor: boldColor, paragraphStyle: para)
            attr.draw(in: drawRect)
        }
    }

    /// Renders (and caches) a table-island cell's inline markdown for drawing.
    private func attributedTableCell(_ markdown: String, font: NSFont,
                                     textColor: NSColor, linkColor: NSColor,
                                     codeColor: NSColor, boldColor: NSColor?,
                                     paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        // Key omits colors that rarely change mid-scroll; theme changes rebuild
        // `tableIslandEntries` and clear the cache via didSet.
        let key = "\(font.fontName)|\(font.pointSize)|\(markdown)"
        if let cached = tableCellAttrCache[key] {
            // Paragraph style (alignment / truncate) is per-column — stamp on a copy.
            let copy = NSMutableAttributedString(attributedString: cached)
            copy.addAttribute(.paragraphStyle, value: paragraphStyle,
                              range: NSRange(location: 0, length: copy.length))
            return copy
        }
        let rendered = renderTableCellAttributed(markdown, baseFont: font,
                                                 textColor: textColor,
                                                 linkColor: linkColor,
                                                 codeColor: codeColor,
                                                 boldColor: boldColor)
        tableCellAttrCache[key] = rendered
        let copy = NSMutableAttributedString(attributedString: rendered)
        if copy.length > 0 {
            copy.addAttribute(.paragraphStyle, value: paragraphStyle,
                              range: NSRange(location: 0, length: copy.length))
        }
        return copy
    }
}
