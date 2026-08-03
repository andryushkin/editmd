import AppKit
import Markdown

// ⌘K link editor (Source + Visual) and the no-selection URL paste form. Pure
// helpers are unit-tested; one NSAlert prompt serves both modes.

// MARK: - Serialization

/// `<url>` for a bare URL pasted with no selection — round-trips as a link in
/// all three modes; a plain bare URL stays literal (renderer does not
/// GFM-autolink). `<`/`>` inside the URL is invalid in a CommonMark autolink →
/// fall back to `[url](url)`.
func markdownAutolinkSyntax(url: String) -> String {
    if url.contains("<") || url.contains(">") {
        return markdownLinkSyntax(text: url, url: url)
    }
    return "<\(url)>"
}

// MARK: - Bare-host normalization

/// Extensions that read as a vault file, not a web address. Built on the
/// wiki-link index set so `[[target]]` and ⌘K cannot drift apart. `html`
/// deliberately absent: `example.com/index.html` is a page.
private let vaultFileExtensions: Set<String> =
    WikiLinkCore.indexedExtensions.union(["txt", "csv", "json", "yml", "yaml"])

/// TLDs a missing scheme is completed for. Curated on purpose: by shape
/// `example.com` is indistinguishable from `build.sh` or `2.Areas/note.md`, and
/// a rare TLD left to type beats a vault path rewritten into a dead URL. Omits
/// codes colliding with common extensions (`md`, `sh`, `rs`, `pl`, `cc`, `am`,
/// `in`, `pro`, `ai`, `app`) — letting the probe settle those would settle them
/// by timing. docs/vault.md § Scheme completion.
private let completableTLDs: Set<String> = [
    "com", "org", "net", "edu", "gov", "mil", "int", "info", "biz",
    "io", "co", "dev", "cloud", "tools", "wiki", "news", "blog",
    "shop", "store", "site", "online", "space", "tech", "digital", "studio",
    "design", "media", "agency", "email", "link", "page", "live", "life",
    "xyz", "top", "art", "fun", "team", "work", "world", "zone", "me", "tv",
    "ru", "ua", "by", "kz", "uk", "us", "ca", "au", "nz", "de", "fr",
    "es", "it", "nl", "be", "ch", "at", "se", "no", "fi", "dk", "pt", "gr",
    "cz", "hu", "ro", "bg", "si", "sk", "lt", "lv", "ee", "ge", "az",
    "tr", "il", "ae", "cn", "jp", "kr", "hk", "sg", "br", "mx", "ar",
    "cl", "za", "eu",
    // Cyrillic IDN TLDs, typed (Unicode) and pasted (punycode) forms. Escaped
    // to keep the repo ASCII (scripts/audit.sh check 1): \u{440}\u{444} = .rf,
    // \u{443}\u{43A}\u{440} = .ukr.
    "\u{440}\u{444}", "xn--p1ai", "\u{443}\u{43A}\u{440}", "xn--j1amh",
]

/// Schemes that carry no `//` authority, so their colon is the whole signal.
private let authorityLessSchemes: Set<String> =
    ["mailto", "tel", "sms", "geo", "data", "callto", "facetime"]

/// Destination to store for what the dialog holds. An untouched field is stored
/// byte-identical: confirming ⌘K on an existing link must not rewrite it.
func linkDestination(typed raw: String, existing: String,
                     localFileExists: (String) -> Bool? = { _ in nil }) -> String {
    // No control characters: a newline breaks link syntax; a tab from a table
    // cell yields a destination CommonMark refuses to parse.
    let typed = withoutControlCharacters(raw).trimmingCharacters(in: .whitespaces)
    return typed == existing
        ? typed
        : normalizedLinkURL(typed, localFileExists: localFileExists)
}

/// Answers "is this destination a file that is really there?" — what keeps
/// `Makefile.am` or a `docs.io` folder from being completed into URLs. Resolves
/// off-main while the user types; OK only reads memory, never waits
/// (docs/architecture.md § Performance); only `true` changes what is stored.
/// Same roots as the link opener and vault lint (adopted workspace, else nearest
/// `.obsidian`), but a basename-only wiki match counts as missing here.
/// docs/vault.md § Scheme completion.
final class LocalDestinationCache: @unchecked Sendable {
    /// Answer cap; typing past it starts a fresh generation rather than growing.
    private static let maxAnswers = 64
    /// Probes allowed to be in flight at once.
    private static let maxInFlight = 8

    private let fileDir: URL?
    private let adoptedRoot: URL?
    private let lock = NSLock()
    private var answers: [String: Bool] = [:]
    /// Keys in the order they were first answered — the eviction order.
    private var arrival: [String] = []
    /// In-flight keys — dedupes probes. Bounded: on a stalled volume each probe
    /// holds a thread; refusing a slot only costs a best-effort save.
    private var pending: Set<String> = []
    /// `.obsidian` fallback root, resolved once off-main (walks the FS). Own
    /// lock: the walk holds it and must never block a main-actor lookup.
    private let rootLock = NSLock()
    private var fallbackRoot: URL??

    /// nil `fileURL` (unsaved document) leaves every answer unknown.
    init(fileURL: URL?, adoptedRoot: URL?) {
        // Same directory the scan resolves a link from, textbundle or not.
        fileDir = fileURL?.deletingLastPathComponent()
        self.adoptedRoot = adoptedRoot
    }

    /// Starts resolving unless already answered/in-flight, or `localProbeKey`
    /// says the normalizer would never ask — probing those stats for nothing.
    func prefetch(_ destination: String) {
        guard fileDir != nil || adoptedRoot != nil,
              let target = localProbeKey(for: destination)
        else { return }
        lock.lock()
        guard answers[target] == nil, !pending.contains(target),
              pending.count < Self.maxInFlight
        else { lock.unlock(); return }
        pending.insert(target)
        lock.unlock()

        let dir = fileDir
        // Global queue, not Task.detached: `fileExists` blocks for the mount's
        // timeout on a dead volume and would stall the whole cooperative pool.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let hit = resolveLocalLinkDestination(target, fileDir: dir,
                                                  vaultRoot: self.vaultRoot())
            self.store(target, hit != nil)
        }
    }

    /// True/false once resolved, nil while unknown. Never waits
    /// (docs/architecture.md § Performance); unknown is a first-class answer.
    func answer(for destination: String) -> Bool? {
        guard let key = localProbeKey(for: destination) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return answers[key]
    }

    /// Adopted workspace first, then nearest `.obsidian` above the file — same
    /// order as the link opener and lint. Background task only.
    private func vaultRoot() -> URL? {
        if let adoptedRoot { return adoptedRoot }
        // Lock held across the walk on purpose: racing probes wait for the one
        // answer instead of each re-walking the ancestors.
        rootLock.lock()
        defer { rootLock.unlock() }
        if let cached = fallbackRoot { return cached }
        let resolved = fileDir.flatMap { nearestVaultRoot(startingAt: $0) }
        fallbackRoot = .some(resolved)
        return resolved
    }

    /// Oldest answer out, never a wipe: a wipe could drop the answer the dialog
    /// is about to read.
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
        pending.remove(key)
        lock.unlock()
    }
}

/// Scheme completion for a typed destination: bare host → `https://` (a
/// scheme-less destination resolves as a relative path and silently points
/// nowhere), bare address → `mailto:`, port-only server (`localhost:3000`,
/// dotted quad) → `http://`. Untouched: anything already schemed, anchors and
/// paths, single-label hosts, TLDs outside `completableTLDs`. A destination
/// ending in a vault-file extension is never completed; `localFileExists`
/// settles the remaining ambiguity by fact, and an unknown answer (`nil`) keeps
/// the local reading — a dead URL is the worse mistake.
/// docs/vault.md § Scheme completion.
func normalizedLinkURL(_ raw: String,
                       localFileExists: (String) -> Bool? = { _ in nil }) -> String {
    guard let s = completionCandidate(raw) else {
        return withoutControlCharacters(raw).trimmingCharacters(in: .whitespaces)
    }

    // Never completed and never probed: whether the note exists *yet* cannot
    // decide the everyday forward link, and consulting the probe would make the
    // outcome timing-dependent. Cost: a hand-typed `archive.org/note.md` stays
    // relative until its scheme is typed.
    if looksLikeVaultFile(s) { return s }

    // Shape-only outcome; nothing to do when it leaves the destination alone.
    guard let completed = shapeCompletion(s) else { return s }

    // A file that is really there is a path, not a host. Best-effort: an
    // in-flight/refused probe leaves the shape rule in charge; a hit only makes
    // the answer more conservative.
    if localProbeKey(for: s) != nil, localFileExists(s) == true { return s }
    return completed
}

/// What shape alone would store, or nil to leave `s` alone. Split out so the
/// probe is asked exactly where its answer matters — `localProbeKey` calls this.
private func shapeCompletion(_ s: String) -> String? {
    // Authority = before the first `/`, `?`, `#`. `@` there is address/userinfo;
    // further down it is path (`youtube.com/@mkbhd`).
    let authority = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    if authority.contains("@") {
        // Whole-string address only; with a path glued on, `@` is userinfo.
        guard authority.count == s.count else { return nil }
        return mailtoAddress(s)
    }

    // Only the authority is inspected; the path, query and fragment ride along.
    guard let host = hostParts(authority) else { return nil }
    let labels = host.name.split(separator: ".", omittingEmptySubsequences: false)
    guard labels.allSatisfy(isHostLabel) else { return nil }
    if hasCompletableTLD(labels) { return "https://" + s }
    // Dotted quad / `localhost:port` are servers, near-always http. `chapter:3`
    // is prose that merely looks like host:port.
    let isAddress = labels.count == 4 && labels.allSatisfy {
        Int($0).map { (0...255).contains($0) } ?? false
    }
    if isAddress || (host.name.lowercased() == "localhost" && !host.port.isEmpty) {
        return "http://" + s
    }
    return nil
}

/// RFC 1123 label shape: alphanumeric ends, hyphens inside; Unicode letters pass
/// (IDN). Rejects `-example.com` / `example-.com`.
private func isHostLabel(_ label: Substring) -> Bool {
    guard let first = label.first, let last = label.last,
          first.isLetter || first.isNumber, last.isLetter || last.isNumber
    else { return false }
    return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
}

/// `mailto:` for a bare address: one `@`, non-empty local part, completable
/// host. Nil otherwise (incl. `user@host/path` — userinfo).
private func mailtoAddress(_ s: String) -> String? {
    let parts = s.split(separator: "@", omittingEmptySubsequences: false)
    // Caller guarantees no `/`, `?`, `#`; a colon — the only structural char
    // left — makes the left side userinfo (`user:pass@host`).
    guard parts.count == 2, !parts[0].isEmpty,
          !parts[0].contains(":"), !parts[1].contains(":"),
          // Same host test as the web branch: `user@-example.com` fails with it.
          isCompletableHost(parts[1])
    else { return nil }
    return "mailto:" + s
}

/// Two or more RFC 1123 labels and a TLD from `completableTLDs`.
private func isCompletableHost(_ host: Substring) -> Bool {
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy(isHostLabel) && hasCompletableTLD(labels)
}

/// Count and TLD only, over labels the caller has already validated.
private func hasCompletableTLD(_ labels: [Substring]) -> Bool {
    guard labels.count >= 2, let tld = labels.last?.lowercased() else { return false }
    return completableTLDs.contains(tld)
}

/// Host name + port, or nil when not shaped like one — a colon followed by
/// non-digits (`https:example.com`, `C:\notes`) is not a port.
private func hostParts(_ authority: Substring) -> (name: Substring, port: Substring)? {
    // Bracketed IPv6 (`[::1]:8080`) is full of colons — left for its author.
    guard !authority.hasPrefix("[") else { return nil }
    let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
    switch pieces.count {
    case 1:
        return (pieces[0], "")
    // Digits only, no leading zero, in range: `+80` / `0080` are text, not ports.
    case 2 where pieces[1].allSatisfy(\.isNumber) && pieces[1].first != "0"
        && (Int(pieces[1]).map { (1...65535).contains($0) } ?? false):
        return (pieces[0], pieces[1])
    default:
        return nil
    }
}

/// Path to resolve `destination` under — and cache it by — or nil when no answer
/// could change what is stored (no stat worth starting): ruled out by
/// `completionCandidate`; ends in a vault-file extension (never completed); a
/// shape the rules leave alone anyway; carries a query/fragment (its path alone
/// would answer for a *different* destination — `docs.dev?next=/guide` must not
/// be settled by a folder `docs.dev`); or a ported authority (no file name holds
/// one). One definition for both sides, so the question and the cache key cannot
/// drift and a stalled volume never probes unread answers.
func localProbeKey(for destination: String) -> String? {
    guard let s = completionCandidate(destination),
          !s.contains("?"), !s.contains("#"),
          !looksLikeVaultFile(s), shapeCompletion(s) != nil
    else { return nil }
    // `@` under a path is userinfo, names nothing local; standing alone it may
    // still be a file (`user@example.com` in a mail archive).
    let authority = s.prefix { $0 != "/" && $0 != "?" && $0 != "#" }
    guard !authority.contains("@") || authority.count == s.count,
          !authority.contains(":")
    else { return nil }
    return s
}

/// The form both normalizer and probe read, or nil when neither touches it
/// (schemed, anchor, absolute/dot-relative, inner whitespace). One definition —
/// two copies had already diverged over control-char stripping.
private func completionCandidate(_ raw: String) -> String? {
    let s = withoutControlCharacters(raw).trimmingCharacters(in: .whitespaces)
    guard let first = s.first, !hasURLScheme(s),
          first != "#", first != "/", first != "?",
          !s.hasPrefix("./"), !s.hasPrefix("../"),
          !s.contains(where: \.isWhitespace)
    else { return nil }
    return s
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

/// Lowercased extension (`notes.md` → `md`), nil otherwise. A colon rules it
/// out: `192.168.1.5:8080` ends in a port, and no file name here holds a colon.
private func fileExtension(_ name: Substring) -> String? {
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
    let ext = name[name.index(after: dot)...]
    guard !ext.isEmpty, !ext.contains(":") else { return nil }
    return ext.lowercased()
}

/// `scheme://` or an authority-less form (`mailto:`). The `//` is required: bare
/// `host:port` looks identical up to the colon.
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
    /// Link label as rendered — what the dialog shows and the user edits.
    var text: String
    /// Label as *written* (`**bold**` where `text` is `bold`); an untouched
    /// label goes back byte-exact so confirming ⌘K cannot flatten formatting.
    /// Nil when the source range is unavailable (autolink, rangeless child) —
    /// then `text` goes through the escaping serializer.
    var rawLabel: String?
    /// Destination as authored (angle brackets already stripped by the parser).
    var url: String
}

/// Inline link whose span contains `caret` (UTF-16), or nil. AST-based, so
/// escapes, angle destinations and code-span exclusion match the renderer. A
/// caret at either edge counts as inside. Autolinks match too — their label
/// prefills with the URL, so ⌘K converts them to `[url](url)`.
func inlineLinkMatch(in source: String, at caret: Int) -> InlineLinkMatch? {
    guard !source.isEmpty else { return nil }
    let lineIdx = LineIndex(source)
    let document = Document(parsing: source)
    var collector = InlineLinkRangeCollector(lineIdx: lineIdx, source: source as NSString)
    collector.visit(document)
    // Innermost containing match wins if links nest.
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
    let source: NSString
    var matches: [InlineLinkMatch] = []

    private func nsRange(for src: SourceRange) -> NSRange? {
        let loc = lineIdx.offset(src.lowerBound.line, src.lowerBound.column)
        let end = lineIdx.offset(src.upperBound.line, src.upperBound.column)
        guard end >= loc else { return nil }
        return NSRange(location: loc, length: end - loc)
    }

    mutating func visitLink(_ link: Link) {
        if let dest = link.destination, let src = link.range,
           let r = nsRange(for: src), r.length >= 2 {
            matches.append(InlineLinkMatch(range: r,
                                           text: link.plainText,
                                           rawLabel: rawLabel(of: link),
                                           url: dest))
        }
        descendInto(link)
    }

    /// Label source text, first child's start to last child's end (markers and
    /// escapes included). Nil for an autolink.
    private func rawLabel(of link: Link) -> String? {
        // Every child must carry a range: a dropped one would hand back a
        // truncated span as if it were whole.
        let childRanges = link.children.map(\.range)
        guard childRanges.allSatisfy({ $0 != nil }),
              let first = childRanges.first ?? nil, let last = childRanges.last ?? nil,
              let start = nsRange(for: first), let end = nsRange(for: last)
        else { return nil }
        let span = NSRange(location: start.location, length: NSMaxRange(end) - start.location)
        guard span.location >= 0, span.length > 0, NSMaxRange(span) <= source.length
        else { return nil }
        return source.substring(with: span)
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

/// Shared add/edit-link dialog; non-empty `existingURL` → "Edit Link" +
/// "Remove Link". Modal on main. `fileURL` is what relative destinations
/// resolve against while typing; without it, shape alone completes.
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

    // Background-resolve typed text so OK reads a ready answer. An untouched
    // destination returns verbatim — nothing to prefetch until the field changes.
    let destinations = LocalDestinationCache(
        fileURL: fileURL,
        adoptedRoot: fileURL.flatMap { WorkspaceModel.shared.workspaceOwning($0)?.url })
    let watcher = LinkURLFieldWatcher(destinations: destinations)
    urlField.delegate = watcher

    // Add starts in the URL field (label usually = selection); edit in its text.
    // `delegate` is weak and AppKit does not retain it: hold the watcher across
    // the modal run or ARC frees it and no keystroke is ever seen.
    let response = withExtendedLifetime(watcher) {
        runModal(alert, focusing: existingURL.isEmpty ? urlField : textField)
    }
    switch response {
    case .alertFirstButtonReturn:
        // Only a confirmed dialog pays for normalization; Cancel/Remove drop
        // the value, and on a slow volume the wait would be felt.
        let url = linkDestination(typed: urlField.stringValue, existing: existingURL,
                                  localFileExists: { destinations.answer(for: $0) })
        guard !url.isEmpty else { return .cancel }
        // Label is one line: a pasted newline inside `[…]` breaks the link in
        // Source and spans one link attribute across two paragraphs in Visual.
        return .apply(text: singleLineFieldText(textField.stringValue), url: url)
    case .alertThirdButtonReturn:
        return .remove
    default:
        return .cancel
    }
}

/// Keeps the cache a keystroke ahead of OK: every URL-field edit starts
/// resolving.
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
