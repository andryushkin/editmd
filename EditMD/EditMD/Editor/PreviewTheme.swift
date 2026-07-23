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
    /// Dark-appearance body stack, for themes whose reference dark look is a
    /// different design with a different family (Typora: Github body is Open
    /// Sans, Night is Helvetica Neue). Emitted by `pageCSS` as a dark-media
    /// rule — and only while the user hasn't picked an explicit family, so a
    /// user choice keeps winning in both appearances. `nil` = one stack.
    let darkBodyFontStack: String?
    /// `@font-face` rules for stack members macOS doesn't ship. Faces embed
    /// bundled files as `data:` URIs: the page CSP allows only
    /// `font-src data:`, an external font URL would never load.
    let fontFacesCSS: String
    /// Reference base font size / reading-column width, for themes ported
    /// from a source that fixes its page geometry. Written into the real
    /// Preview settings once, at selection time, by
    /// `EditorSettings.migratedPreviewGeometry` — render paths always read
    /// plain settings. `nil` = keep whatever the user has.
    let preferredFontSize: CGFloat?
    let preferredColumnWidth: CGFloat?
    /// Rules appended after the page's base CSS (including its dark-mode
    /// block) and before the user's element CSS — later rules win at equal
    /// specificity. Themes deliberately do not set the page background or the
    /// base body text color: `background: Canvas` stays system-adaptive and a
    /// General ▸ Text color override must keep winning.
    let css: String

    init(id: String, title: String, bodyFontStack: String?,
         darkBodyFontStack: String? = nil, fontFacesCSS: String = "",
         preferredFontSize: CGFloat? = nil, preferredColumnWidth: CGFloat? = nil,
         css: String) {
        self.id = id
        self.title = title
        self.bodyFontStack = bodyFontStack
        self.darkBodyFontStack = darkBodyFontStack
        self.fontFacesCSS = fontFacesCSS
        self.preferredFontSize = preferredFontSize
        self.preferredColumnWidth = preferredColumnWidth
        self.css = css
    }

    /// Resolved body `font-family` for the page: an explicit user family
    /// always beats the theme's stack.
    func cssFontFamily(userFamily: String) -> String {
        if !userFamily.isEmpty { return "\"\(userFamily)\", -apple-system, sans-serif" }
        return bodyFontStack ?? "-apple-system, \"Helvetica Neue\", sans-serif"
    }

    /// The theme's complete CSS layer for a page render: bundled font faces,
    /// the look itself, and — while the user keeps the default font — the
    /// dark-appearance body family. `css` alone stays the pure look.
    func pageCSS(userFamily: String) -> String {
        var out = fontFacesCSS + css
        if userFamily.isEmpty, let dark = darkBodyFontStack {
            out += "\n@media (prefers-color-scheme: dark) { body { font-family: \(dark); } }"
        }
        return out
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

    /// Typora's default pair from typora/typora-default-themes — two designs,
    /// not one recolored: light is the "Github" theme (bold Open Sans headings
    /// on #eee hairlines, #4183C4 links, bordered gray code panels, striped
    /// tables), dark is Typora's dark default "Night" (normal-weight Lucida
    /// Grande headings without rules, #e0e0e0 underlined links, indented
    /// 2px-bar quotes, #333 code panels, square bullets, zebra off). Night's
    /// own #363B40 page background is NOT ported: themes keep the system
    /// Canvas. Reference geometry 16px/860px comes from github.css.
    static let typora = PreviewTheme(
        id: "typora",
        title: String(localized: "Typora"),
        bodyFontStack: "\"Open Sans\", \"Clear Sans\", \"Helvetica Neue\", Helvetica, Arial, sans-serif",
        darkBodyFontStack: "\"Helvetica Neue\", Helvetica, Arial, \"Segoe UI Emoji\", \"SF Pro\", sans-serif",
        fontFacesCSS: openSansFontFaces,
        preferredFontSize: 16,
        preferredColumnWidth: 860,
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
            h1, h2, h3, h4, h5, h6 { font-family: "Lucida Grande", "Corbel", sans-serif; font-weight: normal; color: #DEDEDE; }
            h1 { font-size: 2.5rem; line-height: 2.75rem; margin: 2em 0 1.5rem; letter-spacing: -1.5px; }
            h2 { font-size: 1.63rem; line-height: 1.875rem; margin: 0 0 1.5rem; letter-spacing: -1px; font-weight: bold; }
            h3 { font-size: 1.17rem; line-height: 1.5rem; margin: 0 0 1.5rem; letter-spacing: -1px; font-weight: bold; }
            h4 { font-size: 1.12rem; line-height: 1.375rem; margin: 0 0 1.5rem; color: white; }
            h5 { font-size: 0.97rem; line-height: 1.25rem; margin: 0 0 1.5rem; font-weight: bold; }
            h6 { font-size: 0.93rem; line-height: 1rem; margin: 0 0 0.75rem; color: white; }
            h1, h2 { border-bottom: none; padding-bottom: 0; }
            p { margin: 0 0 1.5rem; }
            a { color: #e0e0e0; text-decoration: underline; }
            strong { color: #DEDEDE; }
            code { border: none; border-radius: 0; background: rgba(0,0,0,0.05); padding: 2px 5px; font-size: 0.875em; font-family: Monaco, Consolas, "Andale Mono", "DejaVu Sans Mono", monospace; }
            pre { background: #333; border: none; border-radius: 0; padding: 10px 10px 10px 30px; margin: 0 0 20px; }
            pre code { font-size: 0.875em; }
            blockquote { border-left: 2px solid #474d54; padding: 0 0 0 30px; margin: 35px 0 1.875rem 1.875rem; color: #9DA2A6; }
            hr { background-color: #474d54; margin: 24px 0; }
            ul { list-style: square; }
            ul, ol { margin: 0 0 1.5rem; }
            table { margin: 0 0 1.5rem; display: table; width: 100%; max-width: 100%; }
            th, td { border: 1px solid #474d54; padding: 5px 10px; vertical-align: top; }
            th { color: #DEDEDE; }
            thead { background: none; }
            tbody tr:nth-child(even) { background: none; }
        }
        """
    )

    /// Open Sans faces for the Typora/Github stack, bundled from Typora's own
    /// theme repo (`Resources/opensans/`, Apache 2.0) because macOS doesn't
    /// ship the family — without them the theme silently fell back to
    /// Helvetica Neue, changing metrics and line breaks. The unicode-range
    /// mirrors github.css: latin/latin-ext only, so Cyrillic falls back to
    /// Helvetica Neue exactly like in Typora itself.
    private static let openSansFontFaces: String = {
        let range = "U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC, "
            + "U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, "
            + "U+FFFD, U+0100-024F, U+0259, U+1E00-1EFF, U+2020, U+20A0-20AB, U+20AD-20CF, "
            + "U+2113, U+2C60-2C7F, U+A720-A7FF"
        let faces: [(file: String, weight: String, style: String, locals: String)] = [
            ("opensans-400", "normal", "normal", "local('Open Sans Regular'), local('OpenSans-Regular')"),
            ("opensans-400i", "normal", "italic", "local('Open Sans Italic'), local('OpenSans-Italic')"),
            ("opensans-700", "bold", "normal", "local('Open Sans Bold'), local('OpenSans-Bold')"),
            ("opensans-700i", "bold", "italic", "local('Open Sans Bold Italic'), local('OpenSans-BoldItalic')"),
        ]
        var css = ""
        for face in faces {
            // Like KaTeX: the build may flatten Resources subfolders into the
            // bundle root, so try the subdirectory first, then flat.
            guard let url = Bundle.main.url(forResource: face.file, withExtension: "woff",
                                            subdirectory: "opensans")
                    ?? Bundle.main.url(forResource: face.file, withExtension: "woff"),
                  let data = try? Data(contentsOf: url) else { continue }
            css += """
            @font-face {
                font-family: 'Open Sans';
                font-style: \(face.style);
                font-weight: \(face.weight);
                src: \(face.locals), url(data:font/woff;base64,\(data.base64EncodedString())) format('woff');
                unicode-range: \(range);
            }

            """
        }
        return css
    }()

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
