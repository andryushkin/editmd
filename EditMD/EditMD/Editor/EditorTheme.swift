import AppKit

/// Visual configuration for the Markdown editor.
/// All colours and layout constants are isolated here so different themes
/// can be created by constructing an `EditorTheme` with alternate values.
struct EditorTheme {

    var name: String

    // MARK: - Colors

    /// Base body text.
    var textColor: NSColor
    /// Blockquote text, code block body, bold/italic markers.
    var secondaryColor: NSColor
    /// Heading markers, quote markers, active thematic break, table delimiter.
    var tertiaryColor: NSColor
    /// Links and list markers.
    var accentColor: NSColor
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
    /// Color for thin divider lines drawn below H1 and H2 headings.
    var headingDividerColor: NSColor
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

// MARK: - Built-in themes

extension EditorTheme {

    /// Default theme using system-adaptive NSColor values.
    /// All colours adapt automatically to Light / Dark appearance.
    static let system = EditorTheme(
        name:                "system",
        textColor:           .labelColor,
        secondaryColor:      .secondaryLabelColor,
        tertiaryColor:       .tertiaryLabelColor,
        accentColor:         .linkColor,
        inlineCodeColor:     .systemOrange,
        imageColor:          .systemGreen,
        separatorColor:      .separatorColor,
        inlineCodeBackground:.controlBackgroundColor,
        codeBlockBackground: .systemOrange.withAlphaComponent(0.08),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:   .clear,
        quoteBackground:       .systemBlue.withAlphaComponent(0.07),
        codeBlockCornerRadius: 6,
        tableRowBackground:    .clear,
        listItemSpacing:       0,
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
        accentColor:          gh(0x2c65cf, 0x4c8ef8),
        inlineCodeColor:      gh(0xd1242f, 0xff7b72),
        imageColor:           gh(0x1a7f37, 0x3fb950),
        separatorColor:       gh(0xd0d0d3, 0x333438),
        inlineCodeBackground: gh(0xf0f0f5, 0x252629),
        codeBlockBackground:  gh(0xf6f8fa, 0x161b22),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:  gh(0xd0d0d3, 0x333438),
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

    // MARK: - Settings-driven customization

    // MARK: - Additional presets (D10)

    /// Warm sepia / book-like reading.
    static let sepia = EditorTheme(
        name: "sepia",
        textColor:            gh(0x3b2f2f, 0xe8dcc8),
        secondaryColor:       gh(0x7a6555, 0xb8a890),
        tertiaryColor:        gh(0x9a8068, 0x8a7860),
        accentColor:          gh(0x8b4513, 0xd4a574),
        inlineCodeColor:      gh(0xa0522d, 0xe8b88a),
        imageColor:           gh(0x556b2f, 0x9acd70),
        separatorColor:       gh(0xd4c4a8, 0x4a3f32),
        inlineCodeBackground: gh(0xf5ebe0, 0x2a2218),
        codeBlockBackground:  gh(0xf0e6d8, 0x1e1810),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:  gh(0xd4c4a8, 0x4a3f32),
        quoteBackground:      ghAlpha(light: 0.04, dark: 0.05),
        codeBlockCornerRadius: 6,
        tableRowBackground:   ghAlpha(light: 0.03, dark: 0.04),
        listItemSpacing: 2,
        h1SizeOffset: 8, h2SizeOffset: 5, h3SizeOffset: 3, h4PlusSizeOffset: 1,
        smallFontOffset: -1, h1_2SpacingBefore: 12, h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4, quoteIndentStep: 20, codeBlockHeadIndent: 12,
        codeBlockPanelInset: 8, codeBlockOuterSpacing: 16,
        quoteBarWidth: 3, quoteBarXOffset: 12
    )

    /// Nord-inspired cool palette.
    static let nord = EditorTheme(
        name: "nord",
        textColor:            gh(0x2e3440, 0xeceff4),
        secondaryColor:       gh(0x4c566a, 0xd8dee9),
        tertiaryColor:        gh(0x616e88, 0x81a1c1),
        accentColor:          gh(0x5e81ac, 0x88c0d0),
        inlineCodeColor:      gh(0xbf616a, 0xbf616a),
        imageColor:           gh(0xa3be8c, 0xa3be8c),
        separatorColor:       gh(0xd8dee9, 0x3b4252),
        inlineCodeBackground: gh(0xeceff4, 0x3b4252),
        codeBlockBackground:  gh(0xe5e9f0, 0x2e3440),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:  gh(0xd8dee9, 0x3b4252),
        quoteBackground:      ghAlpha(light: 0.03, dark: 0.05),
        codeBlockCornerRadius: 6,
        tableRowBackground:   ghAlpha(light: 0.03, dark: 0.04),
        listItemSpacing: 2,
        h1SizeOffset: 8, h2SizeOffset: 5, h3SizeOffset: 3, h4PlusSizeOffset: 1,
        smallFontOffset: -1, h1_2SpacingBefore: 12, h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4, quoteIndentStep: 20, codeBlockHeadIndent: 12,
        codeBlockPanelInset: 8, codeBlockOuterSpacing: 16,
        quoteBarWidth: 3, quoteBarXOffset: 12
    )

    /// Solarized-inspired.
    static let solarized = EditorTheme(
        name: "solarized",
        textColor:            gh(0x657b83, 0x839496),
        secondaryColor:       gh(0x93a1a1, 0x586e75),
        tertiaryColor:        gh(0x839496, 0x657b83),
        accentColor:          gh(0x268bd2, 0x2aa198),
        inlineCodeColor:      gh(0xcb4b16, 0xcb4b16),
        imageColor:           gh(0x859900, 0x859900),
        separatorColor:       gh(0xeee8d5, 0x073642),
        inlineCodeBackground: gh(0xeee8d5, 0x073642),
        codeBlockBackground:  gh(0xfdf6e3, 0x002b36),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:  gh(0xeee8d5, 0x073642),
        quoteBackground:      ghAlpha(light: 0.04, dark: 0.06),
        codeBlockCornerRadius: 6,
        tableRowBackground:   ghAlpha(light: 0.03, dark: 0.05),
        listItemSpacing: 2,
        h1SizeOffset: 8, h2SizeOffset: 5, h3SizeOffset: 3, h4PlusSizeOffset: 1,
        smallFontOffset: -1, h1_2SpacingBefore: 12, h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4, quoteIndentStep: 20, codeBlockHeadIndent: 12,
        codeBlockPanelInset: 8, codeBlockOuterSpacing: 16,
        quoteBarWidth: 3, quoteBarXOffset: 12
    )

    /// High-contrast accessibility-oriented.
    static let highContrast = EditorTheme(
        name: "high-contrast",
        textColor:            gh(0x000000, 0xffffff),
        secondaryColor:       gh(0x222222, 0xdddddd),
        tertiaryColor:        gh(0x333333, 0xcccccc),
        accentColor:          gh(0x0000ee, 0x66b3ff),
        inlineCodeColor:      gh(0x990000, 0xff6666),
        imageColor:           gh(0x006600, 0x66ff66),
        separatorColor:       gh(0x000000, 0xffffff),
        inlineCodeBackground: gh(0xeeeeee, 0x222222),
        codeBlockBackground:  gh(0xf5f5f5, 0x111111),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.2),
        headingDividerColor:  gh(0x000000, 0xffffff),
        quoteBackground:      ghAlpha(light: 0.06, dark: 0.1),
        codeBlockCornerRadius: 4,
        tableRowBackground:   ghAlpha(light: 0.05, dark: 0.08),
        listItemSpacing: 2,
        h1SizeOffset: 8, h2SizeOffset: 5, h3SizeOffset: 3, h4PlusSizeOffset: 1,
        smallFontOffset: -1, h1_2SpacingBefore: 12, h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4, quoteIndentStep: 20, codeBlockHeadIndent: 12,
        codeBlockPanelInset: 8, codeBlockOuterSpacing: 16,
        quoteBarWidth: 4, quoteBarXOffset: 12
    )

    /// Dracula-inspired (works in light with muted counterparts).
    static let dracula = EditorTheme(
        name: "dracula",
        textColor:            gh(0x282a36, 0xf8f8f2),
        secondaryColor:       gh(0x6272a4, 0xbd93f9),
        tertiaryColor:        gh(0x44475a, 0x6272a4),
        accentColor:          gh(0x8be9fd, 0x8be9fd),
        inlineCodeColor:      gh(0xff79c6, 0xff79c6),
        imageColor:           gh(0x50fa7b, 0x50fa7b),
        separatorColor:       gh(0xbd93f9, 0x44475a),
        inlineCodeBackground: gh(0xf0eef8, 0x44475a),
        codeBlockBackground:  gh(0xf8f8fc, 0x282a36),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:  gh(0xbd93f9, 0x44475a),
        quoteBackground:      ghAlpha(light: 0.04, dark: 0.08),
        codeBlockCornerRadius: 6,
        tableRowBackground:   ghAlpha(light: 0.03, dark: 0.06),
        listItemSpacing: 2,
        h1SizeOffset: 8, h2SizeOffset: 5, h3SizeOffset: 3, h4PlusSizeOffset: 1,
        smallFontOffset: -1, h1_2SpacingBefore: 12, h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4, quoteIndentStep: 20, codeBlockHeadIndent: 12,
        codeBlockPanelInset: 8, codeBlockOuterSpacing: 16,
        quoteBarWidth: 3, quoteBarXOffset: 12
    )

    /// All selectable theme presets (toolbar + Settings).
    static let allPresets: [(id: String, title: String)] = [
        ("system", String(localized: "System")),
        ("github", "GitHub"),
        ("sepia", "Sepia"),
        ("nord", "Nord"),
        ("solarized", "Solarized"),
        ("high-contrast", String(localized: "High Contrast")),
        ("dracula", "Dracula"),
    ]

    /// Looks up a built-in preset by `GeneralSettings.themePreset` name,
    /// falling back to `.system`. "comfortable" is a retired preset (its only
    /// distinction — larger insets — is now a per-mode setting); old prefs
    /// naming it resolve to System.
    static func preset(named name: String) -> EditorTheme {
        switch name {
        case "github": return .github
        case "sepia": return .sepia
        case "nord": return .nord
        case "solarized": return .solarized
        case "high-contrast": return .highContrast
        case "dracula": return .dracula
        default: return .system
        }
    }

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
