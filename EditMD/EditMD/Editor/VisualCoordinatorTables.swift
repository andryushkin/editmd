import AppKit

// Table editing (native cells + raw GFM islands) of
// VisualMarkdownView.Coordinator.

extension VisualMarkdownView.Coordinator {
        /// All cell paragraphs of a table, in document order.
        func tableCells(group: Int, in storage: NSTextStorage)
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

        func tableRange(group: Int, in storage: NSTextStorage) -> NSRange {
            let cells = tableCells(group: group, in: storage)
            guard let first = cells.first, let last = cells.last else {
                return NSRange(location: 0, length: 0)
            }
            return NSRange(location: first.range.location,
                           length: NSMaxRange(last.range) - first.range.location)
        }

        func tableIsland(at paragraphLocation: Int) -> (range: NSRange, grid: TableGrid)? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let nsText = storage.string as NSString
            guard nsText.length > 0 else { return nil }
            let paragraph = nsText.paragraphRange(for: NSRange(location: min(paragraphLocation, nsText.length - 1),
                                                               length: 0))
            let block = block(at: paragraph, in: storage)
            guard case .raw(let raw) = block.kind, let grid = parseGFMTable(raw) else { return nil }
            return (paragraph, grid)
        }

        /// Layout spacer only — height comes from paragraph min/max line height
        /// in the presentation pass. The grid is drawn in `drawBackground`.
        private func tableIslandDisplayText(_ grid: TableGrid) -> String {
            _ = grid
            return "\u{00A0}"
        }

        func replaceTableIsland(paragraph: NSRange, oldBlock: MDBlock, grid: TableGrid) -> Bool {
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
        func moveCursor(toCell target: (row: Int, column: Int), group: Int) {
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
        func appendTableRow(group: Int) -> Int? {
            guard let textView, let storage = textView.textStorage else { return nil }
            let cells = tableCells(group: group, in: storage)
            guard let last = cells.last else { return nil }
            let columns = last.columns
            let newRow = (cells.map(\.row).max() ?? 0) + 1
            var alignmentByColumn: [Int: Int] = [:]
            for cell in cells { alignmentByColumn[cell.column] = cell.alignment }

            let insertion = NSMutableAttributedString()
            // A document-closing table has no "\n" after its last cell. The
            // first inserted newline would then terminate THAT cell instead of
            // forming the new row's first cell — the row would come up one
            // paragraph short and its first column would not exist at all.
            let lastText = (storage.string as NSString).substring(with: last.range)
            if !lastText.hasSuffix("\n") {
                var closing = MDBlock(kind: .tableCell(row: last.row, column: last.column,
                                                       columns: columns,
                                                       alignment: last.alignment))
                closing.group = group
                insertion.append(NSAttributedString(string: "\n", attributes: [
                    .font: visualStyle.font(for: [], blockKind: closing.kind),
                    .foregroundColor: NSColor.labelColor,
                    .mdBlock: closing,
                ]))
            }
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
        func deleteTableRow(_ row: Int, group: Int) {
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

        func handleTableTab(forward: Bool) -> Bool {
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
}
