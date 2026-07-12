import AppKit

// Cursor-relative table structure ops for Visual mode: insert/delete rows and
// columns, drag row reorder — for both native NSTextTable tables and large
// read-only islands. Native tables rebuild through TableGrid: serialize the
// table's attributed range → parse → mutate → re-render → replace. Split out
// of VisualTextView.swift (editing core stays there).

/// A table under the context menu / drag, resolved from a point or the caret.
/// `row` counts display rows: 0 = header, ≥1 = body row + 1 (both native
/// tables and islands — the island display drops the delimiter line).
enum TableTarget {
    case native(group: Int, row: Int, column: Int, rows: Int, columns: Int)
    case island(paragraphLocation: Int, row: Int, column: Int, rows: Int, columns: Int)

    var row: Int {
        switch self {
        case .native(_, let row, _, _, _), .island(_, let row, _, _, _): return row
        }
    }
    var column: Int {
        switch self {
        case .native(_, _, let column, _, _), .island(_, _, let column, _, _): return column
        }
    }
    var columns: Int {
        switch self {
        case .native(_, _, _, _, let columns), .island(_, _, _, _, let columns): return columns
        }
    }
    var bodyRows: Int {
        switch self {
        case .native(_, _, _, let rows, _), .island(_, _, _, let rows, _): return rows - 1
        }
    }
}

/// Structure ops relative to the target cell.
enum TableStructureOp {
    case insertRowAbove, insertRowBelow, deleteRow
    case insertColumnLeft, insertColumnRight, deleteColumn
}

extension VisualMarkdownView.Coordinator {

    // MARK: Rendered insertion with safe group ids

    /// Renders markdown for insertion into `storage`, shifting the fresh
    /// render's group ids past every group already present. Without the shift
    /// a pasted table/list starts at group 1 and can collide with an existing
    /// group — the serializer would glue adjacent same-group blocks together.
    func renderForInsertion(_ markdown: String, into storage: NSTextStorage) -> NSAttributedString {
        let rendered = renderMarkdownToAttributed(markdown, style: visualStyle)
        let base = uniqueGroup(in: storage) - 1
        guard base > 0, rendered.length > 0 else { return rendered }
        let mutable = NSMutableAttributedString(attributedString: rendered)
        mutable.enumerateAttribute(.mdBlock, in: NSRange(location: 0, length: mutable.length)) { value, range, _ in
            guard var block = value as? MDBlock else { return }
            if block.group >= 0 { block.group += base }
            if block.quoteGroup >= 0 { block.quoteGroup += base }
            mutable.addAttribute(.mdBlock, value: block, range: range)
        }
        return mutable
    }

    // MARK: Target resolution

    /// Native-table target at a character index (islands hit-test
    /// geometrically in the view; the caret never sits inside them).
    func nativeTableTarget(atCharIndex index: Int) -> TableTarget? {
        guard let textView, let storage = textView.textStorage, storage.length > 0 else { return nil }
        let paragraph = paragraphRange(at: index, in: storage.string as NSString)
        let current = block(at: paragraph, in: storage)
        guard case .tableCell(let row, let column, let columns, _) = current.kind else { return nil }
        let rows = (tableCells(group: current.group, in: storage).map(\.row).max() ?? 0) + 1
        return .native(group: current.group, row: row, column: column,
                       rows: rows, columns: columns)
    }

    // MARK: Native table rebuild

    /// Replaces the whole native table with a re-render of the mutated grid,
    /// then puts the caret into `cursor` (display row/column, clamped). The
    /// mutation returning false aborts without touching the document.
    @discardableResult
    func rebuildNativeTable(group: Int, cursor: (row: Int, column: Int)?,
                            mutate: (inout TableGrid) -> Bool) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let range = tableRange(group: group, in: storage)
        guard range.length > 0 else { return false }
        let tableAttr = storage.attributedSubstring(from: range)
        guard var grid = parseGFMTable(serializeAttributedToMarkdown(tableAttr)) else { return false }
        guard mutate(&grid), !grid.headers.isEmpty else { return false }

        var rendered = renderForInsertion(serializeGFMTable(grid), into: storage)
        guard rendered.length > 0 else { return false }
        // The replaced range ends with the last cell's "\n" unless the table
        // closes the document — mirror that so no blank paragraph appears.
        if !tableAttr.string.hasSuffix("\n"), rendered.string.hasSuffix("\n") {
            rendered = rendered.attributedSubstring(
                from: NSRange(location: 0, length: rendered.length - 1))
        }
        let newGroup = (rendered.attribute(.mdBlock, at: 0, effectiveRange: nil) as? MDBlock)?.group

        isProgrammaticTableEdit = true
        defer { isProgrammaticTableEdit = false }
        guard textView.shouldChangeText(in: range, replacementString: rendered.string)
        else { return false }
        isMutating = true
        storage.replaceCharacters(in: range, with: rendered)
        isMutating = false
        textView.didChangeText()
        afterMutation()
        if let cursor, let newGroup {
            let target = (row: max(0, min(cursor.row, grid.rows.count)),
                          column: max(0, min(cursor.column, grid.columnCount - 1)))
            moveCursor(toCell: target, group: newGroup)
        }
        return true
    }

    // MARK: Island grid mutation

    /// Grid mutation on a large-table island through the standard
    /// island-replace path (`.raw` stays the round-trip source of truth).
    @discardableResult
    func mutateTableIsland(at paragraphLocation: Int,
                           _ mutate: (inout TableGrid) -> Bool) -> Bool {
        guard let storage = textView?.textStorage,
              let island = tableIsland(at: paragraphLocation) else { return false }
        var grid = island.grid
        guard mutate(&grid), !grid.headers.isEmpty else { return false }
        let oldBlock = block(at: island.range, in: storage)
        return replaceTableIsland(paragraph: island.range, oldBlock: oldBlock, grid: grid)
    }

    // MARK: Unified structure ops (context menu / toolbar / drag)

    /// Applies a structure op relative to the target cell. Header-row
    /// restrictions (no insert-above / delete on row 0) and the ≥1-column
    /// floor are enforced here; false → caller beeps.
    @discardableResult
    func performTableOp(_ op: TableStructureOp, on target: TableTarget) -> Bool {
        let row = target.row, column = target.column
        let mutation: (inout TableGrid) -> Bool
        var cursor = (row: row, column: column)
        switch op {
        case .insertRowAbove:
            guard row >= 1 else { return false }
            mutation = { $0.insertRow(at: row - 1); return true }
        case .insertRowBelow:
            mutation = { $0.insertRow(at: row); return true }
            cursor.row = row + 1
        case .deleteRow:
            guard row >= 1 else { return false }
            mutation = { $0.deleteRow(at: row - 1) }
        case .insertColumnLeft:
            mutation = { $0.insertColumn(at: column); return true }
        case .insertColumnRight:
            mutation = { $0.insertColumn(at: column + 1); return true }
            cursor.column = column + 1
        case .deleteColumn:
            mutation = { $0.deleteColumn(at: column) }
        }
        switch target {
        case .native(let group, _, _, _, _):
            return rebuildNativeTable(group: group, cursor: cursor, mutate: mutation)
        case .island(let paragraphLocation, _, _, _, _):
            return mutateTableIsland(at: paragraphLocation, mutation)
        }
    }

    /// Drag reorder: move body row `fromBody` to insertion gap `toGap`
    /// (0…bodyRows, indices before the move).
    @discardableResult
    func moveTableRow(target: TableTarget, fromBody: Int, toGap: Int) -> Bool {
        switch target {
        case .native(let group, _, _, _, _):
            return rebuildNativeTable(group: group, cursor: nil) {
                $0.moveRow(from: fromBody, toGap: toGap)
            }
        case .island(let paragraphLocation, _, _, _, _):
            return mutateTableIsland(at: paragraphLocation) {
                $0.moveRow(from: fromBody, toGap: toGap)
            }
        }
    }
}
