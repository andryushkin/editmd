import AppKit
import Markdown

// Shared add / edit / remove-link support: the ⌘K link editor (Source and
// Visual) and the no-selection URL paste form. Pure helpers are unit-tested;
// the NSAlert prompt is the single dialog both modes present.

// MARK: - Serialization

/// Autolink form for a bare URL pasted with **no** selection: `<url>` renders
/// as a clickable link in all three modes and round-trips, whereas a plain
/// bare URL stays literal text (the renderer does not GFM-autolink). The paste
/// detector already guarantees no internal whitespace; a `<`/`>` inside the URL
/// (never valid in a CommonMark autolink) falls back to the `[url](url)` form.
func markdownAutolinkSyntax(url: String) -> String {
    if url.contains("<") || url.contains(">") {
        return markdownLinkSyntax(text: url, url: url)
    }
    return "<\(url)>"
}

// MARK: - Existing-link lookup (Source ⌘K)

/// An inline `[text](dest)` link located in raw markdown.
struct InlineLinkMatch: Equatable {
    /// Full `[text](dest)` span in the source (UTF-16).
    var range: NSRange
    /// Link label (the rendered text between the brackets).
    var text: String
    /// Destination as authored (angle brackets already stripped by the parser).
    var url: String
}

/// The inline link whose full span contains `caret` (a UTF-16 offset into
/// `source`), or nil when the caret isn't on a link. Built from the
/// swift-markdown AST, so escapes, angle-bracket destinations and code-span
/// exclusion are handled the same way the renderer handles them. A caret at
/// either edge of the span counts as inside, so ⌘K just past a link still edits
/// it. An autolink (`<url>`) matches too — its label prefills with the URL, so
/// ⌘K there converts it into a regular `[url](url)` link.
func inlineLinkMatch(in source: String, at caret: Int) -> InlineLinkMatch? {
    guard !source.isEmpty else { return nil }
    let lineIdx = LineIndex(source)
    let document = Document(parsing: source)
    var collector = InlineLinkRangeCollector(lineIdx: lineIdx)
    collector.visit(document)
    // Innermost wins if links ever nest: the last (deepest-visited) containing
    // match is returned.
    var best: InlineLinkMatch?
    for m in collector.matches
    where caret >= m.range.location && caret <= NSMaxRange(m.range) {
        if best == nil || m.range.length <= best!.range.length {
            best = m
        }
    }
    return best
}

private struct InlineLinkRangeCollector: MarkupWalker {
    let lineIdx: LineIndex
    var matches: [InlineLinkMatch] = []

    private func nsRange(for src: SourceRange) -> NSRange? {
        let loc = lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
        let end = lineIdx.offset(src.upperBound.line, src.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    mutating func visitLink(_ link: Link) {
        // Autolinks (`<url>`) are collected too: their label prefills with the
        // URL, so ⌘K on one edits it into a regular `[text](url)` link (see
        // the doc comment on `inlineLinkMatch`).
        if let dest = link.destination, let src = link.range,
           let r = nsRange(for: src), r.length >= 2 {
            matches.append(InlineLinkMatch(range: r, text: link.plainText, url: dest))
        }
        descendInto(link)
    }
}

// MARK: - Add / edit / remove prompt

/// The outcome of the ⌘K link dialog.
enum LinkEditResult: Equatable {
    /// OK with a non-empty URL. `text` may be empty (caller falls back to URL).
    case apply(text: String, url: String)
    /// The "Remove Link" button (only offered when editing an existing link).
    case remove
    /// Cancel, close, or OK with an empty URL (a no-op).
    case cancel
}

/// Presents the shared add/edit-link dialog. `existingURL` non-empty switches
/// the title to "Edit Link" and offers "Remove Link". Runs modally on the main
/// thread; returns the user's choice.
@MainActor
func runLinkEditPrompt(existingText: String, existingURL: String) -> LinkEditResult {
    let editing = !existingURL.isEmpty
    let alert = NSAlert()
    alert.messageText = editing ? String(localized: "Edit Link") : String(localized: "Add Link")
    alert.informativeText = String(localized: "Display text and URL:")

    let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    textField.stringValue = existingText
    textField.placeholderString = String(localized: "Link text")
    let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    urlField.stringValue = existingURL
    urlField.placeholderString = "https://"
    stack.addArrangedSubview(textField)
    stack.addArrangedSubview(urlField)
    alert.accessoryView = stack
    alert.addButton(withTitle: String(localized: "OK"))
    alert.addButton(withTitle: String(localized: "Cancel"))
    if editing { alert.addButton(withTitle: String(localized: "Remove Link")) }

    // Adding a link starts in the URL field (the label is usually the
    // selection); editing an existing one starts in its text.
    let response = runModal(alert, focusing: existingURL.isEmpty ? urlField : textField)
    let url = urlField.stringValue.trimmingCharacters(in: .whitespaces)
    let text = textField.stringValue

    switch response {
    case .alertFirstButtonReturn where !url.isEmpty:
        return .apply(text: text, url: url)
    case .alertThirdButtonReturn:
        return .remove
    default:
        return .cancel
    }
}
