import SwiftUI

/// Review navigator tab: the active file's smotr marks as
/// threads. **Preview is the primary surface** for selecting text and reading
/// washes; Source/Visual also feed the bridge but are secondary for review.
/// Create a mark from the current (or last non-empty) selection, reply,
/// resolve/reopen, accept/reject Claude's `suggest` edits.
struct ReviewSidebar: View {
    @ObservedObject var review: ReviewModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var agent = ReviewAgentRunner.shared
    @ObservedObject private var activity = AgentActivityModel.shared
    /// Bottom filter field text — matches note / quote substrings.
    var filter: String = ""
    /// Jump the editor caret to a markdown offset (reuses the outline plumbing).
    let onJump: (Int) -> Void

    @State private var composing = false
    @State private var composeType: ReviewMarkType = .comment
    @State private var composeNote = ""
    /// Selection snapshot taken when the form opened (nil = nothing was
    /// selected). Held so typing the note doesn't lose the anchor.
    @State private var pendingAnchor: ReviewModel.CapturedAnchor?

    private var filterQuery: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var marks: [ReviewMark] {
        let base = review.visibleMarks
        guard !filterQuery.isEmpty else { return base }
        return base.filter {
            ($0.note ?? "").localizedCaseInsensitiveContains(filterQuery)
                || ($0.quote ?? "").localizedCaseInsensitiveContains(filterQuery)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let status = queueBannerText {
                queueBanner(status)
            }
            if let hint = activity.nextStepHint {
                nextStepBanner(hint)
            }
            Divider()
            if composing { composeForm }
            content
        }
        .onChange(of: agent.state) { newState in
            switch newState {
            case .running:
                review.queueStatus = String(localized: "⏳ Claude is processing…")
            case .finished(let code):
                review.queueStatus = code == 0
                    ? String(localized: "Claude finished — marks updated")
                    : String(localized: "Claude exited with code \(Int(code))")
                review.reload()
            case .failed(let msg):
                review.queueStatus = String(localized: "Agent: \(msg)")
            case .idle:
                break
            }
        }
        .onAppear { openRequestedCompose() }
        .onChange(of: review.composeRequestID) { _ in openRequestedCompose() }
    }

    private var queueBannerText: String? {
        if let s = review.queueStatus, !s.isEmpty { return s }
        return nil
    }

    private func queueBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if agent.isRunning {
                ProgressView().controlSize(.small)
            }
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                review.queueStatus = nil
                agent.resetToIdle()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }

    private func nextStepBanner(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "paperplane")
                .font(.system(size: 10))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                AgentActivityModel.shared.clearNextStepHint()
                review.sendQueue(workspace: workspace)
            } label: {
                Text(String(localized: "Send"))
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            Button {
                AgentActivityModel.shared.clearNextStepHint()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            statusFilterMenu
            typeFilterMenu
            Spacer(minLength: 0)
            Button {
                AgentActivityModel.shared.clearNextStepHint()
                review.sendQueue(workspace: workspace)
            } label: {
                Image(systemName: agent.isRunning
                      ? "arrow.triangle.2.circlepath"
                      : "paperplane")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .foregroundStyle(agent.isRunning ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(agent.isRunning)
            .editMDHelp(EditorSettings.shared.general.claudeReviewAutoSpawn
                        ? String(localized: "Build the queue and launch Claude (claude -p \"/smotr -pr\")")
                        : String(localized: "Build the .smotr-queue.json queue and copy the command"))
            Button { toggleCompose() } label: {
                Image(systemName: composing ? "xmark" : "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .editMDHelp(String(localized: "Add a mark from the selection"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // Menus (with an explicit frame, no `.fixedSize()`) — the proven pattern in
    // this sidebar. A `.fixedSize()` Picker/Menu here sends NSHostingView into a
    // layout↔render cycle inside the animated sidebar column.
    private var statusFilterMenu: some View {
        Menu {
            ForEach(ReviewModel.StatusFilter.allCases, id: \.self) { f in
                Button { review.statusFilter = f } label: {
                    if review.statusFilter == f {
                        Label(f.label, systemImage: "checkmark")
                    } else {
                        Text(f.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(review.statusFilter.label)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 92, alignment: .leading)
    }

    private var typeFilterMenu: some View {
        Menu {
            Button("All Types") { review.typeFilter = nil }
            Divider()
            ForEach(ReviewMarkType.allCases.filter { $0 != .suggest }, id: \.self) { t in
                Button { review.typeFilter = t } label: {
                    Label(t.label, systemImage: t.glyph)
                }
            }
        } label: {
            Image(systemName: review.typeFilter?.glyph ?? "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(review.typeFilter == nil ? Color.secondary : Color.accentColor)
                .frame(width: 22, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .editMDHelp(String(localized: "Filter by type"))
    }

    // MARK: Compose

    @ViewBuilder private var composeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = pendingAnchor {
                ReviewQuoteLabel(quote: anchor.quote)

                Menu {
                    ForEach(ReviewMarkType.allCases.filter { $0 != .suggest }, id: \.self) { t in
                        Button { composeType = t } label: { Label(t.label, systemImage: t.glyph) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: composeType.glyph)
                        Text(composeType.label)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(height: 20)

                TextEditor(text: $composeNote)
                    .font(.system(size: 12))
                    .frame(height: 48)
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1))

                HStack {
                    Spacer()
                    Button("Cancel") { cancelCompose() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("Place") { saveCompose() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .font(.system(size: 11))
            } else {
                Label(String(localized: "Select a fragment in Preview (or Source/Visual), then press +."),
                      systemImage: "hand.point.up.left")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func toggleCompose() {
        if composing {
            cancelCompose()
        } else {
            beginCompose()
        }
    }

    private func openRequestedCompose() {
        guard review.consumeComposeRequest() else { return }
        beginCompose()
    }

    private func beginCompose() {
        let nextAnchor = review.captureSelectionAnchor()
        if Self.shouldResetComposeNote(previous: pendingAnchor, next: nextAnchor) {
            composeNote = ""
        }
        pendingAnchor = nextAnchor
        composing = true
    }

    static func shouldResetComposeNote(previous: ReviewModel.CapturedAnchor?,
                                       next: ReviewModel.CapturedAnchor?) -> Bool {
        previous != next
    }

    private func saveCompose() {
        guard let anchor = pendingAnchor else { return }
        review.addMark(anchor: anchor, type: composeType, note: composeNote)
        cancelCompose()
        AgentActivityModel.shared.noteMarkPlaced()
    }

    private func cancelCompose() {
        composing = false
        composeNote = ""
        pendingAnchor = nil
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        if review.fileURL == nil {
            placeholder(String(localized: "No active file"))
        } else if marks.isEmpty {
            if review.openCount == 0 && filterQuery.isEmpty {
                reviewOnboarding
            } else {
                placeholder(String(localized: "No marks match the filter"))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(marks, id: \.id) { mark in
                        MarkCard(
                            mark: mark,
                            hasAnchor: review.anchor(for: mark) != nil,
                            onJump: {
                                if let r = review.anchor(for: mark) { onJump(r.location) }
                            },
                            onReply: { review.reply(to: mark.id, text: $0) },
                            onResolve: { review.setStatus(mark.id, .resolved) },
                            onReopen: { review.setStatus(mark.id, .open) },
                            onDelete: { review.deleteMark(mark.id) },
                            onAccept: { review.acceptSuggestion(mark.id) },
                            onReject: { review.rejectSuggestion(mark.id) })
                    }
                }
                .padding(8)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.horizontal, 12)
    }

    /// Empty Review tab: three-step onboarding cycle.
    private var reviewOnboarding: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "Review cycle"))
                .font(.system(size: 12, weight: .semibold))
            onboardingStep(1, String(localized: "Select text in Preview or the editor"))
            onboardingStep(2, String(localized: "Press + to place a mark"))
            onboardingStep(3, String(localized: "Send the queue ✈️ to your agent"))
            Text(String(localized: "Or click ✨ in the toolbar for ready-made prompts."))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
        .padding(.horizontal, 12)
    }

    private func onboardingStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.accentColor.opacity(0.85)))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Quote excerpt

/// Two-line quote excerpt with the 2pt accent bar sized by the text. A bare
/// `Rectangle` sibling in an HStack is height-flexible: outside a ScrollView
/// (the compose form) it accepted the whole proposed height and blew the row
/// up to the full sidebar. The overlay is proposed exactly the text's size.
private struct ReviewQuoteLabel: View {
    let quote: String

    /// Multi-paragraph selections start with blank lines often enough that a
    /// two-line excerpt showed nothing — collapse runs of whitespace for
    /// display only (the mark keeps the verbatim quote).
    private var excerpt: String {
        quote.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var body: some View {
        Text(excerpt)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .multilineTextAlignment(.leading)
            .padding(.leading, 6)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
            }
    }
}

// MARK: - Mark card

private struct MarkCard: View {
    let mark: ReviewMark
    let hasAnchor: Bool
    let onJump: () -> Void
    let onReply: (String) -> Void
    let onResolve: () -> Void
    let onReopen: () -> Void
    let onDelete: () -> Void
    let onAccept: () -> Void
    let onReject: () -> Void

    @State private var replyText = ""
    @State private var replying = false

    private var type: ReviewMarkType? { mark.markType }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            if let quote = mark.quote, !quote.isEmpty { quoteRow(quote) }
            if mark.isSuggestion { suggestRow } else if let note = mark.note, !note.isEmpty {
                Text(note).font(.system(size: 12)).foregroundStyle(.primary)
            }
            thread
            actions
            if replying { replyBox }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .opacity(mark.isOpen ? 1 : 0.62)
    }

    private var headerRow: some View {
        HStack(spacing: 5) {
            Image(systemName: type?.glyph ?? "bubble.left")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(type?.label ?? mark.type)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            statusChip
        }
    }

    private var statusChip: some View {
        Text(statusLabel)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(statusColor.opacity(0.15)))
    }

    private func quoteRow(_ quote: String) -> some View {
        Button(action: onJump) {
            HStack(spacing: 4) {
                ReviewQuoteLabel(quote: quote)
                Spacer(minLength: 0)
                if !hasAnchor {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help(String(localized: "Fragment not found in the current text"))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasAnchor)
    }

    private var suggestRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let note = mark.note, !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let repl = mark.replacement {
                AIProposalReplacementView(text: repl)
            }
        }
    }

    @ViewBuilder private var thread: some View {
        if let thread = mark.thread, !thread.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(thread.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: entry.role == "claude" ? "sparkles" : "person")
                            .font(.system(size: 9))
                            .foregroundStyle(entry.role == "claude" ? Color.accentColor : .secondary)
                            .frame(width: 12)
                        Text(entry.text)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if mark.isSuggestion && mark.isOpen {
                AIProposalDecisionButtons(onAccept: onAccept, onDecline: onReject)
            } else {
                Button { replying.toggle() } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                if mark.isOpen {
                    actionButton(String(localized: "Resolve"), "checkmark.circle", .secondary, action: onResolve)
                } else {
                    actionButton(String(localized: "Reopen"), "arrow.counterclockwise", .secondary, action: onReopen)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Delete Mark", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.secondary)
    }

    private func actionButton(_ title: String, _ icon: String, _ color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(color)
    }

    private var replyBox: some View {
        HStack(spacing: 5) {
            TextField(String(localized: "Reply…"), text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(Color(nsColor: .textBackgroundColor)))
    }

    private func send() {
        onReply(replyText)
        replyText = ""
        replying = false
    }

    // MARK: Status styling

    private var statusLabel: String {
        switch ReviewMarkStatus(rawValue: mark.statusOrOpen) {
        case .open: return String(localized: "open")
        case .resolved: return String(localized: "resolved")
        case .wontfix: return String(localized: "declined")
        case .needsInfo: return String(localized: "needs reply")
        case .needsRebase: return String(localized: "drifted")
        case nil: return mark.statusOrOpen
        }
    }

    private var statusColor: Color {
        switch ReviewMarkStatus(rawValue: mark.statusOrOpen) {
        case .open: return .accentColor
        case .resolved: return .green
        case .wontfix: return .secondary
        case .needsInfo: return .orange
        case .needsRebase: return .red
        case nil: return .secondary
        }
    }
}
