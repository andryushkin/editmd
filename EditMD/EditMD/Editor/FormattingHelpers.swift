import Foundation

// Pure helpers — no AppKit dependency, easy to unit-test.

/// Returns (words, chars) for the given string.
func wordAndCharCount(in text: String) -> (words: Int, chars: Int) {
    let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.count
    return (words, text.count)
}

/// Wraps `selection` in `marker…marker`, returning the new full string and
/// the new selection range (covers the wrapped text; if original was empty,
/// positions cursor between the markers).
func applyWrap(marker: String, to text: String, selection: NSRange) -> (newText: String, newSelection: NSRange) {
    let nsText = text as NSString
    let selected = nsText.substring(with: selection)
    let wrapped = marker + selected + marker
    let newText = nsText.replacingCharacters(in: selection, with: wrapped)
    let newSelection: NSRange = selection.length == 0
        ? NSRange(location: selection.location + marker.count, length: 0)
        : NSRange(location: selection.location, length: wrapped.count)
    return (newText, newSelection)
}
