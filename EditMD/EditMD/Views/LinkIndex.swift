import Foundation
import Combine

/// One reverse edge: `source` file contains `link` pointing at the key URL.
struct BacklinkEdge: Equatable, Sendable {
    let source: URL
    let link: OutgoingLink
}

/// Link graph scoped to the ACTIVE workspace (plan 02; one workspace at a
/// time — see `WorkspaceModel.linkIndexRoots`). Full scans run off-main;
/// results publish on the main actor. Own-document flush updates a single
/// file incrementally; filesystem / workspace mutations force a full rebuild
/// that re-parses only files whose (mtime, size) changed since the last scan.
/// `scanCache` outlives workspace switches, so returning to a workspace is a
/// stat-only walk.
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
    /// Files resolved fresh (not served from the per-file resolve cache).
    private(set) var freshResolveCount = 0

    private var indexKey = ""
    private var scanInFlight = false
    /// Key the in-flight scan was started for. A repeated request for the
    /// same key must NOT restart the scan (opening a file re-runs
    /// `ensureIndex` via view onAppear and used to throw away minutes of
    /// parse/resolve work on large vaults).
    private var inFlightKey = ""
    private var scanPending = false
    /// App was activated while a scan was in flight: the scan may already
    /// have read files an external editor changed afterwards, so the
    /// activation re-key must replay once the scan finishes (a re-key NOW
    /// would cancel the scan and drop its work). Weak — purely a callback
    /// target for `refreshLinkGraphAfterActivation`.
    private weak var pendingActivationWorkspace: WorkspaceModel?
    private var fullScanTask: Task<Void, Never>?
    private var roots: [URL] = []
    /// Per-file results of the last full scan; survives `invalidate()` so the
    /// next scan re-parses only files whose (mtime, size) changed.
    private var scanCache: [URL: FileScanEntry] = [:]

    // MARK: - Public API

    /// Ensure the index matches the active workspace root + linkEpoch.
    /// Scoped to ONE workspace (`linkIndexRoots`): switching the active
    /// document to another workspace changes the key and rescans that
    /// workspace — cheaply, because `scanCache` keeps other workspaces'
    /// per-file parse/resolve entries across the switch.
    func ensureIndex(workspace: WorkspaceModel = .shared) {
        let roots = workspace.linkIndexRoots
        let key = Self.scanKey(epoch: workspace.linkEpoch, roots: roots)
        if indexKey == key, hasCompletedFullScan { return }
        scheduleFullScan(roots: roots, key: key)
    }

    /// The active document (and possibly its owning workspace) changed:
    /// re-check the scan key. No-op for sessions that never built the index
    /// (same lazy model as `invalidate`), and for same-workspace file
    /// switches (`ensureIndex` early-returns on an unchanged key).
    func noteActiveDocumentChanged(workspace: WorkspaceModel = .shared) {
        guard hasCompletedFullScan || scanInFlight else { return }
        ensureIndex(workspace: workspace)
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
        let roots = workspace.linkIndexRoots
        let key = Self.scanKey(epoch: workspace.linkEpoch, roots: roots)
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

    /// Remember that an app activation arrived mid-scan; the finishing scan
    /// replays `refreshLinkGraphAfterActivation` (which re-keys — or defers
    /// again if yet another scan is already running by then).
    func deferActivationRefresh(workspace: WorkspaceModel) {
        pendingActivationWorkspace = workspace
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
        /// Resolve cache: links with `resolved`/`candidates` filled, valid
        /// only while `resolveFingerprint` matches the vault's current
        /// file-set fingerprint. Resolution depends on which files exist,
        /// not on their contents — so an unchanged file in an unchanged
        /// file set skips the (expensive) resolve pass entirely.
        var resolvedLinks: [OutgoingLink]? = nil
        var resolveFingerprint: UInt64? = nil
    }

    /// Filesystem facts the resolve pass depends on, captured during the walk:
    /// every visible item under the roots (files of any type AND directories —
    /// `resolveLocalLinkDestination` accepts any existing path), which
    /// directories the walk actually enumerated, and which items are symlinks
    /// (a listed symlink does not prove its destination exists).
    struct ResolveEnvironment: Sendable {
        let paths: Set<String>
        let walkedDirs: Set<String>
        let symlinks: Set<String>
        static let empty = ResolveEnvironment(paths: [], walkedDirs: [], symlinks: [])
    }

    /// Stable FNV-1a over a string. The resolve fingerprint persists to disk
    /// with the workspace index (plan 10), so it must NOT use `Hasher` (its
    /// seed is random per process).
    nonisolated static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// `path` relative to the first root containing it; unchanged otherwise.
    /// Keeps the fingerprint (and the persisted index) portable: moving or
    /// renaming the vault folder must not invalidate per-file entries.
    nonisolated static func relativePath(_ path: String, roots: [URL]) -> String {
        for root in roots {
            let r = root.path
            if path == r { return "." }
            if path.hasPrefix(r + "/") { return String(path.dropFirst(r.count + 1)) }
        }
        return path
    }

    /// Order-independent fingerprint of the resolve environment: the wiki
    /// index (every indexable file's basename → paths) + the full visible
    /// item set under the roots (plain relative links resolve to ANY existing
    /// path, including directories and non-indexable files). Any item
    /// added/removed/renamed changes it; content edits do not. Paths enter
    /// relativized so the value survives a vault move; stable across
    /// processes (FNV-1a) so it can persist with the workspace index.
    nonisolated static func resolveEnvironmentFingerprint(
        roots: [URL], wikiIndex: [String: [URL]], paths: Set<String>
    ) -> UInt64 {
        var result: UInt64 = 0
        for (key, urls) in wikiIndex {
            var entry = stableHash(key)
            for url in urls {
                entry ^= stableHash(relativePath(url.path, roots: roots)) &* 31
            }
            result ^= entry
        }
        for path in paths {
            result ^= stableHash(relativePath(path, roots: roots))
        }
        return result
    }

    /// True when `destination`'s local-path resolution is fully determined by
    /// `environment`: every candidate the probe would try, up to and including
    /// its first hit, lies in a walked directory under a visible (non-hidden,
    /// non-symlink) name — so the environment fingerprint is guaranteed to
    /// change whenever the resolution outcome could change. Destinations that
    /// fail this (targets outside the roots, hidden names, package contents)
    /// must not be resolve-cached: their existence is invisible to the walk.
    nonisolated static func localResolutionCovered(
        _ destination: String,
        fileDir: URL,
        vaultRoot: URL?,
        environment: ResolveEnvironment
    ) -> Bool {
        for candidate in localLinkDestinationCandidates(
            destination, fileDir: fileDir, vaultRoot: vaultRoot) {
            let std = candidate.standardizedFileURL
            guard environment.walkedDirs.contains(std.deletingLastPathComponent().path),
                  !std.lastPathComponent.hasPrefix("."),
                  !environment.symlinks.contains(std.path)
            else { return false }
            // Probe stops at the first existing candidate — later ones
            // cannot influence the outcome.
            if environment.paths.contains(std.path) { return true }
        }
        return true
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
          skipped: Int, filesScanned: Int, newCache: [URL: FileScanEntry],
          environment: ResolveEnvironment) {
        var outgoing: [URL: [OutgoingLink]] = [:]
        var headings: [URL: [String]] = [:]
        var skipped = 0
        var filesScanned = 0
        var newCache: [URL: FileScanEntry] = [:]
        let mdExt: Set<String> = ["md", "markdown"]
        let fm = FileManager.default

        // Phase 1: enumerate candidates (cheap — attributes only) so the
        // parse phase below has a denominator for progress reporting, and
        // capture the resolve environment (which paths exist) along the way.
        // Item paths are used as-is: the walk starts from standardized roots
        // and appends clean component names, so they already match what
        // `standardizedFileURL` produces for link candidates.
        var candidates: [(url: URL, size: Int64, mtime: Date?)] = []
        var envPaths: Set<String> = []
        var envWalkedDirs: Set<String> = []
        var envSymlinks: Set<String> = []
        func walk(_ dir: URL) {
            if Task.isCancelled { return }
            envWalkedDirs.insert(dir.path)
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles])) ?? []
            for url in items {
                if Task.isCancelled { return }
                let vals = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey
                ])
                envPaths.insert(url.path)
                if vals?.isSymbolicLink == true { envSymlinks.insert(url.path) }
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
        let environment = ResolveEnvironment(
            paths: envPaths, walkedDirs: envWalkedDirs, symlinks: envSymlinks)

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
        return (outgoing, headings, skipped, filesScanned, newCache, environment)
    }

    // MARK: - Internals

    private static func scanKey(epoch: Int, roots: [URL]) -> String {
        "\(epoch):" + roots.map { $0.standardizedFileURL.path }.joined(separator: "\u{1F}")
    }

    private func scheduleFullScan(roots: [URL], key: String) {
        guard !scanInFlight else {
            // Same key → the running scan already produces this result;
            // let it finish. Only a genuinely different key (roots or
            // link epoch moved) makes the in-flight result stale.
            guard inFlightKey != key else { return }
            scanPending = true
            // The current result is stale. Stop its cooperative walk/resolution
            // before the pending scan starts against the newest workspace key.
            fullScanTask?.cancel()
            return
        }
        scanInFlight = true
        inFlightKey = key
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
            // Cold start for this workspace (no live cache entries under its
            // root): seed from the persisted index, so an unchanged vault is
            // a walk + stats instead of a full re-parse. Live entries always
            // win over the disk seed.
            var runCache = capturedCache
            if let root = capturedRoots.first {
                let prefix = root.path + "/"
                if !runCache.keys.contains(where: { $0.path.hasPrefix(prefix) }) {
                    runCache = LinkIndexPersistence.load(root: root)
                        .merging(runCache) { _, live in live }
                }
            }
            let scanned = LinkIndex.scanWorkspaceOutgoing(
                roots: capturedRoots, cache: runCache,
                onProgress: { done, total in
                    guard total > 0 else { return }
                    publishProgress(0.5 * Double(done) / Double(total))
                })

            // Resolve against WikiLinkResolver with current roots. The whole
            // basename index is captured once — no actor hop per link. The
            // resolver caches its index per root set; a full scan must see
            // the disk as it is NOW (that is its contract, and the resolve
            // fingerprint below is computed from it), so force a rebuild.
            var cancelled = Task.isCancelled
            var wikiIndex: [String: [URL]] = [:]
            if !cancelled {
                await WikiLinkResolver.shared.setRoots(capturedRoots)
                await WikiLinkResolver.shared.invalidate()
                wikiIndex = await WikiLinkResolver.shared.indexedMatches()
                cancelled = Task.isCancelled
            }
            var resolvedMap: [URL: [OutgoingLink]] = [:]
            var updatedCache = scanned.newCache
            var freshResolves = 0
            let fingerprint = LinkIndex.resolveEnvironmentFingerprint(
                roots: capturedRoots, wikiIndex: wikiIndex,
                paths: scanned.environment.paths)
            let resolveTotal = scanned.outgoing.count
            let resolveStep = max(1, resolveTotal / 100)
            var resolveDone = 0
            for (source, links) in scanned.outgoing where !cancelled {
                // On cancellation fall through to MainActor.run WITHOUT
                // applying data: an early `return` here would leave
                // scanInFlight stuck true and freeze the index for the
                // rest of the session.
                if Task.isCancelled { cancelled = true; break }
                if let hit = updatedCache[source],
                   hit.resolveFingerprint == fingerprint,
                   let cached = hit.resolvedLinks {
                    // Unchanged file in an unchanged file set — the previous
                    // resolution is still exact.
                    resolvedMap[source] = cached
                } else {
                    let result = LinkIndex.resolveScannedLinks(
                        links, source: source, roots: capturedRoots,
                        vaultFallback: nil, wikiIndex: wikiIndex,
                        environment: scanned.environment
                    )
                    resolvedMap[source] = result.links
                    freshResolves += 1
                    // Cache only resolutions the fingerprint fully covers —
                    // a link probing outside the walked tree (or a hidden /
                    // symlinked name) must re-resolve on every full scan.
                    if result.cacheable, var entry = updatedCache[source] {
                        entry.resolvedLinks = result.links
                        entry.resolveFingerprint = fingerprint
                        updatedCache[source] = entry
                    }
                }
                resolveDone += 1
                if resolveDone % resolveStep == 0, resolveTotal > 0 {
                    publishProgress(0.5 + 0.5 * Double(resolveDone) / Double(resolveTotal))
                }
                if Task.isCancelled { cancelled = true; break }
            }
            let resolvedCache = updatedCache
            let freshResolveTotal = freshResolves

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
                    // Per-workspace indexing switches roots: keep entries of
                    // files OUTSIDE the scanned roots (other workspaces) so
                    // switching back costs stats, not a re-parse/re-resolve;
                    // entries under the scanned roots are replaced wholesale
                    // (absent = deleted file).
                    let rootPaths = capturedRoots.map(\.path)
                    self.scanCache = self.scanCache.filter { url, _ in
                        !rootPaths.contains {
                            url.path == $0 || url.path.hasPrefix($0 + "/")
                        }
                    }.merging(resolvedCache) { _, new in new }
                    self.freshResolveCount += freshResolveTotal
                    // Persist the freshly scanned workspace (plan 10):
                    // atomic write off-main; loose/lite (no roots) never
                    // writes, so `.editmd/` appears only in adopted
                    // workspaces. Full scans are rare post-CPU-saga — no
                    // debounce needed; autosaves go through the single-file
                    // path and do not rewrite the file (their entries catch
                    // up on the next full scan via mtime mismatch).
                    if let root = capturedRoots.first {
                        let snapshot = resolvedCache
                        Task.detached(priority: .utility) {
                            LinkIndexPersistence.save(cache: snapshot, root: root)
                        }
                    }
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
                // AFTER the pending-rescan block: if that block just started
                // a new scan, the activation refresh re-defers instead of
                // cancelling it; otherwise it re-keys now, covering files
                // this scan read before the external edit happened.
                if let workspace = self.pendingActivationWorkspace {
                    self.pendingActivationWorkspace = nil
                    workspace.refreshLinkGraphAfterActivation(index: self)
                }
            }
        }
        fullScanTask = task
    }

    /// Resolve one file's scanned links (wiki index + local path rules).
    /// Pure over inputs; hits the disk — call off the main actor. `wikiIndex`
    /// is a captured WikiLinkResolver snapshot: batch resolution must not hop
    /// to the actor per link (the full scan resolves tens of thousands).
    /// `cacheable` is true only when `environment` was given AND every
    /// path-like link's resolution is covered by it (see
    /// `localResolutionCovered`) — the single-file path passes nil.
    nonisolated private static func resolveScannedLinks(
        _ links: [OutgoingLink],
        source: URL,
        roots: [URL],
        vaultFallback: URL?,
        wikiIndex: [String: [URL]],
        environment: ResolveEnvironment? = nil
    ) -> (links: [OutgoingLink], cacheable: Bool) {
        let vault = roots.first { root in
            let p = source.path
            let r = root.standardizedFileURL.path
            return p == r || p.hasPrefix(r + "/")
        } ?? vaultFallback
        var resolvedLinks: [OutgoingLink] = []
        resolvedLinks.reserveCapacity(links.count)
        var cacheable = environment != nil
        for link in links {
            if Task.isCancelled { return ([], false) }
            if cacheable, let environment,
               link.kind == .markdown || link.kind == .image,
               !localResolutionCovered(
                   link.rawTarget,
                   fileDir: source.deletingLastPathComponent(),
                   vaultRoot: vault,
                   environment: environment) {
                cacheable = false
            }
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
        return (resolvedLinks, cacheable)
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
            ).links
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
