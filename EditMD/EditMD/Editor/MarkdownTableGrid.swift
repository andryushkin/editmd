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
