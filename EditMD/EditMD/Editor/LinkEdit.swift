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

// MARK: - Bare-host normalization

/// Extensions that make a destination a *file in this vault* rather than a web
/// address: `notes.md` is a document, even though `md` is also a country TLD, and
/// in a Markdown editor the file reading is the one that was meant. Built on the
/// wiki-link index set, so a `[[target]]` type and a ⌘K local type cannot drift
/// apart. `html` is deliberately **not** here — `example.com/index.html` is a
/// page, not a file next to the document.
private let vaultFileExtensions: Set<String> =
    WikiLinkCore.indexedExtensions.union(["txt", "csv", "json", "yml", "yaml"])

/// Top-level domains a missing scheme is completed for. A curated list on
/// purpose: by shape alone `example.com` is indistinguishable from `build.sh` or
/// the `2.Areas/note.md` of a PARA vault, and rewriting a vault-relative path
/// into an unreachable URL is far worse than leaving a rare TLD
/// (`mysite.ninja`) to be typed with its scheme. Absent on purpose are the
/// two-letter codes that collide with extensions a vault or repo is full of —
/// `md` as Moldova loses to `md` as Markdown here, likewise `sh`, `rs`, `pl`.
private let completableTLDs: Set<String> = [
    "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz", "pro",
    "io", "co", "ai", "dev", "app", "cloud", "tools", "wiki", "news", "blog",
    "shop", "store", "site", "online", "space", "tech", "digital", "studio",
    "design", "media", "agency", "email", "link", "page", "live", "life",
    "xyz", "top", "art", "fun", "team", "work", "world", "zone", "me", "tv",
    "cc", "ru", "ua", "by", "kz", "uk", "us", "ca", "au", "nz", "de", "fr",
    "es", "it", "nl", "be", "ch", "at", "se", "no", "fi", "dk", "pt", "gr",
    "cz", "hu", "ro", "bg", "si", "sk", "lt", "lv", "ee", "ge", "am", "az",
    "tr", "il", "ae", "in", "cn", "jp", "kr", "hk", "sg", "br", "mx", "ar",
    "cl", "za", "eu", "рф", "укр",
]

/// Schemes that carry no `//` authority, so their colon is the whole signal.
private let authorityLessSchemes: Set<String> =
    ["mailto", "tel", "sms", "geo", "data", "callto", "facetime"]

/// The destination to store for what the link dialog holds. A field the user
/// never touched is stored byte-identical: opening ⌘K on an existing link and
/// confirming must not rewrite its destination.
func linkDestination(typed raw: String, existing: String) -> String {
    let typed = raw.trimmingCharacters(in: .whitespaces)
    return typed == existing ? typed : normalizedLinkURL(typed)
}

/// The destination for a URL the user typed: a bare host — `example.com`,
/// `sub.example.com/page?q=1`, `example.com:8080` — gets `https://`, because a
/// scheme-less destination is resolved as a *relative path* and the link then
/// silently points nowhere. A bare address gets `mailto:`, and a server with a
/// port but no domain (`localhost:3000`, `192.168.1.5:8080`) gets `http://`,
/// which is what such a server almost always speaks.
///
/// The vault wins every ambiguity. Returned untouched: anything already carrying
/// a scheme (`http://`, `mailto:`, `editmd://` — unknown ones too), anchors and
/// paths (`#top`, `/a`, `./a`, `../a`), anything whose host is a single label
/// (`notes`, `docs/intro.md`), any host whose TLD is not in `completableTLDs`,
/// and — whatever the rest looks like — anything **ending** in a file this app
/// opens: `notes.md`, `notes.md#heading`, `docs.dev/intro.md`,
/// `archive.org/note.md`. That last rule costs the scheme-less remote URL that
/// ends in `.md` or `.png` (rare, and visibly unfinished when it happens);
/// rewriting a working vault-relative path into an unreachable URL is the worse
/// mistake, because the file is right there and the link silently stops resolving.
func normalizedLinkURL(_ raw: String) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard let first = s.first, !hasURLScheme(s),
          first != "#", first != "/", first != "?",
          !s.hasPrefix("./"), !s.hasPrefix("../"),
          !s.contains(where: \.isWhitespace)
    else { return s }

    if let address = mailtoAddress(s) { return address }
    // Any other `@` is userinfo (`user@host/path`) — not ours to complete.
    guard !s.contains("@") else { return s }

    // What the destination *ends* in decides it: a file we open means a path in
    // the vault, however host-like the first segment reads.
    if let ext = fileExtension(pathTail(s)), vaultFileExtensions.contains(ext) {
        return s
    }

    // Only the authority is inspected; the path, query and fragment ride along.
    guard let host = hostParts(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    else { return s }
    let labels = host.name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy({ !$0.isEmpty }) else { return s }
    if labels.count >= 2, let tld = labels.last?.lowercased(),
       completableTLDs.contains(tld) {
        return "https://" + s
    }
    // A dotted quad is a host, and so is a single label carrying a port — both
    // are servers on this network rather than paths in the vault.
    let isAddress = labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
    if isAddress || (labels.count == 1 && !host.port.isEmpty) { return "http://" + s }
    return s
}

/// `mailto:` form of a bare e-mail address: one `@`, a non-empty local part, and
/// a host that would pass as a completable host on its own. Nil for anything
/// else, including `user@host/path`, which is userinfo in a URL.
private func mailtoAddress(_ s: String) -> String? {
    let parts = s.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty,
          !parts[1].contains(where: { $0 == "/" || $0 == "?" || $0 == "#" || $0 == ":" })
    else { return nil }
    let labels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
          let tld = labels.last?.lowercased(), completableTLDs.contains(tld)
    else { return nil }
    return "mailto:" + s
}

/// Splits an authority into host name and port, or nil when it is not shaped
/// like one — a colon followed by anything but digits (`https:example.com`,
/// `C:\notes`) is not a port, and not something to complete.
private func hostParts(_ authority: Substring) -> (name: Substring, port: Substring)? {
    let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
    switch pieces.count {
    case 1:
        return (pieces[0], "")
    case 2 where !pieces[1].isEmpty && pieces[1].allSatisfy(\.isNumber):
        return (pieces[0], pieces[1])
    default:
        return nil
    }
}

/// The file-name end of a destination: query and fragment dropped, then the last
/// path segment (`docs.dev/intro.md#top` → `intro.md`).
private func pathTail(_ s: String) -> Substring {
    let path = s.prefix { $0 != "?" && $0 != "#" }
    guard let slash = path.lastIndex(of: "/") else { return path }
    return path[path.index(after: slash)...]
}

/// The lowercased extension of a name that has one (`notes.md` → `md`).
private func fileExtension(_ name: Substring) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...]
    return ext.isEmpty ? nil : ext.lowercased()
}

/// True when `s` already carries a URL scheme — either `scheme://` or one of the
/// authority-less forms (`mailto:`, `tel:`). The `//` has to be there because a
/// bare `host:port` (`localhost:3000`) looks identical up to the colon; a dot,
/// slash or `?` before the colon rules a scheme out outright.
private func hasURLScheme(_ s: String) -> Bool {
    var scheme = ""
    for ch in s {
        if ch == ":" {
            guard let f = scheme.first, f.isLetter,
                  scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" })
            else { return false }
            return s.dropFirst(scheme.count + 1).hasPrefix("//")
                || authorityLessSchemes.contains(scheme.lowercased())
        }
        if ch == "." || ch == "/" || ch == "?" || ch == "#" || ch == "@" { return false }
        scheme.append(ch)
    }
    return false
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
    let textField = alertTextField(width: 320)
    textField.stringValue = existingText
    textField.placeholderString = String(localized: "Link text")
    let urlField = alertTextField(width: 320)
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
    let url = linkDestination(typed: urlField.stringValue, existing: existingURL)
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
