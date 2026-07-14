import AppKit

func visualPointHitsCharacterRange(_ point: NSPoint, range: NSRange,
                                   layoutManager: NSLayoutManager,
                                   textContainer: NSTextContainer,
                                   tolerance: CGFloat = 2) -> Bool {
    guard range.length > 0 else { return false }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                              actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return false }
    let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
    return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
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
    /// Line numbers / dirty marks, drawn in the left inset (no NSRulerView —
    /// AppKit would pin it to the pane edge, far from a centred column).
    var gutterState = GutterState()
    var bulletEntries: [(range: NSRange, depth: Int)] = []
    var numberEntries: [(range: NSRange, depth: Int, number: Int)] = []
    var taskEntries: [(range: NSRange, depth: Int, done: Bool)] = []
    var builtInPluginTaskEntries: [(range: NSRange, depth: Int,
                                    token: BuiltInPluginTokenPayload)] = []
    var builtInPluginSnapshot: BuiltInPluginSnapshot = .empty {
        didSet { tableCellAttrCache.removeAll(keepingCapacity: true) }
    }
    var quoteEntries: [(range: NSRange, depth: Int)] = []
    var codePanelRanges: [NSRange] = []
    var ruleRanges: [NSRange] = []
    var headingDividerRanges: [NSRange] = []
    var tableIslandEntries: [TableIslandEntry] = [] {
        didSet {
            tableCellAttrCache.removeAll(keepingCapacity: true)
            // Reassigned by every presentation pass — cheap proxy for "text
            // or layout changed", which also invalidates cached row frames.
            nativeRowFrameCache.removeAll(keepingCapacity: true)
        }
    }
    var propertiesPanelRanges: [NSRange] = []
    private var islandHorizontalOffsets: [Int: CGFloat] = [:]
    private var focusedIslandCell: (paragraphLocation: Int, row: Int, column: Int)?
    private var activeEditor: TableCellEditorField?
    private var activeEditorCell: (paragraphLocation: Int, row: Int, column: Int)?
    /// Cache of rendered cell attributed strings for the current island set
    /// (invalidated when `tableIslandEntries` is reassigned).
    private var tableCellAttrCache: [String: NSAttributedString] = [:]
    /// Native table row frames ("group:row" → view rect) for the grip gutter —
    /// recomputing on every mouseMoved would walk the whole storage.
    private var nativeRowFrameCache: [String: NSRect] = [:]
    /// Context-menu table ops (items reference `menuTableOps` by tag).
    private var menuTableTarget: TableTarget?
    private var menuTableOps: [TableStructureOp] = []
    /// Live row drag-reorder session (grip in the left gutter of body rows).
    private struct RowDragSession {
        let target: TableTarget
        let sourceBody: Int
        let rowFrames: [NSRect]
        var gap: Int
    }
    private var rowDrag: RowDragSession?
    private var hoverRowHandle: (frame: NSRect, target: TableTarget, body: Int)?
    private var rowHandleTracking: NSTrackingArea?

    private var visualCoordinator: VisualMarkdownView.Coordinator? {
        delegate as? VisualMarkdownView.Coordinator
    }
    private var editorSettings: VisualTableEditorSettings { EditorSettings.shared.visualTableEditor }

    // Clipboard rich-text attributes are never accepted. Recognizable Markdown
    // is rebuilt through our own semantic renderer; everything else remains
    // plain text.
    override func paste(_ sender: Any?) {
        if handleVisualSpecialPaste(
            pasteMarkdown: { [weak self] in
                self?.visualCoordinator?.pasteMarkdownFromPasteboard() == true
            },
            pasteImage: { [weak self] in
                self?.visualCoordinator?.pasteImageFromPasteboard() == true
            }) { return }
        pasteAsPlainText(sender)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = rowHandle(at: point) {
            finishActiveTableEditing(commit: true)
            beginRowDrag(handle: handle)
            return
        }
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
        if event.clickCount >= 2, let mathIndex = mathAttachmentIndex(at: point),
           visualCoordinator?.editFormula(at: mathIndex) == true {
            return
        }
        if event.clickCount >= 2, startEditingTableCell(at: point) {
            return
        }
        if let hit = tableCellHit(at: point) {
            focusedIslandCell = (hit.entry.range.location, hit.row, hit.column)
        } else {
            focusedIslandCell = nil
        }
        if event.clickCount == 1, frontmatterToggleRange(at: point) != nil {
            visualCoordinator?.toggleFrontmatterCollapse()
            return
        }
        if let paragraph = builtInPluginTaskParagraph(at: point) {
            visualCoordinator?.toggleBuiltInPluginTask(at: paragraph)
            return
        }
        if let token = builtInPluginInlineToken(at: point) {
            visualCoordinator?.cycleBuiltInPluginInlineToken(in: token.range)
            return
        }
        if event.clickCount == 1, let hit = tableCellHit(at: point),
           cycleBuiltInPluginIslandCell(hit) {
            return
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
           let dest = linkDestination(at: point) {
            visualCoordinator?.openLink(destination: dest)
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

    /// Character index of a rendered-formula attachment under the point, or
    /// nil. Unlike the wiki hit, the glyph's actual rect is verified — a
    /// double-click in empty space next to a formula must select, not edit.
    private func mathAttachmentIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length,
              storage.attribute(.mdMathTex, at: charIndex, effectiveRange: nil) != nil
        else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                              in: textContainer)
        guard rect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return charIndex
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

    /// Exact hit-test for the frontmatter title. `glyphIndex(for:)` returns the
    /// nearest glyph even in blank space, so verify the title's bounding rect
    /// before treating a click as a disclosure action.
    private func frontmatterToggleRange(at point: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard storage.attribute(.mdFrontmatterToggle, at: index,
                                longestEffectiveRange: &range,
                                in: NSRange(location: 0, length: storage.length)) != nil,
              visualPointHitsCharacterRange(containerPoint, range: range,
                                            layoutManager: layoutManager,
                                            textContainer: textContainer)
        else { return nil }
        return range
    }

    /// Raw `[text](destination)` under the cursor — scheme URLs and local
    /// paths alike; the coordinator decides how to open (v: pdf-спринт).
    private func linkDestination(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        return storage.attribute(.mdLink, at: charIndex, effectiveRange: nil) as? String
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

    private func builtInPluginTaskParagraph(at point: NSPoint) -> NSRange? {
        for entry in builtInPluginTaskEntries {
            if let rect = markerRect(forParagraph: entry.range),
               rect.insetBy(dx: -3, dy: -3).contains(point) {
                return entry.range
            }
        }
        return nil
    }

    private func builtInPluginInlineToken(at point: NSPoint)
        -> (range: NSRange, payload: BuiltInPluginTokenPayload)? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        var range = NSRange(location: 0, length: 0)
        guard let payload = storage.attribute(.mdBuiltInPluginToken, at: index,
                                              longestEffectiveRange: &range,
                                              in: NSRange(location: 0,
                                                          length: storage.length))
                as? BuiltInPluginTokenPayload,
              payload.isInteractive else { return nil }
        guard visualPointHitsCharacterRange(containerPoint, range: range,
                                            layoutManager: layoutManager,
                                            textContainer: textContainer) else { return nil }
        return (range, payload)
    }

    private func cycleBuiltInPluginIslandCell(
        _ hit: (entry: TableIslandEntry, row: Int, column: Int, rect: NSRect)) -> Bool {
        let value: String
        if hit.row == 0 {
            guard hit.column < hit.entry.grid.headers.count else { return false }
            value = hit.entry.grid.headers[hit.column]
        } else {
            let row = hit.row - 1
            guard row < hit.entry.grid.rows.count,
                  hit.column < hit.entry.grid.rows[row].count else { return false }
            value = hit.entry.grid.rows[row][hit.column]
        }
        let leading = value.prefix { $0.isWhitespace }
        let trailing = value.reversed().prefix { $0.isWhitespace }.reversed()
        let core = value.trimmingCharacters(in: .whitespaces)
        guard let payload = builtInPluginSnapshot.payload(matchingSource: core) else { return false }
        let replacement = String(leading) + payload.next.state.source + String(trailing)
        return visualCoordinator?.updateTableIslandCell(
            paragraphLocation: hit.entry.range.location,
            row: hit.row, column: hit.column, value: replacement) == true
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

    // MARK: - Table structure ops (context menu)

    /// Table cell (native or island) under a point — context-menu anchor.
    private func tableTarget(at point: NSPoint) -> TableTarget? {
        if let hit = tableCellHit(at: point) {
            return .island(paragraphLocation: hit.entry.range.location,
                           row: hit.row, column: hit.column,
                           rows: hit.entry.grid.rows.count + 1,
                           columns: hit.entry.grid.columnCount)
        }
        guard let index = nearestCharacterIndex(at: point),
              let target = visualCoordinator?.nativeTableTarget(atCharIndex: index),
              case .native(let group, let row, _, _, _) = target,
              let rowFrame = nativeRowFrame(group: group, row: row),
              rowFrame.insetBy(dx: -8, dy: -2).contains(point)
        else { return nil }
        return target
    }

    /// Character index of the glyph nearest to a view point (no containment
    /// check — the row-frame test above rejects far-away hits).
    private func nearestCharacterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        return charIndex < storage.length ? charIndex : nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let point = convert(event.locationInWindow, from: nil)
        guard let target = tableTarget(at: point) else { return menu }
        menuTableTarget = target
        menuTableOps = []
        var insertAt = 0
        func add(_ title: String, _ op: TableStructureOp, enabled: Bool = true) {
            // action == nil → the item auto-disables (header-row restrictions).
            let item = NSMenuItem(title: title,
                                  action: enabled ? #selector(applyTableMenuOp(_:)) : nil,
                                  keyEquivalent: "")
            if enabled { item.target = self }
            item.tag = menuTableOps.count
            menuTableOps.append(op)
            menu.insertItem(item, at: insertAt)
            insertAt += 1
        }
        let isHeader = target.row == 0
        add("Строка выше", .insertRowAbove, enabled: !isHeader)
        add("Строка ниже", .insertRowBelow)
        add("Удалить строку", .deleteRow, enabled: !isHeader)
        menu.insertItem(.separator(), at: insertAt); insertAt += 1
        add("Столбец слева", .insertColumnLeft)
        add("Столбец справа", .insertColumnRight)
        add("Удалить столбец", .deleteColumn, enabled: target.columns > 1)
        menu.insertItem(.separator(), at: insertAt)
        return menu
    }

    @objc private func applyTableMenuOp(_ sender: NSMenuItem) {
        guard let target = menuTableTarget,
              sender.tag >= 0, sender.tag < menuTableOps.count else { return }
        finishActiveTableEditing(commit: true)
        if visualCoordinator?.performTableOp(menuTableOps[sender.tag], on: target) != true {
            NSSound.beep()
        }
    }

    // MARK: - Table row geometry

    private func islandTop(_ entry: TableIslandEntry) -> CGFloat? {
        guard let layoutManager else { return nil }
        let totalLength = (string as NSString).length
        guard entry.range.location < totalLength else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        return layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location,
                                              effectiveRange: nil).minY
            + textContainerInset.height
    }

    private func islandRowFrame(_ entry: TableIslandEntry, row: Int) -> NSRect? {
        guard let top = islandTop(entry), entry.columnEdges.count >= 2 else { return nil }
        let offset = islandHorizontalOffsets[entry.range.location] ?? 0
        let left = entry.columnEdges[0] - offset
        let right = (entry.columnEdges.last ?? left) - offset
        return NSRect(x: left, y: top + CGFloat(row) * entry.rowHeight,
                      width: right - left, height: entry.rowHeight)
    }

    /// Union frame of a native table row's cells (view coordinates, cached —
    /// hover hit-testing runs on every mouseMoved).
    private func nativeRowFrame(group: Int, row: Int) -> NSRect? {
        let key = "\(group):\(row)"
        if let cached = nativeRowFrameCache[key] { return cached }
        guard let coordinator = visualCoordinator, let layoutManager, let textContainer,
              let storage = textStorage else { return nil }
        var union = NSRect.null
        for cell in coordinator.tableCells(group: group, in: storage) where cell.row == row {
            let glyphs = layoutManager.glyphRange(forCharacterRange: cell.range,
                                                  actualCharacterRange: nil)
            guard glyphs.length > 0 else { continue }
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            union = union.isNull ? rect : union.union(rect)
        }
        guard !union.isNull else { return nil }
        let frame = union.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        nativeRowFrameCache[key] = frame
        return frame
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        nativeRowFrameCache.removeAll(keepingCapacity: true)
    }

    // MARK: - Row drag reorder (grip in the left gutter of body rows)

    /// Grip zone left of a table body row; header rows have no grip.
    private func rowHandle(at point: NSPoint) -> (frame: NSRect, target: TableTarget, body: Int)? {
        // Islands: arithmetic row rects.
        for entry in tableIslandEntries
        where entry.columnEdges.count >= 2 && entry.grid.rows.count > 1 {
            guard let top = islandTop(entry) else { continue }
            let totalRows = entry.grid.rows.count + 1
            guard point.y >= top, point.y < top + CGFloat(totalRows) * entry.rowHeight
            else { continue }
            let offset = islandHorizontalOffsets[entry.range.location] ?? 0
            let left = entry.columnEdges[0] - offset
            guard point.x >= left - 26, point.x <= left - 4 else { continue }
            let row = min(totalRows - 1, max(0, Int((point.y - top) / entry.rowHeight)))
            guard row >= 1 else { return nil }
            let frame = NSRect(x: left - 26, y: top + CGFloat(row) * entry.rowHeight,
                               width: 22, height: entry.rowHeight)
            let target = TableTarget.island(paragraphLocation: entry.range.location,
                                            row: row, column: 0,
                                            rows: totalRows, columns: entry.grid.columnCount)
            return (frame, target, row - 1)
        }
        // Native tables: nearest glyph → cell block → row frame → gutter zone.
        guard let index = nearestCharacterIndex(at: point),
              let target = visualCoordinator?.nativeTableTarget(atCharIndex: index),
              case .native(let group, let row, _, let rows, _) = target,
              row >= 1, rows > 2,
              let rowFrame = nativeRowFrame(group: group, row: row) else { return nil }
        let zone = NSRect(x: rowFrame.minX - 26, y: rowFrame.minY,
                          width: 22, height: rowFrame.height)
        guard zone.contains(point) else { return nil }
        return (zone, target, row - 1)
    }

    private func bodyRowFrames(for target: TableTarget) -> [NSRect] {
        switch target {
        case .native(let group, _, _, let rows, _):
            return (1..<max(1, rows)).compactMap { nativeRowFrame(group: group, row: $0) }
        case .island(let paragraphLocation, _, _, let rows, _):
            guard let entry = tableIslandEntries.first(where: {
                $0.range.location == paragraphLocation
            }) else { return [] }
            return (1..<max(1, rows)).compactMap { islandRowFrame(entry, row: $0) }
        }
    }

    /// Synchronous drag loop (standard AppKit tracking): indicator follows the
    /// mouse, mouse-up commits the move through the coordinator.
    private func beginRowDrag(handle: (frame: NSRect, target: TableTarget, body: Int)) {
        let frames = bodyRowFrames(for: handle.target)
        guard frames.count > 1, handle.body < frames.count, let window else { return }
        setHoverRowHandle(nil)
        rowDrag = RowDragSession(target: handle.target, sourceBody: handle.body,
                                 rowFrames: frames, gap: handle.body)
        needsDisplay = true
        NSCursor.closedHand.set()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let p = convert(next.locationInWindow, from: nil)
            let gap = dropGap(for: p.y, frames: frames)
            if gap != rowDrag?.gap {
                rowDrag?.gap = gap
                needsDisplay = true
            }
            autoscroll(with: next)
        }
        let finalGap = rowDrag?.gap
        rowDrag = nil
        needsDisplay = true
        NSCursor.arrow.set()
        if let finalGap, finalGap != handle.body, finalGap != handle.body + 1 {
            if visualCoordinator?.moveTableRow(target: handle.target,
                                               fromBody: handle.body,
                                               toGap: finalGap) != true {
                NSSound.beep()
            }
        }
    }

    private func dropGap(for y: CGFloat, frames: [NSRect]) -> Int {
        for (index, frame) in frames.enumerated() where y < frame.midY { return index }
        return frames.count
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let rowHandleTracking { removeTrackingArea(rowHandleTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        rowHandleTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard rowDrag == nil else { return }
        let handle = rowHandle(at: convert(event.locationInWindow, from: nil))
        setHoverRowHandle(handle)
        if handle != nil { NSCursor.openHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverRowHandle(nil)
    }

    private func setHoverRowHandle(_ handle: (frame: NSRect, target: TableTarget, body: Int)?) {
        guard hoverRowHandle?.frame != handle?.frame else {
            hoverRowHandle = handle
            return
        }
        if let old = hoverRowHandle?.frame { setNeedsDisplay(old.insetBy(dx: -4, dy: -4)) }
        hoverRowHandle = handle
        if let new = handle?.frame { setNeedsDisplay(new.insetBy(dx: -4, dy: -4)) }
    }

    /// Six-dot grip glyph centered in the gutter zone.
    private func drawRowHandle(in frame: NSRect, active: Bool) {
        theme.secondaryColor.withAlphaComponent(active ? 0.9 : 0.6).setFill()
        let dot: CGFloat = 2.4
        let stepX: CGFloat = 4, stepY: CGFloat = 4.5
        for column in 0..<2 {
            for row in 0..<3 {
                let x = frame.midX - stepX / 2 - dot / 2 + CGFloat(column) * stepX
                let y = frame.midY - stepY - dot / 2 + CGFloat(row) * stepY
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
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
        drawGutterNumbers(in: rect, state: gutterState)
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
        // Paired with the presentation's paragraph margin (32): white gap to
        // the neighboring text = 18, the rest becomes inner gray padding.
        let codePanelPadding: CGFloat = 6
        let codeBlockMargin: CGFloat = 18
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
            let panel = NSBezierPath(roundedRect: box,
                                     xRadius: theme.codeBlockCornerRadius,
                                     yRadius: theme.codeBlockCornerRadius)
            panel.fill()
            panel.lineWidth = 1
            theme.inlineCodeColor.withAlphaComponent(0.28).setStroke()
            panel.stroke()
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
            let quoteBox = rectUnion.insetBy(dx: 0, dy: -3)
            theme.quoteBackground.setFill()
            NSBezierPath(roundedRect: quoteBox, xRadius: 5, yRadius: 5).fill()
            theme.accentColor.withAlphaComponent(0.72).setFill()
            for level in 0..<depth {
                NSRect(x: inset.width + CGFloat(level) * 18, y: rectUnion.minY,
                       width: theme.quoteBarWidth, height: rectUnion.height).fill()
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


        // Built-in plugin list markers.
        for (range, _, token) in builtInPluginTaskEntries {
            guard let box = markerRect(forParagraph: range) else { continue }
            drawBuiltInPluginIcon(token.state.icon, label: token.state.label, in: box)
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

        // Row drag-reorder affordances: hover grip / dragged-row wash + gap line.
        if rowDrag == nil, let hover = hoverRowHandle {
            drawRowHandle(in: hover.frame, active: false)
        }
        if let drag = rowDrag, let first = drag.rowFrames.first {
            theme.accentColor.withAlphaComponent(0.08).setFill()
            if drag.sourceBody < drag.rowFrames.count {
                drag.rowFrames[drag.sourceBody].fill()
            }
            let minX = drag.rowFrames.map(\.minX).min() ?? first.minX
            let maxX = drag.rowFrames.map(\.maxX).max() ?? first.maxX
            let y = drag.gap < drag.rowFrames.count
                ? drag.rowFrames[drag.gap].minY
                : (drag.rowFrames.last?.maxY ?? first.maxY)
            theme.accentColor.setFill()
            NSRect(x: minX, y: y - 1, width: maxX - minX, height: 2).fill()
        }
    }


    private func drawBuiltInPluginIcon(_ icon: BuiltInPluginIcon, label: String,
                                       in box: NSRect) {
        switch icon {
        case .sfSymbol(let name):
            guard let image = NSImage(systemSymbolName: name,
                                      accessibilityDescription: label) else { return }
            let config = NSImage.SymbolConfiguration(pointSize: box.height, weight: .regular)
                .applying(.init(paletteColors: [theme.accentColor]))
            let rendered = image.withSymbolConfiguration(config) ?? image
            rendered.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
        case .emoji(let value), .text(let value):
            let string = NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: box.height),
                .foregroundColor: theme.accentColor,
            ])
            let size = string.size()
            string.draw(at: NSPoint(x: box.midX - size.width / 2,
                                    y: box.midY - size.height / 2))
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
                                                 boldColor: boldColor,
                                                 pluginSnapshot: builtInPluginSnapshot)
        tableCellAttrCache[key] = rendered
        let copy = NSMutableAttributedString(attributedString: rendered)
        if copy.length > 0 {
            copy.addAttribute(.paragraphStyle, value: paragraphStyle,
                              range: NSRange(location: 0, length: copy.length))
        }
        return copy
    }
}
