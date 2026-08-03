import AppKit

// Source highlighting pass of SourceTextView.Coordinator.

extension SourceTextView.Coordinator {

    /// Re-styles raw markdown from `collectSpans` + Source per-element settings.
    /// Real storage attributes (not temporary) so heading sizes take effect;
    /// `.string` — the source of truth — is untouched, and attribute-only edits
    /// don't register undo. Block pass then inline pass, so inline overrides win.
    func highlightSource() {
        guard let textView, let storage = textView.textStorage else { return }
        let settings = EditorSettings.shared.source
        let theme = EditorSettings.shared.effectiveTheme
        let els = settings.elements
        let baseFont = settings.resolvedFont(defaultMono: true)
        let nsText = textView.string as NSString
        let full = NSRange(location: 0, length: nsText.length)

        // Heavy documents (300K single-table file) stay plain: collectSpans +
        // per-keystroke re-attribution would freeze every edit. Base font/color
        // only — same choice FSNotes makes.
        if parent.document.isHeavy {
            cachedSpans = []
            cachedHighlightMarks = []
            storage.beginEditing()
            storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)
            storage.endEditing()
            return
        }

        let spans = collectSpans(textView.string)
        cachedSpans = spans
        cachedHighlightMarks = scanHighlightMarks(in: textView.string)

        func headingFont(_ level: Int) -> NSFont {
            let e = els.heading(level)
            return sourceFont(size: settings.fontSize * e.sizeScale,
                              weight: (e.weight ?? .semibold).nsWeight)
        }

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)

        // Block identity across keystrokes: a still-warming block keeps its
        // previous colors instead of flashing plain.
        var codeBlockIndex = 0
        let blockKeyPrefix = "source:\(parent.fileURL?.path ?? "untitled")#"

        // Pass A — block level.
        for span in spans where NSMaxRange(span.range) <= full.length {
            switch span.kind {
            case .headingBody(let level):
                let line = nsText.lineRange(for: span.range)
                storage.addAttribute(.font, value: headingFont(level), range: line)
                if let c = els.heading(level).color {
                    storage.addAttribute(.foregroundColor, value: c, range: line)
                }
            case .quoteBody, .quoteMarker:
                if let c = els.quote.color {
                    storage.addAttribute(.foregroundColor, value: c, range: span.range)
                }
            case .calloutMarker(let type):
                let style = MarkdownCalloutStyle(rawValue: type.lowercased()) ?? .note
                let color = MarkdownCallout(type: type, style: style, title: nil,
                                            markerRange: span.range).color
                storage.addAttributes([
                    .foregroundColor: color,
                    .font: sourceFont(size: baseFont.pointSize, weight: .semibold),
                ], range: span.range)
            case .codeBlockBody(let language):
                defer { codeBlockIndex += 1 }
                if EditorSettings.shared.general.syntaxHighlighting,
                   let body = CodeSyntaxHighlighter.shared.fencedBodyRange(in: nsText,
                                                                            blockRange: span.range) {
                    CodeSyntaxHighlighter.shared.apply(
                        to: storage, codeRange: body, language: language,
                        stableKey: blockKeyPrefix + String(codeBlockIndex))
                }
            default:
                break
            }
        }

        // Pass B — inline.
        for span in spans where NSMaxRange(span.range) <= full.length {
            switch span.kind {
            case .boldBody, .boldMarker:
                let existing = storage.attribute(.font, at: span.range.location,
                                                 effectiveRange: nil) as? NSFont ?? baseFont
                storage.addAttribute(.font, value: sourceFont(
                    size: existing.pointSize, weight: (els.bold.weight ?? .bold).nsWeight),
                                     range: span.range)
                if let c = els.bold.color {
                    storage.addAttribute(.foregroundColor, value: c, range: span.range)
                }
            case .italicBody:
                let existing = storage.attribute(.font, at: span.range.location,
                                                 effectiveRange: nil) as? NSFont ?? baseFont
                if let italic = existing.withSourceTraits(.italic) {
                    storage.addAttribute(.font, value: italic, range: span.range)
                }
            case .code, .codeMarker:
                if let c = els.inlineCode.color {
                    storage.addAttribute(.foregroundColor, value: c, range: span.range)
                }
            case .linkText:
                if let c = els.link.color {
                    storage.addAttribute(.foregroundColor, value: c, range: span.range)
                }
            case .strikethroughBody:
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue, range: span.range)
            case .wikiLink:
                storage.addAttribute(.foregroundColor,
                                     value: els.link.color ?? theme.accentColor, range: span.range)
            case .wikiLinkSyntax:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
            case .mathBody:
                storage.addAttribute(.foregroundColor,
                                     value: els.inlineCode.color ?? theme.inlineCodeColor,
                                     range: span.range)
            case .mathMarker:
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: span.range)
            case .builtInPluginToken(let payload):
                storage.addAttribute(.foregroundColor, value: theme.accentColor,
                                     range: span.range)
                if payload.state.strikethrough {
                    storage.addAttribute(.strikethroughStyle,
                                         value: NSUnderlineStyle.single.rawValue,
                                         range: span.range)
                }
            default:
                break
            }
        }

        // Pass B.25 — syntax markers: repaint delimiter/punctuation spans with
        // the marker color, overriding body colors on just those characters.
        // Before the frontmatter pass so that block keeps its own dimming.
        let markerColor = settings.markerColor ?? theme.markerColor
        for span in spans where NSMaxRange(span.range) <= full.length {
            if span.kind.isSyntaxMarker {
                storage.addAttribute(.foregroundColor, value: markerColor, range: span.range)
            }
        }

        // Pass B.5 — YAML frontmatter. swift-markdown mis-parses it as thematic
        // break + setext heading (Pass A gave the body a heading font); override
        // back to base font, color like a ```yaml block (fences dimmed).
        if let frontmatter = frontmatterRange(in: textView.string),
           NSMaxRange(frontmatter.full) <= nsText.length {
            storage.addAttribute(.font, value: baseFont, range: frontmatter.full)
            storage.addAttribute(.foregroundColor, value: theme.textColor,
                                 range: frontmatter.full)
            let openLen = frontmatter.body.location - frontmatter.full.location
            if openLen > 0 {
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                     range: NSRange(location: frontmatter.full.location,
                                                    length: openLen))
            }
            let closeStart = NSMaxRange(frontmatter.body)
            let closeLen = NSMaxRange(frontmatter.full) - closeStart
            if closeLen > 0 {
                storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                     range: NSRange(location: closeStart, length: closeLen))
            }
            if EditorSettings.shared.general.syntaxHighlighting {
                CodeSyntaxHighlighter.shared.apply(
                    to: storage, codeRange: frontmatter.body, language: "yaml",
                    stableKey: blockKeyPrefix + "frontmatter")
            }
        }

        // Pass C — display-only .kern table column alignment (raw text stays
        // compact).
        applyTableAlignment(storage, baseFont: baseFont)

        storage.endEditing()
    }

    /// Pads table columns via `.kern` so pipes line up WITHOUT inserting spaces
    /// (file bytes untouched — no git churn). Width measured from the styled
    /// substring, so bold/heading cells count; a per-column cap keeps one long
    /// cell from blowing the table wide (its row runs ragged past the cap).
    private func applyTableAlignment(_ storage: NSTextStorage, baseFont: NSFont) {
        let tables = scanSourceTables(storage.string)
        guard !tables.isEmpty else { return }
        let length = storage.length
        let charWidth = ("0" as NSString).size(withAttributes: [.font: baseFont]).width
        let maxColumnWidth = charWidth * 40   // cap ≈ 40 characters
        for cells in tables {
            var target: [Int: CGFloat] = [:]
            var measured: [(cell: SourceTableCell, width: CGFloat)] = []
            for cell in cells where NSMaxRange(cell.segmentRange) <= length {
                let width = cell.segmentRange.length > 0
                    ? storage.attributedSubstring(from: cell.segmentRange).size().width
                    : 0
                measured.append((cell, width))
                target[cell.column] = min(max(target[cell.column] ?? 0, width), maxColumnWidth)
            }
            for (cell, width) in measured {
                guard let goal = target[cell.column], goal > width + 0.5,
                      cell.kernIndex < length else { continue }
                storage.addAttribute(.kern, value: NSNumber(value: Double(goal - width)),
                                     range: NSRange(location: cell.kernIndex, length: 1))
            }
        }
    }

    /// Source font honoring the mode's family (else system mono).
    private func sourceFont(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let family = EditorSettings.shared.source.fontFamily
        if !family.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let font = NSFont(descriptor: descriptor, size: size) { return font }
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }
}
