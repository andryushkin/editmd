import Foundation

/// A parsed GFM pipe-table: header cells, body rows, and per-column alignment.
///
/// Used only to *draw* a large table as a virtualized grid in Visual — the
/// document model still stores the table verbatim as a `.raw` island, so this
/// structure is display-only and never feeds serialization (round-trip stays
/// driven by the raw markdown). Cell strings keep their inline markdown; the
/// only unescaping done is `\|` → `|` and `\\` → `\` (GFM cell escapes).
struct TableGrid: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var headers: [String]
    var rows: [[String]]
    /// One entry per header column; padded with `.leading` when the delimiter
    /// row has fewer cells than the header.
    var alignments: [Alignment]

    var columnCount: Int { headers.count }
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

/// Splits one GFM table row into trimmed cells. Honors `\|` as a literal pipe
/// (used in our vault to keep wiki-link aliases inside table cells) and drops
/// the empty leading/trailing cells produced by border pipes, while preserving
/// genuinely-empty interior cells.
func splitTableRow(_ line: String) -> [String] {
    var cells: [String] = []
    var current = ""
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "\\", i + 1 < chars.count {
            let next = chars[i + 1]
            if next == "|" { current.append("|"); i += 2; continue }
            if next == "\\" { current.append("\\"); i += 2; continue }
            current.append(c); i += 1; continue
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
private func isTableDelimiterRow(_ line: String) -> Bool {
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
