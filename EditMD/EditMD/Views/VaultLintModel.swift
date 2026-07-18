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
    var reportActive = false

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
    /// Suggestion catalog shared by per-file runs against one index revision.
    private var catalogCache: (revision: Int, catalog: WikiRankCatalog)?
    private static let maxTrackedFiles = 32

    private init() {
        bind(to: LinkIndex.shared)
    }

    /// Test / alternate index injection.
    func bind(to index: LinkIndex) {
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
        for url in fileCache.keys where fileCache[url]?.revision != indexRevision {
            scheduleFileRun(url)
        }
    }

    private func scheduleFileRun(_ std: URL) {
        guard let index, fileTasks[std] == nil else { return }
        let revision = indexRevision
        let snap = index.snapshot()
        let sharedCatalog = catalogCache?.revision == revision
            ? catalogCache?.catalog : nil
        let task = Task.detached(priority: .utility) { [weak self] in
            let catalog = sharedCatalog ?? vaultLintCatalog(files: snap.allFiles)
            let result = vaultLintFindings(for: std, index: snap, catalog: catalog)
            await MainActor.run {
                guard let self else { return }
                self.fileTasks[std] = nil
                guard revision == self.indexRevision else {
                    // The graph moved while we ran — redo against the new one.
                    self.scheduleFileRun(std)
                    return
                }
                if self.catalogCache?.revision != revision {
                    self.catalogCache = (revision, catalog)
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

    private func evictStaleTrackedFiles() {
        while fileCache.count > Self.maxTrackedFiles {
            guard let oldest = fileCache.min(by: {
                $0.value.lastAccess < $1.value.lastAccess
            }) else { return }
            fileCache.removeValue(forKey: oldest.key)
        }
    }

    // MARK: - Full run (report panel)

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
        runTask = Task.detached(priority: .utility) {
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
            let result = vaultLintFindings(index: full)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.findings = result
                self.skippedOversizedCount = snap.skippedOversizedCount
                self.isRunning = false
                self.lastRun = Date()
                self.revision += 1
                NotificationCenter.default.post(name: .vaultLintDidUpdate, object: nil)
            }
        }
    }
}

extension Notification.Name {
    /// Vault-lint findings refreshed (Source should re-run lint merge).
    static let vaultLintDidUpdate = Notification.Name("editMD.vaultLintDidUpdate")
}
