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
    /// 0…1 while a full run is in flight; nil when idle. Throttled to ~100
    /// updates per run (status-bar / report progress).
    @Published private(set) var runProgress: Double?
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
    private struct FileTaskEntry {
        let id: Int
        let task: Task<Void, Never>
    }
    private struct RevisionSnapshot {
        let indexRevision: Int
        let snapshot: LinkIndexSnapshot
        let files: [URL]
        let fileSetGeneration: Int
    }
    private var fileCache: [URL: FileCacheEntry] = [:]
    private var fileTasks: [URL: FileTaskEntry] = [:]
    private var nextFileTaskID = 0
    private var indexRevision = 0
    private var revisionSnapshot: RevisionSnapshot?
    private var nextFileSetGeneration = 0
    /// The catalog depends only on the set of indexed files, not link contents.
    /// Keep one completed or in-flight build so an index publication cannot
    /// fan out into one O(vault) build per tracked editor.
    private var catalogCache: (
        fileSetGeneration: Int, catalog: WikiRankCatalog
    )?
    private var catalogBuild: (
        id: Int, fileSetGeneration: Int, task: Task<WikiRankCatalog, Never>
    )?
    private var nextCatalogBuildID = 0
    private static let maxTrackedFiles = 32

    private init() {
        bind(to: LinkIndex.shared)
    }

    /// Test / alternate index injection.
    func bind(to index: LinkIndex) {
        cancelFullRun()
        for entry in fileTasks.values {
            entry.task.cancel()
        }
        fileTasks = [:]
        catalogBuild?.task.cancel()
        catalogBuild = nil
        cancellables.removeAll()
        self.index = index
        indexRevision += 1
        fileCache = [:]
        revisionSnapshot = nil
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

    /// Snapshot and sorted file list are O(vault), so compute them at most once
    /// per published index revision. The separate file-set generation changes
    /// only when files are added/removed and gives catalog lookup an O(1) key.
    private func currentRevisionSnapshot(
        for index: LinkIndex,
        refresh: Bool = false
    ) -> RevisionSnapshot {
        if !refresh, let cached = revisionSnapshot,
           cached.indexRevision == indexRevision {
            return cached
        }
        let snap = index.snapshot()
        let files = snap.allFiles
        let fileSetGeneration: Int
        if let previous = revisionSnapshot, previous.files == files {
            fileSetGeneration = previous.fileSetGeneration
        } else {
            nextFileSetGeneration += 1
            fileSetGeneration = nextFileSetGeneration
        }
        let value = RevisionSnapshot(
            indexRevision: indexRevision,
            snapshot: snap,
            files: files,
            fileSetGeneration: fileSetGeneration
        )
        revisionSnapshot = value
        return value
    }

    private func catalogSource(for state: RevisionSnapshot) -> CatalogSource {
        if let cached = catalogCache,
           cached.fileSetGeneration == state.fileSetGeneration {
            return .ready(cached.catalog)
        }
        if let build = catalogBuild,
           build.fileSetGeneration == state.fileSetGeneration {
            return .building(id: build.id, task: build.task)
        }
        nextCatalogBuildID += 1
        let id = nextCatalogBuildID
        let files = state.files
        let task = Task.detached(priority: .utility) {
            vaultLintCatalog(files: files)
        }
        catalogBuild = (id, state.fileSetGeneration, task)
        return .building(id: id, task: task)
    }

    private func scheduleFileRuns<S: Sequence>(_ urls: S) where S.Element == URL {
        guard let index else { return }
        let pending = urls.filter { fileTasks[$0] == nil }
        guard !pending.isEmpty else { return }
        let revision = indexRevision
        let state = currentRevisionSnapshot(for: index)
        let snap = state.snapshot
        let fileSetGeneration = state.fileSetGeneration
        let catalogSource = catalogSource(for: state)
        for std in pending {
            nextFileTaskID += 1
            let fileTaskID = nextFileTaskID
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
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self?.clearFileTask(for: std, id: fileTaskID)
                    }
                    return
                }
                let result = vaultLintFindings(
                    for: std, index: snap, catalog: catalog)
                await MainActor.run {
                    guard let self else { return }
                    guard self.fileTasks[std]?.id == fileTaskID else { return }
                    self.fileTasks[std] = nil
                    guard !Task.isCancelled else { return }
                    guard revision == self.indexRevision else {
                        // The graph moved while we ran — redo against the new one.
                        self.scheduleFileRun(std)
                        return
                    }
                    if self.catalogCache?.fileSetGeneration != fileSetGeneration {
                        self.catalogCache = (fileSetGeneration, catalog)
                    }
                    if self.catalogBuild?.id == catalogBuildID {
                        self.catalogBuild = nil
                    }
                    let previous = self.fileCache[std]?.findings
                    self.fileCache[std] = FileCacheEntry(
                        revision: revision, findings: result, lastAccess: Date())
                    self.evictStaleTrackedFiles()
                    if (previous ?? []) != result {
                        NotificationCenter.default.post(
                            name: .vaultLintDidUpdate, object: nil)
                    }
                }
            }
            fileTasks[std] = FileTaskEntry(id: fileTaskID, task: task)
        }
    }

    private func clearFileTask(for file: URL, id: Int) {
        guard fileTasks[file]?.id == id else { return }
        fileTasks[file] = nil
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
        runProgress = nil
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
        runProgress = 0
        let state = currentRevisionSnapshot(for: index, refresh: force)
        let snap = state.snapshot
        let fileSetGeneration = state.fileSetGeneration
        let catalogSource = catalogSource(for: state)
        let publishProgress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.runProgress = fraction
            }
        }
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
            let result = vaultLintFindings(
                index: full, catalog: catalog,
                onProgress: { done, total in
                    guard total > 0 else { return }
                    publishProgress(Double(done) / Double(total))
                })
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.findings = result
                self.skippedOversizedCount = snap.skippedOversizedCount
                self.isRunning = false
                self.runProgress = nil
                self.lastRun = Date()
                self.revision += 1
                if self.catalogCache?.fileSetGeneration != fileSetGeneration {
                    self.catalogCache = (fileSetGeneration, catalog)
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
