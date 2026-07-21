import AppKit

/// Visual configuration for the Markdown editor.
/// All colours and layout constants are isolated here so different themes
/// can be created by constructing an `EditorTheme` with alternate values.
struct EditorTheme {

    var name: String

    // MARK: - Colors

    /// Base body text.
    var textColor: NSColor
    /// Dimmed secondary tone: frontmatter delimiters, Visual quote/list
    /// decorations, external-change diff. (Source syntax markers use
    /// `markerColor`, not this.)
    var secondaryColor: NSColor
    /// Legacy tertiary tone — currently unused. Source markers moved to
    /// `markerColor`; kept for the planned Source/Visual theme presets.
    var tertiaryColor: NSColor
    /// Default color for Markdown syntax markers in Source mode (heading `#`,
    /// list bullets, emphasis `*`/`_`, quote `>`, fences, table pipes, brackets).
    /// Graphite on light, a soft gray on dark. Overridable via Source settings.
    var markerColor: NSColor
    /// Links and list markers.
    var accentColor: NSColor
    /// Tint of the fill behind the line holding the caret (Source). Opaque —
    /// the wash alpha is applied at draw time (`currentLineAlpha`), so a color
    /// picked in Settings gets the same translucency as the theme default.
    var currentLineColor: NSColor
    /// Default wash alpha for `currentLineColor`, per appearance. A fill that
    /// reads the same on both needs more alpha on dark.
    static func currentLineAlpha(isDark: Bool) -> CGFloat { isDark ? 0.14 : 0.07 }

    /// Text insertion point. A thin accent bar, like Xcode's — the system
    /// default paints it in the body text color, which reads as a heavy black
    /// slab against monospaced markdown.
    var caretColor: NSColor
    /// Inline code text.
    var inlineCodeColor: NSColor
    /// Image alt-text and image syntax.
    var imageColor: NSColor
    /// Inactive thematic break and blockquote left-bar.
    var separatorColor: NSColor
    /// Inline code background fill.
    var inlineCodeBackground: NSColor
    /// Code block panel fill (semi-transparent).
    var codeBlockBackground: NSColor
    /// Copy-button semi-transparent fill.
    var copyButtonBackground: NSColor
    /// Subtle background fill behind blockquote body text (added to the left bar).
    var quoteBackground: NSColor
    /// Corner radius for code block background panels.
    var codeBlockCornerRadius: CGFloat
    /// Background for alternating (odd-index) body rows in tables.
    var tableRowBackground: NSColor
    /// `paragraphSpacingBefore` added to each list item paragraph.
    var listItemSpacing: CGFloat

    // MARK: - Typography

    /// Font-size delta for H1 (added to base size).
    var h1SizeOffset: CGFloat
    /// Font-size delta for H2.
    var h2SizeOffset: CGFloat
    /// Font-size delta for H3.
    var h3SizeOffset: CGFloat
    /// Font-size delta for H4–H6.
    var h4PlusSizeOffset: CGFloat
    /// Font-size delta for small elements: inline code, HTML, code block body.
    var smallFontOffset: CGFloat

    // MARK: - Spacing

    /// `paragraphSpacingBefore` for H1 and H2.
    var h1_2SpacingBefore: CGFloat
    /// `paragraphSpacingBefore` for H3–H6.
    var h3PlusSpacingBefore: CGFloat
    /// `paragraphSpacing` (after) for all headings.
    var headingSpacingAfter: CGFloat
    /// Horizontal indent step per blockquote nesting level.
    var quoteIndentStep: CGFloat
    /// `headIndent` / `firstLineHeadIndent` for code block body text.
    var codeBlockHeadIndent: CGFloat
    /// Vertical inset (`dy`) for code block background panel (expands block rect).
    var codeBlockPanelInset: CGFloat
    /// `paragraphSpacing` / `paragraphSpacingBefore` added to paragraphs adjacent to code blocks.
    var codeBlockOuterSpacing: CGFloat

    // MARK: - Layout

    /// Width of the blockquote left-border bar.
    var quoteBarWidth: CGFloat
    /// How far the blockquote bar is inset from the left edge of the text container.
    /// `barBaseX = max(0, textContainerInset.width - quoteBarXOffset)`
    var quoteBarXOffset: CGFloat
}

// MARK: - Built-in theme

extension EditorTheme {

    /// The single fixed look for Source and Visual highlighting. The old
    /// selectable presets (System/Sepia/Nord/Solarized/High Contrast/Dracula)
    /// were a second, redundant theme axis and were removed — Preview themes
    /// (`PreviewTheme`) are the theme system now, and dedicated Source/Visual
    /// presets will be reintroduced later on top of this baseline. Colors
    /// adapt to Light / Dark via `gh(...)`.
    static var editorDefault: EditorTheme { github }

    // MARK: - GitHub theme

    /// Creates a dynamic NSColor that uses lightHex in Aqua and darkHex in Dark Aqua.
    private static func ghAlpha(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return NSColor(white: 1.0, alpha: dark)
            default:
                return NSColor(white: 0.0, alpha: light)
            }
        }
    }

    private static func gh(_ lightHex: UInt32, _ darkHex: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            func rgb(_ hex: UInt32) -> NSColor {
                NSColor(
                    red:   CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >>  8) & 0xFF) / 255,
                    blue:  CGFloat( hex        & 0xFF) / 255,
                    alpha: 1
                )
            }
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return rgb(darkHex)
            default:
                return rgb(lightHex)
            }
        }
    }

    /// GitHub-flavored theme with concrete hex colors adapted from swift-markdown-ui's GitHub theme.
    static let github = EditorTheme(
        name:                 "github",
        textColor:            gh(0x060606, 0xfbfbfc),
        secondaryColor:       gh(0x6b6e7b, 0x9294a0),
        tertiaryColor:        gh(0x6b6e7b, 0x6d707d),
        markerColor:          gh(0x4a4d57, 0x9296a1),
        accentColor:          gh(0x2c65cf, 0x4c8ef8),
        currentLineColor:     gh(0x2c65cf, 0x4c8ef8),
        caretColor:           gh(0x2c65cf, 0x4c8ef8),
        inlineCodeColor:      gh(0xd1242f, 0xff7b72),
        imageColor:           gh(0x1a7f37, 0x3fb950),
        separatorColor:       gh(0xd0d0d3, 0x333438),
        inlineCodeBackground: gh(0xf0f0f5, 0x252629),
        codeBlockBackground:  gh(0xf6f8fa, 0x161b22),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        quoteBackground:      ghAlpha(light: 0.025, dark: 0.03),
        codeBlockCornerRadius: 6,
        tableRowBackground:   ghAlpha(light: 0.03, dark: 0.04),
        listItemSpacing:       2,
        h1SizeOffset:          8,
        h2SizeOffset:          5,
        h3SizeOffset:          3,
        h4PlusSizeOffset:      1,
        smallFontOffset:      -1,
        h1_2SpacingBefore:    12,
        h3PlusSpacingBefore:   8,
        headingSpacingAfter:   4,
        quoteIndentStep:      20,
        codeBlockHeadIndent:  12,
        codeBlockPanelInset:   8,
        codeBlockOuterSpacing: 16,
        quoteBarWidth:          3,
        quoteBarXOffset:       12
    )

    /// Applies General's base color overrides on top of this theme.
    /// A nil hex leaves the preset's own color untouched. Fine-grained
    /// per-element colors are applied at draw time, not here.
    func applyingOverrides(_ overrides: GeneralSettings) -> EditorTheme {
        var theme = self
        if let color = overrides.textColorHex.flatMap({ NSColor(hex: $0) }) {
            theme.textColor = color
        }
        if let color = overrides.accentColorHex.flatMap({ NSColor(hex: $0) }) {
            theme.accentColor = color
        }
        return theme
    }
}
