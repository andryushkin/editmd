import Foundation
import Combine
import SwiftUI

// MARK: - Presence / presence channel (stage 1 + 2)

/// Agent presence reported by harness hooks / `editmdctl agent-status` (stage 2).
enum AgentHarnessStatus: String, Equatable, Sendable, CaseIterable {
    case idle
    case active
    case completed
    case blocked
}

/// Aggregated face of all AI surfaces (plan 09 stage 1).
@MainActor
final class AgentActivityModel: ObservableObject {
    static let shared = AgentActivityModel()

    // MARK: Observed sources (re-published)

    @Published private(set) var ideConnected = false
    @Published private(set) var ideListening = false
    @Published private(set) var ideClients = 0

    @Published private(set) var agentRunning = false
    @Published private(set) var agentStateLabel = ""
    @Published private(set) var agentLogTail = ""

    @Published private(set) var pendingDiffCount = 0
    @Published private(set) var pendingDiffTitle: String?

    @Published private(set) var openMarkCount = 0
    @Published private(set) var openSuggestionCount = 0

    /// External harness channel (stage 2); idle when unused.
    @Published private(set) var harnessStatus: AgentHarnessStatus = .idle
    @Published private(set) var harnessLabel: String?
    @Published private(set) var harnessName: String?
    @Published private(set) var harnessUpdatedAt: Date?

    /// Ephemeral toast (agent finished, reloaded from disk, …).
    @Published private(set) var toast: String?
    private var toastTask: Task<Void, Never>?

    /// After Place mark — “N open marks — send to Claude ✈️”.
    @Published var nextStepHint: String?

    /// New suggestions since last dismiss (badge + toast).
    @Published private(set) var suggestionBadge = 0

    private var cancellables = Set<AnyCancellable>()
    private var lastSuggestionIDs = Set<String>()
    private var bootstrapped = false

    private init() {
        bind()
    }

    // MARK: Derived UI state

    enum Presence: Equatable {
        case absent
        case available
        case working
        case needsAttention
    }

    var presence: Presence {
        if pendingDiffCount > 0 || harnessStatus == .blocked {
            return .needsAttention
        }
        if agentRunning || harnessStatus == .active {
            return .working
        }
        if ideConnected || ideListening || harnessStatus == .completed
            || (harnessName != nil && harnessStatus != .idle) {
            return .available
        }
        return .absent
    }

    var badgeCount: Int {
        pendingDiffCount + suggestionBadge
    }

    var sparklesTint: Color {
        switch presence {
        case .absent: return .secondary
        case .available: return Color.accentColor
        case .working: return Color.accentColor
        case .needsAttention: return .orange
        }
    }

    var isPulsing: Bool {
        presence == .working
    }

    // MARK: Prompt palette

    func promptContext(workspace: WorkspaceModel = .shared) -> AgentPromptContext {
        let active = ClaudeIDEBridge.shared.activeURL
        let root = ReviewModel.shared.queueRoot(workspace: workspace)
            ?? workspace.workspaces.first?.url
        if let root {
            return AgentPromptContext(
                activeFilePath: active?.path,
                workspaceRootPath: root.path,
                openMarkCount: openMarkCount,
                agentLaunchCommand: ReviewQueue.manualCommand(
                    for: root,
                    preset: EditorSettings.shared.general.agentCommandPreset,
                    custom: EditorSettings.shared.general.agentCustomCommand),
                ideConnected: ideConnected
            )
        }
        return AgentPromptContext(
            activeFilePath: active?.path,
            workspaceRootPath: nil,
            openMarkCount: openMarkCount,
            agentLaunchCommand: defaultAgentLaunchLine(),
            ideConnected: ideConnected
        )
    }

    func promptItems(workspace: WorkspaceModel = .shared) -> [AgentPromptItem] {
        buildAgentPromptItems(promptContext(workspace: workspace))
    }

    // MARK: Actions

    func showToast(_ message: String, duration: TimeInterval = 3.5) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if toast == message { toast = nil }
        }
    }

    func dismissToast() { toast = nil }

    func clearSuggestionBadge() { suggestionBadge = 0 }

    func noteMarkPlaced() {
        let n = ReviewModel.shared.openCount
        if n > 0 {
            nextStepHint = String(localized: "\(n) open mark(s) — send to Claude ✈️")
        } else {
            nextStepHint = nil
        }
    }

    func clearNextStepHint() {
        nextStepHint = nil
    }

    /// Stage 2 entry: harness reports status over control socket.
    func applyHarnessStatus(
        _ status: AgentHarnessStatus,
        label: String? = nil,
        harness: String? = nil
    ) {
        harnessStatus = status
        if let label { harnessLabel = label.isEmpty ? nil : label }
        if let harness { harnessName = harness.isEmpty ? nil : harness }
        harnessUpdatedAt = Date()
        if status == .completed {
            showToast(String(localized: "Agent finished"))
        }
        objectWillChange.send()
    }

    func stopAgent() {
        ReviewAgentRunner.shared.stop()
    }

    // MARK: Bindings

    private func bind() {
        let ide = ClaudeIDEService.shared
        let agent = ReviewAgentRunner.shared
        let diffs = DiffApprovalController.shared
        let review = ReviewModel.shared

        ide.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.applyIDE(state)
            }
            .store(in: &cancellables)

        agent.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.applyAgent(state)
            }
            .store(in: &cancellables)

        agent.$logTail
            .receive(on: RunLoop.main)
            .sink { [weak self] tail in
                self?.agentLogTail = tail
            }
            .store(in: &cancellables)

        diffs.$queue
            .receive(on: RunLoop.main)
            .sink { [weak self] queue in
                self?.pendingDiffCount = queue.count
                self?.pendingDiffTitle = queue.first.map {
                    "\($0.targetURL.lastPathComponent)"
                }
            }
            .store(in: &cancellables)

        // Review doc changes: open marks + new suggestions.
        review.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Defer to next runloop so doc is already updated.
                DispatchQueue.main.async { self?.refreshReviewDerived() }
            }
            .store(in: &cancellables)

        applyIDE(ide.state)
        applyAgent(agent.state)
        pendingDiffCount = diffs.queue.count
        pendingDiffTitle = diffs.current.map { $0.targetURL.lastPathComponent }
        refreshReviewDerived()
        bootstrapped = true
    }

    private func applyIDE(_ state: ClaudeIDEService.State) {
        switch state {
        case .connected(_, let clients):
            ideConnected = true
            ideListening = true
            ideClients = clients
        case .listening:
            ideConnected = false
            ideListening = true
            ideClients = 0
        default:
            ideConnected = false
            ideListening = false
            ideClients = 0
        }
    }

    private func applyAgent(_ state: ReviewAgentRunner.State) {
        switch state {
        case .idle:
            agentRunning = false
            agentStateLabel = ""
        case .running:
            agentRunning = true
            agentStateLabel = String(localized: "Processing review queue…")
        case .finished(let code):
            agentRunning = false
            agentStateLabel = code == 0
                ? String(localized: "Finished")
                : String(localized: "Exited \(Int(code))")
            // After finish, reload may add suggestions — refresh shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshReviewDerived(announceNewSuggestions: true)
            }
        case .failed(let msg):
            agentRunning = false
            agentStateLabel = msg
        }
    }

    private func refreshReviewDerived(announceNewSuggestions: Bool = false) {
        let review = ReviewModel.shared
        openMarkCount = review.openCount
        let suggests = review.doc.marks.filter { $0.isSuggestion && $0.isOpen }
        openSuggestionCount = suggests.count
        let ids = Set(suggests.map(\.id))
        if bootstrapped, announceNewSuggestions {
            let fresh = ids.subtracting(lastSuggestionIDs)
            if !fresh.isEmpty {
                suggestionBadge += fresh.count
                showToast(String(localized: "Claude finished — \(fresh.count) suggestion(s)"))
            }
        }
        lastSuggestionIDs = ids

        // Drop next-step hint when no open marks remain.
        if openMarkCount == 0 {
            nextStepHint = nil
        } else if nextStepHint != nil {
            nextStepHint = String(localized: "\(openMarkCount) open mark(s) — send to Claude ✈️")
        }
    }
}
