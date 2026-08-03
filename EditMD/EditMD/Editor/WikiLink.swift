// Wiki-link (`[[target#heading|alias]]`) scanner — pure, testable;
// swift-markdown doesn't know `[[...]]`. Round-trip invariant: `originalInner`
// keeps the VERBATIM text inside `[[...]]` and is always re-emitted, never
// reconstructed — `serialize(render(md)) == md` even for exotic escaping.
// Offset-based (UTF-16 NSRange) matching the LineIndex/collectSpans idiom, so
// all three modes can splice results in.

import Foundation

/// Parsed pieces of a wiki-link. `originalInner` is the source of truth for
/// serialization; the other fields are derived for display/resolution only.
struct MDWikiLinkPayload: Equatable, Hashable, Sendable {
    /// Verbatim text between `[[` and `]]` (used to round-trip exactly).
    let originalInner: String
    /// File/note name to resolve (before `#` and `|`).
    let target: String
    /// Display text after `|`, if any.
    let alias: String?
    /// Section after `#` (not `#^`), if any.
    let heading: String?
    /// Block id after `#^`, if any.
    let blockID: String?

    /// Text shown to the reader in Visual/Preview: alias if present, else target.
    var displayText: String {
        if let alias, !alias.isEmpty { return alias }
        return target.isEmpty ? originalInner : target
    }
}

/// One `[[...]]` occurrence, with a UTF-16 range covering the whole construct
/// (including the `[[` and `]]`) relative to the scanned string.
struct WikiLinkMatch: Equatable, Sendable {
    let range: NSRange
    let payload: MDWikiLinkPayload
}

/// Scans for `[[...]]`. Rules (matching Obsidian): single-line — newline before
/// `]]` aborts; first `]]` closes, no nesting; empty `[[]]` ignored. Callers
/// must NOT scan inside code spans/blocks — exclude at the AST-walk level.
func scanWikiLinks(in text: String) -> [WikiLinkMatch] {
    let ns = text as NSString
    let n = ns.length
    guard n >= 4 else { return [] }  // shortest possible: "[[x]]" is 5, but be cheap

    var matches: [WikiLinkMatch] = []
    var i = 0
    let openBracket: unichar = 0x5B  // '['
    let closeBracket: unichar = 0x5D // ']'
    let newline: unichar = 0x0A      // '\n'

    while i < n - 1 {
        if ns.character(at: i) == openBracket, ns.character(at: i + 1) == openBracket {
            var j = i + 2
            var closeAt = -1
            while j < n - 1 {
                let c = ns.character(at: j)
                if c == newline { break }  // wiki-links don't span lines
                if c == closeBracket, ns.character(at: j + 1) == closeBracket {
                    closeAt = j
                    break
                }
                j += 1
            }
            if closeAt >= 0 {
                let inner = ns.substring(with: NSRange(location: i + 2, length: closeAt - (i + 2)))
                if !inner.isEmpty {
                    let full = NSRange(location: i, length: (closeAt + 2) - i)
                    matches.append(WikiLinkMatch(range: full, payload: parseWikiInner(inner)))
                }
                i = closeAt + 2
                continue
            }
        }
        i += 1
    }
    return matches
}

/// Splits `[[...]]` inner into target / alias / heading / blockID. Alias splits
/// on `|` FIRST, then `#` within the target part — Obsidian's form is
/// `target#heading|alias`; `#` first would fold the alias into the heading.
func parseWikiInner(_ inner: String) -> MDWikiLinkPayload {
    // 1. Alias — first `|` (a table cell escapes it as `\|`; treat both as the
    //    separator and strip a trailing backslash from the target side).
    var beforePipe = inner
    var alias: String?
    if let pipeIdx = inner.firstIndex(of: "|") {
        var targetPart = inner[inner.startIndex..<pipeIdx]
        if targetPart.hasSuffix("\\") { targetPart = targetPart.dropLast() }
        beforePipe = String(targetPart)
        alias = String(inner[inner.index(after: pipeIdx)...])
    }

    // 2. Heading / block id — first `#` in the target part; `#^` means block id.
    var target = beforePipe
    var heading: String?
    var blockID: String?
    if let hashIdx = beforePipe.firstIndex(of: "#") {
        target = String(beforePipe[beforePipe.startIndex..<hashIdx])
        let afterHash = beforePipe.index(after: hashIdx)
        if afterHash < beforePipe.endIndex, beforePipe[afterHash] == "^" {
            blockID = String(beforePipe[beforePipe.index(after: afterHash)...])
        } else {
            heading = String(beforePipe[afterHash...])
        }
    }

    func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }
    return MDWikiLinkPayload(
        originalInner: inner,
        target: trim(target),
        alias: alias.map(trim),
        heading: heading.map(trim),
        blockID: blockID.map(trim)
    )
}
