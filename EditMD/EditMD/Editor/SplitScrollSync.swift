import AppKit

/// Split-mode scroll sync — the geometry Source and Visual share.
///
/// The synced character is anchored near the BOTTOM of the viewport (matching
/// the top accumulates drift when Preview's blocks are taller than the source
/// lines that produced them). Two numbers make that anchoring round-trip:
/// `scrollViewport` leaves the anchored line `anchorInset` above the bottom
/// edge, and `visibleAnchorIndex` samples 1pt INSIDE that same line. Sampling
/// below it (as the first cut did) returns the NEXT line, so an offset that
/// went Preview → editor came back one line further down and pushed Preview
/// along on every wheel event.
enum SplitScrollSync {

    /// Gap between the anchored line's bottom and the viewport's bottom edge.
    /// The JS side (`syncScrollToMdOffset`) uses the same 8px.
    static let anchorInset: CGFloat = 8

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
    /// screen, so a short document pinned Preview to the top forever — even
    /// when Preview itself (tall images, formulas) had plenty to scroll.
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

    /// Character index (UTF-16, display space) at the bottom anchor line.
    static func visibleAnchorIndex(in textView: NSTextView) -> Int {
        guard let scroll = textView.enclosingScrollView else {
            return textView.selectedRange().location
        }
        let visible = scroll.contentView.bounds
        let point = textView.convert(
            NSPoint(x: visible.minX + 4, y: visible.maxY - anchorInset - 1),
            from: scroll.contentView)
        let index = textView.characterIndexForInsertion(at: point)
        return max(0, min(index, (textView.string as NSString).length))
    }

    /// Scrolls the viewport only — selection and first responder are untouched,
    /// so following Preview never steals the caret.
    static func scrollViewport(_ textView: NSTextView,
                               toCharacterIndex target: Int,
                               edge: Edge?) {
        guard let scroll = textView.enclosingScrollView,
              let layout = textView.layoutManager,
              let container = textView.textContainer else { return }
        let clip = scroll.contentView
        var proposed = clip.bounds
        switch edge {
        case .top:
            proposed.origin.y = -.greatestFiniteMagnitude / 2
        case .bottom:
            proposed.origin.y = .greatestFiniteMagnitude / 2
        case nil:
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            let range = NSRange(location: max(0, min(target, length - 1)), length: 1)
            layout.ensureLayout(forCharacterRange: range)
            let glyphs = layout.glyphRange(forCharacterRange: range,
                                           actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.y += textView.textContainerOrigin.y
            proposed.origin.y = rect.maxY - proposed.height + anchorInset
        }
        let constrained = clip.constrainBoundsRect(proposed)
        clip.scroll(to: constrained.origin)
        scroll.reflectScrolledClipView(clip)
    }
}
