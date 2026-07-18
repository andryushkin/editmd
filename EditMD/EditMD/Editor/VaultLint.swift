import Foundation

// MARK: - Rules / findings

/// Workspace-level link health rules (plan 06). Separate from per-file
/// `LintRule` so Source lint stays workspace-free.
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

struct VaultLintFinding: Equatable, Sendable, Identifiable {
    let rule: VaultLintRule
    let severity: VaultLintSeverity
    let file: URL
    /// 1-based line when known (orphan has nil).
    let line: Int?
    /// UTF-16 offset for jump (orphan has nil).
    let utf16Offset: Int?
    let message: String
    /// Best-guess target for dead links (basename ranking).
    let targetSuggestion: URL?

    var id: String {
        "\(rule.rawValue)|\(file.path)|\(line ?? -1)|\(utf16Offset ?? -1)|\(message)"
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
        } ?? LinkIndex.projectBacklinks(from: stdOut)
        self.headings = Dictionary(uniqueKeysWithValues:
            headings.map { ($0.key.standardizedFileURL, $0.value) })
        self.skippedOversizedCount = skippedOversizedCount
        self.roots = roots.map(\.standardizedFileURL)
        self.homeDocuments = Set(homeDocuments.map(\.standardizedFileURL))
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

/// Pure vault-lint over an index snapshot. Never reads disk. Returns `[]`
/// when the surrounding task is cancelled mid-run (a superseded run must not
/// burn cores to completion on a stale snapshot).
func vaultLintFindings(index: LinkIndexSnapshot) -> [VaultLintFinding] {
    var findings: [VaultLintFinding] = []
    let files = index.allFiles
    var scratch = VaultLintScratch(catalog: WikiRankCatalog(
        files.map { url -> WikiFileCandidate in
            WikiFileCandidate(
                url: url,
                basename: url.deletingPathExtension().lastPathComponent,
                title: nil,
                aliases: [],
                relativePath: url.lastPathComponent
            )
        }
    ))

    for source in files {
        if Task.isCancelled { return [] }
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
                    message: String(localized: "Nothing links to “\(source.lastPathComponent)”"),
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
                message: String(localized: "“\(link.rawTarget)” is ambiguous (\(link.candidates.count) files)"),
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
                message: suggestion.map {
                    String(localized: "Wiki link “\(link.rawTarget)” not found — maybe “\($0.lastPathComponent)”")
                } ?? String(localized: "Wiki link “\(link.rawTarget)” not found"),
                targetSuggestion: suggestion
            ))
        } else if let target = link.resolved?.standardizedFileURL, target == src {
            out.append(VaultLintFinding(
                rule: .selfWikiLink,
                severity: .warning,
                file: src,
                line: link.line,
                utf16Offset: link.utf16Offset,
                message: String(localized: "Link points to this same file"),
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
                    message: String(localized: "Heading “\(heading)” not found in “\(target.lastPathComponent)”"),
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
                message: String(localized: "Link “\(link.rawTarget)” does not exist"),
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
                message: String(localized: "Link “\(link.rawTarget)” points outside the workspace"),
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
                message: String(localized: "Image “\(link.rawTarget)” not found"),
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
    let qKey = q.lowercased()
    let names = ([best.basename, best.title].compactMap { $0 } + best.aliases)
        .map { $0.lowercased() }
    let related = names.contains {
        $0 == qKey || $0.hasPrefix(qKey) || $0.contains(qKey) || qKey.contains($0)
    }
    return related ? best.url : nil
}

func urlIsUnderRoots(_ url: URL, roots: [URL]) -> Bool {
    let p = url.standardizedFileURL.path
    for root in roots {
        let r = root.standardizedFileURL.path
        if p == r || p.hasPrefix(r + "/") { return true }
    }
    return false
}

/// Convert vault findings for one file into Source-compatible diagnostics
/// (no auto-fixes). Ranges: zero-length at link offset when known.
func vaultFindingsAsLintDiagnostics(
    _ findings: [VaultLintFinding],
    for file: URL
) -> [LintDiagnostic] {
    let std = file.standardizedFileURL
    return findings.compactMap { f -> LintDiagnostic? in
        guard f.file.standardizedFileURL == std else { return nil }
        // Orphans have no range — skip Source underline (still in report).
        guard let offset = f.utf16Offset else { return nil }
        guard let rule = lintRule(for: f.rule) else { return nil }
        let severity: LintSeverity
        switch f.severity {
        case .error: severity = .error
        case .warning, .info: severity = .warning
        }
        return LintDiagnostic(
            range: NSRange(location: max(0, offset), length: 0),
            severity: severity,
            rule: rule,
            message: f.message,
            fixes: []
        )
    }
}

private func lintRule(for rule: VaultLintRule) -> LintRule? {
    switch rule {
    case .deadWikiLink: return .vaultDeadWikiLink
    case .ambiguousWikiLink: return .vaultAmbiguousWikiLink
    case .selfWikiLink: return .vaultSelfWikiLink
    case .deadRelativeLink: return .vaultDeadRelativeLink
    case .deadImageLink: return .vaultDeadImageLink
    case .deadHeadingAnchor: return .vaultDeadHeadingAnchor
    case .orphanFile: return nil
    }
}
