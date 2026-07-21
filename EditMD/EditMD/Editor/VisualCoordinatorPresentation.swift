import AppKit

// Presentation pass for Visual mode: derives fonts/colors/paragraph styles from
// the md.* attributes and registers drawn-decoration entries on the text view
// (bullets, quotes, code panels, table islands, YAML card, images). Split out of
// VisualTextView.swift when it passed 2600 lines; the editing core stays there.

extension VisualMarkdownView.Coordinator {
    /// Absolute x edges (left→right, including the right edge) for a large
    /// table's columns. Widths come from the header plus a sample of body
    /// rows (measuring every row of a 9000-row table would be wasteful),
    /// clamped to a sane min/max so one long cell can't blow out the grid.
    /// Long cells cap at `maxWidth` and wrap vertically instead of stretching
    /// the column.
    private func tableColumnEdges(_ grid: TableGrid, font: NSFont, headerFont: NSFont,
                                  originX: CGFloat,
                                  pluginSnapshot: BuiltInPluginSnapshot) -> [CGFloat] {
        let columns = grid.columnCount
        guard columns > 0 else { return [originX] }
        let cellPadding: CGFloat = 12   // 6pt on each side
        let minWidth: CGFloat = 44
        let maxWidth: CGFloat = 260
        // Measure *rendered* inline markdown (not raw `**bold**` markers) so
        // column widths match what drawTableRow actually paints.
        func measure(_ s: String, _ f: NSFont) -> CGFloat {
            renderTableCellAttributed(s, baseFont: f,
                                      textColor: .labelColor,
                                      linkColor: .linkColor,
                                      codeColor: .systemOrange,
                                      pluginSnapshot: pluginSnapshot).size().width
        }
        var widths = [CGFloat](repeating: minWidth, count: columns)
        for (c, header) in grid.headers.enumerated() where c < columns {
            widths[c] = max(widths[c], measure(header, headerFont) + cellPadding)
        }
        for row in grid.rows.prefix(60) {
            for (c, cell) in row.enumerated() where c < columns {
                widths[c] = max(widths[c], measure(cell, font) + cellPadding)
            }
        }
        var edges: [CGFloat] = [originX]
        for w in widths { edges.append((edges.last ?? originX) + min(w, maxWidth)) }
        return edges
    }

    /// Per-row heights for an island table. Base height fits one line of body
    /// text; a cell that exceeds its column width grows the whole row so the
    /// text can wrap. Cheap path: if the raw string already fits the cell
    /// width under the body font, skip the full markdown measure (markers only
    /// make rendered text shorter).
    private func tableIslandRowHeights(_ grid: TableGrid, columnEdges: [CGFloat],
                                       bodyFont: NSFont, headerFont: NSFont,
                                       baseRowHeight: CGFloat,
                                       pluginSnapshot: BuiltInPluginSnapshot) -> [CGFloat] {
        let columns = grid.columnCount
        guard columns > 0, columnEdges.count >= columns + 1 else {
            return [baseRowHeight]
        }
        let padH: CGFloat = 12
        let padV: CGFloat = 12

        func cellHeight(text: String, font: NSFont, column: Int) -> CGFloat {
            guard !text.isEmpty, column < columns else { return baseRowHeight }
            let textW = max(8, columnEdges[column + 1] - columnEdges[column] - padH)
            // Fast reject: raw string narrower than the cell almost always fits
            // after markdown markers are stripped (markers only shorten text).
            let rawW = (text as NSString).size(withAttributes: [.font: font]).width
            if rawW <= textW + 0.5 { return baseRowHeight }

            let attr = renderTableCellAttributed(text, baseFont: font,
                                                 textColor: .labelColor,
                                                 linkColor: .linkColor,
                                                 codeColor: .systemOrange,
                                                 pluginSnapshot: pluginSnapshot)
            if attr.length == 0 { return baseRowHeight }
            if attr.size().width <= textW + 0.5 {
                return baseRowHeight
            }
            let bounds = attr.boundingRect(
                with: NSSize(width: textW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return max(baseRowHeight, ceil(bounds.height) + padV)
        }

        var heights: [CGFloat] = []
        heights.reserveCapacity(grid.rows.count + 1)

        var headerH = baseRowHeight
        for c in 0..<columns {
            let text = c < grid.headers.count ? grid.headers[c] : ""
            headerH = max(headerH, cellHeight(text: text, font: headerFont, column: c))
        }
        heights.append(headerH)

        for row in grid.rows {
            var h = baseRowHeight
            for c in 0..<columns {
                let text = c < row.count ? row[c] : ""
                h = max(h, cellHeight(text: text, font: bodyFont, column: c))
            }
            heights.append(h)
        }
        return heights
    }

    // MARK: Presentation (derived visuals + decoration entries)

    func applyPresentation() {
        guard let textView, let storage = textView.textStorage else { return }
        let nsText = storage.string as NSString
        var bullets: [(range: NSRange, depth: Int)] = []
        var numbers: [(range: NSRange, depth: Int, number: Int)] = []
        var tasks: [(range: NSRange, depth: Int, done: Bool)] = []
        var pluginTasks: [(range: NSRange, depth: Int,
                           token: BuiltInPluginTokenPayload)] = []
        var quotes: [VisualQuoteEntry] = []
        var seenCalloutGroups = Set<Int>()
        var codeGroups: [Int: NSRange] = [:]
        var codeLanguages: [Int: String] = [:]
        var codeGroupIndents: [Int: CGFloat] = [:]
        var ruleRanges: [NSRange] = []
        var tableIslands: [TableIslandEntry] = []

        var orderedCounters: [String: Int] = [:]
        var lastListGroupDepth: (group: Int, depth: Int)? = nil
        // One shared NSTextTable per table group — cells of one table must
        // reference the same instance or layout falls apart.
        var textTables: [Int: NSTextTable] = [:]
        let theme = textView.theme
        let pluginSnapshot = builtInPluginSnapshot

        let spacingScale = EditorSettings.shared.visualSpacing.scale
        // Pre-scan: which paragraphs are first/last line of each code group,
        // so margin can be applied in the same pass as other styles (a
        // follow-up attribute write was easy to lose / override).
        var codeGroupFirst = Set<Int>()  // paragraph.location
        var codeGroupLast = Set<Int>()
        var codeGroupsTmp: [Int: (first: Int, last: Int)] = [:]  // group → (firstLoc, lastLoc)
        // Blank source lines are collapsed in Visual, so the gap between
        // neighboring blocks of different kinds comes only from paragraph
        // spacing. The scan records what each paragraph is, and the main pass
        // opens up run boundaries (list end, quote edges, table edges) by
        // looking at the neighbors.
        struct ParaScan {
            var isList = false; var isTable = false; var isHeading = false
            var quoteGroup: Int?
        }
        var paraScan: [ParaScan] = []
        var scanLoc = 0
        while scanLoc < nsText.length {
            let para = nsText.paragraphRange(for: NSRange(location: scanLoc, length: 0))
            defer { scanLoc = NSMaxRange(para) == scanLoc ? scanLoc + 1 : NSMaxRange(para) }
            guard let block = storage.attribute(.mdBlock, at: para.location,
                                                effectiveRange: nil) as? MDBlock else {
                paraScan.append(ParaScan())
                continue
            }
            var info = ParaScan()
            info.isList = isListKind(block.kind)
            if case .tableCell = block.kind { info.isTable = true }
            if case .heading = block.kind { info.isHeading = true }
            info.quoteGroup = block.quoteDepth > 0 ? block.quoteGroup : nil
            paraScan.append(info)
            guard case .codeBlock = block.kind else { continue }
            if var ends = codeGroupsTmp[block.group] {
                ends.last = para.location
                codeGroupsTmp[block.group] = ends
            } else {
                codeGroupsTmp[block.group] = (para.location, para.location)
            }
        }
        for ends in codeGroupsTmp.values {
            codeGroupFirst.insert(ends.first)
            codeGroupLast.insert(ends.last)
        }

        // Margin = white between cards. Independent of panel padding.
        // Must be large enough that even if pad steals ~6pt each side, a
        // clear gap remains (and neighboring lines stay unpainted). Works in
        // tandem with drawBackground's clamp margin (18): glyph-to-glyph gap
        // is THIS value, the panel edge sits 18pt from the neighboring text,
        // and the difference (~14pt) becomes the panel's inner top/bottom pad.
        let codeBlockMargin: CGFloat = max(32, 32 * spacingScale)

        isMutating = true
        storage.beginEditing()
        var location = 0
        var paraIndex = 0
        while location < nsText.length {
            let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
            defer {
                location = NSMaxRange(paragraph) == location ? location + 1 : NSMaxRange(paragraph)
                paraIndex += 1
            }
            var blockValue = storage.attribute(.mdBlock, at: paragraph.location,
                                               effectiveRange: nil) as? MDBlock
                ?? MDBlock(kind: .paragraph)

            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 8 * spacingScale
            var markerIndent: CGFloat = 0
            var isTableIsland = false
            // Document-leading block: top gap is `textContainerInset.height`
            // (Settings ▸ Vertical). Extra paragraphSpacingBefore here would
            // stack on insetV and make Vertical look broken at 0.
            let isDocumentStart = paragraph.location == 0

            switch blockValue.kind {
            case .heading(let level):
                // Plan 11.2: a heading clings to ITS section — before:after
                // ≈ 3:1. A heading directly after another heading halves the
                // top gap so consecutive headings read as one cluster.
                let before: CGFloat
                let after: CGFloat
                switch level {
                case 1: before = 26; after = 8
                case 2: before = 22; after = 7
                case 3: before = 16; after = 6
                default: before = 12; after = 5
                }
                let prevIsHeading = paraIndex > 0 && paraIndex <= paraScan.count
                    && paraScan[paraIndex - 1].isHeading
                style.paragraphSpacingBefore = isDocumentStart
                    ? 0
                    : before * (prevIsHeading ? 0.5 : 1) * spacingScale
                style.paragraphSpacing = after * spacingScale
            case .bulletItem(let depth):
                markerIndent = 24 + CGFloat(depth) * 22
                bullets.append((paragraph, depth))
                style.paragraphSpacing = 3 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .taskItem(let depth, let done):
                markerIndent = 24 + CGFloat(depth) * 22
                tasks.append((paragraph, depth, done))
                style.paragraphSpacing = 3 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .builtInPluginTaskItem(let depth, let token):
                markerIndent = 24 + CGFloat(depth) * 22
                pluginTasks.append((paragraph, depth, token))
                style.paragraphSpacing = 3 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .orderedItem(let depth, _):
                markerIndent = 28 + CGFloat(depth) * 22
                // Renumber sequentially within the same group+depth run.
                let key = "\(blockValue.group)/\(depth)"
                let next: Int
                if let last = lastListGroupDepth, last.group == blockValue.group {
                    next = (orderedCounters[key] ?? 0) + 1
                } else {
                    orderedCounters = [:]
                    if case .orderedItem(_, let n) = blockValue.kind { next = max(1, n) } else { next = 1 }
                }
                orderedCounters[key] = next
                if case .orderedItem(let d, let n) = blockValue.kind, n != next {
                    blockValue.kind = .orderedItem(depth: d, number: next)
                    let stamp = paragraph.length > 0 ? paragraph
                        : NSRange(location: paragraph.location,
                                  length: min(1, nsText.length - paragraph.location))
                    if stamp.length > 0 {
                        storage.addAttribute(.mdBlock, value: blockValue, range: stamp)
                    }
                }
                numbers.append((paragraph, depth, {
                    if case .orderedItem(_, let n) = blockValue.kind { return n }
                    return 1
                }()))
                style.paragraphSpacing = 3 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .listContinuation(let indent):
                markerIndent = 24 + CGFloat(max(0, indent - 2) / 4) * 22
            case .codeBlock(let language):
                markerIndent = 10
                // Tight lines inside one fence. Margin only on group edges.
                style.paragraphSpacing = 0
                style.paragraphSpacingBefore = 0
                if codeGroupFirst.contains(paragraph.location), !isDocumentStart {
                    style.paragraphSpacingBefore = codeBlockMargin
                }
                if codeGroupLast.contains(paragraph.location) {
                    style.paragraphSpacing = codeBlockMargin
                }
                let existing = codeGroups[blockValue.group]
                codeGroups[blockValue.group] = existing.map { NSUnionRange($0, paragraph) } ?? paragraph
                codeLanguages[blockValue.group] = language
                codeGroupIndents[blockValue.group] = listIndentPoints(blockValue.listIndent)
            case .thematicBreak:
                ruleRanges.append(paragraph)
            case .tableCell(let row, let column, let columns, let alignment):
                let table: NSTextTable
                if let existing = textTables[blockValue.group] {
                    table = existing
                } else {
                    table = NSTextTable()
                    table.numberOfColumns = columns
                    table.setContentWidth(100, type: .percentageValueType)
                    textTables[blockValue.group] = table
                }
                let cell = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                            startingColumn: column, columnSpan: 1)
                cell.setBorderColor(theme.separatorColor)
                cell.setWidth(0.5, type: .absoluteValueType, for: .border)
                cell.setWidth(6, type: .absoluteValueType, for: .padding)
                if row == 0 {
                    cell.backgroundColor = NSColor(white: 0.5, alpha: 0.08)
                }
                style.textBlocks = [cell]
                style.paragraphSpacing = 0
                switch alignment {
                case 2: style.alignment = .center
                case 3: style.alignment = .right
                default: break
                }
            case .raw(let rawText):
                // A large table stored as a raw island (renderTable falls
                // back to `.raw` above maxNativeTableCells). Draw it as a
                // virtualized grid instead of monospace pipe text: hide the
                // text, pin a fixed row height, register a draw entry. Other
                // raw islands (HTML) keep the monospace fallback.
                if let grid = parseGFMTable(rawText) {
                    let bodyFont = visualStyle.font(for: [], blockKind: .paragraph)
                    let headerFont = visualStyle.font(for: .bold, blockKind: .paragraph)
                    let baseRowHeight = ceil(bodyFont.ascender - bodyFont.descender) + 12
                    let edges = tableColumnEdges(grid, font: bodyFont, headerFont: headerFont,
                                                 originX: textView.textContainerInset.width,
                                                 pluginSnapshot: pluginSnapshot)
                    let rowHeights = tableIslandRowHeights(
                        grid, columnEdges: edges, bodyFont: bodyFont, headerFont: headerFont,
                        baseRowHeight: baseRowHeight, pluginSnapshot: pluginSnapshot)
                    // One layout line reserves the full island height; the grid
                    // is painted in drawBackground with per-row heights (wrap).
                    let totalH = max(baseRowHeight, tableIslandTotalHeight(rowHeights))
                    style.minimumLineHeight = totalH
                    style.maximumLineHeight = totalH
                    style.lineBreakMode = .byClipping
                    style.paragraphSpacing = 8 * spacingScale
                    tableIslands.append(TableIslandEntry(range: paragraph, grid: grid,
                                                         columnEdges: edges, rowHeights: rowHeights,
                                                         font: bodyFont, headerFont: headerFont))
                    isTableIsland = true
                } else {
                    markerIndent = 10
                }
            case .paragraph:
                break
            }

            if !isListKind(blockValue.kind) { lastListGroupDepth = nil }

            // A non-item block nested in a list item (quote, code fence,
            // island) indents to the item's content column, like Preview.
            markerIndent += listIndentPoints(blockValue.listIndent)

            if blockValue.quoteDepth > 0 {
                markerIndent += CGFloat(blockValue.quoteDepth) * 18
                let showsCalloutIcon = blockValue.calloutType != nil
                    && seenCalloutGroups.insert(blockValue.quoteGroup).inserted
                quotes.append(VisualQuoteEntry(
                    range: paragraph,
                    depth: blockValue.quoteDepth,
                    group: blockValue.quoteGroup,
                    leadingIndent: listIndentPoints(blockValue.listIndent),
                    calloutType: blockValue.calloutType,
                    showsCalloutIcon: showsCalloutIcon))
            }
            // Run-boundary margins (see paraScan above). `max` so blocks that
            // already carry a bigger margin (headings, code panels) keep it.
            let prevScan = paraIndex > 0 && paraIndex <= paraScan.count ? paraScan[paraIndex - 1] : nil
            let nextScan = paraIndex + 1 < paraScan.count ? paraScan[paraIndex + 1] : nil
            let isTableCellKind: Bool
            if case .tableCell = blockValue.kind { isTableCellKind = true } else { isTableCellKind = false }
            if isListKind(blockValue.kind), nextScan?.isList != true {
                style.paragraphSpacing = max(style.paragraphSpacing, 8 * spacingScale)
            }
            if !isTableCellKind, nextScan?.isTable == true {
                style.paragraphSpacing = max(style.paragraphSpacing, 8 * spacingScale)
            }
            if !isTableCellKind, prevScan?.isTable == true {
                style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 8 * spacingScale)
            }
            if blockValue.quoteDepth > 0 {
                // Boundaries are per quote GROUP: two adjacent but distinct
                // quotes must separate, not merge into one panel.
                let startsRun = prevScan?.quoteGroup != blockValue.quoteGroup
                let endsRun = nextScan?.quoteGroup != blockValue.quoteGroup
                if startsRun, !isDocumentStart {
                    style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 4 * spacingScale)
                }
                if endsRun {
                    style.paragraphSpacing = max(style.paragraphSpacing, 8 * spacingScale)
                }
                // The entry for this paragraph was appended above; keep its
                // painted panel off the edge spacing (see VisualQuoteEntry).
                if !quotes.isEmpty {
                    if startsRun {
                        quotes[quotes.count - 1].topTrim = style.paragraphSpacingBefore
                    }
                    if endsRun {
                        quotes[quotes.count - 1].bottomTrim = style.paragraphSpacing
                    }
                }
            }
            // Display-math block ($$…$$ paragraph): the tall attachment glyph
            // eats the visual gap, so give it table-like margins. Preview
            // already spaces display math this way.
            var isDisplayMath = false
            if case .paragraph = blockValue.kind, paragraph.length > 0,
               storage.attribute(.mdMath, at: paragraph.location, effectiveRange: nil) != nil {
                if let tex = storage.attribute(.mdMathTex, at: paragraph.location,
                                               effectiveRange: nil) as? String {
                    isDisplayMath = tex.hasPrefix("$$")
                } else {
                    isDisplayMath = nsText.substring(with: paragraph).hasPrefix("$$")
                }
            }
            if isDisplayMath {
                if !isDocumentStart {
                    style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 8 * spacingScale)
                }
                style.paragraphSpacing = max(style.paragraphSpacing, 8 * spacingScale)
            }

            // Reading leading (plan 11.1): CSS-style ratio over the element's
            // FONT SIZE (body 15 → 20pt line), enforced as a per-line floor —
            // `lineHeightMultiple` would scale the natural line height (already
            // ~1.2× the size) and overshoot. A floor also keeps mixed runs
            // (smaller inline code, links) from breathing between lines.
            // Paragraphs carrying attachment glyphs (images, rendered math,
            // thematic breaks — U+FFFC) keep the font default: the glyph
            // defines its own height. Headings get their own leading in 11.2,
            // table cells in 11.5.
            let lineRatio: CGFloat
            let lineBase: CGFloat
            var clampLineHeight = false
            switch blockValue.kind {
            case .codeBlock:
                lineRatio = 1.2
                lineBase = visualStyle.baseSize - 1
            case .raw:
                lineRatio = isTableIsland ? 0 : 1.2
                lineBase = visualStyle.baseSize - 1
            case .heading(let level):
                // Headings are TIGHTER than natural (a multi-line H1 must not
                // look loose) — clamp from both sides (plan 11.2).
                lineRatio = level <= 3 ? 1.12 : 1.18
                lineBase = visualStyle.headingSize(level)
                clampLineHeight = true
            case .tableCell, .thematicBreak:
                lineRatio = 0
                lineBase = 0
            default:
                lineRatio = isDisplayMath ? 0 : 1.3
                lineBase = visualStyle.baseSize
            }
            if lineRatio > 0,
               nsText.range(of: mdObjectChar, options: .literal, range: paragraph)
                   .location == NSNotFound {
                style.minimumLineHeight = round(lineBase * lineRatio)
                if clampLineHeight {
                    style.maximumLineHeight = round(lineBase * lineRatio)
                }
            }

            style.firstLineHeadIndent = markerIndent
            style.headIndent = markerIndent

            if paragraph.length > 0 {
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                if isTableIsland {
                    // The pipe text only reserves layout height; the grid is
                    // drawn in drawBackground. Hide the characters.
                    storage.addAttribute(.foregroundColor, value: NSColor.clear,
                                         range: paragraph)
                } else {
                    applyDerivedInlineDecorations(storage, paragraph: paragraph, block: blockValue)
                }
            }
        }

        // Apply token colours after the normal presentation pass so code panels,
        // paragraph layout and all md.* metadata remain owned by this editor.
        // One request per group preserves multi-line strings/comments.
        if EditorSettings.shared.general.syntaxHighlighting {
            let keyPrefix = "visual:\(parent.fileURL?.path ?? "untitled")#"
            for (group, range) in codeGroups {
                CodeSyntaxHighlighter.shared.apply(to: storage, codeRange: range,
                                                   language: codeLanguages[group],
                                                   stableKey: keyPrefix + String(group))
            }
        }

        attachImages(storage)
        storage.endEditing()
        isMutating = false

        // Do NOT ensureLayout(for: whole container) here — on large docs
        // (Claude.md ~100k) that forces full-document layout on every
        // keystroke/presentation pass and freezes the UI. TextKit lays out
        // as needed for display; code-panel clamp uses whatever fragments
        // exist for the dirty rect.

        textView.bulletEntries = bullets
        textView.numberEntries = numbers
        textView.taskEntries = tasks
        textView.builtInPluginTaskEntries = pluginTasks
        textView.builtInPluginSnapshot = pluginSnapshot
        textView.quoteEntries = quotes
        textView.codePanelEntries = codeGroups.map { group, range in
            (range: range, leadingIndent: codeGroupIndents[group] ?? 0)
        }
        textView.ruleRanges = ruleRanges
        textView.tableIslandEntries = tableIslands
        textView.needsDisplay = true
    }

    /// Display indent for a block nested in a list item, from the item's raw
    /// space indent (`MDBlock.listIndent`). Matches the `.listContinuation`
    /// formula so nested blocks align with the item's own content column.
    private func listIndentPoints(_ spaces: Int) -> CGFloat {
        spaces <= 0 ? 0 : 24 + CGFloat(max(0, spaces - 2) / 4) * 22
    }

    private func isListKind(_ kind: MDBlock.Kind) -> Bool {
        switch kind {
        case .bulletItem, .orderedItem, .taskItem, .builtInPluginTaskItem, .listContinuation:
            return true
        default:
            return false
        }
    }

    /// Obsidian-style highlight fill — matches Preview `mark` CSS.
    private static let highlightMarkColor = NSColor(name: nil) { appearance in
        switch appearance.name {
        case .darkAqua, .vibrantDark,
             .accessibilityHighContrastDarkAqua,
             .accessibilityHighContrastVibrantDark:
            return NSColor(red: 1, green: 0.77, blue: 0, alpha: 0.35)
        default:
            return NSColor(red: 1, green: 0.83, blue: 0, alpha: 0.45)
        }
    }

    /// Strikethrough and colors are derived: .mdInline strike (and plugin
    /// tokens that opt in) get strikethrough; done tasks fade to the
    /// secondary tone WITHOUT strikethrough (plan 11.3); links get the link
    /// color — underlined only under Increase Contrast, the interactive
    /// affordance states live in `VisualNSTextView` as temporary attributes.
    private func applyDerivedInlineDecorations(_ storage: NSTextStorage,
                                               paragraph: NSRange, block: MDBlock) {
        var isDone = false
        var strikeDone = false
        if case .taskItem(_, true) = block.kind { isDone = true }
        if case .builtInPluginTaskItem(_, let token) = block.kind,
           token.state.strikethrough { isDone = true; strikeDone = true }
        var isHeaderCell = false
        if case .tableCell(0, _, _, _) = block.kind { isHeaderCell = true }
        var headingLevel = 0
        if case .heading(let level) = block.kind { headingLevel = level }
        var isBodyCode = false
        if case .codeBlock = block.kind { isBodyCode = true }
        if case .raw = block.kind { isBodyCode = true }
        let isQuote = block.quoteDepth > 0
        // Colors are honest here: theme (preset + General overrides) plus
        // per-element overrides — no hardcoded system colors.
        let theme = textView?.theme ?? .editorDefault
        let elements = EditorSettings.shared.visual.elements

        storage.enumerateAttributes(in: paragraph) { attrs, range, _ in
            let styles = MDInlineStyle(rawValue: attrs[.mdInline] as? Int ?? 0)
            // Always re-derive font from block kind so demoting a heading
            // to body (or promoting body → H1) updates size/weight even on
            // runs that never carried .mdInline.
            var fontStyles: MDInlineStyle = isHeaderCell ? styles.union(.bold) : styles
            // Math runs read as raw TeX — monospace makes the syntax legible.
            if attrs[.mdMath] != nil { fontStyles.insert(.code) }
            storage.addAttribute(.font,
                                 value: self.visualStyle.font(for: fontStyles, blockKind: block.kind),
                                 range: range)
            let strike = styles.contains(.strike) || strikeDone
            if strike {
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: range)
            }
            if attrs[.mdMath] != nil {
                // Math runs show raw TeX (delimiters visible) tinted like
                // inline code, but without the code background wash.
                storage.addAttribute(.foregroundColor,
                                     value: elements.inlineCode.color ?? theme.inlineCodeColor,
                                     range: range)
                storage.removeAttribute(.backgroundColor, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
            } else if attrs[.mdWikiLink] != nil || attrs[.mdLink] != nil {
                // Links (and wiki-links; navigation is Cmd+click) carry no
                // permanent underline — color plus the caret/⌘-hover states
                // in the view. Increase Contrast brings the underline back:
                // color alone may not separate from body text.
                storage.addAttribute(.foregroundColor,
                                     value: elements.link.color ?? theme.accentColor,
                                     range: range)
                if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
                    storage.addAttribute(.underlineStyle,
                                         value: NSUnderlineStyle.single.rawValue,
                                         range: range)
                } else {
                    storage.removeAttribute(.underlineStyle, range: range)
                }
                storage.removeAttribute(.backgroundColor, range: range)
            } else if isDone {
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                     range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            } else if styles.contains(.code) {
                storage.addAttributes([
                    .foregroundColor: elements.inlineCode.color ?? theme.inlineCodeColor,
                    .backgroundColor: theme.inlineCodeBackground,
                ], range: range)
                storage.removeAttribute(.underlineStyle, range: range)
            } else {
                let color: NSColor
                if headingLevel > 0 {
                    // H6 defaults to the secondary tone (plan 11.2) — same
                    // size as body, so the hierarchy reads through color.
                    let headingDefault = headingLevel == 6
                        ? theme.secondaryColor : theme.textColor
                    color = elements.heading(headingLevel).color ?? headingDefault
                } else if isBodyCode {
                    color = theme.secondaryColor
                } else if isQuote {
                    color = elements.quote.color ?? theme.textColor
                } else if styles.contains(.bold), let bold = elements.bold.color {
                    color = bold
                } else {
                    color = theme.textColor
                }
                storage.addAttribute(.foregroundColor, value: color, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                if styles.contains(.highlight) {
                    // Match Preview `<mark>` (light / dark).
                    storage.addAttribute(.backgroundColor,
                                         value: Self.highlightMarkColor,
                                         range: range)
                } else {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
        }
    }

    // MARK: Images

    /// Attaches NSTextAttachments to image placeholders (U+FFFC + .mdImage).
    private func attachImages(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return }
        storage.enumerateAttribute(.mdImage, in: full) { value, range, _ in
            guard let info = value as? [String: String] else { return }
            if storage.attribute(.attachment, at: range.location, effectiveRange: nil) != nil {
                return
            }
            storage.addAttribute(.attachment,
                                 value: attachment(forSource: info["src"] ?? ""),
                                 range: range)
        }
    }

    private func attachment(forSource src: String) -> NSTextAttachment {
        if let cached = imageAttachments[src] { return cached }
        let result = NSTextAttachment()
        if let remote = remoteImageURL(src) {
            // Remote images load off-main; show a placeholder now and fill the
            // same attachment in when the download lands (or a cached copy).
            if let cachedImage = RemoteImageCache.shared.cached(remote) {
                setAttachmentImage(cachedImage, on: result)
            } else {
                setPlaceholder(on: result, src: src)
                loadRemoteImage(remote, into: result, src: src)
            }
        } else if let url = resolveImageURL(src), let image = NSImage(contentsOf: url),
                  image.size.width > 0 {
            setAttachmentImage(image, on: result)
        } else {
            // Missing local file: visible placeholder instead of nothing.
            setPlaceholder(on: result, src: src)
        }
        imageAttachments[src] = result
        return result
    }

    /// Sizes the attachment to the image, capped at a comfortable reading width.
    private func setAttachmentImage(_ image: NSImage, on attachment: NSTextAttachment) {
        attachment.image = image
        let maxWidth: CGFloat = 420
        let scale = image.size.width > maxWidth ? maxWidth / image.size.width : 1
        attachment.bounds = CGRect(x: 0, y: 0,
                                   width: image.size.width * scale,
                                   height: image.size.height * scale)
    }

    private func setPlaceholder(on attachment: NSTextAttachment, src: String) {
        attachment.image = NSImage(systemSymbolName: "photo", accessibilityDescription: src)
        attachment.bounds = CGRect(x: 0, y: -3, width: 18, height: 15)
    }

    /// Kicks off an async download and, on completion, swaps the placeholder for
    /// the real image and reflows just that image's runs. Guarded so a late
    /// callback after a re-render (which reuses the cached attachment) or an
    /// evicted src does nothing.
    private func loadRemoteImage(_ url: URL, into attachment: NSTextAttachment, src: String) {
        RemoteImageCache.shared.load(url) { [weak self, weak attachment] image in
            guard let self, let attachment, let image, image.size.width > 0 else { return }
            guard self.imageAttachments[src] === attachment else { return }
            self.setAttachmentImage(image, on: attachment)
            self.invalidateImageLayout(src: src)
        }
    }

    /// Reflows the runs carrying image `src` after its attachment resized from
    /// placeholder to full image (per-image, not a whole-document relayout).
    private func invalidateImageLayout(src: String) {
        guard let textView, let storage = textView.textStorage,
              let layoutManager = textView.layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.mdImage, in: full) { value, range, _ in
            guard (value as? [String: String])?["src"] == src else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    /// A remote (`http(s)`) image source, or nil for a document-relative path.
    private func remoteImageURL(_ src: String) -> URL? {
        guard let url = URL(string: src), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func resolveImageURL(_ src: String) -> URL? {
        guard URL(string: src)?.scheme == nil, let fileURL = parent.fileURL else { return nil }
        let baseDir = fileURL.pathExtension == "textbundle"
            ? fileURL
            : fileURL.deletingLastPathComponent()
        let path = src.removingPercentEncoding ?? src
        return baseDir.appendingPathComponent(path).standardizedFileURL
    }

}
