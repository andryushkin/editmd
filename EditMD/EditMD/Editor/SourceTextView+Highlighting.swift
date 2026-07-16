import AppKit

// Source highlighting pass of SourceTextView.Coordinator, extracted from
// SourceTextView.swift.

extension SourceTextView.Coordinator {

    /// Re-styles the raw markdown from `collectSpans` + the Source mode's
    /// per-element settings. Real text-storage attributes (not temporary
    /// ones) so heading size changes take effect; the plain `.string` — the
    /// document's source of truth — is untouched, and attribute-only edits
    /// don't register undo. Two passes: block-level (heading lines, quotes)
    /// then inline (bold/code/link/italic/strike) so inline overrides win.
    func highlightSource() {
        guard let textView, let storage = textView.textStorage else { return }
        let settings = EditorSettings.shared.source
        let theme = EditorSettings.shared.effectiveTheme
        let els = settings.elements
        let baseFont = settings.resolvedFont(defaultMono: true)
        let nsText = textView.string as NSString
        let full = NSRange(location: 0, length: nsText.length)

        // Heavy documents (a 300K single-table file) stay plain: collectSpans
        // and the per-keystroke re-attribution would freeze on every edit.
        // Base font/color only — same choice FSNotes makes for large notes.
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

        // Identity of a code block across keystrokes, so a block that is
        // still warming keeps its previous colors instead of flashing plain.
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

        // Pass B.5 — YAML frontmatter (top-of-file ---…---). swift-markdown
        // mis-parses it as a thematic break + setext heading, so Pass A gave
        // the body a big heading font; override the whole block back to the
        // base font and color it like a ```yaml block (fences dimmed).
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

        // Pass C — virtual table column alignment (display-only .kern; the
        // raw text stays compact, columns just line up visually).
        applyTableAlignment(storage, baseFont: baseFont)

        storage.endEditing()
    }

    /// Pads each table column to a common width using the `.kern` attribute
    /// so pipes line up in the monospaced Source view — WITHOUT inserting
    /// spaces (the file bytes are untouched, so no git churn). Width is
    /// measured from the already-styled substring, so bold/heading cells
    /// count correctly; a per-column cap keeps one long cell from blowing
    /// the table wide (that cell's row just runs ragged past the cap).
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

    /// A Source font honoring the mode's family (else system mono) at an
    /// explicit size/weight.
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
