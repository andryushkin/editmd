import AppKit

// The Source-mode NSTextView subclass: gutter drawing, special paste
// (table/image doors), lint quick-fixes and table structure ops in the
// context menu. Extracted from SourceTextView.swift.

/// Ordered special-paste doors for Source. Closures are lazy on purpose: a
/// Word/Excel table must be consumed before image detection even inspects its
/// TIFF preview, and a fenced code block must inspect neither door. The URL
/// door comes last (before plain text): it fires for a pure-URL clipboard,
/// wrapping a selection as `[text](url)` or inserting a `<url>` autolink when
/// there is none — neither of which can be a table or image payload.
func handleSourceSpecialPaste(insideFence: Bool,
                              tableMarkdown: () -> String?,
                              insertTable: (String) -> Void,
                              insertImage: () -> Bool,
                              linkifySelection: () -> Bool) -> Bool {
    guard !insideFence else { return false }
    if let markdown = tableMarkdown() {
        insertTable(markdown)
        return true
    }
    if insertImage() { return true }
    return linkifySelection()
}

final class SourceNSTextView: NSTextView {

    /// Line numbers / dirty marks, drawn in the left inset (no NSRulerView —
    /// AppKit would pin it to the pane edge, far from a centred column).
    var gutterState = GutterState()
    weak var wikiCompletion: WikiCompletionController?

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGutterNumbers(in: rect, state: gutterState)
    }

    override func keyDown(with event: NSEvent) {
        if wikiCompletion?.handleKey(event: event) == true { return }
        super.keyDown(with: event)
    }

    // MARK: - List / checkbox / table auto-continuation

    /// Return continues Markdown structure: a fresh bullet / checkbox / ordered
    /// marker on a list item, a new empty row inside a pipe table. An empty item
    /// (or empty table row) ends the structure instead. Everything else — a
    /// caret inside a fenced code block, a ranged selection, a non-list line —
    /// falls through to the default newline.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length == 0, !caretInsideFence() else {
            super.insertNewline(sender); return
        }
        let ns = string as NSString
        var lineStart = 0, contentEnd = 0
        ns.getLineStart(&lineStart, end: nil, contentsEnd: &contentEnd,
                        for: NSRange(location: selection.location, length: 0))
        let line = ns.substring(with: NSRange(location: lineStart,
                                              length: contentEnd - lineStart))
        let caretColumn = selection.location - lineStart

        if let action = listReturnAction(line: line, caretColumn: caretColumn) {
            applyListReturn(action, lineStart: lineStart, caret: selection.location)
            return
        }
        if continueTableRow(lineStart: lineStart, contentEnd: contentEnd, line: line) {
            return
        }
        super.insertNewline(sender)
    }

    private func applyListReturn(_ action: ListReturnAction, lineStart: Int, caret: Int) {
        switch action {
        case .insertMarker(let marker):
            let insertion = "\n" + marker
            let range = NSRange(location: caret, length: 0)
            guard shouldChangeText(in: range, replacementString: insertion) else { return }
            textStorage?.replaceCharacters(in: range, with: insertion)
            didChangeText()
            setSelectedRange(NSRange(location: caret + (insertion as NSString).length, length: 0))
        case .clearMarker(let relative):
            let range = NSRange(location: lineStart + relative.location, length: relative.length)
            guard shouldChangeText(in: range, replacementString: "") else { return }
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: range.location, length: 0))
        }
    }

    /// Adds an empty row below a pipe-table body row, or ends the table when the
    /// current body row is already empty. Returns false (default newline) unless
    /// the caret sits on a body row — inserting between the header and delimiter
    /// would split the table.
    private func continueTableRow(lineStart: Int, contentEnd: Int, line: String) -> Bool {
        guard let context = sourceTableContext(in: string, at: lineStart),
              context.line >= 2 else { return false }
        if pipeRowIsEmpty(line) {
            let range = NSRange(location: lineStart, length: contentEnd - lineStart)
            guard shouldChangeText(in: range, replacementString: "") else { return true }
            textStorage?.replaceCharacters(in: range, with: "")
            didChangeText()
            setSelectedRange(NSRange(location: lineStart, length: 0))
            return true
        }
        let insertion = "\n" + emptyPipeRow(columns: context.grid.columnCount)
        let range = NSRange(location: contentEnd, length: 0)
        guard shouldChangeText(in: range, replacementString: insertion) else { return true }
        textStorage?.replaceCharacters(in: range, with: insertion)
        didChangeText()
        // Caret into the first cell of the new row (past the leading "\n|").
        setSelectedRange(NSRange(location: contentEnd + 2, length: 0))
        return true
    }

    var lintDiagnostics: [LintDiagnostic] = []
    private var menuFixes: [LintFix] = []
    private enum SourceTableOp { case rowAbove, rowBelow, deleteRow, colLeft, colRight, deleteColumn }
    private var menuTableOps: [SourceTableOp] = []
    private var menuTableContext: SourceTableContext?

    // Paste as plain text — rich content from the clipboard would introduce
    // attributes the highlighter doesn't own (isRichText is on only so our
    // own per-element attributes render). Exceptions: clipboard images become
    // assets + Markdown, and tables (HTML from web/Word/Excel, or TSV) become
    // pipe-table Markdown.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        let inFence = caretInsideFence()
        if handleSourceSpecialPaste(
            insideFence: inFence,
            tableMarkdown: {
                markdownTableFromPasteboard(
                    html: pasteboard.string(forType: .html),
                    plain: pasteboard.string(forType: .string))
            },
            insertTable: { [weak self] in self?.insertPastedTable($0) },
            insertImage: { [weak self] in
                guard let coordinator = self?.delegate as? SourceTextView.Coordinator
                else { return false }
                return coordinator.pasteImageFromPasteboard()
            },
            linkifySelection: { [weak self] in
                self?.linkifyPastedURL(pasteboard.string(forType: .string)) == true
            }) {
            return
        }
        pasteAsPlainText(sender)
    }

    /// Formats a bare-URL clipboard as a Markdown link: over a non-empty
    /// selection the selection becomes the label (`[selection](url)`); with no
    /// selection it inserts an autolink (`<url>`), which — unlike a plain bare
    /// URL — actually renders as a clickable link. Returns false (so plain paste
    /// runs) only when the clipboard isn't a single URL.
    private func linkifyPastedURL(_ pasteboardString: String?) -> Bool {
        guard let url = bareWebURLForPaste(pasteboardString) else { return false }
        let selection = selectedRange()
        let replacement: String
        if selection.length > 0 {
            let selected = (string as NSString).substring(with: selection)
            guard selectionUsableAsLinkLabel(selected) else { return false }
            replacement = markdownLinkSyntax(text: selected, url: url)
        } else {
            replacement = markdownAutolinkSyntax(url: url)
        }
        guard shouldChangeText(in: selection, replacementString: replacement) else { return true }
        textStorage?.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (replacement as NSString).length,
                                 length: 0))
        return true
    }

    // MARK: - Image drag-and-drop

    /// Coordinator for image-drop routing (same object as the paste path).
    private var imageDropCoordinator: SourceTextView.Coordinator? {
        delegate as? SourceTextView.Coordinator
    }

    /// Selection as it was before an image drag started moving the caret —
    /// restored when the drag leaves or is cancelled without a drop.
    private var selectionBeforeImageDrag: NSRange?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if imageCandidate(from: sender.draggingPasteboard) != nil {
            selectionBeforeImageDrag = selectedRange()
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard imageCandidate(from: sender.draggingPasteboard) != nil else {
            return super.draggingUpdated(sender)
        }
        // Track the drop point so the caret shows where the image will land.
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        restoreSelectionAfterAbandonedImageDrag()
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        // Reached without a drop (Esc / released outside): undo the caret moves.
        restoreSelectionAfterAbandonedImageDrag()
        super.draggingEnded(sender)
    }

    private func restoreSelectionAfterAbandonedImageDrag() {
        if let saved = selectionBeforeImageDrag {
            setSelectedRange(saved)
            selectionBeforeImageDrag = nil
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if imageCandidate(from: sender.draggingPasteboard) != nil { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let candidate = imageCandidate(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        // A drop is happening — the pre-drag selection is gone for good.
        selectionBeforeImageDrag = nil
        let point = convert(sender.draggingLocation, from: nil)
        setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        if imageDropCoordinator?.insertDraggedImage(candidate) == true { return true }
        // Refused context (fence) / failed store: hand the drop to the default
        // text handling so it degrades like paste does.
        return super.performDragOperation(sender)
    }

    /// Fenced code blocks are literal — TSV pasted there must stay TSV.
    /// Fence-marker parity up to the caret (``` / ~~~ at line start).
    func caretInsideFence() -> Bool {
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        var inside = false
        var location = 0
        while location < caret {
            var lineEnd = 0, contentEnd = 0
            ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd,
                            for: NSRange(location: location, length: 0))
            let line = ns.substring(with: NSRange(location: location,
                                                  length: contentEnd - location))
                .trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { inside.toggle() }
            if lineEnd == location { break }
            location = lineEnd
        }
        return inside
    }

    /// Inserts pipe-table markdown, padding with newlines so the table starts
    /// on its own line and the following text keeps its own.
    private func insertPastedTable(_ markdown: String) {
        let ns = string as NSString
        let selection = selectedRange()
        var text = markdown
        let atLineStart = selection.location == 0
            || (selection.location <= ns.length
                && ns.character(at: selection.location - 1) == 0x0A)
        if !atLineStart { text = "\n" + text }
        let end = NSMaxRange(selection)
        if end >= ns.length || ns.character(at: end) != 0x0A { text += "\n" }
        guard shouldChangeText(in: selection, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: selection, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: selection.location + (text as NSString).length,
                                 length: 0))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let menu else { return menu }
        let point = convert(event.locationInWindow, from: nil)

        if !lintDiagnostics.isEmpty, let idx = characterIndex(at: point) {
            let hits = lintDiagnostics.filter { NSLocationInRange(idx, $0.range) }
            if !hits.isEmpty {
                menuFixes = []
                var insertAt = 0
                for diagnostic in hits {
                    // action == nil → the item auto-disables; serves as a header.
                    let header = NSMenuItem(title: diagnostic.message, action: nil, keyEquivalent: "")
                    menu.insertItem(header, at: insertAt)
                    insertAt += 1
                    for fix in diagnostic.fixes {
                        let item = NSMenuItem(title: fix.title,
                                              action: #selector(applyLintFix(_:)),
                                              keyEquivalent: "")
                        item.target = self
                        item.tag = menuFixes.count
                        item.indentationLevel = 1
                        menuFixes.append(fix)
                        menu.insertItem(item, at: insertAt)
                        insertAt += 1
                    }
                }
                menu.insertItem(.separator(), at: insertAt)
            }
        }

        // Table structure ops when the click lands inside a pipe table.
        if let idx = nearestCharacterIndex(at: point),
           let context = sourceTableContext(in: string, at: idx) {
            menuTableContext = context
            menuTableOps = []
            var insertAt = 0
            func add(_ title: String, _ op: SourceTableOp, enabled: Bool = true) {
                let item = NSMenuItem(title: title,
                                      action: enabled ? #selector(applySourceTableOp(_:)) : nil,
                                      keyEquivalent: "")
                if enabled { item.target = self }
                item.tag = menuTableOps.count
                menuTableOps.append(op)
                menu.insertItem(item, at: insertAt)
                insertAt += 1
            }
            let onBody = context.bodyIndex != nil
            add(String(localized: "Row Above"), .rowAbove, enabled: onBody)
            add(String(localized: "Row Below"), .rowBelow)
            add(String(localized: "Delete Row"), .deleteRow, enabled: onBody)
            menu.insertItem(.separator(), at: insertAt); insertAt += 1
            add(String(localized: "Column Left"), .colLeft)
            add(String(localized: "Column Right"), .colRight)
            add(String(localized: "Delete Column"), .deleteColumn, enabled: context.grid.columnCount > 1)
            menu.insertItem(.separator(), at: insertAt)
        }
        return menu
    }

    /// Applies a table structure op by replacing the whole table with the
    /// canonical serialization of the mutated grid (reformatting intended).
    @objc private func applySourceTableOp(_ sender: NSMenuItem) {
        guard let context = menuTableContext,
              sender.tag >= 0, sender.tag < menuTableOps.count,
              NSMaxRange(context.tableRange) <= (string as NSString).length else { return }
        var grid = context.grid
        let ok: Bool
        switch menuTableOps[sender.tag] {
        case .rowAbove:
            guard let body = context.bodyIndex else { return }
            grid.insertRow(at: body); ok = true
        case .rowBelow:
            grid.insertRow(at: context.bodyIndex.map { $0 + 1 } ?? 0); ok = true
        case .deleteRow:
            guard let body = context.bodyIndex else { return }
            ok = grid.deleteRow(at: body)
        case .colLeft:
            grid.insertColumn(at: context.column); ok = true
        case .colRight:
            grid.insertColumn(at: context.column + 1); ok = true
        case .deleteColumn:
            ok = grid.deleteColumn(at: context.column)
        }
        guard ok else { NSSound.beep(); return }
        let replacement = serializeGFMTable(grid)
        guard shouldChangeText(in: context.tableRange, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: context.tableRange, with: replacement)
        didChangeText()
    }

    /// Character index of the glyph nearest to a view point — table ops accept
    /// clicks anywhere on the row, incl. right of the line end.
    private func nearestCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        // Reject vertical misses (clicks above/below the text) — nearest-glyph
        // would otherwise snap them onto the first/last line.
        let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        guard containerPoint.y >= lineRect.minY, containerPoint.y <= lineRect.maxY else { return nil }
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < ns.length ? charIndex : nil
    }

    @objc private func applyLintFix(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < menuFixes.count else { return }
        let fix = menuFixes[sender.tag]
        guard NSMaxRange(fix.range) <= (string as NSString).length else { return }
        guard shouldChangeText(in: fix.range, replacementString: fix.replacement) else { return }
        textStorage?.replaceCharacters(in: fix.range, with: fix.replacement)
        didChangeText()
    }

    /// Character index under the view-coordinate point, or nil when the point
    /// falls outside any glyph.
    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        guard glyphRect.contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyphIndex)
    }
}
