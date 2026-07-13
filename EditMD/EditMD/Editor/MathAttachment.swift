import AppKit
import SwiftMath

extension NSAttributedString.Key {
    /// Verbatim math source (`$…$` / `$$…$$`) carried by a RENDERED formula
    /// attachment in Visual. The serializer re-emits this string unchanged
    /// (real newlines inside), so the file round-trips even though the run's
    /// display text is a single U+FFFC attachment character.
    static let mdMathTex = NSAttributedString.Key("md.mathTex")  // String
}

/// SwiftMath (native iosMath port) rendering for Visual-mode formulas.
/// Preview keeps KaTeX — this path exists because WKWebView can't live
/// inside NSTextView; SwiftMath typesets synchronously into an image.
enum MathRender {

    /// TeX → image attachment with a proper baseline (LayoutInfo.descent).
    /// Returns nil when SwiftMath can't parse the TeX — callers fall back to
    /// the tinted raw-text run (still verbatim-serialized via `.mdMath`).
    static func attachment(tex: String, display: Bool,
                           fontSize: CGFloat) -> NSTextAttachment? {
        guard let (mask, layout) = renderMask(tex: tex, display: display,
                                              fontSize: fontSize) else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = tinted(mask)
        attachment.bounds = CGRect(x: 0, y: -(layout?.descent ?? 0),
                                   width: mask.size.width, height: mask.size.height)
        return attachment
    }

    /// Render just the image (popover live preview).
    static func previewImage(tex: String, display: Bool,
                             fontSize: CGFloat) -> NSImage? {
        guard let (mask, _) = renderMask(tex: tex, display: display,
                                         fontSize: fontSize) else { return nil }
        return tinted(mask)
    }

    /// SwiftMath bakes `textColor` into the bitmap, so the formula is typeset
    /// ONCE as an opaque silhouette; the color lands at draw time instead.
    private static func renderMask(tex: String, display: Bool,
                                   fontSize: CGFloat) -> (NSImage, MathImage.LayoutInfo?)? {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var renderer = MathImage(latex: trimmed, fontSize: fontSize,
                                 textColor: .black,
                                 labelMode: display ? .display : .text,
                                 textAlignment: .left)
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image, image.size.width > 0 else { return nil }
        return (image, layout)
    }

    /// Tint the silhouette with `labelColor` inside a drawing handler: the
    /// handler runs per draw, with the *view's* current appearance, so ☀/🌙
    /// overrides and system theme flips are honoured. Resolving the color up
    /// front against `NSApp.effectiveAppearance` baked white glyphs into a
    /// light window (same trap as the code-highlight palettes).
    private static func tinted(_ mask: NSImage) -> NSImage {
        let silhouette = mask
        let image = NSImage(size: mask.size, flipped: false) { rect in
            silhouette.draw(in: rect)
            NSColor.labelColor.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        // Without this the first-drawn bitmap is reused after an appearance
        // flip and the glyphs keep the stale color.
        image.cacheMode = .never
        return image
    }

    /// Rebuild the verbatim source from edited TeX. Inline math is single-line
    /// by grammar — newlines collapse to spaces there.
    static func verbatim(tex: String, display: Bool) -> String {
        if display { return "$$" + tex + "$$" }
        return "$" + tex.replacingOccurrences(of: "\n", with: " ") + "$"
    }

    /// Inner TeX of a verbatim `$…$` / `$$…$$` string.
    static func innerTeX(of verbatim: String) -> String {
        if verbatim.hasPrefix("$$"), verbatim.hasSuffix("$$"), verbatim.count >= 4 {
            return String(verbatim.dropFirst(2).dropLast(2))
        }
        if verbatim.hasPrefix("$"), verbatim.hasSuffix("$"), verbatim.count >= 2 {
            return String(verbatim.dropFirst(1).dropLast(1))
        }
        return verbatim
    }
}
