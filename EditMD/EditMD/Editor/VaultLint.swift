import Foundation

// MARK: - Rules / findings

/// Workspace-level link health rules. Separate from per-file `LintRule` so
/// Source lint stays workspace-free.
enum VaultLintRule: String, Equatable, Sendable, CaseIterable {
    case deadWikiLink
    case ambiguousWikiLink
    case selfWikiLink
    case deadRelativeLink
    case deadImageLink
    case orphanFile
    case deadHeadingAnchor
}

enum VaultLintSeverity: String, Equatable, Sendable {
    case error
    case warning
    case info
}

/// Payload for a finding's user-facing text. Localization happens only in
/// `text` at display time — a full-vault run builds thousands of findings and
/// must not pay CFString/ICU formatting for rows that are never rendered.
enum VaultLintMessage: Equatable, Sendable {
    case deadWiki(target: String, suggestion: String?)
    case ambiguousWiki(target: String, count: Int)
    case selfLink
    case deadRelative(target: String)
    case outsideWorkspace(target: String)
    case deadImage(target: String)
    case deadHeading(heading: String, target: String)
    case orphan(name: String)

    var text: String {
        switch self {
        case let .deadWiki(target, suggestion):
            if let suggestion {
                return String(localized: "Wiki link “\(target)” not found — maybe “\(suggestion)”")
            }
            return String(localized: "Wiki link “\(target)” not found")
        case let .ambiguousWiki(target, count):
            return String(localized: "“\(target)” is ambiguous (\(count) files)")
        case .selfLink:
            return String(localized: "Link points to this same file")
        case let .deadRelative(target):
            return String(localized: "Link “\(target)” does not exist")
        case let .outsideWorkspace(target):
            return String(localized: "Link “\(target)” points outside the workspace")
        case let .deadImage(target):
            return String(localized: "Image “\(target)” not found")
        case let .deadHeading(heading, target):
            return String(localized: "Heading “\(heading)” not found in “\(target)”")
        case let .orphan(name):
            return String(localized: "Nothing links to “\(name)”")
        }
    }
}

struct VaultLintFinding: Equatable, Sendable, Identifiable {
    let rule: VaultLintRule
    let severity: VaultLintSeverity
    let file: URL
    /// 1-based line when known (orphan has nil).
    let line: Int?
    /// UTF-16 offset for jump (orphan has nil).
    let utf16Offset: Int?
    let messagePayload: VaultLintMessage
    /// Best-guess target for dead links (basename ranking).
    let targetSuggestion: URL?

    var message: String { messagePayload.text }

    var id: String {
        "\(rule.rawValue)|\(file.path)|\(line ?? -1)|\(utf16Offset ?? -1)|\(messagePayload)"
    }
}

// MARK: - Snapshot

/// Immutable graph slice for pure vault-lint (Sendable; no disk I/O).
struct LinkIndexSnapshot: Equatable, Sendable {
    /// Every scanned markdown file → its outgoing links (may be empty).
    let outgoing: [URL: [OutgoingLink]]
    /// Reverse edges (targets that were uniquely resolved).
    let backlinks: [URL: [BacklinkEdge]]
    /// Heading titles per file (for `deadHeadingAnchor`). Empty map → rule skipped.
    let headings: [URL: [String]]
    let skippedOversizedCount: Int
    /// Workspace roots (for "outside vault" relative-link checks).
    let roots: [URL]
    /// Home documents (README/index) excluded from orphanFile.
    let homeDocuments: Set<URL>

    /// All markdown files known to the index (scanned sources).
    var allFiles: [URL] {
        Array(outgoing.keys).sorted { $0.path < $1.path }
    }

    init(
        outgoing: [URL: [OutgoingLink]],
        backlinks: [URL: [BacklinkEdge]]? = nil,
        headings: [URL: [String]] = [:],
        skippedOversizedCount: Int = 0,
        roots: [URL] = [],
        homeDocuments: Set<URL> = []
    ) {
        let stdOut = Dictionary(uniqueKeysWithValues:
            outgoing.map { ($0.key.standardizedFileURL, $0.value) })
        self.outgoing = stdOut
        self.backlinks = backlinks.map {
            Dictionary(uniqueKeysWithValues: $0.map {
                ($0.key.standardizedFileURL, $0.value)
            })
        } ?? LinkGraphEngine.projectBacklinks(from: stdOut)
        self.headings = Dictionary(uniqueKeysWithValues:
            headings.map { ($0.key.standardizedFileURL, $0.value) })
        self.skippedOversizedCount = skippedOversizedCount
        self.roots = roots.map(\.standardizedFileURL)
        self.homeDocuments = Set(homeDocuments.map(\.standardizedFileURL))
    }

    /// Trusted variant: the caller guarantees every URL is already
    /// standardized (`LinkIndex` stores standardized keys). The plain init's
    /// per-URL `standardizedFileURL` pays a reachability stat per entry, which
    /// is disk I/O — never do that from the main actor for thousands of files.
    init(
        standardizedOutgoing outgoing: [URL: [OutgoingLink]],
        backlinks: [URL: [BacklinkEdge]],
        headings: [URL: [String]],
        skippedOversizedCount: Int,
        roots: [URL],
        homeDocuments: Set<URL>
    ) {
        self.outgoing = outgoing
        self.backlinks = backlinks
        self.headings = headings
        self.skippedOversizedCount = skippedOversizedCount
        self.roots = roots
        self.homeDocuments = homeDocuments
    }
}

// MARK: - Engine

/// Per-run caches. Fuzzy suggestions repeat heavily across a vault (the same
/// dead target is usually referenced from many files) and heading titles must
/// not be re-normalized per link.
private struct VaultLintScratch {
    let catalog: WikiRankCatalog
    var suggestions: [String: URL?] = [:]
    var headingKeys: [URL: Set<String>] = [:]

    mutating func suggestion(for raw: String) -> URL? {
        if let cached = suggestions[raw] { return cached }
        let s = suggestWikiTarget(raw: raw, catalog: catalog)
        suggestions[raw] = s
        return s
    }

    mutating func headingKeySet(for target: URL, titles: [String]) -> Set<String> {
        if let cached = headingKeys[target] { return cached }
        let s = Set(titles.map(normalizeHeadingKey))
        headingKeys[target] = s
        return s
    }
}

/// Suggestion catalog over the vault's files. O(n) lowercasing — build once
/// per index revision and share between the full run and per-file runs.
func vaultLintCatalog(files: [URL]) -> WikiRankCatalog {
    WikiRankCatalog(
        files.map { url -> WikiFileCandidate in
            WikiFileCandidate(
                url: url,
                basename: url.deletingPathExtension().lastPathComponent,
                title: nil,
                aliases: [],
                relativePath: url.lastPathComponent
            )
        }
    )
}

/// Pure vault-lint over an index snapshot. Never reads disk. Returns `[]`
/// when the surrounding task is cancelled mid-run (a superseded run must not
/// burn cores to completion on a stale snapshot).
func vaultLintFindings(
    index: LinkIndexSnapshot,
    catalog: WikiRankCatalog? = nil,
    onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
) -> [VaultLintFinding] {
    var findings: [VaultLintFinding] = []
    let files = index.allFiles
    var scratch = VaultLintScratch(
        catalog: catalog ?? vaultLintCatalog(files: files))

    let progressStep = max(1, files.count / 100)
    for (fileIndex, source) in files.enumerated() {
        if Task.isCancelled { return [] }
        if fileIndex % progressStep == 0 {
            onProgress?(fileIndex, files.count)
        }
        let links = index.outgoing[source] ?? []
        for (i, link) in links.enumerated() {
            // One file can carry thousands of links — a superseded run must
            // not finish it before noticing the cancel.
            if i % 64 == 0, Task.isCancelled { return [] }
            findings.append(contentsOf: findingsForLink(
                link, source: source, index: index, scratch: &scratch
            ))
        }
        // Orphans: no *external* backlinks. A file that only links to itself
        // still counts as orphan (and separately as selfWikiLink).
        if !index.homeDocuments.contains(source) {
            let edges = (index.backlinks[source] ?? []).filter {
                $0.source.standardizedFileURL != source
            }
            if edges.isEmpty {
                findings.append(VaultLintFinding(
                    rule: .orphanFile,
                    severity: .info,
                    file: source,
                    line: nil,
                    utf16Offset: nil,
                    messagePayload: .orphan(name: source.lastPathComponent),
                    targetSuggestion: nil
                ))
            }
        }
    }

    findings.sort {
        if $0.file.path != $1.file.path { return $0.file.path < $1.file.path }
        let l0 = $0.line ?? Int.max
        let l1 = $1.line ?? Int.max
        if l0 != l1 { return l0 < l1 }
        return $0.rule.rawValue < $1.rule.rawValue
    }
    return findings
}

/// Findings for a single file's links (the editor-underline path). Orphan is
/// a workspace-level rule and intentionally excluded here. Cheap relative to
/// the full run: suggestions rank only this file's dead links. Pass a shared
/// `catalog` when linting several files against one snapshot.
func vaultLintFindings(
    for file: URL,
    index: LinkIndexSnapshot,
    catalog: WikiRankCatalog? = nil
) -> [VaultLintFinding] {
    guard let links = index.outgoing[file], !links.isEmpty else { return [] }
    var scratch = VaultLintScratch(
        catalog: catalog ?? vaultLintCatalog(files: index.allFiles))
    var findings: [VaultLintFinding] = []
    for (i, link) in links.enumerated() {
        if i % 64 == 0, Task.isCancelled { return [] }
        findings.append(contentsOf: findingsForLink(
            link, source: file, index: index, scratch: &scratch
        ))
    }
    findings.sort {
        let l0 = $0.line ?? Int.max
        let l1 = $1.line ?? Int.max
        if l0 != l1 { return l0 < l1 }
        return $0.rule.rawValue < $1.rule.rawValue
    }
    return findings
}

private func findingsForLink(
    _ link: OutgoingLink,
    source: URL,
    index: LinkIndexSnapshot,
    scratch: inout VaultLintScratch
) -> [VaultLintFinding] {
    var out: [VaultLintFinding] = []
    let src = source.standardizedFileURL

    switch link.kind {
    case .wiki:
        if link.candidates.count > 1, link.resolved == nil {
            out.append(VaultLintFinding(
                rule: .ambiguousWikiLink,
                severity: .warning,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .ambiguousWiki(
                    target: link.rawTarget, count: link.candidates.count),
                targetSuggestion: link.candidates.first
            ))
        } else if link.resolved == nil, link.candidates.isEmpty {
            let suggestion = scratch.suggestion(for: link.rawTarget)
            out.append(VaultLintFinding(
                rule: .deadWikiLink,
                severity: .error,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .deadWiki(
                    target: link.rawTarget,
                    suggestion: suggestion?.lastPathComponent),
                targetSuggestion: suggestion
            ))
        } else if let target = link.resolved?.standardizedFileURL, target == src {
            out.append(VaultLintFinding(
                rule: .selfWikiLink,
                severity: .warning,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .selfLink,
                targetSuggestion: nil
            ))
        }

        // Heading anchor (only when index has headings for the target).
        if let heading = link.heading, !heading.isEmpty,
           let target = link.resolved?.standardizedFileURL,
           let titles = index.headings[target], !titles.isEmpty {
            let key = normalizeHeadingKey(heading)
            let hit = scratch.headingKeySet(for: target, titles: titles).contains(key)
            if !hit {
                out.append(VaultLintFinding(
                    rule: .deadHeadingAnchor,
                    severity: .warning,
                    file: src,
                    line: link.line,
                    utf16Offset: link.utf16Offset,
                    messagePayload: .deadHeading(
                        heading: heading, target: target.lastPathComponent),
                    targetSuggestion: target
                ))
            }
        }

    case .markdown:
        if link.resolved == nil {
            out.append(VaultLintFinding(
                rule: .deadRelativeLink,
                severity: .error,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .deadRelative(target: link.rawTarget),
                targetSuggestion: scratch.suggestion(for: link.rawTarget)
            ))
        } else if let target = link.resolved,
                  !index.roots.isEmpty,
                  !urlIsUnderRoots(target, roots: index.roots) {
            out.append(VaultLintFinding(
                rule: .deadRelativeLink,
                severity: .error,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .outsideWorkspace(target: link.rawTarget),
                targetSuggestion: nil
            ))
        }

    case .image:
        if link.resolved == nil {
            out.append(VaultLintFinding(
                rule: .deadImageLink,
                severity: .error,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                messagePayload: .deadImage(target: link.rawTarget),
                targetSuggestion: nil
            ))
        }
    }

    return out
}

func suggestWikiTarget(raw: String, catalog: WikiRankCatalog) -> URL? {
    // Strip path noise for ranking: take last path component without extension.
    var q = raw
    if let slash = q.lastIndex(of: "/") {
        q = String(q[q.index(after: slash)...])
    }
    if q.lowercased().hasSuffix(".md") {
        q = String(q.dropLast(3))
    }
    q = q.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !q.isEmpty, !catalog.isEmpty else { return nil }
    let ranked = rankWikiFileCandidates(query: q, catalog: catalog, limit: 1)
    guard let best = ranked.first else { return nil }
    // Require a real name signal (not empty-query dump of entire vault).
    let qKey = wikiRankKey(q)
    let qKeyBytes = Array(qKey.utf8)
    let names = ([best.basename, best.title].compactMap { $0 } + best.aliases)
        .map(wikiRankKey)
    let related = names.contains {
        $0 == qKey || $0.hasPrefix(qKey)
            || utf8Contains($0, bytes: qKeyBytes)
            || utf8Contains(qKey, bytes: Array($0.utf8))
    }
    return related ? best.url : nil
}

func urlIsUnderRoots(_ url: URL, roots: [URL]) -> Bool {
    let p = url.standardizedFileURL.path
    return roots.contains { PathScope.contains(p, under: $0.standardizedFileURL.path) }
}


/// Prefer `README.md` over `index.md` (case-insensitive), only direct children.
func homeDocument(in folder: URL, fileManager: FileManager = .default) -> URL? {
    let items = (try? fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
    // Case-sensitive volumes can hold README.md and readme.md side by side —
    // uniqueKeysWithValues would trap on the duplicate lowercased key.
    let names = Dictionary(items.map { ($0.lastPathComponent.lowercased(), $0) },
                           uniquingKeysWith: { first, _ in first })
    if let readme = names["readme.md"] { return readme }
    if let index = names["index.md"] { return index }
    return nil
}
