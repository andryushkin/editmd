import Foundation
import Combine

/// One reverse edge: `source` file contains `link` pointing at the key URL.
struct BacklinkEdge: Equatable, Sendable {
    let source: URL
    let link: OutgoingLink
}

/// Workspace-scoped link graph (plan 02). Full scans run off-main; results
/// publish on the main actor. Own-document flush updates a single file
/// incrementally; filesystem / workspace mutations force a full rebuild that
/// re-parses only files whose (mtime, size) changed since the last scan.
@MainActor
final class LinkIndex: ObservableObject {
    static let shared = LinkIndex()

    /// Max file size fully read during a workspace scan (4 MiB).
    nonisolated static let maxFileBytes: Int64 = 4 * 1024 * 1024

    @Published private(set) var outgoing: [URL: [OutgoingLink]] = [:]
    @Published private(set) var backlinks: [URL: [BacklinkEdge]] = [:]
    /// Heading titles per file (plan 06 deadHeadingAnchor).
    @Published private(set) var headings: [URL: [String]] = [:]
    @Published private(set) var isScanning = false
    /// 0…1 while a full scan runs (parse ≙ first half, resolve ≙ second);
    /// nil when idle. Throttled — at most ~200 updates per scan.
    @Published private(set) var scanProgress: Double?
    @Published private(set) var skippedOversizedCount = 0
    /// True after at least one full scan finished for the current key.
    @Published private(set) var hasCompletedFullScan = false

    /// Test hooks — how many full / single-file scans ran (including resolution).
    private(set) var fullScanCount = 0
    private(set) var fileScanCount = 0

    private var indexKey = ""
    private var scanInFlight = false
    private var scanPending = false
    private var fullScanTask: Task<Void, Never>?
    private var roots: [URL] = []
    /// Per-file results of the last full scan; survives `invalidate()` so the
    /// next scan re-parses only files whose (mtime, size) changed.
    private var scanCache: [URL: FileScanEntry] = [:]

    // MARK: - Public API

    /// Ensure the index matches the current workspace roots + contentEpoch.
    func ensureIndex(workspace: WorkspaceModel = .shared) {
        let roots = workspace.workspaces.map(\.url)
        let key = Self.scanKey(epoch: workspace.contentEpoch, roots: roots)
        if indexKey == key, hasCompletedFullScan { return }
        scheduleFullScan(roots: roots, key: key)
    }

    /// Filesystem mutation already bumped contentEpoch: mark the index stale.
    /// Rebuild eagerly only when someone has already built (or is building)
    /// the index — sessions that never opened a consumer stay lazy, same
    /// epoch-key model as `ensureTagIndex`.
    func invalidate(workspace: WorkspaceModel = .shared) {
        indexKey = ""
        let hadConsumers = hasCompletedFullScan || scanInFlight
        hasCompletedFullScan = false
        guard hadConsumers else { return }
        ensureIndex(workspace: workspace)
    }

    /// Own-document persist path (autosave / ⌘S / applyAgentEdit flush).
    /// Rescans only this file when a full index already exists for the key.
    func noteDocumentPersisted(url: URL, content: String,
                               workspace: WorkspaceModel = .shared) {
        let std = url.standardizedFileURL
        let roots = workspace.workspaces.map(\.url)
        let key = Self.scanKey(epoch: workspace.contentEpoch, roots: roots)
        // No workspace yet (lite/loose): still keep a one-file outgoing map.
        if roots.isEmpty {
            Task { await self.rescanSingleFile(std, content: content, roots: roots, key: key) }
            return
        }
        // Stale full index — schedule full rebuild; single-file would be incomplete.
        if indexKey != key || !hasCompletedFullScan {
            ensureIndex(workspace: workspace)
            // Also apply this file's content immediately so UI is not empty.
            Task { await self.rescanSingleFile(std, content: content, roots: roots, key: key) }
            return
        }
        Task { await self.rescanSingleFile(std, content: content, roots: roots, key: key) }
    }

    func outgoingLinks(for url: URL?) -> [OutgoingLink] {
        guard let url else { return [] }
        return outgoing[url.standardizedFileURL] ?? []
    }

    func backlinkEdges(for url: URL?) -> [BacklinkEdge] {
        guard let url else { return [] }
        return backlinks[url.standardizedFileURL] ?? []
    }

    /// Test/seed helper: install a resolved outgoing map as if a full scan finished.
    func seedForTesting(
        outgoing map: [URL: [OutgoingLink]],
        headings heads: [URL: [String]] = [:],
        roots: [URL] = [],
        key: String = "test"
    ) {
        // Standardize keys like the real scan does — snapshot() trusts them.
        outgoing = Dictionary(uniqueKeysWithValues:
            map.map { ($0.key.standardizedFileURL, $0.value) })
        backlinks = Self.projectBacklinks(from: outgoing)
        headings = Dictionary(uniqueKeysWithValues:
            heads.map { ($0.key.standardizedFileURL, $0.value) })
        self.roots = roots.map(\.standardizedFileURL)
        indexKey = key
        hasCompletedFullScan = true
    }

    /// Immutable slice for vault-lint (off-main pure function).
    /// `homeDocuments` stays empty: it needs a directory listing per root, so
    /// the consumer fills it off-main (see `VaultLintModel.scheduleRun`).
    func snapshot() -> LinkIndexSnapshot {
        // Trusted init: the index stores standardized URLs, and the plain
        // init's re-standardization stats the disk per URL — on the main actor
        // that froze the run loop for multi-thousand-file vaults.
        LinkIndexSnapshot(
            standardizedOutgoing: outgoing,
            backlinks: backlinks,
            headings: headings,
            skippedOversizedCount: skippedOversizedCount,
            roots: roots,
            homeDocuments: []
        )
    }

    // MARK: - Resolution (testable pure-ish)

    /// Resolve one link relative to `sourceURL` using local path rules then
    /// `WikiLinkResolver` for wiki basenames.
    nonisolated static func resolveLink(
        _ link: OutgoingLink,
        from sourceURL: URL,
        vaultRoot: URL?,
        wikiMatches: [URL]
    ) -> OutgoingLink {
        var out = link
        let fileDir = sourceURL.deletingLastPathComponent()
        let target = link.rawTarget

        // Markdown / path-like image: try filesystem resolution first.
        let looksLikePath = target.contains("/")
            || target.hasPrefix(".")
            || target.contains(".")
        if link.kind == .markdown || (link.kind == .image && looksLikePath) {
            if let hit = resolveLocalLinkDestination(target, fileDir: fileDir, vaultRoot: vaultRoot) {
                out.resolved = hit.standardizedFileURL
                out.candidates = [hit.standardizedFileURL]
                return out
            }
            // Fall through to wiki basename for bare `Note` style destinations.
        }

        // Wiki (and pathless image embeds `![[img.png]]` already handled as
        // path-like when they have an extension; still try wiki index).
        // `wikiMatches` come standardized from WikiLinkResolver — do not
        // re-standardize: it stats the disk per URL, and the full scan calls
        // this for every link in the vault.
        let matches = wikiMatches
        if matches.isEmpty {
            out.resolved = nil
            out.candidates = []
            return out
        }
        if matches.count == 1 {
            out.resolved = matches[0]
            out.candidates = matches
            return out
        }
        // Prefer sibling of the source (same as navigateToWikiLink).
        let sourceDir = fileDir.standardizedFileURL
        if let sibling = matches.first(where: {
            $0.deletingLastPathComponent().standardizedFileURL == sourceDir
        }) {
            out.resolved = sibling
            out.candidates = matches
            return out
        }
        // Ambiguous — no unique pick.
        out.resolved = nil
        out.candidates = matches
        return out
    }

    nonisolated static func projectBacklinks(
        from outgoing: [URL: [OutgoingLink]]
    ) -> [URL: [BacklinkEdge]] {
        var result: [URL: [BacklinkEdge]] = [:]
        for (source, links) in outgoing {
            let src = source.standardizedFileURL
            for link in links {
                guard let target = link.resolved?.standardizedFileURL else { continue }
                result[target, default: []].append(BacklinkEdge(source: src, link: link))
            }
        }
        for key in result.keys {
            result[key]?.sort {
                if $0.source.path != $1.source.path {
                    return $0.source.path < $1.source.path
                }
                return $0.link.utf16Offset < $1.link.utf16Offset
            }
        }
        return result
    }

    /// One file's parsed scan result keyed by (mtime, size). Full scans reuse
    /// entries for unchanged files, so an epoch bump re-parses only what
    /// actually changed instead of the whole workspace.
    struct FileScanEntry: Sendable {
        let mtime: Date
        let size: Int64
        let links: [OutgoingLink]
        let headings: [String]
    }

    /// Scan all markdown files under `roots` (no resolution). Off-main only.
    /// `onProgress(done, total)` reports the parse phase (directory walk is
    /// fast; parsing dominates) and is called at most ~100 times per scan.
    nonisolated static func scanWorkspaceOutgoing(
        roots: [URL],
        maxBytes: Int64 = LinkIndex.maxFileBytes,
        cache: [URL: FileScanEntry] = [:],
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> (outgoing: [URL: [OutgoingLink]], headings: [URL: [String]],
          skipped: Int, filesScanned: Int, newCache: [URL: FileScanEntry]) {
        var outgoing: [URL: [OutgoingLink]] = [:]
        var headings: [URL: [String]] = [:]
        var skipped = 0
        var filesScanned = 0
        var newCache: [URL: FileScanEntry] = [:]
        let mdExt: Set<String> = ["md", "markdown"]
        let fm = FileManager.default

        // Phase 1: enumerate candidates (cheap — attributes only) so the
        // parse phase below has a denominator for progress reporting.
        var candidates: [(url: URL, size: Int64, mtime: Date?)] = []
        func walk(_ dir: URL) {
            if Task.isCancelled { return }
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey
                ],
                options: [.skipsHiddenFiles])) ?? []
            for url in items {
                if Task.isCancelled { return }
                let vals = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey
                ])
                let isDir = vals?.isDirectory ?? false
                let isPackage = vals?.isPackage ?? false
                if isDir && !isPackage {
                    walk(url)
                    continue
                }
                guard mdExt.contains(url.pathExtension.lowercased()) else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                if size > maxBytes {
                    skipped += 1
                    continue
                }
                candidates.append((url, size, vals?.contentModificationDate))
            }
        }
        for root in roots {
            walk(root.standardizedFileURL)
        }

        // Phase 2: parse (or reuse cache) with progress.
        let total = candidates.count
        let step = max(1, total / 100)
        for (done, candidate) in candidates.enumerated() {
            if Task.isCancelled { break }
            if done % step == 0 { onProgress?(done, total) }
            let key = candidate.url.standardizedFileURL
            if let mtime = candidate.mtime, let hit = cache[key],
               hit.mtime == mtime, hit.size == candidate.size {
                outgoing[key] = hit.links
                headings[key] = hit.headings
                newCache[key] = hit
                continue
            }
            guard let data = try? Data(contentsOf: candidate.url),
                  let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else { continue }
            filesScanned += 1
            let links = scanOutgoingLinks(text: text)
            let titles = markdownOutline(text).map(\.title)
            outgoing[key] = links
            headings[key] = titles
            if let mtime = candidate.mtime {
                newCache[key] = FileScanEntry(
                    mtime: mtime, size: candidate.size, links: links, headings: titles)
            }
        }
        onProgress?(total, total)
        return (outgoing, headings, skipped, filesScanned, newCache)
    }

    // MARK: - Internals

    private static func scanKey(epoch: Int, roots: [URL]) -> String {
        "\(epoch):" + roots.map { $0.standardizedFileURL.path }.joined(separator: "\u{1F}")
    }

    private func scheduleFullScan(roots: [URL], key: String) {
        guard !scanInFlight else {
            scanPending = true
            // The current result is stale. Stop its cooperative walk/resolution
            // before the pending scan starts against the newest workspace key.
            fullScanTask?.cancel()
            return
        }
        scanInFlight = true
        isScanning = true
        scanProgress = 0
        self.roots = roots.map(\.standardizedFileURL)
        let capturedRoots = self.roots
        let capturedCache = scanCache

        // Progress publisher: parse phase maps to 0…0.5, resolve to 0.5…1.
        // Hops to main per report; callers throttle to ~100 reports per phase.
        let publishProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.scanProgress = fraction
            }
        }

        // Scan AND resolution run detached: resolveLocalLinkDestination stats
        // the disk per link — never on the main actor.
        let task = Task.detached(priority: .utility) { [weak self] in
            let scanned = LinkIndex.scanWorkspaceOutgoing(
                roots: capturedRoots, cache: capturedCache,
                onProgress: { done, total in
                    guard total > 0 else { return }
                    publishProgress(0.5 * Double(done) / Double(total))
                })

            // Resolve against WikiLinkResolver with current roots. The whole
            // basename index is captured once — no actor hop per link.
            var cancelled = Task.isCancelled
            var wikiIndex: [String: [URL]] = [:]
            if !cancelled {
                await WikiLinkResolver.shared.setRoots(capturedRoots)
                wikiIndex = await WikiLinkResolver.shared.indexedMatches()
                cancelled = Task.isCancelled
            }
            var resolvedMap: [URL: [OutgoingLink]] = [:]
            let resolveTotal = scanned.outgoing.count
            let resolveStep = max(1, resolveTotal / 100)
            var resolveDone = 0
            for (source, links) in scanned.outgoing where !cancelled {
                // On cancellation fall through to MainActor.run WITHOUT
                // applying data: an early `return` here would leave
                // scanInFlight stuck true and freeze the index for the
                // rest of the session.
                if Task.isCancelled { cancelled = true; break }
                resolvedMap[source] = LinkIndex.resolveScannedLinks(
                    links, source: source, roots: capturedRoots,
                    vaultFallback: nil, wikiIndex: wikiIndex
                )
                resolveDone += 1
                if resolveDone % resolveStep == 0, resolveTotal > 0 {
                    publishProgress(0.5 + 0.5 * Double(resolveDone) / Double(resolveTotal))
                }
                if Task.isCancelled { cancelled = true; break }
            }

            let projected = cancelled ? [:] : LinkIndex.projectBacklinks(from: resolvedMap)
            guard let self else { return }
            await MainActor.run {
                self.scanInFlight = false
                self.isScanning = false
                self.scanProgress = nil
                self.fullScanTask = nil
                // A cancelled walk can hold only a partial cache; never replace
                // the last complete cache with it.
                if !cancelled {
                    self.scanCache = scanned.newCache
                }
                // Accept result unless cancelled or a newer ensureIndex queued
                // a rescan (it re-reads live workspace state below).
                if !cancelled, !self.scanPending {
                    self.outgoing = resolvedMap
                    // Invalidate any in-flight single-file projection so it
                    // cannot overwrite the fresher full-scan result.
                    self.backlinksGeneration += 1
                    self.backlinks = projected
                    self.headings = Dictionary(uniqueKeysWithValues:
                        scanned.headings.map { ($0.key.standardizedFileURL, $0.value) })
                    self.skippedOversizedCount = scanned.skipped
                    self.indexKey = key
                    self.hasCompletedFullScan = true
                    self.fullScanCount += 1
                    self.fileScanCount += scanned.filesScanned
                }
                if self.scanPending {
                    self.scanPending = false
                    // Re-read live workspace state.
                    self.ensureIndex()
                }
            }
        }
        fullScanTask = task
    }

    /// Resolve one file's scanned links (wiki index + local path rules).
    /// Pure over inputs; hits the disk — call off the main actor. `wikiIndex`
    /// is a captured WikiLinkResolver snapshot: batch resolution must not hop
    /// to the actor per link (the full scan resolves tens of thousands).
    nonisolated private static func resolveScannedLinks(
        _ links: [OutgoingLink],
        source: URL,
        roots: [URL],
        vaultFallback: URL?,
        wikiIndex: [String: [URL]]
    ) -> [OutgoingLink] {
        let vault = roots.first { root in
            let p = source.path
            let r = root.standardizedFileURL.path
            return p == r || p.hasPrefix(r + "/")
        } ?? vaultFallback
        var resolvedLinks: [OutgoingLink] = []
        resolvedLinks.reserveCapacity(links.count)
        for link in links {
            if Task.isCancelled { return [] }
            let wikiHits: [URL]
            if link.kind == .wiki
                || (link.kind == .image && !link.rawTarget.contains("/")) {
                wikiHits = WikiLinkResolver.matches(for: link.rawTarget, in: wikiIndex)
            } else if link.kind == .markdown
                        || link.kind == .image {
                // Path resolve first; wiki fallback for bare names.
                let local = resolveLocalLinkDestination(
                    link.rawTarget,
                    fileDir: source.deletingLastPathComponent(),
                    vaultRoot: vault
                )
                if local != nil {
                    wikiHits = []
                } else {
                    wikiHits = WikiLinkResolver.matches(for: link.rawTarget, in: wikiIndex)
                }
            } else {
                wikiHits = []
            }
            resolvedLinks.append(resolveLink(
                link, from: source, vaultRoot: vault, wikiMatches: wikiHits
            ))
        }
        return resolvedLinks
    }

    private func rescanSingleFile(
        _ url: URL,
        content: String,
        roots: [URL],
        key: String
    ) async {
        // Parse + resolve run detached: swift-markdown over the whole buffer
        // and per-link disk stats must not hitch the main actor on every flush.
        let (resolvedLinks, fileHeadings) = await Task.detached(
            priority: .userInitiated
        ) { () -> ([OutgoingLink], [String]) in
            let scanned = scanOutgoingLinks(text: content)
            let headings = markdownOutline(content).map(\.title)

            if !roots.isEmpty {
                await WikiLinkResolver.shared.setRoots(roots)
            } else {
                await WikiLinkResolver.shared.setRoots([url.deletingLastPathComponent()])
            }
            let wikiIndex = await WikiLinkResolver.shared.indexedMatches()

            let hasRootMatch = roots.contains { root in
                let p = url.path
                let r = root.standardizedFileURL.path
                return p == r || p.hasPrefix(r + "/")
            }
            let fallback = hasRootMatch
                ? nil
                : nearestVaultRoot(startingAt: url.deletingLastPathComponent())
            let resolved = LinkIndex.resolveScannedLinks(
                scanned, source: url, roots: roots, vaultFallback: fallback,
                wikiIndex: wikiIndex
            )
            return (resolved, headings)
        }.value

        // Back on the main actor. Drop only when a newer *workspace*
        // full-scan key won the race. Lite / empty-roots updates always
        // apply (single-file map).
        if !roots.isEmpty,
           hasCompletedFullScan,
           !indexKey.isEmpty,
           indexKey != key {
            return
        }
        outgoing[url.standardizedFileURL] = resolvedLinks
        headings[url.standardizedFileURL] = fileHeadings
        fileScanCount += 1
        await refreshBacklinksOffMain()
    }

    /// Recomputes the backlink projection off the main actor: projecting a
    /// multi-thousand-file map on every autosave flush was long enough to trip
    /// the hang detector. Stale projections are dropped via the generation.
    private var backlinksGeneration = 0
    private func refreshBacklinksOffMain() async {
        backlinksGeneration += 1
        let generation = backlinksGeneration
        let snapshot = outgoing
        let projected = await Task.detached(priority: .userInitiated) {
            Self.projectBacklinks(from: snapshot)
        }.value
        guard generation == backlinksGeneration else { return }
        backlinks = projected
    }
}
