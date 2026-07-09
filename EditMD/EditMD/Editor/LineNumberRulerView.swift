import AppKit

/// Vertical ruler for an `NSTextView`: optional 1-based line numbers and
/// session dirty marks (bold green number or a bullet when numbers are off).
final class LineNumberRulerView: NSRulerView {

    weak var hostTextView: NSTextView?
    var fileURL: URL?
    /// 1-based dirty line set (from `LineChangeTracker`).
    var dirtyLines: Set<Int> = []
    var gutter = GutterSettings()

    private let minThicknessNumbers: CGFloat = 36
    private let minThicknessBullets: CGFloat = 16

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = minThicknessNumbers
        needsDisplay = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) not used") }

    func applySettings(_ settings: GutterSettings) {
        gutter = settings
        let thick: CGFloat
        if settings.showLineNumbers {
            thick = minThicknessNumbers
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

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard gutter.gutterVisible, let textView = hostTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView
        else { return }

        let dirtyColor = gutter.dirtyMarkNSColor
        let normalColor = NSColor.secondaryLabelColor
        let fontSize = max(9, (textView.font?.pointSize ?? 12) - 1)
        let normalFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let dirtyFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        let ns = textView.string as NSString
        let firstChar = layoutManager.characterIndexForGlyph(
            at: glyphRange.location == NSNotFound ? 0 : glyphRange.location)
        // 1-based line index of the first visible character.
        var line = 1
        if firstChar > 0 {
            let prefix = ns.substring(with: NSRange(location: 0, length: min(firstChar, ns.length)))
            line = prefix.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }

        let inset = textView.textContainerInset
        // Ruler coordinates: convert fragment rects (container) into ruler view.
        let originInRuler = convert(NSPoint(x: 0, y: inset.height), from: textView)

        layoutManager.enumerateLineFragments(
            forGlyphRange: glyphRange
        ) { fragmentRect, _, _, fragGlyphRange, _ in
            guard fragGlyphRange.location != NSNotFound else { return }
            let charIndex = layoutManager.characterIndexForGlyph(at: fragGlyphRange.location)
            // Only the first fragment of a hard line (skip soft-wrap continuations).
            let hardLine = ns.lineRange(for: NSRange(location: charIndex, length: 0))
            let firstGlyphOfLine = layoutManager.glyphIndexForCharacter(at: hardLine.location)
            guard fragGlyphRange.location == firstGlyphOfLine else { return }

            // Line number for this hard line = count of \n before hardLine.location + 1.
            let thisLine: Int
            if hardLine.location == 0 {
                thisLine = 1
            } else {
                let pre = ns.substring(with: NSRange(location: 0, length: hardLine.location))
                thisLine = pre.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            }

            let y = fragmentRect.minY + originInRuler.y
                + (fragmentRect.height - fontSize) / 2 - 1
            let isDirty = self.gutter.highlightChangedLines && self.dirtyLines.contains(thisLine)
            let drawRect = NSRect(x: 0, y: y, width: self.ruleThickness - 4, height: fontSize + 4)

            if self.gutter.showLineNumbers {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: isDirty ? dirtyFont : normalFont,
                    .foregroundColor: isDirty ? dirtyColor : normalColor,
                ]
                let s = "\(thisLine)" as NSString
                let size = s.size(withAttributes: attrs)
                s.draw(at: NSPoint(x: drawRect.maxX - size.width, y: drawRect.minY),
                       withAttributes: attrs)
            } else if isDirty, self.gutter.showDirtyBulletsWhenNoNumbers {
                let r: CGFloat = 3.5
                let cx = self.ruleThickness / 2
                let cy = y + fontSize / 2
                dirtyColor.setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill()
            }
        }
    }
}

// MARK: - Attach / refresh helpers

extension NSTextView {
    /// Installs (or updates) a line-number ruler on the enclosing scroll view.
    @MainActor
    func installOrUpdateLineNumberRuler(fileURL: URL?,
                                        dirty: Set<Int>,
                                        settings: GutterSettings) {
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
        ruler.dirtyLines = dirty
        ruler.applySettings(settings)
        ruler.needsDisplay = true
    }
}
