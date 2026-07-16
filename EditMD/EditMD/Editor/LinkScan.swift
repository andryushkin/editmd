// Outgoing-link scan for the workspace link index (plan 02).
//
// Pure over the markdown string: no disk I/O, no resolution. Wiki-links reuse
// `scanWikiLinks`; markdown links/images come from the swift-markdown AST so
// code fences / inline code are excluded for free (same contract as Source
// highlighting). Math is masked before parsing (same trick as collectSpans).

import Foundation
import Markdown

/// One outgoing link occurrence inside a markdown buffer (unresolved).
struct OutgoingLink: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case wiki
        case markdown
        case image
    }

    let kind: Kind
    /// Target as written (wiki target / markdown destination, no fragment).
    let rawTarget: String
    /// Wiki heading fragment (`[[Note#H]]`); nil for plain markdown / no `#`.
    let heading: String?
    /// Display label (wiki alias or link text).
    let label: String
    /// 1-based line of the link in the source.
    let line: Int
    /// UTF-16 offset of the link start — jump target for backlinks.
    let utf16Offset: Int
    /// Source line text, trimmed to ~160 characters.
    let context: String
    /// Filled by the index resolver; empty after pure scan.
    var resolved: URL?
    /// All basename matches when ambiguous; empty after pure scan.
    var candidates: [URL]

    init(
        kind: Kind,
        rawTarget: String,
        heading: String? = nil,
        label: String,
        line: Int,
        utf16Offset: Int,
        context: String,
        resolved: URL? = nil,
        candidates: [URL] = []
    ) {
        self.kind = kind
        self.rawTarget = rawTarget
        self.heading = heading
        self.label = label
        self.line = line
        self.utf16Offset = utf16Offset
        self.context = context
        self.resolved = resolved
        self.candidates = candidates
    }
}

/// Scans `text` for outgoing wiki / markdown / image links. Does not resolve
/// targets (`resolved`/`candidates` stay empty). Code contexts and network
/// destinations are excluded.
func scanOutgoingLinks(text: String) -> [OutgoingLink] {
    guard !text.isEmpty else { return [] }
    let mathSpans = scanMathSpans(in: text)
    let (parseText, _) = maskMathSpansForParsing(text, spans: mathSpans)
    let lineIdx = LineIndex(parseText)
    let document = Document(parsing: parseText)
    var collector = OutgoingLinkCollector(text: parseText, lineIdx: lineIdx)
    collector.visit(document)
    return collector.links.sorted { $0.utf16Offset < $1.utf16Offset }
}

// MARK: - Destination filter

/// True when a markdown/image destination should enter the link index.
/// Network schemes, mailto, and pure fragments (`#…`) are excluded.
func shouldIndexLinkDestination(_ destination: String) -> Bool {
    let t = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return false }
    if t.hasPrefix("#") { return false }
    if t.lowercased().hasPrefix("mailto:") { return false }
    if t.contains("://") { return false }
    if let url = URL(string: t),
       let scheme = url.scheme?.lowercased(),
       !scheme.isEmpty,
       scheme != "file" {
        return false
    }
    return true
}

/// Strip a trailing `#fragment` from a markdown destination (keep the path).
func stripLinkFragment(_ destination: String) -> (path: String, fragment: String?) {
    var path = destination
    var fragment: String?
    if let hash = path.firstIndex(of: "#") {
        fragment = String(path[path.index(after: hash)...])
        path = String(path[..<hash])
    }
    path = (path.removingPercentEncoding ?? path)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (path, fragment)
}

// MARK: - Context / line helpers

/// 1-based line number for a UTF-16 offset (CRLF / LF safe via unicodeScalars of `\n`).
func lineNumber(utf16Offset: Int, in text: String) -> Int {
    let ns = text as NSString
    let limit = min(max(0, utf16Offset), ns.length)
    var line = 1
    var i = 0
    while i < limit {
        if ns.character(at: i) == 0x0A { line += 1 }
        i += 1
    }
    return line
}

/// Full source line containing `utf16Offset`, clipped to `maxLen` characters.
func linkContextLine(utf16Offset: Int, in text: String, maxLen: Int = 160) -> String {
    let ns = text as NSString
    let n = ns.length
    guard n > 0 else { return "" }
    let loc = min(max(0, utf16Offset), n)
    var start = loc
    while start > 0, ns.character(at: start - 1) != 0x0A {
        start -= 1
    }
    var end = loc
    while end < n, ns.character(at: end) != 0x0A {
        end += 1
    }
    var line = ns.substring(with: NSRange(location: start, length: end - start))
    // Drop trailing CR from CRLF lines.
    if line.hasSuffix("\r") { line = String(line.dropLast()) }
    line = line.trimmingCharacters(in: .whitespaces)
    if line.count > maxLen {
        let idx = line.index(line.startIndex, offsetBy: maxLen)
        return String(line[..<idx]) + "…"
    }
    return line
}

// MARK: - Collector

private struct OutgoingLinkCollector: MarkupWalker {
    let nsText: NSString
    let text: String
    let lineIdx: LineIndex
    var links: [OutgoingLink] = []

    init(text: String, lineIdx: LineIndex) {
        self.text = text
        self.nsText = text as NSString
        self.lineIdx = lineIdx
    }

    private func nsRange(for srcRange: SourceRange) -> NSRange? {
        let loc = lineIdx.offset(srcRange.lowerBound.line, srcRange.lowerBound.column)
        let end = lineIdx.offset(srcRange.upperBound.line, srcRange.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    private func makeLink(
        kind: OutgoingLink.Kind,
        rawTarget: String,
        heading: String?,
        label: String,
        utf16Offset: Int
    ) -> OutgoingLink {
        OutgoingLink(
            kind: kind,
            rawTarget: rawTarget,
            heading: heading,
            label: label,
            line: lineNumber(utf16Offset: utf16Offset, in: text),
            utf16Offset: utf16Offset,
            context: linkContextLine(utf16Offset: utf16Offset, in: text)
        )
    }

    mutating func visitLink(_ link: Link) {
        guard let dest = link.destination, shouldIndexLinkDestination(dest) else {
            descendInto(link)
            return
        }
        guard let src = link.range, let r = nsRange(for: src) else {
            descendInto(link)
            return
        }
        let (path, fragment) = stripLinkFragment(dest)
        guard !path.isEmpty || fragment == nil else {
            // Pure fragment already filtered; empty path after strip → skip.
            descendInto(link)
            return
        }
        guard !path.isEmpty else {
            descendInto(link)
            return
        }
        let label = link.plainText.isEmpty ? path : link.plainText
        links.append(makeLink(
            kind: .markdown,
            rawTarget: path,
            heading: fragment.flatMap { $0.isEmpty ? nil : $0 },
            label: label,
            utf16Offset: r.location
        ))
        // Do not descend — avoids double-counting nested content as plain text.
    }

    mutating func visitImage(_ image: Image) {
        guard let dest = image.source, shouldIndexLinkDestination(dest) else {
            descendInto(image)
            return
        }
        guard let src = image.range, let r = nsRange(for: src) else {
            descendInto(image)
            return
        }
        let (path, _) = stripLinkFragment(dest)
        guard !path.isEmpty else {
            descendInto(image)
            return
        }
        let label = image.plainText.isEmpty ? path : image.plainText
        links.append(makeLink(
            kind: .image,
            rawTarget: path,
            heading: nil,
            label: label,
            utf16Offset: r.location
        ))
    }

    /// Wiki-links live in plain Text — same exclusion as Source: InlineCode /
    /// CodeBlock content is not a Text child, so fences are free.
    mutating func visitText(_ node: Text) {
        guard let src = node.range, let r = nsRange(for: src), r.length >= 5 else { return }
        let substring = nsText.substring(with: r)
        guard substring.contains("[[") else { return }
        for m in scanWikiLinks(in: substring) {
            let base = r.location + m.range.location
            // `![[img]]` embed → image kind.
            var kind: OutgoingLink.Kind = .wiki
            if base > 0, nsText.character(at: base - 1) == 0x21 { // '!'
                kind = .image
            }
            let p = m.payload
            guard !p.target.isEmpty else { continue }
            links.append(makeLink(
                kind: kind,
                rawTarget: p.target,
                heading: p.heading,
                label: p.displayText,
                utf16Offset: kind == .image ? base - 1 : base
            ))
        }
    }
}
