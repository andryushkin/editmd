import Foundation
import Combine

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

    /// The pure engine (scan/resolve/fingerprint) lives in
    /// `LinkGraphEngine` (Editor/) — shared with the offline editmdctl.
    typealias FileScanEntry = LinkGraphEngine.FileScanEntry
    typealias ResolveEnvironment = LinkGraphEngine.ResolveEnvironment

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
        backlinks = LinkGraphEngine.projectBacklinks(from: outgoing)
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
            let scanned = LinkGraphEngine.scanWorkspaceOutgoing(
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
            let fingerprint = LinkGraphEngine.resolveEnvironmentFingerprint(
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
                    let result = LinkGraphEngine.resolveScannedLinks(
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

            let projected = cancelled ? [:] : LinkGraphEngine.projectBacklinks(from: resolvedMap)
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
            let resolved = LinkGraphEngine.resolveScannedLinks(
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
            LinkGraphEngine.projectBacklinks(from: snapshot)
        }.value
        guard generation == backlinksGeneration else { return }
        backlinks = projected
    }
}
