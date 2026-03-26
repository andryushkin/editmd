import AppKit

/// Visual configuration for the Markdown editor.
/// All colours and layout constants are isolated here so different themes
/// can be created by constructing an `EditorTheme` with alternate values.
struct EditorTheme {

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

    /// Horizontal padding of the text container (left and right).
    var editorInsetH: CGFloat
    /// Vertical padding of the text container (top and bottom).
    var editorInsetV: CGFloat
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
        textColor:           .labelColor,
        secondaryColor:      .secondaryLabelColor,
        tertiaryColor:       .tertiaryLabelColor,
        accentColor:         .linkColor,
        inlineCodeColor:     .systemOrange,
        imageColor:          .systemGreen,
        separatorColor:      .separatorColor,
        inlineCodeBackground:.controlBackgroundColor,
        codeBlockBackground: NSColor(white: 0.5, alpha: 0.07),
        copyButtonBackground: NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:   .clear,
        quoteBackground:       .clear,
        codeBlockCornerRadius: 0,
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
        editorInsetH:          48,
        editorInsetV:          24,
        quoteBarWidth:          3,
        quoteBarXOffset:       12
    )

    /// Comfortable theme — same colours, more generous whitespace.
    static let comfortable = EditorTheme(
        textColor:             .labelColor,
        secondaryColor:        .secondaryLabelColor,
        tertiaryColor:         .tertiaryLabelColor,
        accentColor:           .linkColor,
        inlineCodeColor:       .systemOrange,
        imageColor:            .systemGreen,
        separatorColor:        .separatorColor,
        inlineCodeBackground:  .controlBackgroundColor,
        codeBlockBackground:   NSColor(white: 0.5, alpha: 0.07),
        copyButtonBackground:  NSColor(white: 0.5, alpha: 0.12),
        headingDividerColor:   .clear,
        quoteBackground:       .clear,
        codeBlockCornerRadius: 0,
        tableRowBackground:    .clear,
        listItemSpacing:       0,
        h1SizeOffset:          9,
        h2SizeOffset:          6,
        h3SizeOffset:          4,
        h4PlusSizeOffset:      2,
        smallFontOffset:      -1,
        h1_2SpacingBefore:    16,
        h3PlusSpacingBefore:  12,
        headingSpacingAfter:   6,
        quoteIndentStep:      24,
        codeBlockHeadIndent:  16,
        codeBlockPanelInset:  10,
        codeBlockOuterSpacing: 20,
        editorInsetH:          64,
        editorInsetV:          32,
        quoteBarWidth:          3,
        quoteBarXOffset:       16
    )

    // MARK: - GitHub theme

    /// Creates a dynamic NSColor that uses lightHex in Aqua and darkHex in Dark Aqua.
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
        quoteBackground: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return NSColor(white: 1.0, alpha: 0.03)
            default:
                return NSColor(white: 0.0, alpha: 0.025)
            }
        },
        codeBlockCornerRadius: 6,
        tableRowBackground: NSColor(name: nil) { appearance in
            switch appearance.name {
            case .darkAqua, .vibrantDark,
                 .accessibilityHighContrastDarkAqua,
                 .accessibilityHighContrastVibrantDark:
                return NSColor(white: 1.0, alpha: 0.04)
            default:
                return NSColor(white: 0.0, alpha: 0.03)
            }
        },
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
        editorInsetH:          48,
        editorInsetV:          24,
        quoteBarWidth:          3,
        quoteBarXOffset:       12
    )
}
