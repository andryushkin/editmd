// Wiki-link autocomplete engine (plan 03). Pure over text + caret + catalog —
// hosts (Source/Visual) only present the popup and apply the replacement.

import Foundation

// MARK: - Session

/// Active `[[…` completion session at the caret.
struct WikiCompletionSession: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        /// Completing a file target after `[[`.
        case file
        /// Completing a heading after `[[target#`.
        case heading(fileQuery: String)
    }

    let mode: Mode
    /// Filter text (after `[[` or after `#`).
    let query: String
    /// UTF-16 range of `query` in the buffer — replaced on accept.
    let replaceRange: NSRange
    /// UTF-16 location of the opening `[[` (first `[`).
    let openLocation: Int
}

// MARK: - Candidates

struct WikiFileCandidate: Equatable, Sendable, Identifiable {
    var id: String { url.path }
    let url: URL
    /// Basename without extension (insertion target for `[[Name]]`).
    let basename: String
    let title: String?
    let aliases: [String]
    /// Display path (relative to a workspace root when possible).
    let relativePath: String

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return basename
    }
}

struct WikiCompletionPick: Equatable, Sendable {
    /// Text that replaces `session.replaceRange` (includes closing `]]` when needed).
    let replacement: String
    let displayTitle: String
    let displaySubtitle: String?
}

// MARK: - Session detection

/// Detects an open wiki-completion session at `caret` (UTF-16). Returns nil when
/// not inside `[[…`, inside a code fence / inline code, or the query is invalid.
func wikiCompletionSession(text: String, caretUTF16 caret: Int) -> WikiCompletionSession? {
    let ns = text as NSString
    let n = ns.length
    let caret = max(0, min(caret, n))
    guard caret >= 2 else { return nil }

    if isCaretInsideCodeFence(text: text, caretUTF16: caret) { return nil }
    if isCaretInsideInlineCode(text: text, caretUTF16: caret) { return nil }

    // Find the last `[[` on the same line before the caret.
    var i = caret - 1
    var open = -1
    while i >= 1 {
        let c = ns.character(at: i)
        if c == 0x0A { break } // newline — stop (wiki is single-line)
        if c == 0x5D, ns.character(at: i - 1) == 0x5D {
            // Already closed `]]` on this line before caret — no session.
            return nil
        }
        if c == 0x5B, ns.character(at: i - 1) == 0x5B {
            open = i - 1
            break
        }
        i -= 1
    }
    guard open >= 0 else { return nil }

    // Text between `[[` and caret.
    let innerStart = open + 2
    guard innerStart <= caret else { return nil }
    let inner = ns.substring(with: NSRange(location: innerStart, length: caret - innerStart))

    // Leading whitespace aborts (plan: space at start of query ends session).
    if inner.first == " " || inner.first == "\t" { return nil }

    // No `|` alias completion in v1 — if user typed pipe, still complete
    // only the target side before the pipe (or stop after pipe for simplicity).
    if let pipe = inner.firstIndex(of: "|") {
        // After alias pipe — no completion.
        let before = String(inner[..<pipe])
        if before.contains("#") {
            // rare [[T#H| — stop
        }
        return nil
    }

    if let hash = inner.firstIndex(of: "#") {
        let fileQuery = String(inner[..<hash])
        let headingQuery = String(inner[inner.index(after: hash)...])
        // `^` block ids: no heading completion.
        if headingQuery.hasPrefix("^") { return nil }
        let hashUTF16 = (String(inner[..<hash]) as NSString).length
        let replaceLoc = innerStart + hashUTF16 + 1 // after '#'
        return WikiCompletionSession(
            mode: .heading(fileQuery: fileQuery),
            query: headingQuery,
            replaceRange: NSRange(location: replaceLoc, length: caret - replaceLoc),
            openLocation: open
        )
    }

    return WikiCompletionSession(
        mode: .file,
        query: inner,
        replaceRange: NSRange(location: innerStart, length: caret - innerStart),
        openLocation: open
    )
}

// MARK: - Ranking

/// Rank file candidates for `query`. Prefix basename > prefix title/alias > substring.
func rankWikiFileCandidates(
    query: String,
    catalog: [WikiFileCandidate],
    limit: Int = 20
) -> [WikiFileCandidate] {
    let q = query.trimmingCharacters(in: .whitespaces)
    if q.isEmpty {
        return Array(catalog.sorted {
            $0.basename.localizedCaseInsensitiveCompare($1.basename) == .orderedAscending
        }.prefix(limit))
    }
    let qLower = q.lowercased()

    struct Scored {
        let item: WikiFileCandidate
        let score: Int // lower is better
        let key: String
    }
    var scored: [Scored] = []
    for item in catalog {
        let names = ([item.basename, item.title].compactMap { $0 } + item.aliases)
            .filter { !$0.isEmpty }
        var best: Int?
        for name in names {
            let n = name.lowercased()
            let s: Int?
            if n == qLower { s = 0 }
            else if n.hasPrefix(qLower) {
                s = name == item.basename ? 1 : 2
            } else if n.contains(qLower) {
                s = name == item.basename ? 3 : 4
            } else {
                s = nil
            }
            if let s { best = min(best ?? s, s) }
        }
        // Also match relative path substring lightly.
        if best == nil, item.relativePath.lowercased().contains(qLower) {
            best = 5
        }
        if let best {
            scored.append(Scored(item: item, score: best, key: item.basename.lowercased()))
        }
    }
    scored.sort {
        if $0.score != $1.score { return $0.score < $1.score }
        return $0.key < $1.key
    }
    return scored.prefix(limit).map(\.item)
}

func rankWikiHeadingCandidates(
    query: String,
    headings: [String],
    limit: Int = 20
) -> [String] {
    let q = query.trimmingCharacters(in: .whitespaces)
    // Preserve first-seen order for duplicates; rank by match quality.
    var seen = Set<String>()
    let unique = headings.filter { seen.insert(normalizeHeadingKey($0)).inserted }

    if q.isEmpty { return Array(unique.prefix(limit)) }
    let qKey = normalizeHeadingKey(q)

    struct Scored { let title: String; let score: Int; let idx: Int }
    var scored: [Scored] = []
    for (idx, h) in unique.enumerated() {
        let key = normalizeHeadingKey(h)
        let score: Int
        if key == qKey { score = 0 }
        else if key.hasPrefix(qKey) { score = 1 }
        else if key.contains(qKey) { score = 2 }
        else { continue }
        scored.append(Scored(title: h, score: score, idx: idx))
    }
    scored.sort {
        if $0.score != $1.score { return $0.score < $1.score }
        return $0.idx < $1.idx
    }
    return scored.prefix(limit).map(\.title)
}

func wikiFilePick(for candidate: WikiFileCandidate) -> WikiCompletionPick {
    WikiCompletionPick(
        replacement: candidate.basename + "]]",
        displayTitle: candidate.displayTitle,
        displaySubtitle: candidate.relativePath
    )
}

func wikiHeadingPick(for heading: String) -> WikiCompletionPick {
    WikiCompletionPick(
        replacement: heading + "]]",
        displayTitle: heading,
        displaySubtitle: nil
    )
}

// MARK: - Heading match (navigation)

/// Case-insensitive, whitespace-collapsed key for heading comparison.
/// Strips common emphasis markers so `**Bold**` matches `Bold`.
func normalizeHeadingKey(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    // Strip simple markdown emphasis wrappers repeatedly.
    let wrappers = ["**", "__", "*", "_", "~~", "`"]
    var changed = true
    while changed {
        changed = false
        for w in wrappers {
            if t.hasPrefix(w), t.hasSuffix(w), t.count > w.count * 2 {
                t = String(t.dropFirst(w.count).dropLast(w.count))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
    }
    let collapsed = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return collapsed.lowercased()
}

/// First outline heading matching `heading` (normalized), or nil.
func findHeadingOffset(matching heading: String, in text: String) -> Int? {
    let key = normalizeHeadingKey(heading)
    guard !key.isEmpty else { return nil }
    for item in markdownOutline(text) {
        if normalizeHeadingKey(item.title) == key {
            return item.markdownOffset
        }
    }
    return nil
}

// MARK: - Code context (lightweight, no full AST)

/// Fence-marker parity up to the caret (``` / ~~~ at line start).
func isCaretInsideCodeFence(text: String, caretUTF16 caret: Int) -> Bool {
    let ns = text as NSString
    let limit = max(0, min(caret, ns.length))
    var inside = false
    var location = 0
    while location < limit {
        var lineEnd = 0, contentEnd = 0
        ns.getLineStart(nil, end: &lineEnd, contentsEnd: &contentEnd,
                        for: NSRange(location: location, length: 0))
        let line = ns.substring(with: NSRange(location: location,
                                              length: contentEnd - location))
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") || line.hasPrefix("~~~") { inside.toggle() }
        if lineEnd == location { break }
        location = lineEnd
    }
    return inside
}

/// True when caret sits inside unpaired backticks on the same line.
func isCaretInsideInlineCode(text: String, caretUTF16 caret: Int) -> Bool {
    let ns = text as NSString
    let n = ns.length
    let caret = max(0, min(caret, n))
    // Line bounds.
    var lineStart = 0, lineEnd = 0
    ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: nil,
                    for: NSRange(location: min(caret, max(0, n - 1)), length: 0))
    if n == 0 { return false }
    var ticks = 0
    var i = lineStart
    while i < caret && i < n {
        if ns.character(at: i) == 0x60 { // `
            // Count run of backticks; treat single-tick spans only.
            var j = i
            while j < n, ns.character(at: j) == 0x60 { j += 1 }
            let run = j - i
            if run == 1 { ticks += 1 }
            i = j
            continue
        }
        i += 1
    }
    return ticks % 2 == 1
}

// MARK: - Catalog helpers

/// Frontmatter `title` and `aliases` from a markdown prefix (lossy, for catalog).
func wikiCatalogMeta(fromMarkdownPrefix text: String) -> (title: String?, aliases: [String]) {
    guard let fm = frontmatterRange(in: text) else { return (nil, []) }
    let body = (text as NSString).substring(with: fm.body)
    let props = parseFrontmatterProperties(body)
    var title: String?
    var aliases: [String] = []
    for p in props {
        switch p.key.lowercased() {
        case "title":
            title = p.value.trimmingCharacters(in: .whitespacesAndNewlines)
        case "aliases", "alias":
            if !p.items.isEmpty {
                aliases = p.items.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            } else {
                aliases = p.value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        default: break
        }
    }
    return (title, aliases)
}

/// Basename without extension for wiki insertion.
func wikiBasename(for url: URL) -> String {
    url.deletingPathExtension().lastPathComponent
}

/// Relative path of `url` under the longest matching root, else abbreviated absolute.
func wikiRelativePath(for url: URL, roots: [URL]) -> String {
    let std = url.standardizedFileURL
    let path = std.path
    let match = roots
        .map(\.standardizedFileURL)
        .filter { path == $0.path || path.hasPrefix($0.path + "/") }
        .max(by: { $0.path.count < $1.path.count })
    if let root = match {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
    }
    return (path as NSString).abbreviatingWithTildeInPath
}
