import SwiftUI

// UI surface of the Claude Code IDE channel: the blocking diff sheet and the
// status-bar connection chip. Both are thin — the decisions live in
// `DiffApprovalController` and `ClaudeIDEService`.

// MARK: - openDiff sheet

/// Hosts the pending-diff sheet on the main window. Attached once, in
/// `MainWindowView`: a diff may target a file that is not the one on screen,
/// so it cannot hang off the per-file editor view.
private struct ClaudeDiffApprovalHost: ViewModifier {
    @ObservedObject private var controller = DiffApprovalController.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: presenting) {
            if let diff = controller.current {
                UnifiedDiffSheet(
                    content: sheetContent(for: diff),
                    approval: DiffApprovalActions(
                        onAccept: { controller.accept(diff.tabName) },
                        onReject: { controller.reject(diff.tabName) }
                    )
                )
            }
        }
    }

    /// Dismissing the sheet any other way (Esc, window close) counts as a
    /// reject — Claude must never be left waiting.
    private var presenting: Binding<Bool> {
        Binding(
            get: { controller.current != nil },
            set: { shown in
                guard !shown, let diff = controller.current else { return }
                controller.reject(diff.tabName)
            }
        )
    }

    private func sheetContent(for diff: DiffApprovalController.PendingDiff) -> DiffSheetContent {
        let warning: String?
        if diff.isNewFile {
            warning = String(localized: "New file — it will be created on accept")
        } else if diff.bufferIsDirty {
            warning = String(localized: "The buffer has unsaved edits — accepting will overwrite them")
        } else {
            warning = nil
        }
        return DiffSheetContent(
            title: String(localized: "Claude proposes a change: \(diff.tabName)"),
            fileName: diff.targetURL.lastPathComponent,
            sideLabel: "current → Claude",
            before: diff.before,
            after: diff.after,
            warning: warning
        )
    }
}

extension View {
    /// Shows Claude's pending `openDiff` for approval. Attach once per app.
    func claudeDiffApproval() -> some View {
        modifier(ClaudeDiffApprovalHost())
    }
}

// MARK: - Status-bar chip

/// Grey while the server is merely listening, accent once a `claude` process
/// attached via `/ide`. Hidden when the integration is off.
struct ClaudeIDEChip: View {
    @ObservedObject private var service = ClaudeIDEService.shared

    var body: some View {
        switch service.state {
        case .off, .starting:
            EmptyView()
        case .failed(let message):
            chip(symbol: "exclamationmark.triangle.fill",
                 tint: .orange,
                 help: "Claude Code integration failed: \(message)")
        case .listening(let session):
            chip(symbol: "sparkles",
                 tint: .secondary,
                 help: "Claude Code: listening on 127.0.0.1:\(session.port). "
                     + "Run `claude` in a workspace folder and type /ide.")
        case .connected(let session, let clients):
            chip(symbol: "sparkles",
                 tint: Color.accentColor,
                 help: clients > 1
                     ? "Claude Code: \(clients) clients on 127.0.0.1:\(session.port)"
                     : "Claude Code: connected on 127.0.0.1:\(session.port)")
        }
    }

    private func chip(symbol: String, tint: Color, help: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .help(help)
    }
}
