import AppKit

/// Unified gutter digit size (Source / Visual / Preview CSS). Independent of
/// body font so headings never inflate the numbers.
enum GutterTypography {
    static let fontSize: CGFloat = 11
}

/// Geometry of the Source/Visual line-number gutter.
///
/// The numbers used to live in an `NSRulerView`, which AppKit pins to the left
/// edge of the scroll view — far from a centred reading column. They are drawn
/// inside the text view now, in its left inset, right next to the text (the
/// Preview CSS rail works the same way). The inset RESERVES room for them
/// whether or not they're shown, so toggling never shifts the text.
enum GutterMetrics {
    /// Numbers → text. Matches `PreviewGutterMetrics.gapPx` so the three modes
    /// place their digits identically.
    static let gap: CGFloat = 18
    /// Text view's left edge → numbers, when the reading column leaves no slack.
    static let edgePad: CGFloat = 6

    static func numbersWidth(lineCountHint: Int) -> CGFloat {
        let digits = max(2, String(max(1, lineCountHint)).count)
        let sample = String(repeating: "0", count: digits) as NSString
        let font = NSFont.monospacedDigitSystemFont(ofSize: GutterTypography.fontSize,
                                                    weight: .regular)
        return ceil(sample.size(withAttributes: [.font: font]).width)
    }

    /// Minimum left inset the text needs so the numbers fit beside it.
    static func reserve(lineCountHint: Int) -> CGFloat {
        numbersWidth(lineCountHint: lineCountHint) + gap + edgePad
    }
}

/// What a text view needs to draw its gutter — set by the editor's
/// `refreshGutter`, read by `drawBackground`.
struct GutterState {
    var settings = GutterSettings()
    /// 1-based **source** line numbers that are dirty (`LineChangeTracker`).
    var dirtySourceLines: Set<Int> = []
    /// Index 0 = display hard-line 1 → source line number. Empty = identity
    /// (Source); Visual passes the paragraph→markdown map.
    var displayToSourceLine: [Int] = []
}

// MARK: - Drawing

private struct GutterAnchor {
    var y: CGFloat          // vertical center of the number
    var sourceLine: Int
}

extension NSTextView {

    /// Draws source line numbers (or dirty bullets) in the left inset, right
    /// aligned `GutterMetrics.gap` before the text. Call from `drawBackground`.
    @MainActor
    func drawGutterNumbers(in rect: NSRect, state: GutterState) {
        guard state.settings.gutterVisible,
              let layoutManager,
              let textContainer
        else { return }

        let dirtyColor = state.settings.dirtyMarkNSColor
        let normalColor = NSColor.tertiaryLabelColor
        let normalFont = NSFont.monospacedDigitSystemFont(ofSize: GutterTypography.fontSize,
                                                          weight: .regular)
        let dirtyFont = NSFont.monospacedDigitSystemFont(ofSize: GutterTypography.fontSize,
                                                         weight: .bold)
        let fontSize = GutterTypography.fontSize

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.location != NSNotFound else { return }

        let ns = string as NSString
        let inset = textContainerInset
        // Fragments are container-relative; the text view's own inset puts them
        // where they're drawn.
        let yOffset = inset.height
        let rightEdge = inset.width - GutterMetrics.gap

        func sourceLine(forDisplay displayLine: Int) -> Int {
            let idx = displayLine - 1
            if idx >= 0, idx < state.displayToSourceLine.count {
                return state.displayToSourceLine[idx]
            }
            return displayLine  // identity (Source)
        }

        var anchors: [GutterAnchor] = []
        // Running newline count — O(visible) total, not O(visible × doc) (the
        // old per-fragment prefix walk pegged CPU on large Source files).
        var lastHardLineStart = -1
        var lastDisplayLine = 0

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            fragmentRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location != NSNotFound else { return }
            // Empty hard lines still produce a fragment; length may be 0 for
            // the final empty paragraph — still number them.
            let charIndex: Int
            if fragGlyphRange.length > 0 {
                charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)
            } else if ns.length > 0 {
                charIndex = min(layoutManager.characterIndexForGlyph(at: fragGlyphRange.location),
                                ns.length - 1)
            } else {
                charIndex = 0
            }
            guard ns.length == 0 || charIndex < ns.length || fragGlyphRange.length == 0 else { return }

            let probe = ns.length == 0 ? 0 : min(charIndex, ns.length - 1)
            let hardLine = ns.lineRange(for: NSRange(location: probe, length: 0))
            let firstGlyphOfLine = layoutManager.glyphIndexForCharacter(at: hardLine.location)
            // Soft-wrap continuation: skip (except when glyph range is empty at EOL).
            if fragGlyphRange.length > 0, fragGlyphRange.location != firstGlyphOfLine {
                return
            }

            let displayLine: Int
            if hardLine.location == lastHardLineStart {
                displayLine = lastDisplayLine
            } else if hardLine.location == 0 {
                displayLine = 1
                lastHardLineStart = 0
                lastDisplayLine = 1
            } else if hardLine.location > lastHardLineStart, lastHardLineStart >= 0 {
                // Forward scan from previous hard line (common while scrolling down).
                var dl = lastDisplayLine
                var i = lastHardLineStart
                while i < hardLine.location {
                    if ns.character(at: i) == 0x0A { dl += 1 }
                    i += 1
                }
                displayLine = dl
                lastHardLineStart = hardLine.location
                lastDisplayLine = dl
            } else {
                // Scrolled up / first fragment: count newlines in prefix once.
                var dl = 1
                var i = 0
                while i < hardLine.location {
                    if ns.character(at: i) == 0x0A { dl += 1 }
                    i += 1
                }
                displayLine = dl
                lastHardLineStart = hardLine.location
                lastDisplayLine = dl
            }

            let y = fragmentRect.minY + yOffset
                + (fragmentRect.height - fontSize) * 0.5
                - 1
            anchors.append(GutterAnchor(y: y, sourceLine: sourceLine(forDisplay: displayLine)))
        }

        guard !anchors.isEmpty else { return }
        anchors.sort { $0.y < $1.y }

        func drawNumber(_ src: Int, at y: CGFloat) {
            guard y + fontSize >= rect.minY - 2, y <= rect.maxY + 2 else { return }
            let isDirty = state.settings.highlightChangedLines
                && state.dirtySourceLines.contains(src)
            if state.settings.showLineNumbers {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isDirty ? dirtyFont : normalFont,
                    .foregroundColor: isDirty ? dirtyColor : normalColor,
                ]
                let s = "\(src)" as NSString
                let size = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: max(2, rightEdge - size.width), y: y),
                       withAttributes: attrs)
            } else if isDirty, state.settings.showDirtyBulletsWhenNoNumbers {
                let r: CGFloat = max(2.5, fontSize * 0.22)
                let cx = rightEdge - r
                let cy = y + fontSize * 0.5
                dirtyColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
            }
        }

        // One number per block, like the Preview rail. Source lines with no
        // fragment of their own (blank lines Visual folds into paragraph
        // spacing) are NOT back-filled into the gaps: squeezing them in turned
        // dense stretches into an unreadable stack of digits.
        var lastDrawnLine = Int.min
        var lastDrawnY = -CGFloat.greatestFiniteMagnitude
        for a in anchors {
            // Several display paragraphs can map to one source line (table rows,
            // islands) — draw it once.
            guard a.sourceLine != lastDrawnLine,
                  a.y - lastDrawnY >= fontSize * 1.1
            else { continue }
            drawNumber(a.sourceLine, at: a.y)
            lastDrawnLine = a.sourceLine
            lastDrawnY = a.y
        }
    }
}

// MARK: - Source-line map helpers

/// 1-based source line of a UTF-16 offset in markdown.
func sourceLineNumber(at utf16Offset: Int, in markdown: String) -> Int {
    let ns = markdown as NSString
    let loc = max(0, min(utf16Offset, ns.length))
    if loc == 0 { return 1 }
    return ns.substring(with: NSRange(location: 0, length: loc))
        .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
}

/// For each Visual display paragraph (same order as hard `\n` lines in the
/// visual buffer), the 1-based **source** line where that paragraph begins.
/// Single forward scan — not one full-prefix walk per paragraph (that was O(n²)).
func displayToSourceLineMap(paragraphRanges: [NSRange], markdown: String) -> [Int] {
    if paragraphRanges.isEmpty { return [] }
    let ns = markdown as NSString
    let n = ns.length
    var result: [Int] = []
    result.reserveCapacity(paragraphRanges.count)
    var line = 1
    var cursor = 0
    for range in paragraphRanges {
        let loc = max(0, min(range.location, n))
        if loc < cursor {
            // Out-of-order: fall back (should not happen for real maps).
            result.append(sourceLineNumber(at: loc, in: markdown))
            continue
        }
        while cursor < loc {
            if ns.character(at: cursor) == 0x0A { line += 1 }
            cursor += 1
        }
        result.append(line)
    }
    return result
}
