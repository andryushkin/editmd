import AppKit

/// The run's area, one rect per line fragment: horizontally the glyph box
/// (wider would light the gutter and past-EOL — phantom underline), vertically
/// the whole used fragment (the leading still belongs to that line).
func visualRunRects(_ range: NSRange, layoutManager: NSLayoutManager,
                    textContainer: NSTextContainer) -> [NSRect] {
    guard range.length > 0 else { return [] }
    let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                              actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return [] }
    var rects: [NSRect] = []
    // usedRect covers glyphs plus leading: lineSpacing, minimumLineHeight and
    // lineHeightMultiple land inside it (measured, TextKit 1). Paragraph
    // spacing does not, and should not — the gap between blocks belongs to
    // neither (docs/architecture.md § Mouse cursor).
    layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphs, _ in
        let part = NSIntersectionRange(glyphRange, lineGlyphs)
        guard part.length > 0 else { return }
        let box = layoutManager.boundingRect(forGlyphRange: part, in: textContainer)
        rects.append(NSRect(x: box.minX, y: usedRect.minY,
                            width: box.width, height: usedRect.height))
    }
    return rects
}

func visualPointHitsCharacterRange(_ point: NSPoint, range: NSRange,
                                   layoutManager: NSLayoutManager,
                                   textContainer: NSTextContainer,
                                   tolerance: CGFloat = 2) -> Bool {
    visualRunRects(range, layoutManager: layoutManager, textContainer: textContainer)
        .contains { $0.insetBy(dx: -tolerance, dy: 0).contains(point) }
}

// MARK: - Text view with drawn markers

/// Large table drawn as a virtualized grid (NSTextTable pegs the CPU past a
/// few thousand cells). `range` = island paragraph whose hidden spacer reserves
/// the vertical space; `columnEdges` = absolute x, left→right incl. right edge;
/// `rowHeights` per row (header at 0). Row rects are arithmetic from
/// `rowHeights` — no line-fragment enumeration — keeping 9000 rows cheap.
struct TableIslandEntry {
    let range: NSRange
    let grid: TableGrid
    let columnEdges: [CGFloat]
    /// Per-row heights (index 0 = header). Sum is the island's layout height.
    let rowHeights: [CGFloat]
    let font: NSFont
    let headerFont: NSFont

    var totalHeight: CGFloat { tableIslandTotalHeight(rowHeights) }

    func rowOffset(_ row: Int) -> CGFloat { tableIslandRowOffset(rowHeights, row: row) }

    func rowIndex(atLocalY y: CGFloat) -> Int {
        tableIslandRowIndex(heights: rowHeights, localY: y)
    }

    func rowHeight(_ row: Int) -> CGFloat {
        guard row >= 0, row < rowHeights.count else { return 0 }
        return rowHeights[row]
    }
}

// MARK: - Island row geometry (pure)

func tableIslandTotalHeight(_ heights: [CGFloat]) -> CGFloat {
    heights.reduce(0, +)
}

func tableIslandRowOffset(_ heights: [CGFloat], row: Int) -> CGFloat {
    guard row > 0 else { return 0 }
    let n = min(row, heights.count)
    var y: CGFloat = 0
    for i in 0..<n { y += heights[i] }
    return y
}

func tableIslandRowIndex(heights: [CGFloat], localY: CGFloat) -> Int {
    guard !heights.isEmpty else { return 0 }
    if localY <= 0 { return 0 }
    var acc: CGFloat = 0
    for (i, h) in heights.enumerated() {
        acc += h
        if localY < acc { return i }
    }
    return heights.count - 1
}

/// Cell overlay editor. While editing, first responder is AppKit's field
/// editor, so `keyDown` never sees Enter/Tab/Esc — they arrive as field-editor
/// commands intercepted in `control(_:textView:doCommandBy:)`; plain Enter
/// commits and exits (like a click outside), not "select all"/newline.
private final class TableCellEditorField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onMove: ((Bool) -> Void)?      // true: forward, false: backward
    var onDeleteRow: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(insertNewline(_:)),
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            onCommit?(stringValue)
            return true
        case #selector(cancelOperation(_:)):
            onCancel?()
            return true
        case #selector(insertTab(_:)):
            onCommit?(stringValue)
            onMove?(true)
            return true
        case #selector(insertBacktab(_:)):
            onCommit?(stringValue)
            onMove?(false)
            return true
        case #selector(deleteToBeginningOfLine(_:)):
            // Cmd+Backspace (and equivalents that map here) → delete row.
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                onDeleteRow?()
                return true
            }
            return false
        default:
            return false
        }
    }
}

private final class TableCellEditorCell: NSTextFieldCell {
    var insets: NSSize = .zero

    /// Bare `NSTextFieldCell` defaults to non-editable/non-selectable — the
    /// overlay would paint but never take the caret. Always construct via
    /// `init(textCell:)`; the parameterless convenience `init()` skips this
    /// override.
    override init(textCell string: String) {
        super.init(textCell: string)
        isEditable = true
        isSelectable = true
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        isEditable = true
        isSelectable = true
    }

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

struct VisualQuoteEntry {
    let range: NSRange
    let depth: Int
    /// Quote group of the paragraph — the background panel is painted ONCE per
    /// group (per-paragraph boxes overlapped at seams and double-painted the
    /// translucent fill).
    let group: Int
    /// Display indent when the quote is nested in a list item.
    let leadingIndent: CGFloat
    let calloutType: String?
    let showsCalloutIcon: Bool
    /// Paragraph spacing at the quote run's edges. Line fragment rects include
    /// paragraph spacing, so without this trim the background panel would
    /// swallow the inter-block gap the spacing was meant to create.
    var topTrim: CGFloat = 0
    var bottomTrim: CGFloat = 0
}

final class VisualNSTextView: NSTextView {
    var theme: EditorTheme = .editorDefault
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
    var quoteEntries: [VisualQuoteEntry] = []
    var codePanelEntries: [(range: NSRange, leadingIndent: CGFloat)] = []
    var ruleRanges: [NSRange] = []
    var tableIslandEntries: [TableIslandEntry] = [] {
        didSet {
            tableCellAttrCache.removeAll(keepingCapacity: true)
            // Reassigned by every presentation pass — cheap proxy for "text
            // or layout changed", which also invalidates cached row frames.
            nativeRowFrameCache.removeAll(keepingCapacity: true)
        }
    }
    var islandHorizontalOffsets: [Int: CGFloat] = [:]
    private var focusedIslandCell: (paragraphLocation: Int, row: Int, column: Int)?
    var activeEditor: NSTextField?
    private var activeEditorCell: (paragraphLocation: Int, row: Int, column: Int)?
    /// Cache of rendered cell attributed strings for the current island set
    /// (invalidated when `tableIslandEntries` is reassigned).
    var tableCellAttrCache: [String: NSAttributedString] = [:]
    /// Native table row frames ("group:row" → view rect) for the grip gutter —
    /// recomputing on every mouseMoved would walk the whole storage.
    private var nativeRowFrameCache: [String: NSRect] = [:]
    /// Context-menu table ops (items reference `menuTableOps` by tag).
    private var menuTableTarget: TableTarget?
    private var menuTableOps: [TableStructureOp] = []
    /// Live row drag-reorder session (grip in the left gutter of body rows).
    struct RowDragSession {
        let target: TableTarget
        let sourceBody: Int
        let rowFrames: [NSRect]
        var gap: Int
    }
    var rowDrag: RowDragSession?
    var hoverRowHandle: (frame: NSRect, target: TableTarget, body: Int)?
    private var rowHandleTracking: NSTrackingArea?

    private var visualCoordinator: VisualMarkdownView.Coordinator? {
        delegate as? VisualMarkdownView.Coordinator
    }
    var editorSettings: VisualTableEditorSettings { EditorSettings.shared.visualTableEditor }

    // MARK: - Image drag-and-drop

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
        if visualCoordinator?.insertDraggedImage(candidate) == true { return true }
        // Refused context (code block / cell / raw island) or failed store:
        // hand the drop to the default text handling, like the paste funnel.
        return super.performDragOperation(sender)
    }

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
            },
            pasteURLLink: { [weak self] in
                self?.visualCoordinator?.pasteURLLinkFromPasteboard() == true
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
        // Click outside the active overlay (including another table cell) commits
        // and returns to view mode. Do not auto-open the clicked cell — only
        // double-click / F2 / Enter start editing.
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
            // Status-token cells still cycle on a single click.
            if event.clickCount == 1, cycleBuiltInPluginIslandCell(hit) {
                return
            }
            // Island tables are a drawn grid over hidden pipe text; a caret
            // there is useless (can't type into `.raw`) and distracting. Keep
            // cell focus for F2/Enter, never the insertion point.
            if activeEditor == nil {
                clearInsertionPointIfInsideTableIsland(hit.entry.range)
                window?.makeFirstResponder(self)
            }
            return
        }
        focusedIslandCell = nil
        if let paragraph = builtInPluginTaskParagraph(at: point) {
            visualCoordinator?.toggleBuiltInPluginTask(at: paragraph)
            return
        }
        if let token = builtInPluginInlineToken(at: point) {
            visualCoordinator?.cycleBuiltInPluginInlineToken(in: token.range)
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

    weak var wikiCompletion: WikiCompletionController?

    override func keyDown(with event: NSEvent) {
        if wikiCompletion?.handleKey(event: event) == true { return }
        if event.keyCode == 120, beginEditingFocusedTableCell() { // F2
            return
        }
        // Return/Enter while completion is closed may still start table cell edit.
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

    /// Character index under the point, verified against the actual glyph
    /// rect of `attribute`'s run — glyphIndex(for:) snaps to the nearest
    /// glyph, so a bare lookup makes empty space next to a link clickable.
    private func hitCharacterIndex(at point: NSPoint,
                                   attribute: NSAttributedString.Key) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerInset.width,
                                     y: point.y - textContainerInset.height)
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint, in: textContainer,
                                                  fractionOfDistanceThroughGlyph: &fraction)
        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard charIndex < storage.length else { return nil }
        let bounds = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: charIndex, length: 0))
        var run = NSRange()
        guard storage.attribute(attribute, at: charIndex,
                                longestEffectiveRange: &run, in: bounds) != nil,
              visualPointHitsCharacterRange(containerPoint, range: run,
                                            layoutManager: layoutManager,
                                            textContainer: textContainer)
        else { return nil }
        return charIndex
    }

    private func wikiPayload(at point: NSPoint) -> MDWikiLinkPayload? {
        guard let storage = textStorage,
              let charIndex = hitCharacterIndex(at: point, attribute: .mdWikiLink)
        else { return nil }
        return storage.attribute(.mdWikiLink, at: charIndex, effectiveRange: nil) as? MDWikiLinkPayload
    }

    /// Raw `[text](destination)` under the cursor — scheme URLs and local
    /// paths alike; the coordinator decides how to open.
    private func linkDestination(at point: NSPoint) -> String? {
        guard let storage = textStorage,
              let charIndex = hitCharacterIndex(at: point, attribute: .mdLink)
        else { return nil }
        return storage.attribute(.mdLink, at: charIndex, effectiveRange: nil) as? String
    }

    // MARK: - Link affordance

    /// Links carry no permanent underline; the underline appears as a
    /// TEMPORARY layout-manager attribute (drawing-only, layout untouched)
    /// while the caret sits inside the link or the pointer ⌘-hovers it.
    /// Under Increase Contrast the presentation pass paints a permanent
    /// underline and these states stay quiet.
    private var caretLinkRange: NSRange?
    private var hoverLinkRange: NSRange?
    private var paintedLinkUnderlines: [NSRange] = []

    /// Longest run of `.mdLink`/`.mdWikiLink` covering `charIndex`, or nil.
    private func linkRun(at charIndex: Int) -> NSRange? {
        guard let storage = textStorage, charIndex >= 0,
              charIndex < storage.length else { return nil }
        let bounds = (storage.string as NSString)
            .paragraphRange(for: NSRange(location: charIndex, length: 0))
        var effective = NSRange()
        if storage.attribute(.mdLink, at: charIndex,
                             longestEffectiveRange: &effective, in: bounds) != nil {
            return effective
        }
        if storage.attribute(.mdWikiLink, at: charIndex,
                             longestEffectiveRange: &effective, in: bounds) != nil {
            return effective
        }
        return nil
    }

    private func caretLinkRangeNow() -> NSRange? {
        let sel = selectedRange()
        guard sel.length == 0,
              !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        else { return nil }
        return linkRun(at: sel.location) ?? linkRun(at: sel.location - 1)
    }

    /// Caret-inside state: called by the coordinator on selection changes.
    func updateCaretLinkAffordance() {
        let next = caretLinkRangeNow()
        guard next != caretLinkRange else { return }
        caretLinkRange = next
        repaintLinkUnderlines()
    }

    /// Recompute + repaint after a presentation pass: attribute runs were
    /// re-stamped (ranges may have drifted) and the Increase Contrast state
    /// may have flipped since the last selection change.
    func refreshLinkAffordances() {
        hoverLinkRange = nil
        caretLinkRange = caretLinkRangeNow()
        repaintLinkUnderlines()
    }

    /// The link run under `containerPoint`, found from the LINKS' own geometry.
    /// Starting from the nearest glyph instead (`glyphIndex(for:)`) makes a small
    /// vertical move snap to the line above or below while the pointer is still
    /// inside this link's line fragment: the run then resolves to nil and the
    /// hand flickers back to the I-beam.
    private func linkRun(hitAt containerPoint: NSPoint) -> NSRange? {
        guard let layoutManager, let textContainer, let storage = textStorage,
              storage.length > 0 else { return nil }
        let visibleGlyphs = layoutManager.glyphRange(
            forBoundingRect: visibleRect.offsetBy(dx: -textContainerOrigin.x,
                                                  dy: -textContainerOrigin.y),
            in: textContainer)
        let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs,
                                                   actualGlyphRange: nil)
        guard visible.length > 0 else { return nil }
        var hit: NSRange?
        for key in [NSAttributedString.Key.mdLink, .mdWikiLink] {
            storage.enumerateAttribute(key, in: visible) { value, range, stop in
                guard value != nil,
                      visualPointHitsCharacterRange(containerPoint, range: range,
                                                    layoutManager: layoutManager,
                                                    textContainer: textContainer)
                else { return }
                // Runs are clipped to the visible range — a link across the
                // viewport edge would hover as its visible half. Re-open the
                // ORDINARY effective range: bounded, unlike a paragraph walk
                // over a megabyte block. (Adjacent equal-destination links are
                // one storage run either way — issue #9, not this hit test.)
                var effective = NSRange(location: 0, length: 0)
                _ = storage.attribute(key, at: range.location, effectiveRange: &effective)
                hit = effective.length > 0 ? effective : range
                stop.pointee = true
            }
            if hit != nil { break }
        }
        return hit
    }

    /// ⌘-hover state: from mouseMoved / flagsChanged.
    ///
    /// The underline only needs a repaint when the run changes. The pointing
    /// hand must be re-asserted on EVERY call while the hover is live:
    /// `NSTextView` re-publishes the I-beam from its own cursor rects on each
    /// mouse-moved, and cursor rects we add in `resetCursorRects` never win
    /// that channel (measured — see architecture.md § Mouse cursor).
    private func updateHoverLinkAffordance(commandDown: Bool, windowPoint: NSPoint) {
        var next: NSRange?
        if commandDown, !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            let point = convert(windowPoint, from: nil)
            next = linkRun(hitAt: NSPoint(x: point.x - textContainerInset.width,
                                          y: point.y - textContainerInset.height))
        }
        let hadHover = hoverLinkRange != nil
        if next != hoverLinkRange {
            hoverLinkRange = next
            repaintLinkUnderlines()
        }
        if next != nil {
            NSCursor.pointingHand.set()
        } else if hadHover {
            // ⌘ released or the pointer left the link without a mouseMoved that
            // would re-assert openHand for a row handle.
            NSCursor.iBeam.set()
        }
    }

    /// Caret and hover may target the same run — repaint the union so
    /// clearing one state never wipes the other's underline.
    private func repaintLinkUnderlines() {
        guard let layoutManager, let storage = textStorage else { return }
        let length = storage.length
        for range in paintedLinkUnderlines {
            guard range.location < length else { continue }
            let clamped = NSRange(location: range.location,
                                  length: min(range.length, length - range.location))
            layoutManager.removeTemporaryAttribute(.underlineStyle,
                                                   forCharacterRange: clamped)
        }
        paintedLinkUnderlines = [caretLinkRange, hoverLinkRange].compactMap { $0 }
        for range in paintedLinkUnderlines where range.location < length {
            let clamped = NSRange(location: range.location,
                                  length: min(range.length, length - range.location))
            layoutManager.addTemporaryAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue,
                forCharacterRange: clamped)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window else { return }
        updateHoverLinkAffordance(
            commandDown: event.modifierFlags.contains(.command),
            windowPoint: window.mouseLocationOutsideOfEventStream)
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
            guard entry.token.canCycle else { continue }
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
              payload.canCycle else { return nil }
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
        guard let payload = builtInPluginSnapshot.payload(matchingSource: core),
              payload.canCycle else { return false }
        let replacement = String(leading) + payload.next.state.source + String(trailing)
        return visualCoordinator?.updateTableIslandCell(
            paragraphLocation: hit.entry.range.location,
            row: hit.row, column: hit.column, value: replacement) == true
    }

    private func tableCellHit(at point: NSPoint) -> (entry: TableIslandEntry, row: Int, column: Int, rect: NSRect)? {
        guard let layoutManager else { return nil }
        let totalLength = (string as NSString).length
        for entry in tableIslandEntries {
            guard entry.range.location < totalLength, entry.columnEdges.count >= 2,
                  !entry.rowHeights.isEmpty else { continue }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }
            let firstRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            let top = firstRect.minY + textContainerInset.height
            let height = entry.totalHeight
            let islandRect = NSRect(x: textContainerInset.width, y: top,
                                    width: bounds.width - textContainerInset.width * 2, height: height)
            guard islandRect.contains(point) else { continue }
            let offset = islandHorizontalOffsets[entry.range.location] ?? 0
            let row = entry.rowIndex(atLocalY: point.y - top)
            let rowH = entry.rowHeight(row)
            let x = point.x + offset
            var column = 0
            while column + 1 < entry.columnEdges.count, x >= entry.columnEdges[column + 1] {
                column += 1
            }
            column = min(max(0, column), entry.grid.columnCount - 1)
            let left = entry.columnEdges[column] - offset
            let right = entry.columnEdges[column + 1] - offset
            let rect = NSRect(x: left, y: top + entry.rowOffset(row),
                              width: right - left, height: rowH)
            return (entry, row, column, rect)
        }
        return nil
    }

    /// If the insertion point (or a selection) sits inside a table island's
    /// hidden pipe text, move it just after the island so no caret blinks under
    /// the drawn grid. No-op when the selection is already outside.
    private func clearInsertionPointIfInsideTableIsland(_ islandRange: NSRange) {
        let sel = selectedRange()
        let islandEnd = NSMaxRange(islandRange)
        let intersects = NSIntersectionRange(sel, islandRange).length > 0
        let caretInside = sel.length == 0
            && sel.location >= islandRange.location
            && sel.location < islandEnd
        guard intersects || caretInside else { return }
        let after = min(islandEnd, (string as NSString).length)
        setSelectedRange(NSRange(location: after, length: 0))
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
        let rowH = entry.rowHeight(row)
        let cellFrame = NSRect(x: left + cellInset,
                               y: top + entry.rowOffset(row) + cellInset,
                               width: max(32, right - left - cellInset * 2),
                               height: max(20, rowH - cellInset * 2))
        let frame = expandedEditorFrame(for: value, cellFrame: cellFrame, font: row == 0 ? entry.headerFont : entry.font)
        let editor = TableCellEditorField(frame: frame)
        // Must use `textCell:` so `TableCellEditorCell.init(textCell:)` runs and
        // sets isEditable/isSelectable. Parameterless `TableCellEditorCell()` is
        // NSCell's convenience path and skips that override.
        let cell = TableCellEditorCell(textCell: "")
        cell.insets = NSSize(width: editorSettings.editorTextInsetH, height: editorSettings.editorTextInsetV)
        editor.cell = cell
        // Belt-and-braces: control mirrors the cell flags after the swap so a
        // future bare-cell assignment cannot silently reintroduce the
        // "overlay without caret" bug.
        editor.isEditable = true
        editor.isSelectable = true
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
        add(String(localized: "Row Above"), .insertRowAbove, enabled: !isHeader)
        add(String(localized: "Row Below"), .insertRowBelow)
        add(String(localized: "Delete Row"), .deleteRow, enabled: !isHeader)
        menu.insertItem(.separator(), at: insertAt); insertAt += 1
        add(String(localized: "Column Left"), .insertColumnLeft)
        add(String(localized: "Column Right"), .insertColumnRight)
        add(String(localized: "Delete Column"), .deleteColumn, enabled: target.columns > 1)
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
        guard let top = islandTop(entry), entry.columnEdges.count >= 2,
              !entry.rowHeights.isEmpty else { return nil }
        let offset = islandHorizontalOffsets[entry.range.location] ?? 0
        let left = entry.columnEdges[0] - offset
        let right = (entry.columnEdges.last ?? left) - offset
        return NSRect(x: left, y: top + entry.rowOffset(row),
                      width: right - left, height: entry.rowHeight(row))
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
        // Islands: arithmetic row rects (variable height when cells wrap).
        for entry in tableIslandEntries
        where entry.columnEdges.count >= 2 && entry.grid.rows.count > 1
            && !entry.rowHeights.isEmpty {
            guard let top = islandTop(entry) else { continue }
            let totalRows = entry.rowHeights.count
            guard point.y >= top, point.y < top + entry.totalHeight else { continue }
            let offset = islandHorizontalOffsets[entry.range.location] ?? 0
            let left = entry.columnEdges[0] - offset
            guard point.x >= left - 26, point.x <= left - 4 else { continue }
            let row = entry.rowIndex(atLocalY: point.y - top)
            guard row >= 1 else { return nil }
            let frame = NSRect(x: left - 26, y: top + entry.rowOffset(row),
                               width: 22, height: entry.rowHeight(row))
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
        // the drag loop owned the cursor while the button was down.
        NSCursor.iBeam.set()
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
        updateHoverLinkAffordance(
            commandDown: event.modifierFlags.contains(.command),
            windowPoint: event.locationInWindow)
        guard rowDrag == nil else { return }
        let handle = rowHandle(at: convert(event.locationInWindow, from: nil))
        setHoverRowHandle(handle)
        // Same channel rule as the link hand: re-assert every move. Skip when
        // ⌘-hover already owns the pointer — pointingHand must win for open.
        if handle != nil, hoverLinkRange == nil {
            NSCursor.openHand.set()
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHoverLinkAffordance(commandDown: false, windowPoint: .zero)
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
}
