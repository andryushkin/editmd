import SwiftUI

/// Shared visual language for AI proposals (openDiff + review suggests) — plan 09 stage 5.
enum AIProposalChrome {
    static let acceptTitle = String(localized: "Accept")
    static let declineTitle = String(localized: "Decline")
    static let acceptColor = Color.green
    static let declineColor = Color.secondary
    static let replacementFill = Color.green.opacity(0.14)

    /// Status labels used in both openDiff residual UI and review cards.
    static func statusLabel(accepted: Bool?, declined: Bool?, drifted: Bool) -> String {
        if drifted { return String(localized: "Drifted") }
        if accepted == true { return String(localized: "Accepted") }
        if declined == true { return String(localized: "Declined") }
        return String(localized: "Pending")
    }
}

/// Compact Accept / Decline pair shared by Review suggest cards.
struct AIProposalDecisionButtons: View {
    var onAccept: () -> Void
    var onDecline: () -> Void
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onAccept) {
                Label(AIProposalChrome.acceptTitle, systemImage: "checkmark")
                    .font(.system(size: compact ? 11 : 12, weight: .semibold))
                    .foregroundStyle(AIProposalChrome.acceptColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)

            Button(action: onDecline) {
                Label(AIProposalChrome.declineTitle, systemImage: "xmark")
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .foregroundStyle(AIProposalChrome.declineColor)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }
}

/// Highlighted replacement text block (suggest cards).
struct AIProposalReplacementView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(AIProposalChrome.replacementFill))
    }
}
