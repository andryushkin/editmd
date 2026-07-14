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

    // MARK: Presentation (derived visuals + decoration entries)

    func applyPresentation() {
        guard let textView, let storage = textView.textStorage else { return }
        let nsText = storage.string as NSString
        var bullets: [(range: NSRange, depth: Int)] = []
        var numbers: [(range: NSRange, depth: Int, number: Int)] = []
        var tasks: [(range: NSRange, depth: Int, done: Bool)] = []
        var pluginTasks: [(range: NSRange, depth: Int,
                           token: BuiltInPluginTokenPayload)] = []
        var quotes: [(range: NSRange, depth: Int)] = []
        var codeGroups: [Int: NSRange] = [:]
        var codeLanguages: [Int: String] = [:]
        var ruleRanges: [NSRange] = []
        var headingDividers: [NSRange] = []
        var tableIslands: [TableIslandEntry] = []
        var propertiesPanels: [NSRange] = []

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
        var scanLoc = 0
        while scanLoc < nsText.length {
            let para = nsText.paragraphRange(for: NSRange(location: scanLoc, length: 0))
            defer { scanLoc = NSMaxRange(para) == scanLoc ? scanLoc + 1 : NSMaxRange(para) }
            guard let block = storage.attribute(.mdBlock, at: para.location,
                                                effectiveRange: nil) as? MDBlock,
                  case .codeBlock = block.kind else { continue }
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
        while location < nsText.length {
            let paragraph = nsText.paragraphRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(paragraph) == location ? location + 1 : NSMaxRange(paragraph) }
            var blockValue = storage.attribute(.mdBlock, at: paragraph.location,
                                               effectiveRange: nil) as? MDBlock
                ?? MDBlock(kind: .paragraph)

            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6 * spacingScale
            var markerIndent: CGFloat = 0
            var isTableIsland = false
            var isFrontmatter = false
            // Document-leading block: top gap is `textContainerInset.height`
            // (Settings ▸ Vertical). Extra paragraphSpacingBefore here would
            // stack on insetV and make Vertical look broken at 0.
            let isDocumentStart = paragraph.location == 0

            switch blockValue.kind {
            case .heading(let level):
                style.paragraphSpacingBefore = isDocumentStart
                    ? 0
                    : (level <= 2 ? 14 : 10) * spacingScale
                style.paragraphSpacing = 8 * spacingScale
                if level <= 2 { headingDividers.append(paragraph) }
            case .bulletItem(let depth):
                markerIndent = 24 + CGFloat(depth) * 22
                bullets.append((paragraph, depth))
                style.paragraphSpacing = 2 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .taskItem(let depth, let done):
                markerIndent = 24 + CGFloat(depth) * 22
                tasks.append((paragraph, depth, done))
                style.paragraphSpacing = 2 * spacingScale
                lastListGroupDepth = (blockValue.group, depth)
            case .builtInPluginTaskItem(let depth, let token):
                markerIndent = 24 + CGFloat(depth) * 22
                pluginTasks.append((paragraph, depth, token))
                style.paragraphSpacing = 2 * spacingScale
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
                style.paragraphSpacing = 2 * spacingScale
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
                    let rowHeight = ceil(bodyFont.ascender - bodyFont.descender) + 12
                    style.minimumLineHeight = rowHeight
                    style.maximumLineHeight = rowHeight
                    style.lineBreakMode = .byClipping
                    style.paragraphSpacing = 8 * spacingScale
                    let edges = tableColumnEdges(grid, font: bodyFont, headerFont: headerFont,
                                                 originX: textView.textContainerInset.width,
                                                 pluginSnapshot: pluginSnapshot)
                    tableIslands.append(TableIslandEntry(range: paragraph, grid: grid,
                                                         columnEdges: edges, rowHeight: rowHeight,
                                                         font: bodyFont, headerFont: headerFont))
                    isTableIsland = true
                } else if frontmatterRange(in: rawText) != nil {
                    // Frontmatter properties card: a subtle panel (drawn in
                    // drawBackground) with colored keys (colorYAMLIsland).
                    // Leading frontmatter sits flush under the strip via insetV.
                    style.paragraphSpacingBefore = isDocumentStart ? 0 : 4 * spacingScale
                    style.paragraphSpacing = 12 * spacingScale
                    markerIndent = 14
                    propertiesPanels.append(paragraph)
                    isFrontmatter = true
                } else {
                    markerIndent = 10
                }
            case .paragraph:
                break
            }

            if !isListKind(blockValue.kind) { lastListGroupDepth = nil }

            if blockValue.quoteDepth > 0 {
                markerIndent += CGFloat(blockValue.quoteDepth) * 18
                quotes.append((paragraph, blockValue.quoteDepth))
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
                } else if isFrontmatter {
                    colorYAMLIsland(storage, paragraph: paragraph)
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
        textView.codePanelRanges = Array(codeGroups.values)
        textView.ruleRanges = ruleRanges
        textView.headingDividerRanges = headingDividers
        textView.tableIslandEntries = tableIslands
        textView.propertiesPanelRanges = propertiesPanels
        textView.needsDisplay = true
    }

    /// Colors a frontmatter island's display text. Token colors come from the
    /// same YAML highlighter Source and Preview use — a per-mode palette is how
    /// the modes drift apart. Keys additionally stay semibold: that's the
    /// island's own Obsidian-style scanability, not a token color.
    ///
    /// Display lines are joined by the hard-break char inside one paragraph.
    /// It's a single UTF-16 unit, so swapping it for `\n` to feed Highlight.js
    /// keeps every offset valid in the island.
    private func colorYAMLIsland(_ storage: NSTextStorage, paragraph: NSRange) {
        guard let textView else { return }
        let theme = textView.theme
        let nsText = storage.string as NSString
        storage.addAttribute(.foregroundColor, value: theme.textColor, range: paragraph)

        let display = nsText.substring(with: paragraph)
        if EditorSettings.shared.general.syntaxHighlighting {
            let yaml = display.replacingOccurrences(of: mdHardBreak, with: "\n")
            let runs = CodeSyntaxHighlighter.shared.runsToPaint(
                for: yaml, language: "yaml",
                stableKey: "visual:\(parent.fileURL?.path ?? "untitled")#frontmatter")
            for run in runs where NSMaxRange(run.range) <= paragraph.length {
                storage.addAttribute(
                    .foregroundColor, value: run.color,
                    range: NSRange(location: paragraph.location + run.range.location,
                                   length: run.range.length))
            }
        }

        let keyFont = NSFont.monospacedSystemFont(ofSize: max(1, visualStyle.baseSize - 1),
                                                  weight: .semibold)
        var lineStart = paragraph.location
        for line in display.components(separatedBy: mdHardBreak) {
            var col = lineStart
            for (segText, kind) in yamlLineSegments(line) {
                let length = (segText as NSString).length
                let range = NSRange(location: col, length: length)
                if kind == .key, NSMaxRange(range) <= NSMaxRange(paragraph) {
                    storage.addAttribute(.font, value: keyFont, range: range)
                }
                col += length
            }
            lineStart += (line as NSString).length + 1   // + hard-break char
        }

        storage.enumerateAttribute(.mdFrontmatterToggle, in: paragraph) { value, range, _ in
            guard value != nil else { return }
            storage.addAttributes([
                .font: visualStyle.font(for: [], blockKind: .heading(3)),
                .foregroundColor: theme.textColor,
                .cursor: NSCursor.pointingHand,
            ], range: range)
        }
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

    /// Strikethrough and colors are derived: .mdInline strike ∪ done-task
    /// paragraphs get strikethrough; links get link color + underline.
    private func applyDerivedInlineDecorations(_ storage: NSTextStorage,
                                               paragraph: NSRange, block: MDBlock) {
        var isDone = false
        if case .taskItem(_, true) = block.kind { isDone = true }
        if case .builtInPluginTaskItem(_, let token) = block.kind,
           token.state.strikethrough { isDone = true }
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
        let theme = textView?.theme ?? .system
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
            let strike = styles.contains(.strike) || isDone
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
            } else if attrs[.mdWikiLink] != nil {
                // Wiki-links look like links; navigation is Cmd+click (resolver).
                storage.addAttributes([
                    .foregroundColor: elements.link.color ?? theme.accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            } else if attrs[.mdLink] != nil {
                storage.addAttributes([
                    .foregroundColor: elements.link.color ?? theme.accentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            } else if isDone {
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                     range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            } else if styles.contains(.code) {
                storage.addAttributes([
                    .foregroundColor: elements.inlineCode.color ?? theme.inlineCodeColor,
                    .backgroundColor: NSColor(white: 0.5, alpha: 0.12),
                ], range: range)
                storage.removeAttribute(.underlineStyle, range: range)
            } else {
                let color: NSColor
                if headingLevel > 0 {
                    color = elements.heading(headingLevel).color ?? theme.textColor
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
        if let url = resolveImageURL(src), let image = NSImage(contentsOf: url),
           image.size.width > 0 {
            result.image = image
            let maxWidth: CGFloat = 420
            let scale = image.size.width > maxWidth ? maxWidth / image.size.width : 1
            result.bounds = CGRect(x: 0, y: 0,
                                   width: image.size.width * scale,
                                   height: image.size.height * scale)
        } else {
            // Missing/remote file: visible placeholder instead of nothing.
            result.image = NSImage(systemSymbolName: "photo",
                                   accessibilityDescription: src)
            result.bounds = CGRect(x: 0, y: -3, width: 18, height: 15)
        }
        imageAttachments[src] = result
        return result
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
