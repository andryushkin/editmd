import Foundation

/// A Preview-only markdown look: typography, colors and decorations for the
/// rendered HTML page. Source and Visual are not affected — their look still
/// comes from `EditorTheme`. A theme is a CSS layer inserted between the
/// page's base rules and the user's per-element overrides, so the cascade
/// keeps the precedence: base < theme < user settings.
///
/// Themes are compiled-in declarations (no JSON/user theme files), matching
/// the plugin model: a limited, opinionated set. The selected theme id is
/// persisted in `PreviewTypographySettings.theme`.
struct PreviewTheme {
    let id: String
    let title: String
    /// CSS `font-family` stack for body text (headings inherit). Applied only
    /// when the user hasn't picked an explicit Preview font family.
    /// `nil` = keep the default system sans stack.
    let bodyFontStack: String?
    /// Rules appended after the page's base CSS (including its dark-mode
    /// block) and before the user's element CSS — later rules win at equal
    /// specificity. Themes deliberately do not set the page background or the
    /// base body text color: `background: Canvas` stays system-adaptive and a
    /// General ▸ Text color override must keep winning.
    let css: String

    /// Resolved body `font-family` for the page: an explicit user family
    /// always beats the theme's stack.
    func cssFontFamily(userFamily: String) -> String {
        if !userFamily.isEmpty { return "\"\(userFamily)\", -apple-system, sans-serif" }
        return bodyFontStack ?? "-apple-system, \"Helvetica Neue\", sans-serif"
    }
}

// MARK: - Built-in catalog

extension PreviewTheme {

    /// The current look, unchanged. Empty CSS: base rules + user settings only.
    static let standard = PreviewTheme(
        id: "default",
        title: String(localized: "Default"),
        bodyFontStack: nil,
        css: ""
    )

    /// Near-monochrome: structure carried by weight and whitespace, not color.
    /// No heading rules, no code panels, no table zebra; links underlined in
    /// the text color instead of painted blue.
    static let minimal = PreviewTheme(
        id: "minimal",
        title: String(localized: "Minimal"),
        bodyFontStack: nil,
        css: """
        h1, h2 { border-bottom: none; padding-bottom: 0; }
        a { color: inherit; text-decoration: underline; text-decoration-color: rgba(128,128,128,0.55); text-underline-offset: 2px; }
        a:hover { text-decoration-color: currentColor; }
        code { background: rgba(128,128,128,0.1); }
        pre { background: none; border: none; border-left: 2px solid rgba(128,128,128,0.35); border-radius: 0; padding: 2px 0 2px 16px; }
        blockquote { border-left: 2px solid rgba(128,128,128,0.5); border-radius: 0; background: none; }
        blockquote.callout { border-radius: 0; }
        hr { border-top: 1px solid rgba(128,128,128,0.35); }
        th, td { border: none; border-bottom: 1px solid rgba(128,128,128,0.3); }
        thead th { border-bottom: 2px solid rgba(128,128,128,0.45); }
        tbody tr:nth-child(odd) { background: none; }
        """
    )

    /// Book-like reading: serif body, centered chapter titles, italic quotes
    /// without the colored bar, a fleuron instead of a horizontal rule, warm
    /// muted accents.
    static let literary = PreviewTheme(
        id: "literary",
        title: String(localized: "Literary"),
        bodyFontStack: "ui-serif, \"New York\", Georgia, serif",
        css: """
        h1, h2, h3, h4, h5, h6 { font-weight: 600; letter-spacing: 0.01em; }
        h1 { text-align: center; }
        h1, h2 { border-bottom: none; padding-bottom: 0; }
        a { color: #8b5e34; }
        blockquote { border-left: none; border-radius: 0; background: none; padding: 0 2.2em; font-style: italic; }
        blockquote.callout { font-style: normal; border-left: 4px solid rgb(var(--callout-rgb)); background: rgba(var(--callout-rgb),0.09); }
        code { background: rgba(139,110,80,0.12); }
        pre { background: rgba(139,110,80,0.08); border: none; border-radius: 4px; }
        hr { border: none; margin: 2em 0; text-align: center; }
        hr::after { content: "\\2766"; font-size: 1.1em; color: rgba(128,128,128,0.8); }
        th, td { border: none; border-bottom: 1px solid rgba(139,110,80,0.35); }
        tbody tr:nth-child(odd) { background: none; }
        @media (prefers-color-scheme: dark) {
            a { color: #d4a574; }
            blockquote.callout { background: rgba(var(--callout-rgb),0.14); }
        }
        """
    )

    /// Paper-like formality: serif, justified text, centered title, booktabs
    /// tables (horizontal rules only), centered display math, plain `\\texttt`
    /// inline code, one restrained link blue.
    static let academic = PreviewTheme(
        id: "academic",
        title: String(localized: "Academic"),
        bodyFontStack: "\"Times New Roman\", Times, ui-serif, serif",
        css: """
        body { text-align: justify; -webkit-hyphens: auto; hyphens: auto; }
        h1 { text-align: center; font-size: 1.5em; }
        h2 { font-size: 1.25em; }
        h3 { font-size: 1.1em; }
        h4, h5 { font-size: 1em; }
        h1, h2, h3 { font-weight: 700; }
        h1, h2 { border-bottom: none; padding-bottom: 0; }
        a { color: #1a4b8c; }
        blockquote { border-left: 3px solid rgba(128,128,128,0.45); border-radius: 0; background: none; }
        code { background: none; padding: 0; }
        pre { background: none; border: 1px solid rgba(128,128,128,0.35); border-radius: 0; }
        table { border-top: 2px solid rgba(128,128,128,0.8); border-bottom: 2px solid rgba(128,128,128,0.8); }
        th, td { border: none; }
        thead th { border-bottom: 1px solid rgba(128,128,128,0.6); }
        tbody tr:nth-child(odd) { background: none; }
        .math-display { text-align: center; padding-left: 0; }
        .math-display .katex-display { text-align: center; }
        .math-display .katex-display > .katex { text-align: center; }
        @media (prefers-color-scheme: dark) {
            a { color: #7da7d9; }
        }
        """
    )

    /// GitHub-flavored documentation look: gray code panels, gray quote bar,
    /// bordered striped tables, the familiar link blue.
    static let technical = PreviewTheme(
        id: "technical",
        title: String(localized: "Technical"),
        bodyFontStack: nil,
        css: """
        h1, h2 { border-bottom: 1px solid #d0d7de; }
        a { color: #0969da; }
        code { background: rgba(129,139,152,0.18); border-radius: 6px; }
        pre { background: #f6f8fa; border: 1px solid #d0d7de; border-radius: 6px; }
        blockquote { border-left: 4px solid #d0d7de; border-radius: 0; background: none; color: #59636e; opacity: 1; }
        blockquote.callout { color: inherit; border-left-color: rgb(var(--callout-rgb)); background: rgba(var(--callout-rgb),0.09); }
        th, td { border: 1px solid #d0d7de; }
        tbody tr:nth-child(odd) { background: none; }
        tbody tr:nth-child(even) { background: #f6f8fa; }
        hr { border-top: 2px solid #d0d7de; }
        @media (prefers-color-scheme: dark) {
            h1, h2 { border-bottom-color: #30363d; }
            a { color: #4493f8; }
            pre { background: #161b22; border-color: #30363d; }
            blockquote { border-left-color: #30363d; color: #8b949e; }
            blockquote.callout { background: rgba(var(--callout-rgb),0.14); }
            th, td { border-color: #30363d; }
            tbody tr:nth-child(even) { background: #161b22; }
            hr { border-top-color: #30363d; }
        }
        """
    )

    /// Typora's default look — the "Github" theme from
    /// typora/typora-default-themes: bold headings on hairline rules, the
    /// #4183C4 link blue, bordered light-gray code panels with a 3px radius,
    /// plain gray quote text without a wash, and fully bordered tables with a
    /// painted header row. Dark values come from Typora's own Night theme
    /// palette (#474d54 borders, #9DA2A6 muted text).
    static let typora = PreviewTheme(
        id: "typora",
        title: String(localized: "Typora"),
        bodyFontStack: "\"Open Sans\", \"Clear Sans\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        css: """
        h1, h2, h3, h4, h5, h6 { font-weight: bold; line-height: 1.4; margin: 1rem 0; }
        h1 { font-size: 2.25em; line-height: 1.2; }
        h2 { font-size: 1.75em; line-height: 1.225; }
        h3 { font-size: 1.5em; line-height: 1.43; }
        h4 { font-size: 1.25em; }
        h5 { font-size: 1em; }
        h6 { font-size: 1em; color: #777; opacity: 1; }
        h1, h2 { border-bottom: 1px solid #eee; padding-bottom: 0; }
        h1 code, h2 code, h3 code, h4 code, h5 code, h6 code { font-size: inherit; }
        p { margin: 0.8em 0; }
        ul, ol { margin: 0.8em 0; padding-left: 30px; }
        li > ul, li > ol { margin: 0; }
        a { color: #4183C4; }
        code { border: 1px solid #e7eaed; background: #f3f4f4; border-radius: 3px; padding: 0 2px; font-size: 0.9em; }
        pre { background: #f8f8f8; border: 1px solid #e7eaed; border-radius: 3px; padding: 8px 12px 6px; }
        pre code { border: none; font-size: 0.9em; }
        blockquote { border-left: 4px solid #dfe2e5; border-radius: 0; background: none; padding: 0 15px; color: #777777; opacity: 1; }
        blockquote.callout { color: inherit; }
        hr { border: none; height: 2px; background-color: #e7e7e7; margin: 16px 0; }
        table { margin: 0.8em 0; }
        th, td { border: 1px solid #dfe2e5; padding: 6px 13px; }
        th { font-weight: bold; }
        thead { background: #f8f8f8; }
        tbody tr:nth-child(odd) { background: none; }
        tbody tr:nth-child(even) { background: #f8f8f8; }
        @media (prefers-color-scheme: dark) {
            h1, h2 { border-bottom-color: #474d54; }
            h6 { color: #9DA2A6; }
            a { color: #81b1db; }
            code { border-color: #474d54; background: rgba(255,255,255,0.06); }
            pre { background: rgba(255,255,255,0.05); border-color: #474d54; }
            blockquote { border-left-color: #474d54; color: #9DA2A6; }
            hr { background-color: #474d54; }
            th, td { border-color: #474d54; }
            thead { background: rgba(255,255,255,0.05); }
            tbody tr:nth-child(even) { background: rgba(255,255,255,0.05); }
        }
        """
    )

    /// Selection order for the Settings ▸ Preview picker.
    static let allPresets: [PreviewTheme] = [
        .standard, .minimal, .literary, .academic, .technical, .typora,
    ]

    /// Looks up a theme by its persisted id, falling back to the default look
    /// for unknown/legacy ids.
    static func preset(named name: String) -> PreviewTheme {
        allPresets.first { $0.id == name } ?? .standard
    }
}
