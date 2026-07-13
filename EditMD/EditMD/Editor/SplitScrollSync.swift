import AppKit

/// Split-mode scroll sync — the geometry Source and Visual share.
///
/// The shared coordinate is a FRACTIONAL markdown offset: the paragraph at the
/// TOP of the viewport, plus how far down that paragraph the top edge has
/// travelled, expressed in characters. Preview maps it to a Y by interpolating
/// between its own anchors.
///
/// Anchoring the BOTTOM edge (an earlier cut) is what made Preview sit still
/// while the editor already scrolled: to put the editor's last visible line at
/// its own bottom edge, Preview needs `y - viewportHeight`, which is negative —
/// and clamps to zero — for the whole first screenful. Whenever the panes have
/// different content heights, one of them pays that debt. The top edge is
/// shared: both panes start at zero and move together.
///
/// Syncing a LINE (a character index, or a line plus a sub-line fraction) is
/// also wrong: the editor's line and Preview's line are different objects,
/// since the panes wrap at different column widths. A paragraph-relative
/// position has no such dependency — it is monotonic on both sides, so the
/// follow is monotonic too.
enum SplitScrollSync {

    /// Gap between the anchor and the viewport's top edge. The JS side uses the
    /// same 8px, so a position that goes editor → Preview → editor is a fixed
    /// point.
    static let anchorInset: CGFloat = 8

    /// Inline presentation can alter a Visual line's metrics by a few pixels.
    /// Treat only that scale as layout jitter; real caret-follow scrolls are
    /// deliberately outside this window.
    static func isMinorLayoutDrift(_ drift: CGFloat) -> Bool {
        abs(drift) > 0.01 && abs(drift) <= 4
    }

    enum Edge { case top, bottom }

    /// Where the viewport sits in the document.
    enum Position {
        /// Content fits on one screen — no scroll position to share.
        case unscrollable
        case atEdge(Edge)
        case middle
    }

    /// Computed from the clip view, not `verticalScroller.doubleValue`: a
    /// scroller reports 0 both at the top AND when the content fits on one
    /// screen, which pinned Preview to the top for every short document.
    static func position(of textView: NSTextView) -> Position {
        guard let scroll = textView.enclosingScrollView,
              let documentView = scroll.documentView else { return .unscrollable }
        let visible = scroll.contentView.bounds
        let maxY = documentView.frame.height - visible.height
        guard maxY > 0.5 else { return .unscrollable }
        if visible.minY <= 0.5 { return .atEdge(.top) }
        if visible.minY >= maxY - 0.5 { return .atEdge(.bottom) }
        return .middle
    }

    /// The paragraph crossing the top edge, and how far down it the edge sits
    /// (0…1 of the paragraph's HEIGHT, wrapped lines included).
    struct ParagraphAnchor {
        /// Display-space character range of the paragraph.
        let range: NSRange
        let fraction: Double
    }

    static func visibleParagraphAnchor(in textView: NSTextView) -> ParagraphAnchor? {
        guard let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        let text = textView.string as NSString
        guard text.length > 0 else { return nil }

        let visible = scroll.contentView.bounds
        // Container coordinates — the layout manager knows nothing of the inset.
        let edgeY = visible.minY + anchorInset - textView.textContainerOrigin.y
        let glyph = layout.glyphIndex(for: NSPoint(x: 1, y: max(0, edgeY)), in: container)
        let charIndex = layout.characterIndexForGlyph(at: glyph)
        let paragraph = text.paragraphRange(
            for: NSRange(location: min(charIndex, text.length - 1), length: 0))

        guard let rect = boundingRect(of: paragraph, in: textView) else { return nil }
        let fraction = rect.height > 0 ? (edgeY - rect.minY) / rect.height : 0
        return ParagraphAnchor(range: paragraph,
                               fraction: min(1, max(0, Double(fraction))))
    }

    /// Scrolls the viewport only — selection and first responder are untouched,
    /// so following Preview never steals the caret. Exactly inverts
    /// `visibleParagraphAnchor`.
    static func scrollViewport(_ textView: NSTextView,
                               toParagraph paragraph: NSRange,
                               fraction: Double,
                               edge: Edge?) {
        guard let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let clip = scroll.contentView
        var proposed = clip.bounds

        switch edge {
        case .top:
            proposed.origin.y = 0
        case .bottom:
            // A "large enough" sentinel is NOT safe: constrainBoundsRect does
            // arithmetic on it, and an overflowed origin makes AppKit snap the
            // scroll to zero — landing at the TOP exactly when Preview reached
            // its bottom. Ask the layout manager for the real height instead.
            layout.ensureLayout(for: container)
            let documentHeight = scroll.documentView?.frame.height ?? proposed.height
            proposed.origin.y = max(0, documentHeight - proposed.height)
        case nil:
            guard let rect = boundingRect(of: paragraph, in: textView) else { return }
            let clamped = CGFloat(min(1, max(0, fraction)))
            let edgeY = rect.minY + rect.height * clamped + textView.textContainerOrigin.y
            proposed.origin.y = edgeY - anchorInset
        }

        let constrained = clip.constrainBoundsRect(proposed)
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// Union rect of a character range, in container coordinates.
    private static func boundingRect(of range: NSRange, in textView: NSTextView) -> NSRect? {
        guard let layout = textView.layoutManager,
              let container = textView.textContainer else { return nil }
        layout.ensureLayout(forCharacterRange: range)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.height > 0 ? rect : nil
    }
}
