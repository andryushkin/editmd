import AppKit

// Background drawing of VisualNSTextView: gutter, code panels, quote bars,
// list markers, thematic breaks, and virtualized table islands.
// Extracted from VisualNSTextView.swift.

extension VisualNSTextView {
    /// Six-dot grip glyph centered in the gutter zone.
    func drawRowHandle(in frame: NSRect, active: Bool) {
        theme.secondaryColor.withAlphaComponent(active ? 0.9 : 0.6).setFill()
        let dot: CGFloat = 2.4
        let stepX: CGFloat = 4, stepY: CGFloat = 4.5
        for column in 0..<2 {
            for row in 0..<3 {
                let x = frame.midX - stepX / 2 - dot / 2 + CGFloat(column) * stepX
                let y = frame.midY - stepY - dot / 2 + CGFloat(row) * stepY
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: dot, height: dot)).fill()
            }
        }
    }

    /// Rect of the drawn marker (bullet/checkbox/number) for a paragraph:
    /// in the indent margin, on the first line fragment.
    func markerRect(forParagraph range: NSRange) -> NSRect? {
        guard let layoutManager, let textContainer else { return nil }
        let totalLength = (string as NSString).length
        guard range.location < totalLength else { return nil }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: range.location, length: 1),
            actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return nil }
        let lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard lineRect.height > 0 else { return nil }
        let boxSize: CGFloat = 15
        // The marker sits left of the text indent (paragraph firstLineHeadIndent).
        let indent = (textStorage?.attribute(.paragraphStyle, at: range.location,
                                             effectiveRange: nil) as? NSParagraphStyle)?
            .firstLineHeadIndent ?? 0
        return NSRect(x: textContainerInset.width + indent - 21,
                      y: textContainerInset.height + lineRect.midY - boxSize / 2,
                      width: boxSize, height: boxSize)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawGutterNumbers(in: rect, state: gutterState)
        if activeEditor != nil {
            editorSettings.overlayColor.setFill()
            (enclosingScrollView?.contentView.documentVisibleRect ?? bounds).fill()
        }
        guard let layoutManager else { return }
        let inset = textContainerInset
        let totalLength = (string as NSString).length
        let fullWidth = bounds.width - inset.width * 2

        func unionRect(for range: NSRange) -> NSRect? {
            guard range.location < totalLength else { return nil }
            let safe = NSRange(location: range.location,
                               length: min(range.length, totalLength - range.location))
            guard safe.length > 0 else { return nil }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
            var union = NSRect.null
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { fragment, _, _, _, _ in
                let line = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                  width: fullWidth, height: fragment.height)
                union = union.isNull ? line : union.union(line)
            }
            return union.isNull ? nil : union
        }

        // Code panels.
        // padding = gray around glyphs only (fixed).
        // margin = enforced white gap between panel outer edges + clamp so a
        // panel never paints over a neighboring (non-member) line fragment.
        // Paired with the presentation's paragraph margin (32): white gap to
        // the neighboring text = 18, the rest becomes inner gray padding.
        let codePanelPadding: CGFloat = 6
        let codeBlockMargin: CGFloat = 18
        var panelRects: [NSRect] = []
        panelRects.reserveCapacity(codePanelEntries.count)
        for entry in codePanelEntries {
            let range = entry.range
            guard var box = unionRect(for: range) else { continue }
            // Nested-in-list fences indent to the item's content column.
            box.origin.x += entry.leadingIndent
            box.size.width = max(0, box.width - entry.leadingIndent)
            // Internal padding around the text of THIS fence only.
            box = box.insetBy(dx: 0, dy: -codePanelPadding)
            // Clamp to neighbors outside the character range so pad cannot
            // bleed onto the previous/next paragraph (quote, list, other code).
            if range.location > 0 {
                let prevIdx = range.location - 1
                let prevGlyph = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: prevIdx, length: 1),
                    actualCharacterRange: nil)
                if prevGlyph.location != NSNotFound {
                    var prevFrag = NSRect.null
                    layoutManager.enumerateLineFragments(forGlyphRange: prevGlyph) { fragment, _, _, _, _ in
                        let r = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                       width: fullWidth, height: fragment.height)
                        prevFrag = prevFrag.isNull ? r : prevFrag.union(r)
                    }
                    if !prevFrag.isNull {
                        box.origin.y = max(box.minY, prevFrag.maxY + codeBlockMargin)
                        box.size.height = max(0, box.maxY - box.minY)
                    }
                }
            }
            let after = NSMaxRange(range)
            if after < totalLength {
                let nextGlyph = layoutManager.glyphRange(
                    forCharacterRange: NSRange(location: after, length: 1),
                    actualCharacterRange: nil)
                if nextGlyph.location != NSNotFound {
                    var nextFrag = NSRect.null
                    layoutManager.enumerateLineFragments(forGlyphRange: nextGlyph) { fragment, _, _, _, _ in
                        let r = NSRect(x: inset.width, y: fragment.minY + inset.height,
                                       width: fullWidth, height: fragment.height)
                        nextFrag = nextFrag.isNull ? r : nextFrag.union(r)
                    }
                    if !nextFrag.isNull {
                        let maxY = nextFrag.minY - codeBlockMargin
                        if maxY < box.maxY {
                            box.size.height = max(0, maxY - box.minY)
                        }
                    }
                }
            }
            if box.height > 0 { panelRects.append(box) }
        }
        // Resolve panel–panel overlap (adjacent fences): keep margin between
        // outer edges by shrinking into the gap, never by expanding gray.
        panelRects.sort { $0.minY < $1.minY }
        if panelRects.count > 1 {
            for i in 1..<panelRects.count {
                let prev = panelRects[i - 1]
                var cur = panelRects[i]
                let minTop = prev.maxY + codeBlockMargin
                if cur.minY < minTop {
                    let shrink = minTop - cur.minY
                    cur.origin.y += shrink
                    cur.size.height = max(0, cur.height - shrink)
                    panelRects[i] = cur
                }
            }
        }
        theme.codeBlockBackground.setFill()
        for box in panelRects where box.intersects(rect) && box.height > 1 {
            let panel = NSBezierPath(roundedRect: box,
                                     xRadius: theme.codeBlockCornerRadius,
                                     yRadius: theme.codeBlockCornerRadius)
            panel.fill()
            panel.lineWidth = 1
            theme.separatorColor.setStroke()
            panel.stroke()
        }

        // Quote panels + bars. The translucent background is painted ONCE per
        // quote group: per-paragraph boxes overlapped at the seams and the
        // doubled fill showed as darker bands. All boxes share x/width, so the
        // group panel is a plain vertical union of the trimmed paragraph rects.
        func makeCallout(_ type: String?) -> MarkdownCallout? {
            type.map { type in
                let style = MarkdownCalloutStyle(rawValue: type.lowercased()) ?? .note
                return MarkdownCallout(type: type, style: style, title: nil,
                                       markerRange: NSRange(location: 0, length: 0))
            }
        }
        func trimmedRect(_ entry: VisualQuoteEntry) -> NSRect? {
            guard var r = unionRect(for: entry.range) else { return nil }
            r.origin.y += entry.topTrim
            r.size.height = max(0, r.height - entry.topTrim - entry.bottomTrim)
            r.origin.x += entry.leadingIndent
            r.size.width = max(0, r.width - entry.leadingIndent)
            return r
        }
        var groupBoxes: [Int: (box: NSRect, calloutType: String?)] = [:]
        for entry in quoteEntries {
            guard let r = trimmedRect(entry) else { continue }
            if let existing = groupBoxes[entry.group] {
                groupBoxes[entry.group] = (existing.box.union(r),
                                           existing.calloutType ?? entry.calloutType)
            } else {
                groupBoxes[entry.group] = (r, entry.calloutType)
            }
        }
        for (_, groupBox) in groupBoxes {
            let box = groupBox.box.insetBy(dx: 0, dy: -3)
            guard box.intersects(rect), box.height > 1 else { continue }
            let callout = makeCallout(groupBox.calloutType)
            (callout?.color.withAlphaComponent(0.09) ?? theme.quoteBackground).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
        }
        for entry in quoteEntries {
            guard let rectUnion = trimmedRect(entry), rectUnion.intersects(rect) else { continue }
            let callout = makeCallout(entry.calloutType)
            // Plain quotes are quiet (plan 11.4): a thin neutral bar, no
            // accent, no wash. Callouts keep their typed color.
            (callout?.color.withAlphaComponent(0.78)
                ?? theme.secondaryColor.withAlphaComponent(0.45)).setFill()
            for level in 0..<entry.depth {
                NSRect(x: inset.width + entry.leadingIndent + CGFloat(level) * 18,
                       y: rectUnion.minY,
                       width: theme.quoteBarWidth, height: rectUnion.height).fill()
            }
            if entry.showsCalloutIcon, let callout,
               let image = NSImage(systemSymbolName: callout.iconSystemName,
                                   accessibilityDescription: callout.type) {
                let iconRect = NSRect(
                    x: inset.width + entry.leadingIndent
                        + CGFloat(max(0, entry.depth - 1)) * 18 + 5,
                    y: rectUnion.minY + 1,
                    width: 11,
                    height: 11)
                // Template symbols ignore the current fill color — tint via
                // SymbolConfiguration (same as drawBuiltInPluginIcon).
                let config = NSImage.SymbolConfiguration(pointSize: iconRect.height,
                                                         weight: .semibold)
                    .applying(.init(paletteColors: [callout.color]))
                let rendered = image.withSymbolConfiguration(config) ?? image
                rendered.draw(in: iconRect, from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
            }
        }

        // Bullets — depth cycles • (fill) / ◦ (stroke) / ▪ (square), like
        // Source. Neutral tone and a small dot (plan 11.4): the accent is
        // reserved for interactive marks, list bullets are furniture.
        for (range, depth) in bulletEntries {
            guard let marker = markerRect(forParagraph: range) else { continue }
            let radius = min(2, marker.height * 0.18)
            let center = NSPoint(x: marker.midX, y: marker.midY)
            let box = NSRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)
            switch depth % 3 {
            case 0:
                theme.secondaryColor.setFill()
                NSBezierPath(ovalIn: box).fill()
            case 1:
                theme.secondaryColor.setStroke()
                let ring = NSBezierPath(ovalIn: box)
                ring.lineWidth = max(1.25, radius * 0.35)
                ring.stroke()
            default:
                theme.secondaryColor.setFill()
                let side = radius * 1.7
                let square = NSRect(x: center.x - side / 2, y: center.y - side / 2,
                                    width: side, height: side)
                NSBezierPath(rect: square).fill()
            }
        }

        // Ordered numbers — tabular figures, secondary tone, right-aligned to
        // the marker column so units and tens don't dance (plan 11.4).
        for (range, _, number) in numberEntries {
            guard let marker = markerRect(forParagraph: range) else { continue }
            let numberSize = max(9, round(EditorSettings.shared.visual.fontSize * 0.75))
            let label = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: numberSize, weight: .medium),
                .foregroundColor: theme.secondaryColor,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: marker.maxX - size.width,
                                   y: marker.midY - size.height / 2))
        }

        // Task checkboxes
        for (range, _, done) in taskEntries {
            guard let box = markerRect(forParagraph: range) else { continue }
            let path = NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
            path.lineWidth = 1.5
            if done {
                theme.accentColor.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + 3.5, y: box.minY + box.height * 0.45))
                check.line(to: NSPoint(x: box.minX + box.width * 0.45, y: box.minY + box.height * 0.75))
                check.line(to: NSPoint(x: box.maxX - 3.5, y: box.minY + box.height * 0.25))
                check.lineWidth = 2
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                theme.secondaryColor.setStroke()
                path.stroke()
            }
        }


        // Built-in plugin list markers.
        for (range, _, token) in builtInPluginTaskEntries {
            guard let box = markerRect(forParagraph: range) else { continue }
            drawBuiltInPluginIcon(token.state.icon, label: token.state.label, in: box)
        }

        // Thematic breaks — a 1pt hairline (plan 11.4).
        for range in ruleRanges {
            guard let rectUnion = unionRect(for: range), rectUnion.intersects(rect) else { continue }
            theme.separatorColor.setFill()
            NSRect(x: inset.width, y: rectUnion.midY - 0.5, width: fullWidth, height: 1).fill()
        }

        // Large tables (drawn as virtualized read-only grids)
        for entry in tableIslandEntries {
            drawTableIsland(entry, dirty: rect, inset: inset, layoutManager: layoutManager)
        }

        // Row drag-reorder affordances: hover grip / dragged-row wash + gap line.
        if rowDrag == nil, let hover = hoverRowHandle {
            drawRowHandle(in: hover.frame, active: false)
        }
        if let drag = rowDrag, let first = drag.rowFrames.first {
            theme.accentColor.withAlphaComponent(0.08).setFill()
            if drag.sourceBody < drag.rowFrames.count {
                drag.rowFrames[drag.sourceBody].fill()
            }
            let minX = drag.rowFrames.map(\.minX).min() ?? first.minX
            let maxX = drag.rowFrames.map(\.maxX).max() ?? first.maxX
            let y = drag.gap < drag.rowFrames.count
                ? drag.rowFrames[drag.gap].minY
                : (drag.rowFrames.last?.maxY ?? first.maxY)
            theme.accentColor.setFill()
            NSRect(x: minX, y: y - 1, width: maxX - minX, height: 2).fill()
        }
    }


    private func drawBuiltInPluginIcon(_ icon: BuiltInPluginIcon, label: String,
                                       in box: NSRect) {
        switch icon {
        case .sfSymbol(let name):
            guard let image = NSImage(systemSymbolName: name,
                                      accessibilityDescription: label) else { return }
            let config = NSImage.SymbolConfiguration(pointSize: box.height, weight: .regular)
                .applying(.init(paletteColors: [theme.accentColor]))
            let rendered = image.withSymbolConfiguration(config) ?? image
            rendered.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                          respectFlipped: true, hints: nil)
        case .emoji(let value), .text(let value):
            let string = NSAttributedString(string: value, attributes: [
                .font: NSFont.systemFont(ofSize: box.height),
                .foregroundColor: theme.accentColor,
            ])
            let size = string.size()
            string.draw(at: NSPoint(x: box.midX - size.width / 2,
                                    y: box.midY - size.height / 2))
        }
    }

    /// Draws only the rows of a large table that intersect `dirty`. Row rects
    /// are derived from the island's first line-fragment origin plus per-row
    /// heights (arithmetic, not a full fragment walk), so cost scales with the
    /// viewport, not with table size. Rows taller than the base height hold
    /// word-wrapped cell text.
    private func drawTableIsland(_ entry: TableIslandEntry, dirty: NSRect, inset: NSSize,
                                 layoutManager: NSLayoutManager) {
        let totalLength = (string as NSString).length
        guard entry.range.location < totalLength, entry.columnEdges.count >= 2,
              !entry.rowHeights.isEmpty else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: entry.range,
                                                  actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return }
        let firstRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location,
                                                       effectiveRange: nil)
        let top = firstRect.minY + inset.height
        let grid = entry.grid
        let edges = entry.columnEdges
        let horizontalOffset = islandHorizontalOffsets[entry.range.location] ?? 0
        let left = (edges.first ?? inset.width) - horizontalOffset
        let right = (edges.last ?? inset.width) - horizontalOffset
        let width = right - left
        let bottom = top + entry.totalHeight

        let firstVisible = entry.rowIndex(atLocalY: dirty.minY - top)
        let lastVisible = entry.rowIndex(atLocalY: max(dirty.minY, dirty.maxY - 0.5) - top)
        guard firstVisible <= lastVisible else { return }

        let border = theme.separatorColor
        for i in firstVisible...lastVisible {
            let rowH = entry.rowHeight(i)
            let rowY = top + entry.rowOffset(i)
            let rowRect = NSRect(x: left, y: rowY, width: width, height: rowH)
            if i == 0 {
                // No header fill (plan 11.5) — the header reads through
                // weight and its heavier bottom rule.
                drawTableRow(grid.headers, in: rowRect, font: entry.headerFont,
                             color: theme.textColor, edges: edges, alignments: grid.alignments,
                             horizontalOffset: horizontalOffset)
            } else {
                let dataIndex = i - 1
                if dataIndex < grid.rows.count {
                    drawTableRow(grid.rows[dataIndex], in: rowRect, font: entry.font,
                                 color: theme.textColor, edges: edges, alignments: grid.alignments,
                                 horizontalOffset: horizontalOffset)
                }
            }
            border.setFill()
            let ruleHeight: CGFloat = i == 0 ? 1 : 0.5
            NSRect(x: left, y: rowY + rowH - ruleHeight, width: width,
                   height: ruleHeight).fill()   // row rule
        }

        // Vertical column separators are an interaction guide (plan 11.5):
        // visible while the pointer is inside this island or during a row
        // drag, invisible at rest — the resting grid is horizontal-only.
        let visTop = max(dirty.minY, top)
        let visBottom = min(dirty.maxY, bottom)
        if visBottom > visTop,
           hoveredIslandLocation == entry.range.location || rowDrag != nil {
            border.setFill()
            for x in edges {
                NSRect(x: x - horizontalOffset - 0.25, y: visTop, width: 0.5, height: visBottom - visTop).fill()
            }
        }
    }

    private func drawTableRow(_ cells: [String], in rowRect: NSRect, font: NSFont,
                              color: NSColor, edges: [CGFloat],
                              alignments: [TableGrid.Alignment], horizontalOffset: CGFloat) {
        let columns = edges.count - 1
        let pad: CGFloat = 8
        let elements = EditorSettings.shared.visual.elements
        let linkColor = elements.link.color ?? theme.accentColor
        let codeColor = elements.inlineCode.color ?? theme.inlineCodeColor
        let boldColor = elements.bold.color
        for c in 0..<columns where c < cells.count {
            let text = cells[c]
            guard !text.isEmpty else { continue }
            let cellW = edges[c + 1] - edges[c]
            guard cellW > 12 else { continue }
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            switch (c < alignments.count ? alignments[c] : .leading) {
            case .leading: para.alignment = .left
            case .center: para.alignment = .center
            case .trailing: para.alignment = .right
            }
            let drawRect = NSRect(x: edges[c] - horizontalOffset + pad,
                                  y: rowRect.minY + pad,
                                  width: cellW - pad * 2,
                                  height: max(1, rowRect.height - pad * 2))
            let attr = attributedTableCell(text, font: font, textColor: color,
                                           linkColor: linkColor, codeColor: codeColor,
                                           boldColor: boldColor, paragraphStyle: para)
            attr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// Renders (and caches) a table-island cell's inline markdown for drawing.
    private func attributedTableCell(_ markdown: String, font: NSFont,
                                     textColor: NSColor, linkColor: NSColor,
                                     codeColor: NSColor, boldColor: NSColor?,
                                     paragraphStyle: NSParagraphStyle) -> NSAttributedString {
        // Key omits colors that rarely change mid-scroll; theme changes rebuild
        // `tableIslandEntries` and clear the cache via didSet.
        let key = "\(font.fontName)|\(font.pointSize)|\(markdown)"
        if let cached = tableCellAttrCache[key] {
            // Paragraph style (alignment / truncate) is per-column — stamp on a copy.
            let copy = NSMutableAttributedString(attributedString: cached)
            copy.addAttribute(.paragraphStyle, value: paragraphStyle,
                              range: NSRange(location: 0, length: copy.length))
            return copy
        }
        let rendered = renderTableCellAttributed(markdown, baseFont: font,
                                                 textColor: textColor,
                                                 linkColor: linkColor,
                                                 codeColor: codeColor,
                                                 boldColor: boldColor,
                                                 pluginSnapshot: builtInPluginSnapshot)
        tableCellAttrCache[key] = rendered
        let copy = NSMutableAttributedString(attributedString: rendered)
        if copy.length > 0 {
            copy.addAttribute(.paragraphStyle, value: paragraphStyle,
                              range: NSRange(location: 0, length: copy.length))
        }
        return copy
    }
}
