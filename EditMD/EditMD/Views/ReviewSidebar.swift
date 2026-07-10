import SwiftUI

/// Review navigator tab (phase 2, v37): the active file's smotr marks as
/// threads. **Preview is the primary surface** for selecting text and reading
/// washes; Source/Visual also feed the bridge but are secondary for review.
/// Create a mark from the current (or last non-empty) selection, reply,
/// resolve/reopen, accept/reject Claude's `suggest` edits.
struct ReviewSidebar: View {
    @ObservedObject var review: ReviewModel
    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var agent = ReviewAgentRunner.shared
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
            Divider()
            if composing { composeForm }
            content
        }
        .onChange(of: agent.state) { newState in
            switch newState {
            case .running:
                review.queueStatus = "⏳ Claude обрабатывает…"
            case .finished(let code):
                review.queueStatus = code == 0
                    ? "Claude закончил — метки обновлены"
                    : "Claude завершился с кодом \(code)"
                review.reload()
            case .failed(let msg):
                review.queueStatus = "Агент: \(msg)"
            case .idle:
                break
            }
        }
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

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            statusFilterMenu
            typeFilterMenu
            Spacer(minLength: 0)
            Button {
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
                        ? "Собрать очередь и запустить Claude (claude -p \"/smotr -pr\")"
                        : "Собрать очередь .smotr-queue.json и скопировать команду")
            Button { toggleCompose() } label: {
                Image(systemName: composing ? "xmark" : "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .editMDHelp("Добавить метку из выделения")
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
            Button("Все типы") { review.typeFilter = nil }
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
        .editMDHelp("Фильтр по типу")
    }

    // MARK: Compose

    @ViewBuilder private var composeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let anchor = pendingAnchor {
                HStack(spacing: 4) {
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
                    Text(anchor.quote)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

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
                    Button("Отмена") { cancelCompose() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    Button("Поставить") { saveCompose() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .font(.system(size: 11))
            } else {
                Label("В Preview (или Source/Visual) выдели фрагмент, затем нажми +.",
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
            pendingAnchor = review.captureSelectionAnchor()
            composing = true
        }
    }

    private func saveCompose() {
        guard let anchor = pendingAnchor else { return }
        review.addMark(anchor: anchor, type: composeType, note: composeNote)
        cancelCompose()
    }

    private func cancelCompose() {
        composing = false
        composeNote = ""
        pendingAnchor = nil
    }

    // MARK: List

    @ViewBuilder private var content: some View {
        if review.fileURL == nil {
            placeholder("Нет активного файла")
        } else if marks.isEmpty {
            placeholder(review.openCount == 0
                        ? "Меток нет.\nВыдели текст и нажми +"
                        : "Нет меток под фильтром")
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
                Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 2)
                Text(quote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !hasAnchor {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Фрагмент не найден в текущем тексте")
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
                Text(repl)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.green.opacity(0.14)))
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
                actionButton("Принять", "checkmark", .green, action: onAccept)
                actionButton("Отклонить", "xmark", .secondary, action: onReject)
            } else {
                Button { replying.toggle() } label: {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                if mark.isOpen {
                    actionButton("Решить", "checkmark.circle", .secondary, action: onResolve)
                } else {
                    actionButton("Открыть", "arrow.counterclockwise", .secondary, action: onReopen)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Удалить метку", role: .destructive, action: onDelete)
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
            TextField("Ответ…", text: $replyText)
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
        case .open: return "открыта"
        case .resolved: return "решена"
        case .wontfix: return "отклонена"
        case .needsInfo: return "нужен ответ"
        case .needsRebase: return "уехала"
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
