import Foundation
import Markdown

// Markdown lint for Source mode. Detection principle: compare raw text against
// what actually parsed (collectSpans / AST) — a construct that *looks* like
// markdown but produced no node is what gets flagged (`- [+]` parses as a plain
// list item, not a checkbox). Pure function, unit-testable.

enum LintSeverity: Equatable {
    case error      // author clearly wanted markup and it will not render
    case warning    // style issue or probable mistake
}

struct LintFix: Equatable {
    let title: String
    let range: NSRange
    let replacement: String
}

enum LintRule: String, Equatable {
    case invalidCheckbox
    case emptyCheckbox
    case uppercaseCheckbox
    case checkboxMissingSpace
    case listMarkerMissingSpace
    case unpairedBold
    case unpairedStrikethrough
    case unpairedBacktick
    case repeatedInlineMarkers
    case emptyLinkDestination
    case unresolvedReference
    case unclosedLink
    case headingMissingSpace
    case unclosedCodeFence
    case tableCellCountMismatch
    // Vault-lint rules — produced only by merge, never by `lint(_:)`.
    case vaultDeadWikiLink
    case vaultAmbiguousWikiLink
    case vaultSelfWikiLink
    case vaultDeadRelativeLink
    case vaultDeadImageLink
    case vaultDeadHeadingAnchor
}

struct LintDiagnostic: Equatable {
    var range: NSRange
    let severity: LintSeverity
    let rule: LintRule
    let message: String
    let fixes: [LintFix]
}

func lint(_ text: String) -> [LintDiagnostic] {
    guard !text.isEmpty else { return [] }
    let nsText = text as NSString
    let spans = collectSpans(text)
    var diags: [LintDiagnostic] = []

    // Ranges where raw markdown syntax is expected to appear literally.
    var excluded: [NSRange] = []
    // Ranges already consumed as markers by the parser (paired emphasis etc.).
    var markerCovered: [NSRange] = []
    // Task checkbox spans the parser recognized.
    var taskMarkerLocs = Set<Int>()
    var quoteRanges: [NSRange] = []

    for s in spans {
        switch s.kind {
        case .codeBlockBody, .htmlBlock, .code, .codeMarker, .htmlInline,
             .wikiLink, .wikiLinkSyntax:
            excluded.append(s.range)
        case .boldMarker, .italicMarker, .strikethroughMarker,
             .codeBlockFence, .linkSyntax, .imageSyntax, .thematicBreak:
            markerCovered.append(s.range)
        case .taskListMarker:
            taskMarkerLocs.insert(s.range.location)
        case .quoteBody:
            quoteRanges.append(s.range)
        default:
            break
        }
    }
    var linkTextSpans: [(range: NSRange, destination: String?)] = []
    for s in spans {
        if case .linkText(let destination) = s.kind {
            linkTextSpans.append((s.range, destination))
        }
    }

    func intersects(_ ranges: [NSRange], _ r: NSRange) -> Bool {
        let probe = r.length == 0 ? NSRange(location: r.location, length: 1) : r
        return ranges.contains { NSIntersectionRange($0, probe).length > 0 }
    }
    func isExcluded(_ r: NSRange) -> Bool { intersects(excluded, r) }
    func isCovered(_ r: NSRange) -> Bool {
        isExcluded(r) || intersects(markerCovered, r)
    }

    // MARK: Rule: accidentally repeated toggle markers

    // Unambiguous products of the same toolbar toggle applied twice. Asterisks
    // excluded: **** may be valid bold/italic.
    let repeatedMarkerRx = try! NSRegularExpression(
        pattern: #"(~~~~)([^~\n]+)(~~~~)|(====)([^=\n]+)(====)"#)
    repeatedMarkerRx.enumerateMatches(
        in: text, range: NSRange(location: 0, length: nsText.length)
    ) { match, _, _ in
        guard let match, !isExcluded(match.range) else { return }
        let strike = match.range(at: 1).location != NSNotFound
        let bodyRange = match.range(at: strike ? 2 : 5)
        let body = nsText.substring(with: bodyRange)
        let marker = strike ? "~~" : "=="
        diags.append(LintDiagnostic(
            range: match.range,
            severity: .warning,
            rule: .repeatedInlineMarkers,
            message: String(localized: "Repeated \(marker) markers — formatting was probably toggled twice"),
            fixes: [LintFix(title: String(localized: "Reduce to one marker pair"),
                            range: match.range,
                            replacement: marker + body + marker)]))
    }

    // MARK: Rule: checkboxes (invalid char / empty / uppercase / missing spaces)

    // A multi-checkbox plugin replaces GFM's two-state grammar for this file;
    // core [ ]/[x] rules must not flag its markers.
    let pluginOwnsCheckboxSyntax = BuiltInPluginRegistry.ownsCoreCheckboxSyntax(in: text)

    // List marker, spaces, bracket pair holding at most ONE char. Longer
    // content (`- [Link](url)`, `- [^1]`) never matches — main FP guard.
    let checkboxRx = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*(?:[-*+]|\d{1,9}[.)])[ \t]+\[([^\n\[\]]?)\](.?)"#,
        options: [.anchorsMatchLines])
    checkboxRx.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
        guard !pluginOwnsCheckboxSyntax, let m else { return }
        let contentRange = m.range(at: 1)
        let bracketRange = NSRange(location: contentRange.location - 1,
                                   length: contentRange.length + 2)
        // isCovered also skips brackets that parsed as link syntax (`- [x](url)`).
        guard !isCovered(bracketRange) else { return }
        let content = nsText.substring(with: contentRange)
        let afterRange = m.range(at: 2)
        let after = afterRange.length > 0 ? nsText.substring(with: afterRange) : ""
        let spacedAfter = after.isEmpty || after == " " || after == "\t" || after == "\n"

        switch content {
        case " ", "x":
            if !spacedAfter {
                diags.append(LintDiagnostic(
                    range: bracketRange, severity: .warning, rule: .checkboxMissingSpace,
                    message: String(localized: "No space after checkbox — it will not render"),
                    fixes: [LintFix(title: String(localized: "Insert space"),
                                    range: NSRange(location: NSMaxRange(bracketRange), length: 0),
                                    replacement: " ")]))
            }
        case "X":
            diags.append(LintDiagnostic(
                range: bracketRange, severity: .warning, rule: .uppercaseCheckbox,
                message: String(localized: "Uppercase X in checkbox"),
                fixes: [LintFix(title: String(localized: "Replace with [x]"), range: contentRange, replacement: "x")]))
            if !spacedAfter {
                diags.append(LintDiagnostic(
                    range: bracketRange, severity: .warning, rule: .checkboxMissingSpace,
                    message: String(localized: "No space after checkbox — it will not render"),
                    fixes: [LintFix(title: String(localized: "Insert space"),
                                    range: NSRange(location: NSMaxRange(bracketRange), length: 0),
                                    replacement: " ")]))
            }
        case "":
            diags.append(LintDiagnostic(
                range: bracketRange, severity: .error, rule: .emptyCheckbox,
                message: String(localized: "Empty checkbox “[]” — needs a space or x inside"),
                fixes: [LintFix(title: String(localized: "Replace with [ ]"), range: bracketRange, replacement: "[ ]"),
                        LintFix(title: String(localized: "Replace with [x]"), range: bracketRange, replacement: "[x]")]))
        default:
            diags.append(LintDiagnostic(
                range: bracketRange, severity: .error, rule: .invalidCheckbox,
                message: String(localized: "Invalid checkbox marker “\(content)” — only [ ] and [x] render"),
                fixes: [LintFix(title: String(localized: "Replace with [x]"), range: contentRange, replacement: "x"),
                        LintFix(title: String(localized: "Replace with [ ]"), range: contentRange, replacement: " ")]))
        }
    }

    // `-[ ]` — no space after the list marker, so it is not even a list item.
    let tightMarkerRx = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*([-*+])\[([^\n\[\]]?)\]"#,
        options: [.anchorsMatchLines])
    tightMarkerRx.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
        guard !pluginOwnsCheckboxSyntax, let m else { return }
        let content = nsText.substring(with: m.range(at: 2))
        guard content == "" || content == " " || content == "x" || content == "X" else { return }
        let markerRange = m.range(at: 1)
        let diagRange = NSRange(location: markerRange.location,
                                length: NSMaxRange(m.range) - markerRange.location)
        // isCovered skips emphasis like `*[x]* note` (marker parsed as italic).
        guard !isCovered(diagRange) else { return }
        diags.append(LintDiagnostic(
            range: diagRange, severity: .warning, rule: .listMarkerMissingSpace,
            message: String(localized: "No space after list marker — checkbox will not render"),
            fixes: [LintFix(title: String(localized: "Insert space"),
                            range: NSRange(location: NSMaxRange(markerRange), length: 0),
                            replacement: " ")]))
    }

    // MARK: Rule: heading without space (`#Heading`)

    let headingRx = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*(#{1,6})([^#\s])"#,
        options: [.anchorsMatchLines])
    headingRx.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
        guard let m else { return }
        let hashes = m.range(at: 1)
        let diagRange = NSRange(location: hashes.location,
                                length: NSMaxRange(m.range(at: 2)) - hashes.location)
        guard !isExcluded(diagRange) else { return }
        diags.append(LintDiagnostic(
            range: diagRange, severity: .warning, rule: .headingMissingSpace,
            message: String(localized: "No space after # — heading will not render"),
            fixes: [LintFix(title: String(localized: "Insert space"),
                            range: NSRange(location: NSMaxRange(hashes), length: 0),
                            replacement: " ")]))
    }

    // MARK: Rule: unpaired emphasis / strikethrough / backtick

    // Paired markers become marker spans; occurrences left in plain text are
    // the unpaired ones.
    func scanUnpaired(_ needle: String, rule: LintRule, severity: LintSeverity, message: String) {
        var search = NSRange(location: 0, length: nsText.length)
        while true {
            let found = nsText.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            if !isCovered(found) {
                diags.append(LintDiagnostic(
                    range: found, severity: severity, rule: rule, message: message,
                    fixes: [LintFix(title: String(localized: "Remove “\(needle)”"), range: found, replacement: "")]))
            }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: nsText.length - next)
        }
    }
    scanUnpaired("**", rule: .unpairedBold, severity: .warning,
                 message: String(localized: "Unpaired ** — bold is not closed"))
    scanUnpaired("~~", rule: .unpairedStrikethrough, severity: .warning,
                 message: String(localized: "Unpaired ~~ — strikethrough is not closed"))
    scanUnpaired("`", rule: .unpairedBacktick, severity: .warning,
                 message: String(localized: "Unpaired backtick — inline code is not closed"))

    // MARK: Rule: links

    for entry in linkTextSpans where (entry.destination ?? "").isEmpty {
        diags.append(LintDiagnostic(
            range: entry.range, severity: .warning, rule: .emptyLinkDestination,
            message: String(localized: "Link has an empty URL"), fixes: []))
    }

    // `[text][ref]` left as literal text = reference without a definition.
    let refRx = try! NSRegularExpression(pattern: #"\[([^\n\[\]]+)\]\[([^\n\[\]]*)\]"#)
    refRx.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
        guard let m else { return }
        let r = m.range
        guard !isCovered(r), !intersects(linkTextSpans.map(\.range), r) else { return }
        let label = nsText.substring(with: m.range(at: 2).length > 0 ? m.range(at: 2) : m.range(at: 1))
        diags.append(LintDiagnostic(
            range: r, severity: .warning, rule: .unresolvedReference,
            message: String(localized: "Reference “\(label)” has no definition"), fixes: []))
    }

    // `[text](…` with no closing paren before end of line.
    let unclosedLinkRx = try! NSRegularExpression(
        pattern: #"\[([^\n\[\]]+)\]\([^)\n]*$"#,
        options: [.anchorsMatchLines])
    unclosedLinkRx.enumerateMatches(in: text, range: NSRange(location: 0, length: nsText.length)) { m, _, _ in
        guard let m else { return }
        let r = m.range
        // Coverage check on the [text] part only: GFM autolinks fire on the bare
        // URL after "(" and their linkText span would mask the match.
        let bracketPart = NSRange(location: r.location, length: m.range(at: 1).length + 2)
        guard !isCovered(bracketPart), !intersects(linkTextSpans.map(\.range), bracketPart) else { return }
        diags.append(LintDiagnostic(
            range: r, severity: .error, rule: .unclosedLink,
            message: String(localized: "Unclosed link — missing “)”"),
            fixes: [LintFix(title: String(localized: "Insert )"),
                            range: NSRange(location: NSMaxRange(r), length: 0),
                            replacement: ")")]))
    }

    // MARK: Rule: unclosed code fence

    for s in spans {
        guard case .codeBlockBody = s.kind, s.range.location < nsText.length else { continue }
        // Skip fences inside blockquotes: the "> " prefix on every line would
        // false-positive the close detection.
        guard !intersects(quoteRanges, s.range) else { continue }
        let first = nsText.character(at: s.range.location)
        guard first == 0x60 || first == 0x7E else { continue }  // ` or ~  (fenced only)
        let fenceChar = Character(UnicodeScalar(first)!)
        let blockText = nsText.substring(with: s.range)
        let lines = blockText.components(separatedBy: "\n")
        let opening = lines[0].drop(while: { $0 == " " })
        let fenceLen = opening.prefix(while: { $0 == fenceChar }).count

        var closed = false
        if lines.count > 1, let last = lines.last {
            let trimmed = last.trimmingCharacters(in: .whitespaces)
            closed = trimmed.count >= fenceLen && trimmed.allSatisfy { $0 == fenceChar }
        }
        if !closed {
            let openLineLen = (lines[0] as NSString).length
            diags.append(LintDiagnostic(
                range: NSRange(location: s.range.location, length: openLineLen),
                severity: .warning, rule: .unclosedCodeFence,
                message: String(localized: "Code fence is not closed"),
                fixes: [LintFix(title: String(localized: "Close fence"),
                                range: NSRange(location: NSMaxRange(s.range), length: 0),
                                replacement: "\n" + String(repeating: fenceChar, count: max(fenceLen, 3)))]))
        }
    }

    // MARK: Rule: table rows with wrong cell count

    var tableAuditor = TableAuditor()
    tableAuditor.visit(Document(parsing: text))
    if !tableAuditor.tables.isEmpty {
        let lineIdx = LineIndex(text)
        for table in tableAuditor.tables {
            let sl = table.range.lowerBound.line
            let el = table.range.upperBound.line
            guard el >= sl + 2 else { continue }
            for line in (sl + 2)...el {
                let start = lineIdx.lineStart(line)
                let end = line < lineIdx.lineCount ? lineIdx.lineStart(line + 1) : nsText.length
                guard end > start else { continue }
                var lineRange = NSRange(location: start, length: end - start)
                var lineStr = nsText.substring(with: lineRange)
                if lineStr.hasSuffix("\n") {
                    lineStr.removeLast()
                    lineRange.length -= 1
                }
                guard let cells = tableCellCount(lineStr), cells != table.columns else { continue }
                diags.append(LintDiagnostic(
                    range: lineRange, severity: .warning, rule: .tableCellCountMismatch,
                    message: String(localized: "Row has \(cells) cells, header has \(table.columns)"),
                    fixes: []))
            }
        }
    }

    // MARK: Sort + merge adjacent same-rule diagnostics (e.g. "****")

    diags.sort { $0.range.location < $1.range.location }
    var merged: [LintDiagnostic] = []
    for d in diags {
        if var last = merged.last, last.rule == d.rule,
           NSMaxRange(last.range) >= d.range.location {
            last.range = NSUnionRange(last.range, d.range)
            merged[merged.count - 1] = last
        } else {
            merged.append(d)
        }
    }
    return merged
}

/// Cells in a table row; nil when no pipe at all (not a row — e.g. a trailing
/// paragraph cmark glued to the table range).
func tableCellCount(_ line: String) -> Int? {
    guard line.contains("|") else { return nil }
    // Escaped pipes are cell content, not separators.
    let cleaned = line.replacingOccurrences(of: "\\|", with: "__")
    var cells = cleaned.components(separatedBy: "|")
    if let first = cells.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        cells.removeFirst()
    }
    if let last = cells.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        cells.removeLast()
    }
    return cells.isEmpty ? nil : cells.count
}

private struct TableAuditor: MarkupWalker {
    var tables: [(range: SourceRange, columns: Int)] = []

    mutating func visitTable(_ table: Table) {
        if let range = table.range {
            tables.append((range, table.columnAlignments.count))
        }
        descendInto(table)
    }
}
