import SwiftUI
import AppKit

/// Left-sidebar Search tab: workspace full-text query + results (plan 07).
struct WorkspaceSearchSidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    @ObservedObject var model: WorkspaceSearchModel
    /// Open file (same modal path as Files). Line jump uses
    /// `AppState.requestControlJump` so ContentView can apply it after mount.
    let onOpen: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            queryField
            Divider()
            resultsArea
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshContextAndMaybeSearch() }
        .onChange(of: workspace.contentEpoch) { _ in refreshContextAndMaybeSearch() }
        .onChange(of: workspace.workspaces) { _ in refreshContextAndMaybeSearch() }
        .onChange(of: model.sortByDate) { _ in
            if !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.runSearchNow()
            }
        }
    }

    // MARK: - Query

    private var queryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(
                    "поиск · \"фраза\" path: type: tag:",
                    text: Binding(
                        get: { model.queryText },
                        set: { model.setQueryText($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                if !model.queryText.isEmpty {
                    Button {
                        model.clear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )

            if model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cheatSheet
            } else {
                HStack(spacing: 8) {
                    Button {
                        model.sortByDate.toggle()
                    } label: {
                        Label(
                            model.sortByDate ? "По дате" : "По совпадениям",
                            systemImage: model.sortByDate
                                ? "calendar"
                                : "text.magnifyingglass"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .editMDHelp("Переключить сортировку: совпадения ↔ дата изменения")
                    Spacer(minLength: 0)
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var cheatSheet: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Фильтры")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Group {
                Text("токен1 токен2  — AND")
                Text("\"точная фраза\"")
                Text("path:docs/plans")
                Text("type:md · type:*")
                Text("tag:research")
                Text("is:modified")
                Text("after:2026-07-01 · before:…")
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsArea: some View {
        let q = model.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspace.workspaces.isEmpty {
            emptyMessage("Добавьте папку workspace\nчтобы искать")
        } else if q.isEmpty {
            emptyMessage("Введите запрос")
        } else if let reason = model.emptyReason, model.results.isEmpty, !model.isSearching {
            emptyMessage(reason)
        } else if model.results.isEmpty && !model.isSearching {
            emptyMessage("Ничего не найдено")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.results) { file in
                        fileGroup(file)
                    }
                    if model.truncated {
                        Text("Показаны первые \(model.results.count) файлов — уточните запрос")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func fileGroup(_ file: SearchFileResult) -> some View {
        Button {
            openFile(file.url, offset: file.lineHits.first?.utf16Offset)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(file.relativePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if file.matchCount > 0 {
                    Text("\(file.matchCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        ForEach(file.lineHits) { hit in
            Button {
                openFile(file.url, offset: hit.utf16Offset)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(hit.lineNumber)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, alignment: .trailing)
                    highlightedLine(hit.lineText, query: model.lastQuery)
                        .font(.system(size: 11))
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        if file.lineHits.isEmpty && file.nameMatched {
            Text("совпадение в имени файла")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.leading, 46)
                .padding(.bottom, 2)
        }
    }

    /// Soft highlight of the first matching needle in the line.
    private func highlightedLine(_ line: String, query: SearchQuery) -> Text {
        let needles = query.tokens + query.phrases
        guard let needle = needles.first(where: {
            line.range(of: $0, options: .caseInsensitive) != nil
        }),
        let range = line.range(of: needle, options: .caseInsensitive)
        else {
            return Text(line)
        }
        var attr = AttributedString(line)
        if let lower = AttributedString.Index(range.lowerBound, within: attr),
           let upper = AttributedString.Index(range.upperBound, within: attr) {
            attr[lower..<upper].backgroundColor = Color.accentColor.opacity(0.22)
        }
        return Text(attr)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 4) {
            if model.isSearching {
                Text("Поиск…")
            } else if model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Диск · без несохранённых буферов")
            } else {
                Text("\(model.results.count) файл\(filePlural(model.results.count))")
                if model.skippedOversized > 0 {
                    Text("·")
                    Text("\(model.skippedOversized) пропущено")
                }
                Text("·")
                Text("\(model.elapsedMs) мс")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .editMDHelp("Поиск по диску; несохранённые изменения в других окнах не учитываются")
    }

    private func filePlural(_ n: Int) -> String {
        let mod10 = n % 10
        let mod100 = n % 100
        if mod10 == 1 && mod100 != 11 { return "" }
        if mod10 >= 2 && mod10 <= 4 && !(mod100 >= 12 && mod100 <= 14) { return "а" }
        return "ов"
    }

    // MARK: - Actions

    private func refreshContextAndMaybeSearch() {
        workspace.ensureTagIndex()
        // Stage 3: tags from workspace; git modified set filled in stage 4.
        model.updateContext(
            roots: workspace.workspaces.map(\.url),
            tagIndex: workspace.tagIndex,
            modifiedPaths: modelModifiedPathsPlaceholder,
            gitAvailable: modelGitAvailablePlaceholder
        )
        if !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.runSearchNow()
        }
    }

    /// Overridden by stage-4 wiring via static hooks (kept simple for one model).
    private var modelModifiedPathsPlaceholder: Set<String> {
        WorkspaceSearchGitBridge.modifiedPaths
    }

    private var modelGitAvailablePlaceholder: Bool {
        WorkspaceSearchGitBridge.gitAvailable
    }

    private func openFile(_ url: URL, offset: Int?) {
        // Same path as vault-lint / wiki heading jump: park offset in AppState,
        // then open. ContentView consumes via `.editMDControlJump` (same file)
        // or onAppear / fileURL change (other file).
        if let offset {
            AppState.shared.requestControlJump(url: url, offset: offset)
        }
        onOpen(url)
    }
}

// MARK: - Git bridge (stage 4 fills this; stage 3 leaves empty)

/// Shared git-modified path set for `is:modified`. Updated by search UI when
/// a snapshot is available; never spawns Process from the search hot path alone
/// without going through the cached bridge API.
@MainActor
enum WorkspaceSearchGitBridge {
    static var modifiedPaths: Set<String> = []
    static var gitAvailable: Bool = false
    /// Generation so callers can detect staleness.
    static var revision: Int = 0

    static func apply(snapshot: GitWorkspaceSnapshot) {
        var paths = Set<String>()
        for section in snapshot.sections {
            for f in section.files {
                paths.insert(f.url.standardizedFileURL.path)
            }
        }
        for f in snapshot.openDirty {
            paths.insert(f.url.standardizedFileURL.path)
        }
        modifiedPaths = paths
        gitAvailable = snapshot.hasAnyRepo
        revision += 1
    }

    static func clear() {
        modifiedPaths = []
        gitAvailable = false
        revision += 1
    }
}
