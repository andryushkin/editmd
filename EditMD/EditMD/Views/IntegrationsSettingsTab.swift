import SwiftUI
import AppKit

/// Settings ▸ Integrations — one home for AI surfaces (plan 09 stage 4).
struct IntegrationsSettingsTab: View {
    @ObservedObject var settings: EditorSettings
    @ObservedObject private var control = ControlService.shared
    @ObservedObject private var ide = ClaudeIDEService.shared
    @ObservedObject private var activity = AgentActivityModel.shared

    @State private var statusNote: String?
    /// Disk-derived install states, refreshed off-main (CLAUDE.md: no sync
    /// disk I/O from a SwiftUI body) on appear and after each install action.
    @State private var disk = DiskStatusSnapshot()

    /// One pass of every file-system check the Status section shows.
    struct DiskStatusSnapshot: Equatable, Sendable {
        var skillClaude = false
        var skillCodex = false
        var hooks = false
        var ctlLinked = false
        var ctlOnPath: String?
    }

    var body: some View {
        Form {
            Section("Status") {
                statusRow(
                    title: String(localized: "Control socket"),
                    ok: control.isListening,
                    detail: control.socketPath.path
                )
                statusRow(
                    title: String(localized: "Claude Code IDE"),
                    ok: ide.isConnected || {
                        if case .listening = ide.state { return true }
                        return false
                    }(),
                    detail: ideStatusDetail
                )
                statusRow(
                    title: String(localized: "Agent skill (Claude)"),
                    ok: disk.skillClaude,
                    detail: SkillInstaller.claudeDestination().path
                )
                statusRow(
                    title: String(localized: "Agent skill (Codex)"),
                    ok: disk.skillCodex,
                    detail: SkillInstaller.codexDestination().path
                )
                statusRow(
                    title: String(localized: "Status hooks"),
                    ok: disk.hooks,
                    detail: AgentHooksInstaller.installDirectory().path
                )
                statusRow(
                    title: String(localized: "editmdctl on PATH"),
                    ok: disk.ctlLinked || disk.ctlOnPath != nil,
                    detail: disk.ctlLinked
                        ? EditMDCtlInstaller.linkPath
                        : (disk.ctlOnPath ?? String(localized: "not found"))
                )
                if let statusNote {
                    Text(statusNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Install") {
                Button(String(localized: "Install / Update Agent Skill…")) {
                    SkillInstaller.installWithUI()
                    refreshDiskStatus()
                }
                Button(String(localized: "Install Status Hooks…")) {
                    installHooks()
                    refreshDiskStatus()
                }
                Button(String(localized: "Install Command Line Tool…")) {
                    EditMDCtlInstaller.installWithUI()
                    refreshDiskStatus()
                }
                Text(String(localized: "Installers are idempotent and merge carefully — they do not wipe foreign hooks or skills."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude Code") {
                Toggle(String(localized: "Claude Code integration"),
                       isOn: $settings.general.claudeIDEEnabled)
                Text(String(localized: "Local /ide server for live selection and openDiff."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Review agent (✈️)") {
                Toggle(String(localized: "Auto-run agent for Review queue"),
                       isOn: $settings.general.claudeReviewAutoSpawn)
                Picker(String(localized: "Command preset"),
                       selection: $settings.general.agentCommandPreset) {
                    ForEach(AgentCommandPreset.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                if settings.general.agentCommandPreset == .custom {
                    TextField(String(localized: "Custom command"),
                             text: $settings.general.agentCustomCommand)
                    Text(String(localized: "Shell-split argv. EDITMD_AGENT_CMD still overrides for tests."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(String(localized: "Spawn injects EDITMD_ENABLED, EDITMD_SOCKET, EDITMD_WORKSPACE, EDITMD_QUEUE."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("External files") {
                Toggle(String(localized: "Auto-reload clean buffer when disk changes"),
                       isOn: $settings.general.autoReloadCleanExternal)
                Text(String(localized: "When the buffer has no unsaved edits, silently reload and show a short toast. Dirty buffers still show the conflict chip."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Live harness") {
                Text(String(localized: "Last agent-status: \(activity.harnessStatus.rawValue)"))
                if let h = activity.harnessName {
                    Text(String(localized: "Harness: \(h)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let label = activity.harnessLabel {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDiskStatus() }
    }

    private func refreshDiskStatus() {
        Task.detached(priority: .userInitiated) {
            let snapshot = DiskStatusSnapshot(
                skillClaude: SkillInstaller.isInstalled(at: SkillInstaller.claudeDestination()),
                skillCodex: SkillInstaller.isInstalled(at: SkillInstaller.codexDestination()),
                hooks: AgentHooksInstaller.isInstalled(),
                ctlLinked: EditMDCtlInstaller.isLinked(),
                ctlOnPath: Self.resolveEditmdctlOnPath()
            )
            await MainActor.run { disk = snapshot }
        }
    }

    private var ideStatusDetail: String {
        switch ide.state {
        case .off: return String(localized: "off")
        case .starting: return String(localized: "starting")
        // UInt16 interpolation extracts as a different specifier than %lld —
        // cast to Int so the catalog key stays the predictable "%lld" form.
        case .listening(let s): return String(localized: "listening :\(Int(s.port))")
        case .connected(let s, let n): return String(localized: "connected :\(Int(s.port)) · \(Int(n))")
        case .failed(let m): return m
        }
    }

    private func statusRow(title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func installHooks() {
        do {
            let ctl = EditMDCtlInstaller.bundledBinaryURL()?.path
                ?? Self.resolveEditmdctlOnPath()
            let dest = try AgentHooksInstaller.installPackage(editmdctlPath: ctl)
            try? AgentHooksInstaller.mergeClaudeHooks()
            statusNote = String(localized: "Hooks installed to \(dest.path)")
        } catch {
            statusNote = String(localized: "Hooks install failed: \(error.localizedDescription)")
        }
    }

    nonisolated private static func resolveEditmdctlOnPath() -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let home = NSHomeDirectory()
        let dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + path.split(separator: ":").map(String.init)
        for d in dirs {
            let c = URL(fileURLWithPath: d).appendingPathComponent("editmdctl")
            if FileManager.default.isExecutableFile(atPath: c.path) { return c.path }
        }
        return nil
    }
}
