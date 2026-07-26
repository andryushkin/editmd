import Foundation

// URL-linkify door for paste: when the clipboard is exactly one web URL and it
// is dropped onto a non-empty selection, the selection becomes a Markdown link
// `[selection](url)`. With no selection the normal plain-text paste path runs
// (the URL is inserted verbatim). Pure helpers so Source and Visual share one
// detector and one serializer. Only fires at paste time — there is no live
// linkification as the user types, so deleting the formatting afterwards never
// brings it back.

/// The clipboard string when it is exactly a single web URL — one line, an
/// http/https scheme, a non-empty host, and no internal whitespace. Returns the
/// trimmed URL, else nil. Conservative on purpose: ordinary prose (even a
/// sentence that contains a URL) must keep the normal plain-text paste path.
func bareWebURLForPaste(_ pasteboardString: String?) -> String? {
    guard let raw = pasteboardString else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.unicodeScalars.contains(where: {
              CharacterSet.whitespacesAndNewlines.contains($0)
          }),
          let url = URL(string: trimmed),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false
    else { return nil }
    return trimmed
}

/// True when the selection can serve as a link label. A newline inside the
/// label breaks the `[label](url)` syntax outright when a blank line follows,
/// and reads as an accident either way — multi-line selections keep the
/// normal plain-text paste path instead of linkifying.
func selectionUsableAsLinkLabel(_ text: String) -> Bool {
    !text.contains(where: \.isNewline)
}

/// Canonical inline-link serializer: `[text](url)`. The label escapes `\`, `[`
/// and `]`; a destination carrying spaces or parens is angle-bracketed so the
/// link can't be broken by the URL (mirrors the image serializer's
/// `formatDestination`).
func markdownLinkSyntax(text: String, url: String) -> String {
    markdownLinkSyntax(rawLabel: text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]"),
        url: url)
}

/// Same, for a label that is already markdown source — an existing link's label
/// put back unchanged (`**bold**`), which must not be escaped a second time.
func markdownLinkSyntax(rawLabel: String, url: String) -> String {
    let dest = (url.contains(" ") || url.contains("(") || url.contains(")"))
        ? "<\(url)>" : url
    return "[\(rawLabel)](\(dest))"
}
