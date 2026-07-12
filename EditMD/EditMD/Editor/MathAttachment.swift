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
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var renderer = MathImage(latex: trimmed, fontSize: fontSize,
                                 textColor: resolvedLabelColor(),
                                 labelMode: display ? .display : .text,
                                 textAlignment: .left)
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image, image.size.width > 0 else { return nil }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -(layout?.descent ?? 0),
                                   width: image.size.width, height: image.size.height)
        return attachment
    }

    /// Render just the image (popover live preview).
    static func previewImage(tex: String, display: Bool,
                             fontSize: CGFloat) -> NSImage? {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var renderer = MathImage(latex: trimmed, fontSize: fontSize,
                                 textColor: resolvedLabelColor(),
                                 labelMode: display ? .display : .text,
                                 textAlignment: .left)
        let (error, image, _) = renderer.asImage()
        guard error == nil else { return nil }
        return image
    }

    /// The image bakes its color in, so the dynamic labelColor must be
    /// resolved against the app's appearance NOW (a theme switch later shows
    /// the old color until the document re-renders — known cosmetic gap).
    private static func resolvedLabelColor() -> NSColor {
        var resolved = NSColor.labelColor
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
        }
        return resolved
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
