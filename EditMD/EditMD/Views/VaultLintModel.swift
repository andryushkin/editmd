import Foundation
import Combine
import SwiftUI

/// Runs vault-lint off-main whenever the link index finishes a scan / file update.
@MainActor
final class VaultLintModel: ObservableObject {
    static let shared = VaultLintModel()

    @Published private(set) var findings: [VaultLintFinding] = []
    @Published private(set) var skippedOversizedCount = 0
    @Published private(set) var isRunning = false
    @Published private(set) var lastRun: Date?
    /// Bumps when findings change so SwiftUI can rebind cheaply.
    @Published private(set) var revision = 0

    private var cancellables = Set<AnyCancellable>()
    private var runTask: Task<Void, Never>?
    private weak var index: LinkIndex?

    private init() {
        bind(to: LinkIndex.shared)
    }

    /// Test / alternate index injection.
    func bind(to index: LinkIndex) {
        cancellables.removeAll()
        self.index = index
        // Recompute when the published graph changes (full scan or single-file).
        index.$outgoing
            .combineLatest(index.$hasCompletedFullScan, index.$isScanning)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _, completed, scanning in
                guard let self else { return }
                if scanning { return }
                if completed || !index.outgoing.isEmpty {
                    self.scheduleRun()
                }
            }
            .store(in: &cancellables)
    }

    /// Manual re-run (report refresh button).
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

    func findings(for file: URL?) -> [VaultLintFinding] {
        guard let file else { return [] }
        let std = file.standardizedFileURL
        return findings.filter { $0.file.standardizedFileURL == std }
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
        runTask = Task.detached(priority: .utility) {
            // Home documents need a directory listing per root — do the disk
            // work here, not in `LinkIndex.snapshot()` on the main actor.
            let homes = Set(snap.roots.compactMap {
                homeDocument(in: $0)?.standardizedFileURL
            })
            let full = LinkIndexSnapshot(
                outgoing: snap.outgoing,
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
