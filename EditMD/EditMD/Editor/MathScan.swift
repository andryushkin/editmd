// Math spans (`$inline$` / `$$display$$`) — a pure, testable scanner + the
// length-preserving mask that lets the Preview parse math-bearing markdown
// without cmark mangling TeX (`\frac` → escape processing, `_`/`*` → emphasis).
//
// The mask replaces every masked UTF-16 unit with U+E000 (private use area),
// so the masked string has the SAME UTF-16 layout and the SAME line structure
// as the original: every offset cmark reports against the masked source is a
// valid offset in the original document (the data-md-lo/hi invariant).
//
// Scanner conventions (Obsidian/Pandoc-style):
// - `$x$` inline: opener not followed by space, closer not preceded by space,
//   closer not followed by a digit (currency guard: `$20 and $30` stays text),
//   single line, `\$` never opens/closes.
// - `$$…$$` display: same-line form works anywhere; the multiline form
//   requires the opening `$$` to start its line (whitespace-only prefix) and
//   no intermediate line may start a blockquote (`>` would be masked away and
//   break the quote structure).
// - Code is skipped: fenced blocks (```/~~~), indented code blocks and
//   single-line `` `code` `` spans never contain math.

import Foundation

/// One math occurrence. Ranges are UTF-16, relative to the scanned string;
/// `range` covers the whole construct including delimiters.
struct MDMathSpan: Equatable, Sendable {
    let range: NSRange
    /// Content between the `$`/`$$` delimiters (the TeX source).
    let innerRange: NSRange
    /// `$$…$$` (block/display) vs `$…$` (inline).
    let display: Bool
}

/// The mask character — one UTF-16 unit, never markdown-significant.
let mathSentinelUnit: unichar = 0xE000

/// Scans `text` for math spans, skipping code regions.
func scanMathSpans(in text: String) -> [MDMathSpan] {
    let ns = text as NSString
    let n = ns.length
    guard n >= 3 else { return [] }
    guard ns.range(of: "$").location != NSNotFound else { return [] }

    let dollar: unichar = 0x24
    let backslash: unichar = 0x5C
    let backtick: unichar = 0x60
    let newline: unichar = 0x0A
    let space: unichar = 0x20
    let tab: unichar = 0x09

    // ---- Line pass: mark code lines (fenced + indented) as excluded. ----
    // lineExcluded[k] == true → no math may start on / cross into line k.
    var lineStarts: [Int] = [0]
    for i in 0..<n where ns.character(at: i) == newline {
        lineStarts.append(i + 1)
    }
    var lineExcluded = [Bool](repeating: false, count: lineStarts.count)

    var fenceChar: unichar = 0
    var fenceLen = 0
    var inParagraph = false
    for k in 0..<lineStarts.count {
        let start = lineStarts[k]
        let end = k + 1 < lineStarts.count ? lineStarts[k + 1] - 1 : n
        var indent = 0
        var i = start
        var sawTab = false
        while i < end {
            let c = ns.character(at: i)
            if c == space { indent += 1 } else if c == tab { sawTab = true } else { break }
            i += 1
        }
        let blank = i >= end
        if fenceLen > 0 {
            // Inside a fenced block: everything is excluded until the closer.
            lineExcluded[k] = true
            if !blank, indent <= 3, !sawTab, ns.character(at: i) == fenceChar {
                var run = 0
                var j = i
                while j < end, ns.character(at: j) == fenceChar { run += 1; j += 1 }
                var restBlank = true
                while j < end {
                    let c = ns.character(at: j)
                    if c != space && c != tab { restBlank = false; break }
                    j += 1
                }
                if run >= fenceLen, restBlank { fenceLen = 0 }
            }
            continue
        }
        if blank { inParagraph = false; continue }
        if indent <= 3, !sawTab {
            let c = ns.character(at: i)
            if c == backtick || c == 0x7E {  // ` or ~
                var run = 0
                var j = i
                while j < end, ns.character(at: j) == c { run += 1; j += 1 }
                if run >= 3 {
                    fenceChar = c
                    fenceLen = run
                    lineExcluded[k] = true
                    continue
                }
            }
        }
        if (indent >= 4 || sawTab), !inParagraph {
            lineExcluded[k] = true  // indented code block
            continue
        }
        inParagraph = true
    }

    // Line number for an offset (binary search over lineStarts).
    func lineIndex(of offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    // ---- Char pass over non-excluded lines. ----
    var spans: [MDMathSpan] = []
    var line = 0
    var i = 0
    while i < n {
        // Advance the current line and hop over excluded ones.
        while line + 1 < lineStarts.count, lineStarts[line + 1] <= i { line += 1 }
        if lineExcluded[line] {
            i = line + 1 < lineStarts.count ? lineStarts[line + 1] : n
            continue
        }
        let lineEnd = line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : n

        let c = ns.character(at: i)
        if c == backslash {
            i += 2
            continue
        }
        if c == backtick {
            // Single-line code span: a same-length backtick run closes it.
            var run = 0
            var j = i
            while j < lineEnd, ns.character(at: j) == backtick { run += 1; j += 1 }
            var k = j
            while k < lineEnd {
                if ns.character(at: k) == backtick {
                    var closeRun = 0
                    var m = k
                    while m < lineEnd, ns.character(at: m) == backtick { closeRun += 1; m += 1 }
                    if closeRun == run { j = m; break }
                    k = m
                } else {
                    k += 1
                }
            }
            i = j
            continue
        }
        if c == dollar {
            let isDisplay = i + 1 < n && ns.character(at: i + 1) == dollar
            if isDisplay {
                if let span = matchDisplay(ns, n: n, at: i, lineEnd: lineEnd,
                                           lineStart: lineStarts[line],
                                           lineStarts: lineStarts,
                                           lineExcluded: lineExcluded,
                                           lineIndex: lineIndex) {
                    spans.append(span)
                    i = NSMaxRange(span.range)
                    continue
                }
                i += 2
                continue
            }
            if let span = matchInline(ns, n: n, at: i, lineEnd: lineEnd) {
                spans.append(span)
                i = NSMaxRange(span.range)
                continue
            }
        }
        i += 1
    }
    return spans
}

/// `$…$` on one line. Returns nil when no valid closer exists.
private func matchInline(_ ns: NSString, n: Int, at i: Int, lineEnd: Int) -> MDMathSpan? {
    let dollar: unichar = 0x24
    let backslash: unichar = 0x5C
    let space: unichar = 0x20
    let tab: unichar = 0x09
    guard i + 2 < n else { return nil }
    let first = ns.character(at: i + 1)
    guard first != space, first != tab, first != dollar else { return nil }
    var j = i + 1
    while j < lineEnd {
        let c = ns.character(at: j)
        if c == backslash { j += 2; continue }
        if c == dollar {
            let prev = ns.character(at: j - 1)
            let nextIsDigit = j + 1 < n && (0x30...0x39).contains(ns.character(at: j + 1))
            if prev != space, prev != tab, j > i + 1, !nextIsDigit {
                return MDMathSpan(
                    range: NSRange(location: i, length: j + 1 - i),
                    innerRange: NSRange(location: i + 1, length: j - (i + 1)),
                    display: false)
            }
            return nil  // first $ decides: an invalid closer means "not math"
        }
        j += 1
    }
    return nil
}

/// `$$…$$`: same-line always allowed; multiline only when the opener starts
/// its line, the closer ends its line, and no inner line is excluded / starts
/// a blockquote. "Span = whole lines" is what lets Source/Visual treat the
/// masked block as an atomic unit.
private func matchDisplay(_ ns: NSString, n: Int, at i: Int, lineEnd: Int,
                          lineStart: Int, lineStarts: [Int], lineExcluded: [Bool],
                          lineIndex: (Int) -> Int) -> MDMathSpan? {
    let dollar: unichar = 0x24
    let backslash: unichar = 0x5C
    let space: unichar = 0x20
    let tab: unichar = 0x09
    let gt: unichar = 0x3E
    let newline: unichar = 0x0A
    let cr: unichar = 0x0D

    func makeSpan(_ close: Int) -> MDMathSpan? {
        guard close > i + 2 else { return nil }  // $$$$ → empty, not math
        return MDMathSpan(
            range: NSRange(location: i, length: close + 2 - i),
            innerRange: NSRange(location: i + 2, length: close - (i + 2)),
            display: true)
    }

    // Same-line closer.
    var j = i + 2
    while j + 1 < n, j < lineEnd {
        let c = ns.character(at: j)
        if c == backslash { j += 2; continue }
        if c == dollar, j + 1 < n, ns.character(at: j + 1) == dollar {
            return makeSpan(j)
        }
        j += 1
    }

    // Multiline: opener must start the line (whitespace-only prefix).
    var k = lineStart
    while k < i {
        let c = ns.character(at: k)
        guard c == space || c == tab else { return nil }
        k += 1
    }
    let scanLimit = min(n, i + 20_000)
    j = lineEnd
    while j + 1 < scanLimit {
        let c = ns.character(at: j)
        if c == backslash { j += 2; continue }
        if c == dollar, ns.character(at: j + 1) == dollar {
            // Closer must end its line (trailing whitespace only).
            var t = j + 2
            var closesLine = true
            while t < n {
                let tc = ns.character(at: t)
                if tc == newline { break }
                if tc != space, tc != tab, tc != cr { closesLine = false; break }
                t += 1
            }
            if !closesLine { j += 2; continue }
            // Every line the span crosses must be usable.
            let firstLine = lineIndex(i)
            let lastLine = lineIndex(j)
            for l in (firstLine + 1)...lastLine {
                if lineExcluded[l] { return nil }
                var p = lineStarts[l]
                let pe = l + 1 < lineStarts.count ? lineStarts[l + 1] - 1 : n
                while p < pe, ns.character(at: p) == space || ns.character(at: p) == tab { p += 1 }
                if p < pe, ns.character(at: p) == gt { return nil }  // blockquote line
            }
            return makeSpan(j)
        }
        j += 1
    }
    return nil
}

/// Replaces the content of every span with U+E000 sentinels, preserving the
/// UTF-16 layout exactly (unit-for-unit) and keeping the line structure:
/// newlines and each line's LEADING whitespace stay (list indentation
/// survives), all other units — including internal/trailing whitespace — are
/// masked. Returns the masked string plus the per-span count of masked units
/// (the HTML visitor consumes sentinel runs against these counts).
func maskMathSpansForParsing(_ text: String, spans: [MDMathSpan])
    -> (masked: String, sentinelUnits: [Int]) {
    guard !spans.isEmpty else { return (text, []) }
    let ns = text as NSString
    var buf = [unichar](repeating: 0, count: ns.length)
    ns.getCharacters(&buf)

    let newline: unichar = 0x0A
    let cr: unichar = 0x0D
    let space: unichar = 0x20
    let tab: unichar = 0x09

    var units: [Int] = []
    for span in spans {
        var count = 0
        var atLineStart = false  // span opener is never at line start itself
        var i = span.range.location
        let end = min(NSMaxRange(span.range), buf.count)
        while i < end {
            let c = buf[i]
            if c == newline || c == cr {
                atLineStart = true
                i += 1
                continue
            }
            if atLineStart, c == space || c == tab {
                i += 1  // leading indentation survives the mask
                continue
            }
            atLineStart = false
            buf[i] = mathSentinelUnit
            count += 1
            i += 1
        }
        units.append(count)
    }
    return (String(utf16CodeUnits: buf, count: buf.count), units)
}
