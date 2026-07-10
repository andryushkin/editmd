import SwiftUI

/// Review navigator tab (phase 2, v37): the active file's smotr marks as
/// threads. Create a mark from the current selection, reply, resolve/reopen,
/// and accept/reject Claude's `suggest` edits. Anchors are resolved against the
/// live buffer; a mark whose fragment is gone still shows but cannot jump.
struct ReviewSidebar: View {
    @ObservedObject var review: ReviewModel
    /// Bottom filter field text — matches note / quote substrings.
    var filter: String = ""
    /// Jump the editor caret to a markdown offset (reuses the outline plumbing).
    let onJump: (Int) -> Void

    @State private var composing = false
    @State private var composeType: ReviewMarkType = .comment
    @State private var composeNote = ""

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
            Divider()
            if composing { composeForm }
            content
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Picker("", selection: $review.statusFilter) {
                ForEach(ReviewModel.StatusFilter.allCases, id: \.self) {
                    Text($0.label).tag($0)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()

            typeFilterMenu

            Spacer(minLength: 0)

            Button {
                composing.toggle()
            } label: {
                Image(systemName: composing ? "xmark" : "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!composing && !review.canAddMark)
            .editMDHelp(review.canAddMark
                        ? "Добавить метку из выделения"
                        : "Выдели текст в редакторе, чтобы поставить метку")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var typeFilterMenu: some View {
        Menu {
            Button("Все типы") { review.typeFilter = nil }
            Divider()
            ForEach(ReviewMarkType.allCases.filter { $0 != .suggest }, id: \.self) { t in
                Button {
                    review.typeFilter = t
                } label: {
                    Label(t.label, systemImage: t.glyph)
                }
            }
        } label: {
            Image(systemName: review.typeFilter?.glyph ?? "line.3.horizontal.decrease.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(review.typeFilter == nil ? Color.secondary : Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .editMDHelp("Фильтр по типу")
    }

    // MARK: Compose

    private var composeForm: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $composeType) {
                ForEach(ReviewMarkType.allCases.filter { $0 != .suggest }, id: \.self) { t in
                    Label(t.label, systemImage: t.glyph).tag(t)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            TextEditor(text: $composeNote)
                .font(.system(size: 12))
                .frame(height: 48)
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
                    .disabled(!review.canAddMark)
            }
            .font(.system(size: 11))
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func saveCompose() {
        if review.addMarkFromSelection(type: composeType, note: composeNote) {
            cancelCompose()
        }
    }

    private func cancelCompose() {
        composing = false
        composeNote = ""
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
