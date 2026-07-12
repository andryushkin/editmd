import CoreGraphics

/// Where the text and its line-number rail sit inside an editor pane.
///
/// All three modes now draw numbers INSIDE the text's left margin — Source and
/// Visual in the text view's inset, Preview in the body's left padding — so the
/// column position never depends on whether numbers are shown. The action strip
/// and the gutter toggle both read this, so they cannot drift apart.
struct EditorFieldGeometry {
    /// Left edge of the text within the pane.
    var textLeading: CGFloat
    /// Slack on the right of the column (the rail shifts nothing there).
    var textTrailing: CGFloat
    /// Numbers → text gap, so the toggle can sit right over the digits.
    var railGap: CGFloat

    /// Trailing edge of the numbers column: the toggle aligns its right edge
    /// here, exactly where the digits end.
    var railTrailingX: CGFloat { max(0, textLeading - railGap) }
}
