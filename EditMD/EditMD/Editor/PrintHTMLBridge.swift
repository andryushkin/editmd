import Foundation

/// Translates print intent into the vocabulary of the HTML render path.
///
/// Print declares itself in points on paper; the page source it currently
/// draws from is the same HTML the Preview uses, which speaks CSS. Everything
/// in this file is that adapter and nothing else — no print decision is taken
/// here, and the whole file goes away with the interim source. Keeping it
/// separate is what lets `PrintSettings` and `PrintTheme` stay free of CSS.
enum PrintHTMLBridge {

    /// Quoted CSS `font-family` list, with a generic fallback so a family the
    /// machine does not have still lands on something.
    static func fontStack(_ families: [String], generic: String) -> String {
        let quoted = families
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\"\($0)\"" }
        return (quoted + [generic]).joined(separator: ", ")
    }

    /// The theme layer for a print render. Injected as `themeCSS`, i.e. after
    /// the page's base rules and before the user's per-element overrides, so
    /// the cascade Print sees is the same one Preview documents.
    ///
    /// The page is forced to black on white: the render happens in an offscreen
    /// web view that inherits the app's appearance, and `Canvas`/`CanvasText`
    /// under a dark appearance would print white text onto white paper.
    static func pageCSS(settings: PrintSettings, theme: PrintTheme) -> String {
        let body = fontStack(theme.resolvedBodyFamilies(userFamily: settings.fontFamily),
                             generic: "serif")
        let heading = fontStack(theme.resolvedHeadingFamilies(userFamily: settings.fontFamily),
                                generic: "serif")
        let mono = fontStack(theme.monoFamilies, generic: "monospace")
        // Emitted in px, not pt: the capture maps one CSS pixel to one PDF
        // point, so a size chosen for paper reaches the page unscaled only in
        // px. In pt it would arrive a third too large.
        let size = String(format: "%.2f", settings.fontSize)
        let leading = String(format: "%.3g", settings.lineHeight)
        return """
        html, body { background: #fff; color: #000; }
        body {
            font-family: \(body);
            font-size: \(size)px;
            line-height: \(leading);
            /* Paper margins belong to the page, not the text frame. */
            padding: 0; margin: 0; max-width: none;
        }
        h1, h2, h3, h4, h5, h6 { font-family: \(heading); }
        code, pre, pre code, kbd, samp { font-family: \(mono); }
        /* Break control. A heading that lands at the foot of a page with its
           text overleaf reads as a mistake; two lines is the smallest orphan
           worth avoiding without pushing large holes into the page. */
        h1, h2, h3, h4, h5, h6 { break-after: avoid-page; }
        p, li, blockquote { orphans: 2; widows: 2; }
        table, figure, img { break-inside: avoid-page; }
        thead { display: table-header-group; }
        /* A long listing must be allowed to split — `avoid` on a page-tall
           block silently leaves the rest of the page empty and splits anyway. */
        pre { break-inside: auto; }
        /* Screen affordances that mean nothing on paper. */
        a { color: #000; text-decoration: underline; }
        ::selection { background: transparent; }
        """
    }
}
