import Foundation
import Combine
import SwiftUI

/// Owns vault-lint results. The full-vault run is expensive (it ranks
/// suggestions for every dead link in the workspace), so it executes only on
/// demand: while the report panel is open, or via `runNow()`. Editors get
/// their underlines from a cheap per-file path that lints just one file's
/// links whenever the link index changes.
@MainActor
final class VaultLintModel: ObservableObject {
    static let shared = VaultLintModel()

    @Published private(set) var findings: [VaultLintFinding] = []
    @Published private(set) var skippedOversizedCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?
    /// Bumps when findings change so SwiftUI can rebind cheaply.
    @Published private(set) var revision = 0

    /// True while the report panel is visible. Index updates re-run the full
    /// lint only then; otherwise only tracked per-file entries refresh.
    var reportActive = false {
        didSet {
            if !reportActive {
                cancelFullRun()
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    private weak var index: LinkIndex?

    // Per-file lint cache for open editors. Keyed by standardized URL;
    // entries refresh off-main when the index revision moves.
    private struct FileCacheEntry {
        var revision: Int
        var findings: [VaultLintFinding]
        var lastAccess: Date
    }
    private var fileCache: [URL: FileCacheEntry] = [:]
    private var fileTasks: [URL: Task<Void, Never>] = [:]
    private var indexRevision = 0
    /// The catalog depends only on the set of indexed files, not link contents.
    /// Keep one completed or in-flight build so an index publication cannot
    /// fan out into one O(vault) build per tracked editor.
    private var catalogCache: (files: [URL], catalog: WikiRankCatalog)?
    private var catalogBuild: (
        id: Int, files: [URL], task: Task<WikiRankCatalog, Never>
    )?
    private var nextCatalogBuildID = 0
    private static let maxTrackedFiles = 32

    private init() {
        bind(to: LinkIndex.shared)
    }

    /// Test / alternate index injection.
    func bind(to index: LinkIndex) {
        cancelFullRun()
        for task in fileTasks.values {
            task.cancel()
        }
        fileTasks = [:]
        catalogBuild?.task.cancel()
        catalogBuild = nil
        cancellables.removeAll()
        self.index = index
        indexRevision += 1
        fileCache = [:]
        catalogCache = nil
        // Recompute when the published graph changes (full scan or single-file).
        index.$outgoing
            .combineLatest(index.$hasCompletedFullScan, index.$isScanning)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _, completed, scanning in
                guard let self else { return }
                if scanning { return }
                self.indexRevision += 1
                if index.outgoing.isEmpty, !index.hasCompletedFullScan {
                    // No workspace roots and empty graph → clear.
                    self.findings = []
                    self.skippedOversizedCount = 0
                    self.fileCache = [:]
                    self.revision += 1
                    return
                }
                if completed || !index.outgoing.isEmpty {
                    self.refreshTrackedFiles()
                    if self.reportActive {
                        self.scheduleRun()
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// Manual re-run (report panel open / refresh button).
    func runNow() {
        scheduleRun(force: true)
    }

    var issueCount: Int { findings.count }

    var errorCount: Int {
        findings.filter { $0.severity == .error }.count
    }

    var warningCount: Int {
        findings.filter { $0.severity == .warning || $0.severity == .info }.count
    }

    /// Per-file findings for the editor-underline merge. Returns the cached
    /// result immediately and refreshes it off-main when stale; a refresh
    /// that changes the result posts `.vaultLintDidUpdate`, which re-runs the
    /// merge. Falls back to the last full run while the cache warms up.
    func findings(for file: URL?) -> [VaultLintFinding] {
        guard let file else { return [] }
        let std = file.standardizedFileURL
        if var entry = fileCache[std] {
            entry.lastAccess = Date()
            fileCache[std] = entry
            if entry.revision != indexRevision {
                scheduleFileRun(std)
            }
            return entry.findings
        }
        scheduleFileRun(std)
        guard !findings.isEmpty else { return [] }
        return findings.filter { $0.file == std }
    }

    // MARK: - Per-file path

    private func refreshTrackedFiles() {
        let stale = fileCache.keys.filter {
            fileCache[$0]?.revision != indexRevision
        }
        scheduleFileRuns(stale)
    }

    private func scheduleFileRun(_ std: URL) {
        scheduleFileRuns([std])
    }

    private enum CatalogSource: Sendable {
        case ready(WikiRankCatalog)
        case building(id: Int, task: Task<WikiRankCatalog, Never>)
    }

    private func catalogSource(for files: [URL]) -> CatalogSource {
        if let cached = catalogCache, cached.files == files {
            return .ready(cached.catalog)
        }
        if let build = catalogBuild, build.files == files {
            return .building(id: build.id, task: build.task)
        }
        nextCatalogBuildID += 1
        let id = nextCatalogBuildID
        let task = Task.detached(priority: .utility) {
            vaultLintCatalog(files: files)
        }
        catalogBuild = (id, files, task)
        return .building(id: id, task: task)
    }

    private func scheduleFileRuns<S: Sequence>(_ urls: S) where S.Element == URL {
        guard let index else { return }
        let pending = urls.filter { fileTasks[$0] == nil }
        guard !pending.isEmpty else { return }
        let revision = indexRevision
        let snap = index.snapshot()
        let files = snap.allFiles
        let catalogSource = catalogSource(for: files)
        for std in pending {
            let task = Task.detached(priority: .utility) { [weak self] in
                let catalog: WikiRankCatalog
                let catalogBuildID: Int?
                switch catalogSource {
                case let .ready(value):
                    catalog = value
                    catalogBuildID = nil
                case let .building(id, task):
                    catalog = await task.value
                    catalogBuildID = id
                }
                guard !Task.isCancelled else { return }
                let result = vaultLintFindings(
                    for: std, index: snap, catalog: catalog)
                await MainActor.run {
                    guard let self else { return }
                    guard !Task.isCancelled else { return }
                    self.fileTasks[std] = nil
                    guard revision == self.indexRevision else {
                        // The graph moved while we ran — redo against the new one.
                        self.scheduleFileRun(std)
                        return
                    }
                    if self.catalogCache?.files != files {
                        self.catalogCache = (files, catalog)
                    }
                    if self.catalogBuild?.id == catalogBuildID {
                        self.catalogBuild = nil
                    }
                    let previous = self.fileCache[std]?.findings
                    self.fileCache[std] = FileCacheEntry(
                        revision: revision, findings: result, lastAccess: Date())
                    self.evictStaleTrackedFiles()
                    if previous != result {
                        NotificationCenter.default.post(
                            name: .vaultLintDidUpdate, object: nil)
                    }
                }
            }
            fileTasks[std] = task
        }
    }

    private func evictStaleTrackedFiles() {
        while fileCache.count > Self.maxTrackedFiles {
            guard let oldest = fileCache.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            }) else { return }
            fileCache.removeValue(forKey: oldest.key)
        }
    }

    // MARK: - Full run (report panel)

    private func cancelFullRun() {
        runTask?.cancel()
        runTask = nil
        isRunning = false
    }

    private func scheduleRun(force: Bool = false) {
        runTask?.cancel()
        guard let index else { return }
        // No workspace roots and empty graph → clear.
        if index.outgoing.isEmpty, !index.hasCompletedFullScan, !force {
            findings = []
            skippedOversizedCount = 0
            revision += 1
            return
        }
        isRunning = true
        let snap = index.snapshot()
        let files = snap.allFiles
        let catalogSource = catalogSource(for: files)
        runTask = Task.detached(priority: .utility) {
            let catalog: WikiRankCatalog
            let catalogBuildID: Int?
            switch catalogSource {
            case let .ready(value):
                catalog = value
                catalogBuildID = nil
            case let .building(id, task):
                catalog = await task.value
                catalogBuildID = id
            }
            guard !Task.isCancelled else { return }
            // Home documents need a directory listing per root — do the disk
            // work here, not in `LinkIndex.snapshot()` on the main actor.
            let homes = Set(snap.roots.compactMap {
                homeDocument(in: $0)?.standardizedFileURL
            })
            let full = LinkIndexSnapshot(
                standardizedOutgoing: snap.outgoing,
                backlinks: snap.backlinks,
                headings: snap.headings,
                skippedOversizedCount: snap.skippedOversizedCount,
                roots: snap.roots,
                homeDocuments: homes
            )
            let result = vaultLintFindings(index: full, catalog: catalog)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.findings = result
                self.skippedOversizedCount = snap.skippedOversizedCount
                self.isRunning = false
                self.lastRun = Date()
                self.revision += 1
                if self.catalogCache?.files != files {
                    self.catalogCache = (files, catalog)
                }
                if self.catalogBuild?.id == catalogBuildID {
                    self.catalogBuild = nil
                }
                self.runTask = nil
                NotificationCenter.default.post(name: .vaultLintDidUpdate, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Vault-lint findings refreshed (Source should re-run lint merge).
    static let vaultLintDidUpdate = Notification.Name("editMD.vaultLintDidUpdate")
}
