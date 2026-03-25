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
        copyButtonBackground:NSColor(white: 0.5, alpha: 0.12),
        h1SizeOffset:        8,
        h2SizeOffset:        5,
        h3SizeOffset:        3,
        h4PlusSizeOffset:    1,
        smallFontOffset:    -1,
        h1_2SpacingBefore:  12,
        h3PlusSpacingBefore: 8,
        headingSpacingAfter: 4,
        quoteIndentStep:    20,
        codeBlockHeadIndent:12,
        codeBlockPanelInset: 8,
        codeBlockOuterSpacing:16,
        editorInsetH:       48,
        editorInsetV:       24,
        quoteBarWidth:       3,
        quoteBarXOffset:    12
    )

    /// Comfortable theme — same colours, more generous whitespace.
    static let comfortable = EditorTheme(
        textColor:           .labelColor,
        secondaryColor:      .secondaryLabelColor,
        tertiaryColor:       .tertiaryLabelColor,
        accentColor:         .linkColor,
        inlineCodeColor:     .systemOrange,
        imageColor:          .systemGreen,
        separatorColor:      .separatorColor,
        inlineCodeBackground:.controlBackgroundColor,
        codeBlockBackground: NSColor(white: 0.5, alpha: 0.07),
        copyButtonBackground:NSColor(white: 0.5, alpha: 0.12),
        h1SizeOffset:        9,
        h2SizeOffset:        6,
        h3SizeOffset:        4,
        h4PlusSizeOffset:    2,
        smallFontOffset:    -1,
        h1_2SpacingBefore:  16,
        h3PlusSpacingBefore:12,
        headingSpacingAfter: 6,
        quoteIndentStep:    24,
        codeBlockHeadIndent:16,
        codeBlockPanelInset:10,
        codeBlockOuterSpacing:20,
        editorInsetH:       64,
        editorInsetV:       32,
        quoteBarWidth:       3,
        quoteBarXOffset:    16
    )
}
