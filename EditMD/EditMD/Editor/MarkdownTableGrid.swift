import Foundation

/// A parsed GFM pipe-table: header cells, body rows, and per-column alignment.
///
/// Used only to *draw* a large table as a virtualized grid in Visual — the
/// document model still stores the table verbatim as a `.raw` island, so this
/// structure is display-only and never feeds serialization (round-trip stays
/// driven by the raw markdown). Cell strings keep their inline markdown; the
/// only unescaping done is `\|` → `|` (the structural pipe). Every other
/// backslash pair (`\_`, `\[`, `\\`…) is a markdown escape that stays verbatim —
/// re-escaping those backslashes made every grid mutation grow `\_` → `\\_`.
struct TableGrid: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var headers: [String]
    var rows: [[String]]
    /// One entry per header column; padded with `.leading` when the delimiter
    /// row has fewer cells than the header.
    var alignments: [Alignment]

    var columnCount: Int { headers.count }

    mutating func updateCell(row: Int, column: Int, value: String) {
        guard column >= 0, column < columnCount else { return }
        if row == 0 {
            headers[column] = value
            return
        }
        let bodyIndex = row - 1
        guard bodyIndex >= 0, bodyIndex < rows.count else { return }
        if rows[bodyIndex].count < columnCount {
            rows[bodyIndex] += Array(repeating: "", count: columnCount - rows[bodyIndex].count)
        }
        rows[bodyIndex][column] = value
    }

    mutating func insertRow(at bodyIndex: Int) {
        let index = max(0, min(bodyIndex, rows.count))
        rows.insert(Array(repeating: "", count: columnCount), at: index)
    }

    @discardableResult
    mutating func deleteRow(at bodyIndex: Int) -> Bool {
        guard bodyIndex >= 0, bodyIndex < rows.count else { return false }
        rows.remove(at: bodyIndex)
        return true
    }

    mutating func insertColumn(at index: Int) {
        let idx = max(0, min(index, columnCount))
        headers.insert("", at: idx)
        alignments.insert(.leading, at: min(idx, alignments.count))
        for i in rows.indices {
            rows[i].insert("", at: min(idx, rows[i].count))
        }
    }

    /// Keeps at least one column — a zero-column pipe table is not a table.
    @discardableResult
    mutating func deleteColumn(at index: Int) -> Bool {
        guard columnCount > 1, index >= 0, index < columnCount else { return false }
        headers.remove(at: index)
        if index < alignments.count { alignments.remove(at: index) }
        for i in rows.indices where index < rows[i].count {
            rows[i].remove(at: index)
        }
        return true
    }

    /// Moves a body row to an insertion gap (0…rows.count, indices in the
    /// CURRENT array). Gaps `from` and `from + 1` are both no-ops — they
    /// bracket the row itself.
    @discardableResult
    mutating func moveRow(from: Int, toGap gap: Int) -> Bool {
        guard from >= 0, from < rows.count, gap >= 0, gap <= rows.count,
              gap != from, gap != from + 1 else { return false }
        let row = rows.remove(at: from)
        rows.insert(row, at: gap > from ? gap - 1 : gap)
        return true
    }
}

/// Parses the verbatim text of a `.raw` island as a GFM pipe table. Returns
/// `nil` when the text is not a well-formed table (needs a header line, a
/// delimiter line of `---`/`:--`/`:-:`/`--:` cells, and at least one pipe in the
/// header) — HTML islands and other raw blocks fall through to `nil` and keep
/// their plain monospace rendering.
func parseGFMTable(_ raw: String) -> TableGrid? {
    var lines = raw.components(separatedBy: "\n")
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
    }
    guard lines.count >= 2, lines[0].contains("|"), isTableDelimiterRow(lines[1]) else {
        return nil
    }

    let headers = splitTableRow(lines[0])
    guard !headers.isEmpty else { return nil }

    var alignments = parseColumnAlignments(lines[1])
    if alignments.count < headers.count {
        alignments += Array(repeating: .leading, count: headers.count - alignments.count)
    } else if alignments.count > headers.count {
        alignments = Array(alignments.prefix(headers.count))
    }

    let rows = lines.dropFirst(2).map { splitTableRow($0) }
    return TableGrid(headers: headers, rows: Array(rows), alignments: alignments)
}

/// Serializes an editable grid back to canonical GFM pipe-table markdown.
/// Rows are padded/truncated to `headers.count`; alignment row is always emitted.
func serializeGFMTable(_ grid: TableGrid) -> String {
    guard !grid.headers.isEmpty else { return "" }
    let columns = grid.columnCount

    func normalized(_ row: [String]) -> [String] {
        if row.count == columns { return row }
        if row.count > columns { return Array(row.prefix(columns)) }
        return row + Array(repeating: "", count: columns - row.count)
    }

    // Inverse of `splitTableRow`: escape bare structural pipes, keep every
    // existing backslash pair (a markdown escape) verbatim. Doubling those
    // backslashes corrupted `\_`/`\[` cells on every mutation.
    func escapeCell(_ cell: String) -> String {
        var out = ""
        let chars = Array(cell)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                out.append(c)
                out.append(chars[i + 1])
                i += 2
            } else if c == "|" {
                out += "\\|"
                i += 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return out
    }

    func line(_ row: [String]) -> String {
        let escaped = normalized(row).map { escapeCell($0) }
        return "| " + escaped.joined(separator: " | ") + " |"
    }

    func delimiter(_ alignment: TableGrid.Alignment) -> String {
        switch alignment {
        case .leading: return "---"
        case .center: return ":-:"
        case .trailing: return "--:"
        }
    }

    var aligns = grid.alignments
    if aligns.count < columns {
        aligns += Array(repeating: .leading, count: columns - aligns.count)
    } else if aligns.count > columns {
        aligns = Array(aligns.prefix(columns))
    }

    var lines = [line(grid.headers),
                 "| " + aligns.map(delimiter).joined(separator: " | ") + " |"]
    lines += grid.rows.map(line)
    return lines.joined(separator: "\n")
}

/// Splits one GFM table row into trimmed cells. Honors `\|` as a literal pipe
/// (used in our vault to keep wiki-link aliases inside table cells) and drops
/// the empty leading/trailing cells produced by border pipes, while preserving
/// genuinely-empty interior cells. Every other backslash pair passes through
/// verbatim — it is a markdown escape the cell's inline renderer resolves —
/// but is consumed as a pair so `\\|` still splits on its structural pipe.
func splitTableRow(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
            let next = chars[i + 1]
            if next == "|" {
                current.append("|")
            } else {
                current.append(c)
                current.append(next)
            }
            i += 2
            continue
        }
        if c == "|" {
            cells.append(current); current = ""; i += 1; continue
        }
        current.append(c); i += 1
    }
    cells.append(current)

    if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        cells.removeFirst()
    }
    if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        cells.removeLast()
    }
    return cells.map { $0.trimmingCharacters(in: .whitespaces) }
}

/// A delimiter row's cells are each `-`+ optionally wrapped by `:` (`:--`, `:-:`,
/// `--:`, `---`). Requires at least one cell and rejects anything else.
func isTableDelimiterRow(_ line: String) -> Bool {
    let cells = splitTableRow(line)
    guard !cells.isEmpty else { return false }
    for cell in cells {
        guard isDelimiterCell(cell) else { return false }
    }
    return true
}

private func isDelimiterCell(_ cell: String) -> Bool {
    var body = Substring(cell)
    if body.first == ":" { body = body.dropFirst() }
    if body.last == ":" { body = body.dropLast() }
    guard !body.isEmpty else { return false }
    return body.allSatisfy { $0 == "-" }
}

private func parseColumnAlignments(_ line: String) -> [TableGrid.Alignment] {
    splitTableRow(line).map { cell in
        let leading = cell.hasPrefix(":")
        let trailing = cell.hasSuffix(":")
        switch (leading, trailing) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }
}

// MARK: - Source virtual column alignment

/// One cell of a Source-mode table, used to pad columns to a common width with
/// a display-only `.kern` attribute (no text change). `segmentRange` is the text
/// between the cell's surrounding pipes (exclusive of both); `kernIndex` is the
/// single character whose `.kern` widens the cell — the char just before the
/// closing pipe, or the opening pipe itself for an empty cell.
struct SourceTableCell: Equatable {
    let column: Int
    let segmentRange: NSRange
    let kernIndex: Int
}

/// Scans `text` for GFM pipe tables (a header line with a pipe followed by a
/// `---` delimiter line, then body rows that keep pipes until a blank line) and
/// returns each table's cells across all its physical rows — header, delimiter
/// and body. Pure: measuring widths and applying `.kern` happens in the view.
/// UTF-16 offsets (NSRange), so it composes with NSTextStorage directly.
func scanSourceTables(_ text: String) -> [[SourceTableCell]] {
    let ns = text as NSString
    let lines = sourceLineRanges(ns)
    var tables: [[SourceTableCell]] = []
    var i = 0
    while i < lines.count {
        if i + 1 < lines.count,
           hasUnescapedPipe(ns, in: lines[i]),
           isTableDelimiterRow(ns.substring(with: lines[i + 1])) {
            var members = [i, i + 1]
            var j = i + 2
            while j < lines.count {
                let range = lines[j]
                if ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty { break }
                if !hasUnescapedPipe(ns, in: range) { break }
                members.append(j)
                j += 1
            }
            var cells: [SourceTableCell] = []
            for m in members { cells.append(contentsOf: sourceRowCells(ns, in: lines[m])) }
            if !cells.isEmpty { tables.append(cells) }
            i = j
        } else {
            i += 1
        }
    }
    return tables
}

private func sourceLineRanges(_ ns: NSString) -> [NSRange] {
    var lines: [NSRange] = []
    var idx = 0
    let n = ns.length
    while idx < n {
        var lineEnd = 0, contentEnd = 0
        ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd,
                        for: NSRange(location: idx, length: 0))
        lines.append(NSRange(location: idx, length: contentEnd - idx))
        idx = lineEnd
    }
    return lines
}

private func sourceRowCells(_ ns: NSString, in lineRange: NSRange) -> [SourceTableCell] {
    let pipes = unescapedPipePositions(ns, in: lineRange)
    guard pipes.count >= 2 else { return [] }
    return (0..<(pipes.count - 1)).map { k in
        let opening = pipes[k]
        let closing = pipes[k + 1]
        let segLen = closing - (opening + 1)
        return SourceTableCell(
            column: k,
            segmentRange: NSRange(location: opening + 1, length: max(0, segLen)),
            kernIndex: segLen > 0 ? closing - 1 : opening)
    }
}

private func unescapedPipePositions(_ ns: NSString, in range: NSRange) -> [Int] {
    var result: [Int] = []
    var i = range.location
    let end = NSMaxRange(range)
    while i < end {
        let c = ns.character(at: i)
        if c == 0x5C { i += 2; continue }   // backslash escapes the next char
        if c == 0x7C { result.append(i) }   // unescaped pipe
        i += 1
    }
    return result
}

private func hasUnescapedPipe(_ ns: NSString, in range: NSRange) -> Bool {
    !unescapedPipePositions(ns, in: range).isEmpty
}

// MARK: - Cursor-relative table context (Source mode row/column ops)

/// A GFM pipe table located around a text offset, with the cursor's position
/// inside it. `line` counts physical table lines: 0 = header, 1 = delimiter,
/// ≥2 = body. Replacing `tableRange` with `serializeGFMTable(grid)` after a
/// grid mutation is the whole edit — canonical reformatting is intentional.
struct SourceTableContext {
    /// Full table text, first line start to last line end (no trailing \n).
    let tableRange: NSRange
    let grid: TableGrid
    let line: Int
    let column: Int

    /// Body-row index for `line`, nil on the header/delimiter lines.
    var bodyIndex: Int? { line >= 2 ? line - 2 : nil }
}

/// Finds the pipe table containing `offset` (same detection rules as
/// `scanSourceTables`: a header line with an unescaped pipe, a `---` delimiter
/// line, then body lines that keep pipes until a blank line). Local scan around
/// the offset — never walks the whole document.
func sourceTableContext(in text: String, at offset: Int) -> SourceTableContext? {
    let ns = text as NSString
    guard ns.length > 0 else { return nil }
    let clamped = max(0, min(offset, ns.length))

    func lineRange(at location: Int) -> NSRange {
        var start = 0, contentEnd = 0
        ns.getLineStart(&start, end: nil, contentsEnd: &contentEnd,
                        for: NSRange(location: min(location, ns.length), length: 0))
        return NSRange(location: start, length: contentEnd - start)
    }
    func isTableLine(_ range: NSRange) -> Bool {
        guard !unescapedPipePositions(ns, in: range).isEmpty else { return false }
        return !ns.substring(with: range).trimmingCharacters(in: .whitespaces).isEmpty
    }

    let cursorLine = lineRange(at: clamped)
    guard isTableLine(cursorLine) else { return nil }

    // Walk up to the run's first table-looking line.
    var lines: [NSRange] = [cursorLine]
    while lines[0].location > 0 {
        let previous = lineRange(at: lines[0].location - 1)
        guard isTableLine(previous) else { break }
        lines.insert(previous, at: 0)
    }
    // Walk down to the run's last table-looking line.
    while true {
        let end = NSMaxRange(lines[lines.count - 1])
        guard end < ns.length else { break }
        // Skip the newline; a second newline (blank line) ends the run.
        let next = lineRange(at: end + 1)
        guard next.location > end, isTableLine(next) else { break }
        lines.append(next)
    }

    // The table starts at the line whose successor is the delimiter row —
    // stray pipe-containing prose above the header is not part of the table.
    guard let headerIdx = lines.indices.dropLast().first(where: {
        isTableDelimiterRow(ns.substring(with: lines[$0 + 1]))
    }) else { return nil }
    let tableLines = Array(lines[headerIdx...])
    let cursorIdx = tableLines.firstIndex { NSLocationInRange(clamped, $0) || NSMaxRange($0) == clamped }
    guard let cursorIdx else { return nil }

    let tableRange = NSRange(location: tableLines[0].location,
                             length: NSMaxRange(tableLines[tableLines.count - 1]) - tableLines[0].location)
    guard let grid = parseGFMTable(ns.substring(with: tableRange)) else { return nil }

    // Column = unescaped pipes strictly before the cursor on its line, minus
    // the border pipe when the row starts with one.
    let cursorLineRange = tableLines[cursorIdx]
    let pipes = unescapedPipePositions(ns, in: cursorLineRange)
    let before = pipes.filter { $0 < clamped }.count
    let hasLeadingPipe = ns.substring(with: cursorLineRange)
        .trimmingCharacters(in: .whitespaces).hasPrefix("|")
    let column = max(0, min(before - (hasLeadingPipe ? 1 : 0), grid.columnCount - 1))

    return SourceTableContext(tableRange: tableRange, grid: grid,
                              line: cursorIdx, column: column)
}
