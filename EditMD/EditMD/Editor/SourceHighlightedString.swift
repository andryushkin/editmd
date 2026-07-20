import AppKit

// Shared Source highlighting (editor + external-change diff). Extracted from
// SourceTextView.swift — renders markdown with the same per-element
// fonts/colors as Source mode without a live text view.

/// Renders markdown with the same per-element fonts/colors as Source mode
/// (Settings ▸ Source ▸ Elements + effective theme). No table-kern pass —
/// callers that need alignment run it separately on a live text view.
@MainActor
func makeSourceHighlightedString(_ text: String) -> NSAttributedString {
    let settings = EditorSettings.shared.source
    let theme = EditorSettings.shared.effectiveTheme
    let els = settings.elements
    let baseFont = settings.resolvedFont(defaultMono: true)
    let storage = NSTextStorage(string: text)
    let nsText = storage.string as NSString
    let full = NSRange(location: 0, length: nsText.length)
    guard full.length > 0 else {
        return NSAttributedString(string: text, attributes: [
            .font: baseFont, .foregroundColor: theme.textColor,
        ])
    }

    func font(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let family = settings.fontFamily
        if !family.isEmpty {
            let descriptor = NSFontDescriptor(fontAttributes: [
                .family: family,
                .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
            ])
            if let f = NSFont(descriptor: descriptor, size: size) { return f }
        }
        return .monospacedSystemFont(ofSize: size, weight: weight)
    }

    storage.beginEditing()
    storage.setAttributes([.font: baseFont, .foregroundColor: theme.textColor], range: full)

    let spans = collectSpans(text)
    for span in spans where NSMaxRange(span.range) <= full.length {
        switch span.kind {
        case .headingBody(let level):
            let line = nsText.lineRange(for: span.range)
            let e = els.heading(level)
            storage.addAttribute(.font,
                                 value: font(size: settings.fontSize * e.sizeScale,
                                             weight: (e.weight ?? .semibold).nsWeight),
                                 range: line)
            if let c = e.color {
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
                .font: font(size: baseFont.pointSize, weight: .semibold),
            ], range: span.range)
        case .codeBlockBody(let language):
            // A one-shot render (no view to repaint later) — highlight inline.
            if EditorSettings.shared.general.syntaxHighlighting,
               let body = CodeSyntaxHighlighter.shared.fencedBodyRange(in: nsText,
                                                                        blockRange: span.range) {
                CodeSyntaxHighlighter.shared.apply(to: storage, codeRange: body, language: language,
                                                   blocking: true)
            }
        default:
            break
        }
    }
    for span in spans where NSMaxRange(span.range) <= full.length {
        switch span.kind {
        case .boldBody, .boldMarker:
            let existing = storage.attribute(.font, at: span.range.location,
                                             effectiveRange: nil) as? NSFont ?? baseFont
            storage.addAttribute(.font,
                                 value: font(size: existing.pointSize,
                                             weight: (els.bold.weight ?? .bold).nsWeight),
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
            storage.addAttribute(.foregroundColor, value: theme.accentColor, range: span.range)
            if payload.state.strikethrough {
                storage.addAttribute(.strikethroughStyle,
                                     value: NSUnderlineStyle.single.rawValue,
                                     range: span.range)
            }
        default:
            break
        }
    }
    // Syntax markers: repaint every delimiter / punctuation span with the
    // configurable marker color (graphite default), mirroring the live editor.
    let markerColor = settings.markerColor ?? theme.markerColor
    for span in spans where NSMaxRange(span.range) <= full.length {
        if span.kind.isSyntaxMarker {
            storage.addAttribute(.foregroundColor, value: markerColor, range: span.range)
        }
    }

    if let frontmatter = frontmatterRange(in: text),
       NSMaxRange(frontmatter.full) <= nsText.length {
        storage.addAttribute(.font, value: baseFont, range: frontmatter.full)
        storage.addAttribute(.foregroundColor, value: theme.textColor, range: frontmatter.full)
        let openLen = frontmatter.body.location - frontmatter.full.location
        if openLen > 0 {
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                 range: NSRange(location: frontmatter.full.location, length: openLen))
        }
        let closeStart = NSMaxRange(frontmatter.body)
        let closeLen = NSMaxRange(frontmatter.full) - closeStart
        if closeLen > 0 {
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor,
                                 range: NSRange(location: closeStart, length: closeLen))
        }
        if EditorSettings.shared.general.syntaxHighlighting {
            CodeSyntaxHighlighter.shared.apply(to: storage, codeRange: frontmatter.body,
                                               language: "yaml", blocking: true)
        }
    }
    storage.endEditing()
    return NSAttributedString(attributedString: storage)
}

/// One Source-highlighted attributed string per logical line — indices match
/// `splitDiffLines` / `lineDiff` line numbers (1-based → array index 0).
@MainActor
func sourceHighlightedLines(_ text: String) -> [NSAttributedString] {
    let full = makeSourceHighlightedString(text)
    let ns = full.string as NSString
    let plain = splitDiffLines(text)
    var lines: [NSAttributedString] = []
    lines.reserveCapacity(plain.count)
    var loc = 0
    for line in plain {
        let len = (line as NSString).length
        let range = NSRange(location: loc, length: min(len, max(0, ns.length - loc)))
        if range.length > 0, NSMaxRange(range) <= ns.length {
            lines.append(full.attributedSubstring(from: range))
        } else if range.location <= ns.length {
            let attrs: [NSAttributedString.Key: Any] = ns.length > 0
                ? full.attributes(at: min(range.location, ns.length - 1), effectiveRange: nil)
                : [.font: EditorSettings.shared.source.resolvedFont(defaultMono: true)]
            lines.append(NSAttributedString(string: line, attributes: attrs))
        } else {
            lines.append(NSAttributedString(string: line))
        }
        loc += len
        if loc < ns.length, ns.character(at: loc) == 0x0A {
            loc += 1
        }
    }
    return lines
}

extension NSFont {
    func withSourceTraits(_ traits: NSFontDescriptor.SymbolicTraits) -> NSFont? {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        return NSFont(descriptor: fontDescriptor.withSymbolicTraits(combined), size: pointSize)
    }
}
