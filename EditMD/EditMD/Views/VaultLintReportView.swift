import SwiftUI
import AppKit

/// Workspace-wide vault-lint report (plan 06). Opened from View menu / Info.
struct VaultLintReportView: View {
    @ObservedObject var model: VaultLintModel
    var onOpen: (URL, Int?) -> Void
    var onClose: () -> Void

    private var grouped: [(URL, [VaultLintFinding])] {
        var map: [URL: [VaultLintFinding]] = [:]
        for f in model.findings {
            map[f.file.standardizedFileURL, default: []].append(f)
        }
        return map.keys.sorted { $0.path < $1.path }.map { ($0, map[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.findings.isEmpty && !model.isRunning {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 520)
        .onAppear {
            LinkIndex.shared.ensureIndex()
            model.runNow()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Workspace link check")
                    .font(.headline)
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Refresh") {
                LinkIndex.shared.ensureIndex()
                model.runNow()
            }
            .disabled(model.isRunning)
        }
        .padding(12)
    }

    private var summaryLine: String {
        var parts: [String] = []
        parts.append(String(localized: "\(model.errorCount) errors"))
        parts.append(String(localized: "\(model.warningCount) warnings"))
        if model.skippedOversizedCount > 0 {
            parts.append(String(localized: "files skipped: \(model.skippedOversizedCount)"))
        }
        if let last = model.lastRun {
            let f = DateFormatter()
            f.timeStyle = .short
            f.dateStyle = .none
            parts.append(String(localized: "at \(f.string(from: last))"))
        }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No problems found")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("A workspace with a link index is required")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.0.path) { file, items in
                Section(file.lastPathComponent) {
                    ForEach(items) { finding in
                        Button {
                            onOpen(finding.file, finding.utf16Offset)
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: finding.severity))
                                    .foregroundStyle(color(for: finding.severity))
                                    .font(.system(size: 12))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(finding.message)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    HStack(spacing: 6) {
                                        Text(finding.rule.rawValue)
                                        if let line = finding.line {
                                            Text("line \(line)")
                                        }
                                        if let sug = finding.targetSuggestion {
                                            Text("→ \(sug.lastPathComponent)")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.skippedOversizedCount > 0 {
                Section {
                    Text("Files skipped (>4 MB): \(model.skippedOversizedCount)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text("Report only — no automatic fixes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
    }

    private func icon(for s: VaultLintSeverity) -> String {
        switch s {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }

    private func color(for s: VaultLintSeverity) -> Color {
        switch s {
        case .error: return .red
        case .warning: return .orange
        case .info: return .secondary
        }
    }
}

// MARK: - Host window

@MainActor
enum VaultLintReportPresenter {
    private static var panel: NSPanel?

    static func present() {
        if let existing = panel, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let root = VaultLintReportView(
            model: VaultLintModel.shared,
            onOpen: { url, offset in
                if let offset {
                    AppState.shared.requestControlJump(url: url, offset: offset)
                }
                AppState.shared.openInMainWindow(url)
            },
            onClose: { dismiss() }
        )
        let hosting = NSHostingController(rootView: root)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Workspace link check")
        panel.contentViewController = hosting
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }
}
