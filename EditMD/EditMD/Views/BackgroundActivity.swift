import SwiftUI

/// Status-bar chip for workspace background work: the LinkIndex full scan
/// (parse + resolve) and the vault-lint full run. Renders nothing when idle,
/// so hosts can embed it unconditionally.
struct BackgroundActivityChip: View {
    @ObservedObject private var linkIndex = LinkIndex.shared
    @ObservedObject private var vaultLint = VaultLintModel.shared

    var body: some View {
        if linkIndex.isScanning {
            chip(
                label: String(localized: "Indexing links…"),
                progress: linkIndex.scanProgress,
                help: String(localized: "Building the workspace link graph (backlinks, completion, link check)")
            )
        } else if vaultLint.isRunning {
            chip(
                label: String(localized: "Checking workspace…"),
                progress: vaultLint.runProgress,
                help: String(localized: "Linting workspace links (report panel)")
            )
        }
    }

    private func chip(label: String, progress: Double?, help: String) -> some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.mini)
            Text(progressText(label: label, progress: progress))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .editMDHelp(help)
    }

    private func progressText(label: String, progress: Double?) -> String {
        guard let progress else { return label }
        let percent = Int((progress * 100).rounded())
        return "\(label) \(min(percent, 100))%"
    }
}

/// Thin bottom bar for window panes that have no editor status bar (welcome,
/// PDF / image viewer, folder card). Appears only while background work runs —
/// idle panes keep their full height.
struct StandaloneActivityBar: View {
    @ObservedObject private var linkIndex = LinkIndex.shared
    @ObservedObject private var vaultLint = VaultLintModel.shared

    var body: some View {
        if linkIndex.isScanning || vaultLint.isRunning {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    BackgroundActivityChip()
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
        }
    }
}
