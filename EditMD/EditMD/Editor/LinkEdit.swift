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
    "cl", "za", "eu",
    // Cyrillic IDN TLDs in both forms a destination arrives in — typed as
    // Unicode, pasted as punycode. Escaped rather than written out so the repo
    // stays ASCII outside the allowlist `scripts/audit.sh` check 1 enforces:
    // \u{440}\u{444} is .rf (xn--p1ai), \u{443}\u{43A}\u{440} is .ukr.
    "\u{440}\u{444}", "xn--p1ai", "\u{443}\u{43A}\u{440}", "xn--j1amh",
]

/// Schemes that carry no `//` authority, so their colon is the whole signal.
private let authorityLessSchemes: Set<String> =
    ["mailto", "tel", "sms", "geo", "data", "callto", "facetime"]

/// The destination to store for what the link dialog holds. A field the user
/// never touched is stored byte-identical: opening ⌘K on an existing link and
/// confirming must not rewrite its destination.
func linkDestination(typed raw: String, existing: String,
                     localFileExists: (String) -> Bool? = { _ in nil }) -> String {
    // A destination can never hold a newline: a two-line paste would break the
    // link syntax and split the paragraph it sits in.
    let typed = raw.components(separatedBy: .newlines).joined()
        .trimmingCharacters(in: .whitespaces)
    return typed == existing
        ? typed
        : normalizedLinkURL(typed, localFileExists: localFileExists)
}

/// Answers "does this destination name a file that is really there?" for the link
/// dialog, turning the one genuine ambiguity — `docs.dev/intro.md` is a folder in
/// this vault, `archive.org/note.md` is a web page — from a guess into a fact.
///
/// Resolution runs off the main actor **while the user types**, so pressing OK
/// only reads memory: the main actor must not touch the disk
/// (`docs/architecture.md` § Performance), and a vault on a network volume is
/// exactly why. An answer that has not arrived yet reads as `nil`, and an unknown
/// destination is left alone — the conservative side.
///
/// The path resolution is `resolveLocalLinkDestination`, the same one vault lint
/// applies to a relative link, with the same roots: the adopted workspace, or the
/// nearest `.obsidian` vault above the file when no workspace owns it. Lint also
/// accepts a wiki-index basename match for a markdown link, which this does not
/// consult — a destination that resolves *only* by basename is treated as
/// missing here.
final class LocalDestinationCache: @unchecked Sendable {
    /// Enough answers for a typed destination and its prefixes; a dialog that
    /// somehow types past it starts a fresh generation rather than growing.
    private static let maxAnswers = 64

    private let fileDir: URL?
    private let adoptedRoot: URL?
    private let lock = NSLock()
    private var answers: [String: Bool] = [:]
    /// Keys in the order they were first answered — the eviction order.
    private var arrival: [String] = []
    /// `.obsidian` fallback root, resolved once off the main actor (it walks the
    /// file system, so it cannot be computed where the dialog is built).
    private var fallbackRoot: URL??

    /// `fileURL` is the document being edited; nil (an unsaved document) leaves
    /// every answer unknown, since there is nothing to resolve against.
    /// `adoptedRoot` is the workspace owning it, when one does.
    init(fileURL: URL?, adoptedRoot: URL?) {
        // Same directory the scan resolves a link from: the folder holding the
        // document, textbundle or not.
        fileDir = fileURL?.deletingLastPathComponent()
        self.adoptedRoot = adoptedRoot
    }

    /// Starts resolving `destination`, unless the answer is already in hand or
    /// `localProbeKey` says the normalizer would never ask about it — an address,
    /// something already schemed, or a plain host with no path is not arbitrated,
    /// and probing every keystroke of one would stat the disk for nothing.
    func prefetch(_ destination: String) {
        guard fileDir != nil || adoptedRoot != nil,
              let target = localProbeKey(for: destination),
              answer(for: destination) == nil
        else { return }
        let dir = fileDir
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let hit = resolveLocalLinkDestination(target, fileDir: dir,
                                                  vaultRoot: self.vaultRoot())
            self.store(target, hit != nil)
        }
    }

    /// True/false once resolved, nil while unknown.
    func answer(for destination: String) -> Bool? {
        guard let key = localProbeKey(for: destination) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return answers[key]
    }

    /// Adopted workspace first, then the nearest `.obsidian` vault above the
    /// file — the same order the link opener and the lint use. Called only from
    /// the background task.
    private func vaultRoot() -> URL? {
        if let adoptedRoot { return adoptedRoot }
        lock.lock()
        if let cached = fallbackRoot { lock.unlock(); return cached }
        lock.unlock()
        let resolved = fileDir.flatMap { nearestVaultRoot(startingAt: $0) }
        lock.lock()
        fallbackRoot = .some(resolved)
        lock.unlock()
        return resolved
    }

    /// Oldest answer out, never a wipe: an answer is a pure function of the path
    /// and the roots, so a task landing late is merely late — but clearing the
    /// table under it could drop the answer the dialog is about to read.
    private func store(_ key: String, _ exists: Bool) {
        lock.lock()
        if answers[key] == nil {
            arrival.append(key)
            while arrival.count > Self.maxAnswers, let oldest = arrival.first {
                arrival.removeFirst()
                answers[oldest] = nil
            }
        }
        answers[key] = exists
        lock.unlock()
    }
}

/// The destination for a URL the user typed: a bare host — `example.com`,
/// `sub.example.com/page?q=1`, `example.com:8080` — gets `https://`, because a
/// scheme-less destination is resolved as a *relative path* and the link then
/// silently points nowhere. A bare address gets `mailto:`, and a server with a
/// port but no domain (`localhost:3000`, `192.168.1.5:8080`) gets `http://`,
/// which is what such a server almost always speaks.
///
/// Returned untouched: anything already carrying a scheme (`http://`, `mailto:`,
/// `editmd://` — unknown ones too), anchors and paths (`#top`, `/a`, `./a`,
/// `../a`), anything whose host is a single label (`notes`, `notes/intro.md`), and
/// any host whose TLD is not in `completableTLDs`.
///
/// A destination that **ends** in a file this app opens is the ambiguous case —
/// `docs.dev/intro.md` is a folder in someone's vault, `archive.org/note.md` is a
/// web page — and `localFileExists` settles it by fact: a file that is really
/// there stays a path. When the answer is unknown (`nil`: no document to resolve
/// against, or the probe has not finished) the vault keeps the benefit of the
/// doubt, since rewriting a working relative link into an unreachable URL is the
/// worse mistake — the file sits right there and the link just stops resolving.
/// A plain `notes.md` stays local either way: `md` is not a completable TLD, so
/// linking a note before creating it keeps working.
func normalizedLinkURL(_ raw: String,
                       localFileExists: (String) -> Bool? = { _ in nil }) -> String {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard let first = s.first, !hasURLScheme(s),
          first != "#", first != "/", first != "?",
          !s.hasPrefix("./"), !s.hasPrefix("../"),
          !s.contains(where: \.isWhitespace)
    else { return s }

    // Everything before the first `/`, `?` or `#`. An `@` in *there* is an
    // address or userinfo; further down it belongs to the path and means nothing
    // (`youtube.com/@mkbhd` is an ordinary page).
    let authority = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    if authority.contains("@") {
        // Only a whole string that is an address becomes `mailto:`; with a path
        // glued on it is userinfo in a URL, which is not ours to complete.
        guard authority.count == s.count, let address = mailtoAddress(s) else { return s }
        return address
    }

    // A destination with a path could be a folder in the vault, extension or not
    // (`docs.io/guide`), and one ending in a file we open could be a note. The
    // file system is the only authority on which it is; `localProbeKey` is the
    // single definition of "worth asking", shared with the probe so the question
    // and the cache key cannot drift apart.
    if localProbeKey(for: s) != nil {
        // A hit is always a path.
        if localFileExists(s) == true { return s }
        // Unknown — no document to resolve against, or the probe has not
        // answered — keeps the vault's benefit of the doubt where the tail reads
        // as a file we open; elsewhere it must not block an ordinary web link.
        if looksLikeVaultFile(s), localFileExists(s) == nil { return s }
    }

    // Only the authority is inspected; the path, query and fragment ride along.
    guard let host = hostParts(authority) else { return s }
    let labels = host.name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy(isHostLabel) else { return s }
    if isCompletableTLD(labels) { return "https://" + s }
    // A dotted quad is a host, and so is a single label carrying a port — both
    // are servers on this network rather than paths in the vault.
    let isAddress = labels.count == 4 && labels.allSatisfy {
        Int($0).map { (0...255).contains($0) } ?? false
    }
    if isAddress || (labels.count == 1 && !host.port.isEmpty) { return "http://" + s }
    return s
}

/// A host label by RFC 1123 shape: alphanumeric at both ends, hyphens inside.
/// Keeps `-example.com` and `example-.com` from being completed into a URL that
/// cannot resolve. Unicode letters pass, so an IDN host still completes.
private func isHostLabel(_ label: Substring) -> Bool {
    guard let first = label.first, let last = label.last,
          first.isLetter || first.isNumber, last.isLetter || last.isNumber
    else { return false }
    return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
}

/// `mailto:` form of a bare e-mail address: one `@`, a non-empty local part, and
/// a host that would pass as a completable host on its own. Nil for anything
/// else, including `user@host/path`, which is userinfo in a URL.
private func mailtoAddress(_ s: String) -> String? {
    let structural: Set<Character> = ["/", "?", "#", ":"]
    let parts = s.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty,
          // `user:pass@host` is userinfo, `contacts/john@acme.com` is a path.
          !parts[0].contains(where: { structural.contains($0) }),
          !parts[1].contains(where: { structural.contains($0) }),
          // The same host test the web branch uses — an address at a malformed
          // host (`user@-example.com`) is no more completable than the host is.
          isCompletableHost(parts[1])
    else { return nil }
    return "mailto:" + s
}

/// True when an authority reads as a host worth completing a scheme for: two or
/// more RFC 1123 labels and a TLD from `completableTLDs`.
private func isCompletableHost(_ host: Substring) -> Bool {
    isCompletableTLD(host.split(separator: ".", omittingEmptySubsequences: false))
}

/// The same test over labels a caller has already split.
private func isCompletableTLD(_ labels: [Substring]) -> Bool {
    guard labels.count >= 2, labels.allSatisfy(isHostLabel),
          let tld = labels.last?.lowercased()
    else { return false }
    return completableTLDs.contains(tld)
}

/// Splits an authority into host name and port, or nil when it is not shaped
/// like one — a colon followed by anything but digits (`https:example.com`,
/// `C:\notes`) is not a port, and not something to complete.
private func hostParts(_ authority: Substring) -> (name: Substring, port: Substring)? {
    // A bracketed IPv6 authority (`[::1]:8080`) is full of colons: not shaped
    // like this, and rare enough to leave for its author to write in full.
    guard !authority.hasPrefix("[") else { return nil }
    let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
    switch pieces.count {
    case 1:
        return (pieces[0], "")
    case 2 where Int(pieces[1]).map({ (1...65535).contains($0) }) ?? false:
        return (pieces[0], pieces[1])
    default:
        return nil
    }
}

/// The path a destination would be arbitrated by — and remembered under —
/// or nil when the normalizer never asks the file system about it: something
/// already carrying a scheme, an anchor, an absolute or dot-relative path, an
/// address, or a host with no path beneath it. One definition for both sides, so
/// the question and the cache key cannot drift apart.
///
/// The returned path excludes query and fragment: neither is part of a file name,
/// and a `/` inside a query (`docs.dev?next=/guide`) does not make a destination
/// a path — while `resolveLocalLinkDestination` only strips the fragment itself.
func localProbeKey(for destination: String) -> String? {
    let s = destination.components(separatedBy: .newlines).joined()
        .trimmingCharacters(in: .whitespaces)
    guard let first = s.first, !hasURLScheme(s),
          first != "#", first != "/", first != "?",
          !s.hasPrefix("./"), !s.hasPrefix("../"),
          !s.contains(where: \.isWhitespace),
          !s.prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" }).contains("@")
    else { return nil }
    let path = String(s.prefix { $0 != "?" && $0 != "#" })
    guard path.contains("/") || looksLikeVaultFile(s) else { return nil }
    return path
}

/// True when a destination ends in a file this app opens (`notes.md#heading`).
private func looksLikeVaultFile(_ s: String) -> Bool {
    fileExtension(pathTail(s)).map(vaultFileExtensions.contains) ?? false
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
/// thread; returns the user's choice. `fileURL` is the document being edited —
/// what a relative destination is resolved against while the user types
/// (`LocalDestinationCache`); without it a scheme is completed by shape alone.
@MainActor
func runLinkEditPrompt(existingText: String, existingURL: String,
                       fileURL: URL? = nil) -> LinkEditResult {
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

    // Resolve what is typed against the vault in the background, so the decision
    // at OK costs nothing on the main actor.
    let destinations = LocalDestinationCache(
        fileURL: fileURL,
        adoptedRoot: fileURL.flatMap { WorkspaceModel.shared.workspaceOwning($0)?.url })
    let watcher = LinkURLFieldWatcher(destinations: destinations)
    urlField.delegate = watcher
    destinations.prefetch(existingURL)

    // Adding a link starts in the URL field (the label is usually the
    // selection); editing an existing one starts in its text.
    // `delegate` is a weak reference and AppKit does not retain it either, so
    // the watcher's lifetime has to be held open across the modal run by hand —
    // otherwise ARC may release it right after the assignment and no keystroke
    // is ever seen.
    let response = withExtendedLifetime(watcher) {
        runModal(alert, focusing: existingURL.isEmpty ? urlField : textField)
    }
    let url = linkDestination(typed: urlField.stringValue, existing: existingURL,
                              localFileExists: { destinations.answer(for: $0) })
    // A label is one line: a two-line paste would otherwise put a newline inside
    // `[…]`, which breaks the link in Source and makes one link attribute span
    // two paragraphs in Visual.
    let text = singleLineFieldText(textField.stringValue)

    switch response {
    case .alertFirstButtonReturn where !url.isEmpty:
        return .apply(text: text, url: url)
    case .alertThirdButtonReturn:
        return .remove
    default:
        return .cancel
    }
}

/// Keeps `LocalDestinationCache` a keystroke ahead of the OK button: every edit
/// of the URL field starts resolving what it now holds.
@MainActor
private final class LinkURLFieldWatcher: NSObject, NSTextFieldDelegate {
    private let destinations: LocalDestinationCache

    init(destinations: LocalDestinationCache) {
        self.destinations = destinations
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        destinations.prefetch(field.stringValue)
    }
}
