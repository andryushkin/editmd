import SwiftUI
import AppKit

// MARK: - Toolbar ✨

/// Face of the AI system: sparkles in the toolbar + popover.
/// Mounted by `EditorToolbar` as a plain ToolbarItem.
struct AgentActivityButton: View {
    @ObservedObject private var activity = AgentActivityModel.shared
    @State private var showPopover = false

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(activity.sparklesTint)
                    .frame(width: 22, height: 22)
                    .modifier(OptionalPulse(isActive: activity.isPulsing))

                if activity.badgeCount > 0 {
                    Text(activity.badgeCount > 9 ? "9+" : "\(activity.badgeCount)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: 6, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(helpText)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            AgentActivityPopover(isPresented: $showPopover)
                .frame(width: 320)
        }
    }

    private var helpText: String {
        switch activity.presence {
        case .absent:
            return String(localized: "AI — no agent connected. Click for setup and prompts.")
        case .available:
            return String(localized: "AI — agent available")
        case .working:
            return String(localized: "AI — agent working")
        case .needsAttention:
            return String(localized: "AI — needs your decision")
        }
    }
}

private struct OptionalPulse: ViewModifier {
    let isActive: Bool
    func body(content: Content) -> some View {
        content.symbolEffect(.pulse, isActive: isActive)
    }
}

// MARK: - Popover

struct AgentActivityPopover: View {
    @Binding var isPresented: Bool
    @ObservedObject private var activity = AgentActivityModel.shared
    @ObservedObject private var ide = ClaudeIDEService.shared
    @ObservedObject private var agent = ReviewAgentRunner.shared
    @ObservedObject private var diffs = DiffApprovalController.shared
    @ObservedObject private var workspace = WorkspaceModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusSection
                    if activity.pendingDiffCount > 0 {
                        pendingDiffSection
                    }
                    if activity.openSuggestionCount > 0 {
                        suggestionsSection
                    }
                    if agent.isRunning {
                        stopSection
                    }
                    if !activity.agentLogTail.isEmpty {
                        logSection
                    }
                    promptsSection
                    actionsSection
                }
                .padding(12)
            }
            .frame(maxHeight: 420)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(activity.sparklesTint)
            Text(String(localized: "AI activity"))
                .font(.headline)
            Spacer()
            if activity.badgeCount > 0 {
                Text("\(activity.badgeCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange))
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Status"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(statusLine)
                .font(.system(size: 12))
            if let label = activity.harnessLabel ?? (activity.agentStateLabel.isEmpty ? nil : activity.agentStateLabel) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let harness = activity.harnessName {
                Text(String(localized: "Harness: \(harness)"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Last quiet auto-reload from disk.
            if let file = activity.lastDiskReloadFile,
               let at = activity.lastDiskReloadAt {
                Text(String(localized: "Reloaded from disk: \(file) · \(at.formatted(date: .omitted, time: .shortened))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusLine: String {
        if activity.pendingDiffCount > 0 {
            return String(localized: "Waiting for your decision on a proposed change")
        }
        if agent.isRunning {
            return String(localized: "Review agent is running")
        }
        if activity.harnessStatus == .active {
            return String(localized: "External agent is active")
        }
        if activity.harnessStatus == .blocked {
            return String(localized: "Agent is blocked — needs input")
        }
        switch ide.state {
        case .connected(_, let n):
            return n > 1
                ? String(localized: "Claude Code connected (\(n) clients)")
                : String(localized: "Claude Code connected")
        case .listening:
            return String(localized: "Claude Code listening — run /ide in a workspace")
        case .failed(let m):
            return String(localized: "IDE failed: \(m)")
        case .off:
            return String(localized: "No agent connected")
        case .starting:
            return String(localized: "Starting Claude Code integration…")
        }
    }

    private var pendingDiffSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Pending approval"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let diff = diffs.current {
                Button {
                    // Sheet is already presented by claudeDiffApproval host.
                    isPresented = false
                } label: {
                    Label(
                        String(localized: "Open diff: \(diff.targetURL.lastPathComponent)"),
                        systemImage: "doc.badge.ellipsis"
                    )
                    .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Suggestions"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(String(localized: "\(activity.openSuggestionCount) open suggestion(s) in Review"))
                .font(.system(size: 12))
            Button {
                activity.clearSuggestionBadge()
                // Same pair as ContentView.requestReviewMark(): the tab switch
                // alone is invisible while the inspector is hidden.
                UserDefaults.standard.set(true, forKey: "inspectorVisible")
                UserDefaults.standard.set("review", forKey: "inspectorTab")
                isPresented = false
            } label: {
                Text(String(localized: "Open Review tab"))
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
    }

    private var stopSection: some View {
        Button(role: .destructive) {
            activity.stopAgent()
        } label: {
            Label(String(localized: "Stop agent"), systemImage: "stop.fill")
                .font(.system(size: 12))
        }
        .buttonStyle(.borderless)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Agent log (tail)"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(activity.agentLogTail)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var promptsSection: some View {
        let items = activity.promptItems(workspace: workspace)
        return VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Ready-made prompts"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .medium))
                    Text(item.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button {
                        copy(item.command)
                    } label: {
                        Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }
        }
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(String(localized: "Setup"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Button {
                SkillInstaller.installWithUI()
            } label: {
                Label(String(localized: "Install Agent Skill…"), systemImage: "arrow.down.doc")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)

            Button {
                if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
                isPresented = false
            } label: {
                Label(String(localized: "Open Settings…"), systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        activity.showToast(String(localized: "Copied to clipboard"))
    }
}

// MARK: - Toast overlay

struct AgentToastOverlay: ViewModifier {
    @ObservedObject private var activity = AgentActivityModel.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = activity.toast {
                Text(toast)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                    .padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { activity.dismissToast() }
                    .animation(.easeInOut(duration: 0.18), value: activity.toast)
            }
        }
    }
}

extension View {
    func agentActivityToast() -> some View {
        modifier(AgentToastOverlay())
    }
}
