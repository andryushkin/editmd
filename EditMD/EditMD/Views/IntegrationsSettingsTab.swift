import SwiftUI
import AppKit

/// Settings ▸ Integrations — one home for AI surfaces (plan 09 stage 4).
struct IntegrationsSettingsTab: View {
    @ObservedObject var settings: EditorSettings
    @ObservedObject private var control = ControlService.shared
    @ObservedObject private var ide = ClaudeIDEService.shared
    @ObservedObject private var activity = AgentActivityModel.shared

    @State private var statusNote: String?

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
                    ok: SkillInstaller.isInstalled(at: SkillInstaller.claudeDestination()),
                    detail: SkillInstaller.claudeDestination().path
                )
                statusRow(
                    title: String(localized: "Agent skill (Codex)"),
                    ok: SkillInstaller.isInstalled(at: SkillInstaller.codexDestination()),
                    detail: SkillInstaller.codexDestination().path
                )
                statusRow(
                    title: String(localized: "Status hooks"),
                    ok: AgentHooksInstaller.isInstalled(),
                    detail: AgentHooksInstaller.installDirectory().path
                )
                statusRow(
                    title: String(localized: "editmdctl on PATH"),
                    ok: EditMDCtlInstaller.isLinked()
                        || resolveEditmdctlOnPath() != nil,
                    detail: EditMDCtlInstaller.isLinked()
                        ? EditMDCtlInstaller.linkPath
                        : (resolveEditmdctlOnPath() ?? String(localized: "not found"))
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
                    statusNote = String(localized: "Skill install finished")
                }
                Button(String(localized: "Install Status Hooks…")) {
                    installHooks()
                }
                Button(String(localized: "Install Command Line Tool…")) {
                    EditMDCtlInstaller.installWithUI()
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
    }

    private var ideStatusDetail: String {
        switch ide.state {
        case .off: return String(localized: "off")
        case .starting: return String(localized: "starting")
        case .listening(let s): return String(localized: "listening :\(s.port)")
        case .connected(let s, let n): return String(localized: "connected :\(s.port) · \(n)")
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
                ?? resolveEditmdctlOnPath()
            let dest = try AgentHooksInstaller.installPackage(editmdctlPath: ctl)
            try? AgentHooksInstaller.mergeClaudeHooks()
            statusNote = String(localized: "Hooks installed to \(dest.path)")
        } catch {
            statusNote = String(localized: "Hooks install failed: \(error.localizedDescription)")
        }
    }

    private func resolveEditmdctlOnPath() -> String? {
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
