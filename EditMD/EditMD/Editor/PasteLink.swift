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

/// Canonical inline-link serializer: `[text](url)`. The label escapes `\`, `[`
/// and `]`; a destination carrying spaces or parens is angle-bracketed so the
/// link can't be broken by the URL (mirrors the image serializer's
/// `formatDestination`).
func markdownLinkSyntax(text: String, url: String) -> String {
    let label = text
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "[", with: "\\[")
        .replacingOccurrences(of: "]", with: "\\]")
    let dest = (url.contains(" ") || url.contains("(") || url.contains(")"))
        ? "<\(url)>" : url
    return "[\(label)](\(dest))"
}
