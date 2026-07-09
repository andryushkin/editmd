import AppKit

/// Unified gutter digit size (Source / Visual / Preview CSS). Independent of
/// body font so headings never inflate the numbers.
enum GutterTypography {
    static let fontSize: CGFloat = 11
}

/// Vertical ruler for an `NSTextView`: optional **source** line numbers and
/// session dirty marks (bold colored number or a bullet when numbers are off).
///
/// In Source mode display line ≡ source line (identity map).
/// In Visual mode pass `displayToSourceLine` so the gutter shows the markdown
/// line number for each display paragraph. Gaps between source lines (blank
/// lines collapsed to paragraph spacing in Visual) are filled by drawing the
/// intermediate numbers in the vertical gap.
final class LineNumberRulerView: NSRulerView {

    weak var hostTextView: NSTextView?
    var fileURL: URL?
    /// 1-based **source** line numbers that are dirty (`LineChangeTracker`).
    var dirtySourceLines: Set<Int> = []
    var gutter = GutterSettings()
    /// Kept for API compatibility; digit size uses `GutterTypography.fontSize`.
    var bodyFont: NSFont = .monospacedSystemFont(ofSize: 14, weight: .regular)
    /// Index 0 = display hard-line 1 → source line number.
    /// Empty = identity (Source).
    var displayToSourceLine: [Int] = []

    private let minThicknessNumbers: CGFloat = 36
    private let minThicknessBullets: CGFloat = 16
    private let trailingPad: CGFloat = 8

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = minThicknessNumbers
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    func applySettings(_ settings: GutterSettings, bodyFont: NSFont, lineCountHint: Int) {
        gutter = settings
        self.bodyFont = bodyFont
        let thick: CGFloat
        if settings.showLineNumbers {
            let digits = max(2, String(max(1, lineCountHint)).count)
            let sample = String(repeating: "0", count: digits) as NSString
            let digitFont = numberFont(bold: false)
            let w = sample.size(withAttributes: [.font: digitFont]).width
            thick = max(minThicknessNumbers, ceil(w) + trailingPad + 6)
        } else if settings.gutterVisible {
            thick = minThicknessBullets
        } else {
            thick = 0
        }
        if abs(ruleThickness - thick) > 0.5 {
            ruleThickness = thick
        }
        needsDisplay = true
    }

    private func numberFont(bold: Bool) -> NSFont {
        .monospacedDigitSystemFont(ofSize: GutterTypography.fontSize,
                                   weight: bold ? .bold : .regular)
    }

    /// Source line for a 1-based display hard-line index.
    private func sourceLine(forDisplay displayLine: Int) -> Int {
        let idx = displayLine - 1
        if idx >= 0, idx < displayToSourceLine.count {
            return displayToSourceLine[idx]
        }
        return displayLine  // identity
    }

    /// Fill the whole ruler (no default NSRuler hash/separator chrome).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        if gutter.gutterVisible {
            drawHashMarksAndLabels(in: dirtyRect)
        }
    }

    private struct Anchor {
        var y: CGFloat          // vertical center of the number
        var height: CGFloat     // line fragment height
        var sourceLine: Int
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard gutter.gutterVisible,
              let textView = hostTextView ?? clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer
        else { return }

        let dirtyColor = gutter.dirtyMarkNSColor
        let normalColor = NSColor.tertiaryLabelColor
        let normalFont = numberFont(bold: false)
        let dirtyFont = numberFont(bold: true)
        let fontSize = GutterTypography.fontSize

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.location != NSNotFound else { return }

        let ns = textView.string as NSString
        let inset = textView.textContainerInset
        let yOffset = inset.height - visibleRect.origin.y

        var anchors: [Anchor] = []

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
            if hardLine.location == 0 {
                displayLine = 1
            } else {
                let pre = ns.substring(with: NSRange(location: 0, length: hardLine.location))
                displayLine = pre.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            }
            let srcLine = self.sourceLine(forDisplay: displayLine)

            let y = fragmentRect.minY + yOffset
                + (fragmentRect.height - fontSize) * 0.5
                - 1
            anchors.append(Anchor(y: y, height: fragmentRect.height, sourceLine: srcLine))
        }

        // Draw anchors + fill source-line gaps (blank lines collapsed in Visual).
        guard !anchors.isEmpty else { return }
        anchors.sort { $0.y < $1.y }

        func drawNumber(_ src: Int, at y: CGFloat) {
            guard y + fontSize >= rect.minY - 2, y <= rect.maxY + 2 else { return }
            let isDirty = self.gutter.highlightChangedLines
                && self.dirtySourceLines.contains(src)
            if self.gutter.showLineNumbers {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isDirty ? dirtyFont : normalFont,
                    .foregroundColor: isDirty ? dirtyColor : normalColor,
                ]
                let s = "\(src)" as NSString
                let size = s.size(withAttributes: attrs)
                let x = self.ruleThickness - self.trailingPad - size.width
                s.draw(at: NSPoint(x: max(2, x), y: y), withAttributes: attrs)
            } else if isDirty, self.gutter.showDirtyBulletsWhenNoNumbers {
                let r: CGFloat = max(2.5, fontSize * 0.22)
                let cx = self.ruleThickness * 0.5
                let cy = y + fontSize * 0.5
                dirtyColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
            }
        }

        for (i, a) in anchors.enumerated() {
            drawNumber(a.sourceLine, at: a.y)

            // Intermediate source lines between this anchor and the next
            // (e.g. blank lines between H1 and H2 that Visual folded into spacing).
            guard i + 1 < anchors.count else { continue }
            let b = anchors[i + 1]
            let gapStart = a.sourceLine + 1
            let gapEnd = b.sourceLine - 1
            guard gapStart <= gapEnd else { continue }

            let top = a.y + fontSize  // below first number
            let bottom = b.y          // above next number
            let gapH = bottom - top
            let missing = gapEnd - gapStart + 1
            // Need room for at least a tiny digit; if spacing is tight, still try.
            guard gapH > fontSize * 0.35 else { continue }

            for k in 0..<missing {
                let src = gapStart + k
                let t = (CGFloat(k) + 0.5) / CGFloat(missing)
                let y = top + gapH * t - fontSize * 0.5
                drawNumber(src, at: y)
            }
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
func displayToSourceLineMap(paragraphRanges: [NSRange], markdown: String) -> [Int] {
    if paragraphRanges.isEmpty { return [] }
    return paragraphRanges.map { range in
        sourceLineNumber(at: range.location, in: markdown)
    }
}

// MARK: - Attach / refresh helpers

extension NSTextView {
    /// Installs (or updates) a line-number ruler on the enclosing scroll view.
    @MainActor
    func installOrUpdateLineNumberRuler(fileURL: URL?,
                                        dirtySourceLines: Set<Int>,
                                        settings: GutterSettings,
                                        bodyFont: NSFont,
                                        displayToSourceLine: [Int] = [],
                                        sourceLineCountHint: Int? = nil) {
        guard let scroll = enclosingScrollView else { return }
        scroll.hasVerticalRuler = settings.gutterVisible
        scroll.rulersVisible = settings.gutterVisible
        if !settings.gutterVisible {
            scroll.verticalRulerView = nil
            return
        }
        let ruler: LineNumberRulerView
        if let existing = scroll.verticalRulerView as? LineNumberRulerView {
            ruler = existing
        } else {
            ruler = LineNumberRulerView(scrollView: scroll, orientation: .verticalRuler)
            scroll.verticalRulerView = ruler
        }
        ruler.hostTextView = self
        ruler.clientView = self
        ruler.fileURL = fileURL
        ruler.dirtySourceLines = dirtySourceLines
        ruler.displayToSourceLine = displayToSourceLine
        let hint = sourceLineCountHint
            ?? displayToSourceLine.max()
            ?? max(1, (string as NSString).components(separatedBy: "\n").count)
        ruler.applySettings(settings, bodyFont: bodyFont, lineCountHint: hint)
        ruler.needsDisplay = true
    }
}
