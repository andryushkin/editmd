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
    /// Hand-rolled `MathImage` equivalent (same public building blocks) so the
    /// parsed list can be opened up before typesetting.
    private static func renderMask(tex: String, display: Bool,
                                   fontSize: CGFloat) -> (NSImage, MathImage.LayoutInfo?)? {
        let trimmed = tex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var error: NSError?
        guard let mathList = MTMathListBuilder.build(fromString: trimmed, error: &error),
              error == nil else { return nil }
        openUp(mathList)
        // MTTypesetter is internal, so a throwaway MTMathUILabel is the only
        // public way to typeset an already-parsed (opened-up) list. NSView ⇒
        // main thread; off-main callers get the stock path and stock spacing.
        guard Thread.isMainThread else { return stockRender(trimmed, display: display,
                                                            fontSize: fontSize) }
        nonisolated(unsafe) var typeset: MTMathListDisplay?
        MainActor.assumeIsolated {
            let label = MTMathUILabel()
            label.font = MathFont.latinModernFont.mtfont(size: fontSize)
            label.fontSize = fontSize
            label.labelMode = display ? .display : .text
            label.textAlignment = .left
            label.textColor = .black
            label.mathList = mathList
            let fitting = label.fittingSize
            guard fitting.width > 0 else { return }
            // layout() positions the display list inside these bounds with the
            // same centering formula MathImage uses; `position` is internal,
            // so the frame is the only way to steer it.
            label.frame = CGRect(x: 0, y: 0,
                                 width: ceil(fitting.width),
                                 height: ceil(max(fitting.height, fontSize / 2)))
            label.layout()
            typeset = label.displayList
        }
        guard let displayList = typeset else {
            return stockRender(trimmed, display: display, fontSize: fontSize)
        }
        let contentHeight = max(displayList.ascent + displayList.descent, fontSize / 2)
        let size = CGSize(width: ceil(displayList.width), height: ceil(contentHeight))
        guard size.width > 0, size.height > 0 else { return nil }
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            displayList.draw(context)
            context.restoreGState()
            return true
        }
        return (image, MathImage.LayoutInfo(ascent: displayList.ascent,
                                            descent: displayList.descent))
    }

    /// The unmodified `MathImage` pipeline — parse-error and off-main fallback.
    private static func stockRender(_ tex: String, display: Bool,
                                    fontSize: CGFloat) -> (NSImage, MathImage.LayoutInfo?)? {
        var renderer = MathImage(latex: tex, fontSize: fontSize,
                                 textColor: .black,
                                 labelMode: display ? .display : .text,
                                 textAlignment: .left)
        let (error, image, layout) = renderer.asImage()
        guard error == nil, let image, image.size.width > 0 else { return nil }
        return (image, layout)
    }

    /// SwiftMath spaces `aligned`/`gather`/`eqnarray` rows one \jot apart,
    /// which reads cramped once rows carry integrals or fractions — open those
    /// up. Matrices and `cases` declare 0 and keep their tight grid.
    private static func openUp(_ list: MTMathList) {
        for atom in list.atoms {
            if let table = atom as? MTMathTable {
                if table.interRowAdditionalSpacing > 0 {
                    table.interRowAdditionalSpacing += 1.5
                }
                for row in table.cells { for cell in row { openUp(cell) } }
            }
            if let sub = atom.subScript { openUp(sub) }
            if let sup = atom.superScript { openUp(sup) }
            if let fraction = atom as? MTFraction {
                fraction.numerator.map(openUp)
                fraction.denominator.map(openUp)
            }
            if let radical = atom as? MTRadical {
                radical.radicand.map(openUp)
                radical.degree.map(openUp)
            }
            if let inner = atom as? MTInner { inner.innerList.map(openUp) }
            if let over = atom as? MTOverLine { over.innerList.map(openUp) }
            if let under = atom as? MTUnderLine { under.innerList.map(openUp) }
            if let accent = atom as? MTAccent { accent.innerList.map(openUp) }
        }
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
