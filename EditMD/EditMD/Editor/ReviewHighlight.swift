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
    static func displayHighlights(marks: [ReviewMark], displayText: String)
        -> [ReviewAnchorHighlight] {
        marks.compactMap { m in
            guard m.isOpen, let quote = m.quote, !quote.isEmpty else { return nil }
            // Prefer a match near the stored start (clamped into display), then
            // fall back to a global search — same ladder as `_find_anchor`, but
            // without prefix (display has no markers / different surrounding).
            guard let range = ReviewSidecar.anchorRange(
                quote: quote, prefix: "", start: m.start ?? 0, in: displayText)
            else { return nil }
            let tip: String
            if m.isSuggestion, let repl = m.replacement {
                tip = "suggest: \(repl)"
            } else if let note = m.note, !note.isEmpty {
                tip = "\(m.markType?.label ?? m.type): \(note)"
            } else {
                tip = m.markType?.label ?? m.type
            }
            return ReviewAnchorHighlight(
                id: m.id, range: NSRange(range, in: displayText),
                type: m.markType, tooltip: tip)
        }
    }
}
