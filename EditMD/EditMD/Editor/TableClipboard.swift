import Foundation

// Clipboard tables → GFM pipe tables. Two sources:
//  • HTML (web pages, Word, Excel put `public.html` on the pasteboard) —
//    parsed with XMLDocument's HTML tidy. Conversion fires only when the
//    payload is "table-dominant" (no meaningful text outside <table>), so
//    pasting an article that merely contains a table keeps the text path.
//  • TSV (Excel/Numbers plain text) — every line carries a tab.
//
// Cell contents become inline markdown (b/i/code/a/img/del mapped); the grid
// stores them unescaped — `serializeGFMTable` escapes pipes on output.

/// Decision funnel for paste: markdown for a clipboard payload that IS a
/// table, nil otherwise. HTML wins over plain text (Excel provides both).
/// HTML without a `<table>` — or with one buried in prose — means ordinary
/// rich text: TSV is not attempted, tabs in prose must not become a table.
func markdownTableFromPasteboard(html: String?, plain: String?) -> String? {
    if let html, !html.isEmpty {
        guard html.range(of: "<table", options: .caseInsensitive) != nil else { return nil }
        return markdownTablesFromHTML(html)
    }
    if let plain, let grid = tableGridFromTSV(plain) {
        return serializeGFMTable(grid)
    }
    return nil
}

/// All top-level `<table>`s of a table-dominant HTML payload as pipe-table
/// markdown (several tables join with a blank line); nil when the HTML has no
/// tables or carries meaningful text outside them.
func markdownTablesFromHTML(_ html: String) -> String? {
    guard let data = html.data(using: .utf8),
          let doc = try? XMLDocument(data: data, options: [.documentTidyHTML]),
          let root = doc.rootElement(),
          let allTables = try? root.nodes(forXPath: "//table"),
          !allTables.isEmpty
    else { return nil }
    let tables = allTables.filter { nearestTableAncestor($0) == nil }
    guard !tables.isEmpty else { return nil }

    // Table-dominant gate. Word wraps tables in empty paragraphs/&nbsp; —
    // compare ignoring whitespace, with a tiny tolerance for stray chars.
    let body = (try? root.nodes(forXPath: "//body").first) ?? root
    let bodyLength = strippedTextLength(body.stringValue ?? "")
    let tablesLength = tables.reduce(0) { $0 + strippedTextLength($1.stringValue ?? "") }
    guard bodyLength <= tablesLength + 2 else { return nil }

    // Single-column "tables" are almost always a copied Excel cell/column —
    // those paste better as plain text (same ≥2-column floor as TSV).
    let grids = tables.compactMap(tableGridFromHTMLTable).filter { $0.columnCount >= 2 }
    guard !grids.isEmpty else { return nil }
    return grids.map(serializeGFMTable).joined(separator: "\n\n")
}

/// Conservative TSV: at least two non-empty lines, every one containing a tab,
/// at least two columns. First row becomes the header (GFM requires one).
func tableGridFromTSV(_ text: String) -> TableGrid? {
    let normalized = text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    var lines = normalized.components(separatedBy: "\n")
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeFirst()
    }
    while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeLast()
    }
    guard lines.count >= 2, lines.allSatisfy({ $0.contains("\t") }) else { return nil }
    let rows = lines.map {
        $0.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    let columns = rows.map(\.count).max() ?? 0
    guard columns >= 2 else { return nil }
    func padded(_ row: [String]) -> [String] {
        row.count >= columns ? row : row + Array(repeating: "", count: columns - row.count)
    }
    return TableGrid(headers: padded(rows[0]),
                     rows: rows.dropFirst().map(padded),
                     alignments: Array(repeating: .leading, count: columns))
}

// MARK: - HTML table → grid

private func tableGridFromHTMLTable(_ table: XMLNode) -> TableGrid? {
    guard let allRows = try? table.nodes(forXPath: ".//tr") else { return nil }
    let rows = allRows.filter { nearestTableAncestor($0) === table }

    var cellRows: [[String]] = []
    var alignRows: [[TableGrid.Alignment?]] = []
    for row in rows {
        guard let cells = try? row.nodes(forXPath: "./td | ./th"), !cells.isEmpty else { continue }
        var texts: [String] = []
        var aligns: [TableGrid.Alignment?] = []
        for cell in cells {
            texts.append(cellMarkdown(cell))
            aligns.append(htmlAlignment(cell))
            // colspan keeps later columns in place; rowspan is ignored.
            if let element = cell as? XMLElement,
               let span = element.attribute(forName: "colspan")?.stringValue,
               let n = Int(span), n > 1 {
                texts += Array(repeating: "", count: n - 1)
                aligns += Array(repeating: nil, count: n - 1)
            }
        }
        cellRows.append(texts)
        alignRows.append(aligns)
    }
    guard !cellRows.isEmpty else { return nil }
    let columns = cellRows.map(\.count).max() ?? 0
    guard columns > 0 else { return nil }

    func padded(_ row: [String]) -> [String] {
        row.count >= columns ? row : row + Array(repeating: "", count: columns - row.count)
    }
    // Per-column alignment: first row that declares one wins.
    var alignments = [TableGrid.Alignment](repeating: .leading, count: columns)
    for column in 0..<columns {
        for aligns in alignRows where column < aligns.count {
            if let alignment = aligns[column] {
                alignments[column] = alignment
                break
            }
        }
    }
    return TableGrid(headers: padded(cellRows[0]),
                     rows: cellRows.dropFirst().map(padded),
                     alignments: alignments)
}

private func nearestTableAncestor(_ node: XMLNode) -> XMLNode? {
    var parent = node.parent
    while let current = parent {
        if (current.name ?? "").lowercased() == "table" { return current }
        parent = current.parent
    }
    return nil
}

private func htmlAlignment(_ node: XMLNode) -> TableGrid.Alignment? {
    guard let element = node as? XMLElement else { return nil }
    var value = element.attribute(forName: "align")?.stringValue?.lowercased()
    if value == nil, let style = element.attribute(forName: "style")?.stringValue?.lowercased(),
       let range = style.range(of: "text-align") {
        let tail = style[range.upperBound...].drop { $0 == ":" || $0 == " " }
        value = String(tail.prefix { $0.isLetter })
    }
    switch value {
    case "center": return .center
    case "right": return .trailing
    case "left": return .leading
    default: return nil
    }
}

// MARK: - Cell inline conversion

/// One cell's content as single-line inline markdown: bold/italic/code/strike
/// wrappers, links, image placeholders; block children flatten to spaces.
private func cellMarkdown(_ node: XMLNode) -> String {
    collapsedWhitespace(inlineMarkdown(node)).trimmingCharacters(in: .whitespaces)
}

private func inlineMarkdown(_ node: XMLNode) -> String {
    guard let element = node as? XMLElement else {
        return node.stringValue ?? ""
    }
    let name = (element.name ?? "").lowercased()
    if name == "br" { return " " }
    if name == "img" {
        let src = element.attribute(forName: "src")?.stringValue ?? ""
        let alt = element.attribute(forName: "alt")?.stringValue ?? ""
        return src.isEmpty ? alt : "![\(alt)](\(src)) "
    }
    let inner = (element.children ?? []).map(inlineMarkdown).joined()
    switch name {
    case "b", "strong":
        return wrapped(inner, in: "**")
    case "i", "em":
        return wrapped(inner, in: "*")
    case "del", "s", "strike":
        return wrapped(inner, in: "~~")
    case "code", "tt", "kbd", "samp":
        let trimmed = inner.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.contains("`") ? inner : "`\(trimmed)`"
    case "a":
        let href = element.attribute(forName: "href")?.stringValue ?? ""
        let text = inner.trimmingCharacters(in: .whitespaces)
        guard !href.isEmpty, !href.hasPrefix("#"), !text.isEmpty else { return inner }
        return "[\(text)](\(href))"
    case "p", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6":
        return inner + " "
    default:
        return inner
    }
}

/// Emphasis markers may not touch spaces — keep leading/trailing space outside.
private func wrapped(_ inner: String, in marker: String) -> String {
    let trimmed = inner.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return inner }
    let lead = inner.hasPrefix(" ") ? " " : ""
    let trail = inner.hasSuffix(" ") ? " " : ""
    return lead + marker + trimmed + marker + trail
}

private func collapsedWhitespace(_ string: String) -> String {
    var out = ""
    var lastWasSpace = false
    for ch in string {
        if ch.isWhitespace {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
        } else {
            out.append(ch)
            lastWasSpace = false
        }
    }
    return out
}

private func strippedTextLength(_ string: String) -> Int {
    string.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
}
