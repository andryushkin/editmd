import AppKit

// In-text wash for open review marks (v37 step C). Temporary layout-manager
// attributes only — never touch NSTextStorage (document + undo stay clean),
// matching the lint-underline pattern in SourceTextView.
//
// Source resolves anchors against the raw markdown (same as the sidecar).
// Visual searches the display plain text for `quote` (markers are gone there;
// a selection captured in Visual already maps to body text without `# `/`> `).

enum ReviewHighlight {

    /// Soft background wash by mark type. Low alpha so syntax colors remain.
    static func color(for type: ReviewMarkType?) -> NSColor {
        switch type {
        case .question: return NSColor.systemBlue.withAlphaComponent(0.18)
        case .fix: return NSColor.systemOrange.withAlphaComponent(0.18)
        case .rewrite: return NSColor.systemPurple.withAlphaComponent(0.18)
        case .cut: return NSColor.systemRed.withAlphaComponent(0.16)
        case .keep: return NSColor.systemGray.withAlphaComponent(0.16)
        case .comment: return NSColor.systemYellow.withAlphaComponent(0.22)
        case .suggest: return NSColor.systemGreen.withAlphaComponent(0.18)
        case .none: return NSColor.systemYellow.withAlphaComponent(0.18)
        }
    }

    /// Clears previous washes and paints the given ranges. Empty `highlights`
    /// just clears. Safe to call when the layout manager is missing (no-op).
    ///
    /// Only `backgroundColor` is touched — lint owns temporary tooltips /
    /// underlines, and the two must not wipe each other out.
    static func apply(to textView: NSTextView, highlights: [ReviewAnchorHighlight]) {
        guard let lm = textView.layoutManager else { return }
        let len = (textView.string as NSString).length
        let full = NSRange(location: 0, length: len)
        lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)

        for h in highlights {
            guard h.range.location < len else { continue }
            let r = NSRange(location: h.range.location,
                            length: min(h.range.length, len - h.range.location))
            guard r.length > 0 else { continue }
            lm.addTemporaryAttribute(.backgroundColor,
                                     value: color(for: h.type),
                                     forCharacterRange: r)
        }
    }

    /// Visual path: locate each open mark's `quote` inside the *display* string
    /// (plainText search). Prefix is ignored — it may contain raw-markdown
    /// context that does not appear in WYSIWYG text.
    ///
    /// `hintForRawOffset` translates the mark's raw-markdown `start` into a
    /// display offset (Visual's paragraph map). The raw offset itself must NOT
    /// be used as the hint: display text is shorter (markers stripped), so a
    /// raw hint can overshoot the true occurrence and wash a later duplicate.
    static func displayHighlights(marks: [ReviewMark], displayText: String,
                                  hintForRawOffset: (Int) -> Int? = { _ in nil })
        -> [ReviewAnchorHighlight] {
        marks.compactMap { m in
            guard m.isOpen, let quote = m.quote, !quote.isEmpty else { return nil }
            let hint = m.start.flatMap(hintForRawOffset) ?? 0
            guard let range = ReviewSidecar.anchorRange(
                quote: quote, prefix: "", start: hint, in: displayText)
            else { return nil }
            return ReviewAnchorHighlight(
                id: m.id, range: NSRange(range, in: displayText),
                type: m.markType, tooltip: m.washTooltip)
        }
    }
}
