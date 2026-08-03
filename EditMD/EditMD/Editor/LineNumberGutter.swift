import AppKit

/// Unified gutter digit size (Source / Visual / Preview CSS). Independent of
/// body font so headings never inflate the numbers.
enum GutterTypography {
    static let fontSize: CGFloat = 11
}

/// Geometry of the Source/Visual line-number gutter. Numbers draw inside the
/// text view's left inset (no NSRulerView — AppKit pins it to the scroll-view
/// edge, far from a centred column; Preview's CSS rail matches). The inset
/// RESERVES room whether or not numbers show, so toggling never shifts text.
enum GutterMetrics {
    /// Numbers → text. Matches `PreviewGutterMetrics.gapPx` so the three modes
    /// place their digits identically.
    static let gap: CGFloat = 18
    /// Text view's left edge → numbers, when the reading column leaves no slack.
    static let edgePad: CGFloat = 6
    /// How far left of the numbers the current-line band starts.
    static let bandLeadIn: CGFloat = 3
    /// Band's right margin. Small and fixed: mirroring the left inset would
    /// leave a far wider gap, since that inset carries the gutter reserve.
    static let bandRightMargin: CGFloat = 12

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
    /// Caret offset (UTF-16, this view's text); `nil` = no emphasis. An offset,
    /// not a line number, on purpose: the drawing pass already walks visible
    /// hard lines (O(visible)); deriving a line number per caret move would
    /// rescan the whole prefix of a large file.
    var caretOffset: Int?
}

// MARK: - Drawing

private struct GutterAnchor {
    var y: CGFloat          // vertical center of the number
    var sourceLine: Int
    var isCurrent: Bool
}

/// Is `caret` on the hard line `lineRange`? A caret at the line's trailing
/// edge belongs to it only when the line does not end in a newline — otherwise
/// that offset is the first position of the NEXT line (and a document ending
/// in `\n` really does have one more, empty, line).
func gutterLineHoldsCaret(_ caret: Int, lineRange: NSRange, lineEndsWithNewline: Bool) -> Bool {
    if NSLocationInRange(caret, lineRange) { return true }
    return caret == lineRange.location + lineRange.length && !lineEndsWithNewline
}

/// Hard line (including its newline) that owns `caret`. Unlike a plain
/// `lineRange(for:)` on a clamped probe, a caret parked after a trailing `\n`
/// gets the empty last line, not the line above it.
func gutterCaretLineRange(in ns: NSString, caret: Int) -> NSRange {
    let loc = max(0, min(caret, ns.length))
    guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
    if loc == ns.length, ns.character(at: ns.length - 1) == 0x0A {
        return NSRange(location: ns.length, length: 0)
    }
    return ns.lineRange(for: NSRange(location: min(loc, ns.length - 1), length: 0))
}

/// Caret offset to emphasize, or `nil`. A ranged selection emphasizes nothing:
/// the selection fill already marks the spot, and lighting the anchor's number
/// would claim one current line across a multi-line selection.
func gutterEmphasisOffset(selection: NSRange, enabled: Bool) -> Int? {
    guard enabled, selection.length == 0 else { return nil }
    return selection.location
}

/// Does `lineRange` end in a newline (i.e. another line follows)?
func gutterLineEndsWithNewline(in ns: NSString, lineRange: NSRange) -> Bool {
    let end = lineRange.location + lineRange.length
    guard lineRange.length > 0, end <= ns.length else { return false }
    return ns.character(at: end - 1) == 0x0A
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
            let isCurrent = state.caretOffset.map {
                gutterLineHoldsCaret(
                    $0, lineRange: hardLine,
                    lineEndsWithNewline: gutterLineEndsWithNewline(in: ns, lineRange: hardLine))
            } ?? false
            anchors.append(GutterAnchor(y: y,
                                        sourceLine: sourceLine(forDisplay: displayLine),
                                        isCurrent: isCurrent))
        }

        guard !anchors.isEmpty else { return }
        anchors.sort { $0.y < $1.y }

        func drawNumber(_ src: Int, at y: CGFloat, isCurrent: Bool) {
            guard y + fontSize >= rect.minY - 2, y <= rect.maxY + 2 else { return }
            let isDirty = state.settings.highlightChangedLines
                && state.dirtySourceLines.contains(src)
            if state.settings.showLineNumbers {
                // Caret's line reads in full label color against the tertiary
                // rest (Xcode's cue). A dirty line keeps its own color — that
                // is information the caret position does not replace.
                let color: NSColor = isDirty
                    ? dirtyColor
                    : (isCurrent ? .labelColor : normalColor)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isDirty ? dirtyFont : normalFont,
                    .foregroundColor: color,
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
            drawNumber(a.sourceLine, at: a.y, isCurrent: a.isCurrent)
            lastDrawnLine = a.sourceLine
            lastDrawnY = a.y
        }
    }

    /// Fills the caret's hard line (all wrapped fragments), full editor width.
    /// Call from `drawBackground` BEFORE the gutter so numbers stay on top.
    /// `gutterReserve` places the band's left edge just outside the numbers.
    /// `opacity` 0 = theme default for the *drawing* appearance — resolved
    /// here, not at settings time, so a light/dark flip repaints correctly.
    @MainActor
    func drawCurrentLineHighlight(in rect: NSRect, caret: Int, tint: NSColor,
                                  opacity: CGFloat, gutterReserve: CGFloat) {
        guard let layoutManager else { return }
        let ns = string as NSString
        let lineRange = gutterCaretLineRange(in: ns, caret: caret)
        let inset = textContainerInset
        var fill: NSRect?

        if lineRange.length == 0, lineRange.location == ns.length, ns.length > 0 {
            // Caret parked on the empty line after a trailing newline: that
            // line has no fragment of its own, only the extra rect.
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { fill = extra.offsetBy(dx: inset.width, dy: inset.height) }
        } else {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange,
                                                      actualCharacterRange: nil)
            // Union of the line's fragments: a soft-wrapped line highlights whole.
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragRect, _, _, _, _ in
                let r = fragRect.offsetBy(dx: inset.width, dy: inset.height)
                fill = fill.map { $0.union(r) } ?? r
            }
            if fill == nil {
                let extra = layoutManager.extraLineFragmentRect
                if !extra.isEmpty { fill = extra.offsetBy(dx: inset.width, dy: inset.height) }
            }
        }
        guard var band = fill, band.intersects(rect) else { return }
        // Band covers the number (like Xcode) but starts left of it, not at the
        // view edge. Numbers are right-aligned at `inset.width - gap`, so their
        // left edge = `inset.width - reserve + edgePad`; unknown reserve
        // (numbers hidden / other host) falls back to a small margin. Right
        // margin fixed — mirroring the left inset would gape (it carries the
        // reserve).
        let numbersLeft = gutterReserve > 0
            ? inset.width - gutterReserve + GutterMetrics.edgePad
            : GutterMetrics.edgePad
        let leftMargin = max(0, min(numbersLeft - GutterMetrics.bandLeadIn, inset.width))
        band.origin.x = leftMargin
        band.size.width = max(0, bounds.width - leftMargin - GutterMetrics.bandRightMargin)

        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha = opacity > 0 ? opacity : EditorTheme.currentLineAlpha(isDark: isDark)
        tint.withAlphaComponent(alpha).setFill()
        band.fill()
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

/// Per Visual display paragraph (hard-`\n` order), the 1-based **source** line
/// where it begins. Single forward scan — a full-prefix walk per paragraph was
/// O(n²).
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
