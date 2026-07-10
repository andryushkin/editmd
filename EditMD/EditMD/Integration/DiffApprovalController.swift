import Foundation
import SwiftUI

// `openDiff` — the only blocking tool in the IDE protocol (v36).
//
// Claude calls it and stops; EditMD shows the diff; the user's click decides
// the answer. Two hard rules live here:
//
//  1. **Every continuation resolves exactly once.** Accept, Reject, sheet
//     dismissal, client disconnect, `close_tab`, a timeout, and a second
//     `openDiff` for the same tab all funnel through `resolve`, which removes
//     the continuation before resuming it. A leaked continuation would hang
//     Claude forever; a double-resume would trap.
//
//  2. **Accept writes through `DocumentRegistry`.** A raw `write(to:)` bypasses
//     `knownModDate` + watch re-arm, so our own write comes back as an
//     "external change" conflict chip (v34 invariant).

@MainActor
final class DiffApprovalController: ObservableObject {

    static let shared = DiffApprovalController()

    /// A diff waiting for the user. `tabName` is the protocol-level identity —
    /// `close_tab` addresses it by that name.
    struct PendingDiff: Identifiable, Equatable {
        var id: String { tabName }
        let tabName: String
        let targetURL: URL
        /// Text the diff is computed against: the open buffer when the file is
        /// open (even unsaved), otherwise the bytes on disk.
        let before: String
        let after: String
        /// The buffer had unsaved edits — accepting overwrites them.
        let bufferIsDirty: Bool
        /// The file does not exist yet (Claude is creating it).
        let isNewFile: Bool
    }

    /// Abandoned diffs shouldn't wedge Claude forever if the user walks away.
    /// Settable so tests don't have to wait ten minutes.
    var timeout: Duration = .seconds(600)

    /// Oldest first; the sheet shows `current`.
    @Published private(set) var queue: [PendingDiff] = []

    var current: PendingDiff? { queue.first }
    var hasPending: Bool { !queue.isEmpty }

    private var continuations: [String: CheckedContinuation<DiffOutcome, Never>] = [:]
    private var timeouts: [String: Task<Void, Never>] = [:]

    /// Suspends until the user (or a lifecycle event) answers. A repeat call
    /// for the same `tabName` rejects the previous diff and replaces it.
    func present(_ diff: PendingDiff) async -> DiffOutcome {
        await withCheckedContinuation { continuation in
            if continuations[diff.tabName] != nil {
                claudeIDELog.notice("openDiff replaced pending tab \(diff.tabName, privacy: .public)")
                resolve(diff.tabName, .rejected)
            }
            queue.append(diff)
            continuations[diff.tabName] = continuation
            let limit = timeout
            timeouts[diff.tabName] = Task { [weak self] in
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled else { return }
                claudeIDELog.notice("openDiff timed out: \(diff.tabName, privacy: .public)")
                self?.resolve(diff.tabName, .rejected)
            }
        }
    }

    // MARK: User actions

    /// Writes `after` through the registry, then answers `FILE_SAVED`.
    /// A failed write answers `DIFF_REJECTED` — Claude must not believe the
    /// file changed when it didn't.
    func accept(_ tabName: String) {
        guard let diff = queue.first(where: { $0.tabName == tabName }) else { return }
        do {
            try DocumentRegistry.shared.applyAgentEdit(diff.targetURL, content: diff.after)
            resolve(tabName, .accepted)
        } catch {
            claudeIDELog.error("openDiff accept failed to write: \(String(describing: error), privacy: .public)")
            resolve(tabName, .rejected)
        }
    }

    func reject(_ tabName: String) {
        resolve(tabName, .rejected)
    }

    // MARK: Protocol / lifecycle paths

    /// `close_tab`. Returns whether a diff by that name was open.
    @discardableResult
    func closeTab(named tabName: String) -> Bool {
        let existed = continuations[tabName] != nil
        resolve(tabName, .rejected)
        return existed
    }

    /// `closeAllDiffTabs`. Returns how many were open.
    @discardableResult
    func closeAllTabs() -> Int {
        let names = Array(continuations.keys)
        for name in names { resolve(name, .rejected) }
        return names.count
    }

    /// Client disconnected or the server stopped: nobody is listening for the
    /// answer, but the continuation still has to be released.
    func rejectAll(reason: String) {
        guard !continuations.isEmpty else { return }
        claudeIDELog.notice("Rejecting \(self.continuations.count, privacy: .public) pending diff(s): \(reason, privacy: .public)")
        _ = closeAllTabs()
    }

    // MARK: Single-resolution core

    private func resolve(_ tabName: String, _ outcome: DiffOutcome) {
        timeouts.removeValue(forKey: tabName)?.cancel()
        queue.removeAll { $0.tabName == tabName }
        // `removeValue` is the exactly-once gate: a second path finds nothing.
        guard let continuation = continuations.removeValue(forKey: tabName) else { return }
        continuation.resume(returning: outcome)
    }
}
