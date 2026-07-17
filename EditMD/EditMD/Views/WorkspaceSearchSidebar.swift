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
        .onChange(of: workspace.tagIndex.count) { _ in refreshContextAndMaybeSearch() }
        .onChange(of: model.sortByDate) { _ in
            if !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.runSearchNow()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { _ in
            WorkspaceSearchGitBridge.shared.invalidate()
            let q = parseSearchQuery(model.queryText)
            if q.isModified {
                refreshContextAndMaybeSearch()
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
                    String(localized: "search · \"phrase\" path: type: tag:"),
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
                            model.sortByDate
                                ? String(localized: "By date")
                                : String(localized: "By matches"),
                            systemImage: model.sortByDate
                                ? "calendar"
                                : "text.magnifyingglass"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .editMDHelp(String(localized: "Toggle sorting: matches ↔ modification date"))
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
            Text("Filters")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Group {
                Text("token1 token2  — AND")
                Text("\"exact phrase\"")
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
            emptyMessage(String(localized: "Add a workspace folder\nto search"))
        } else if q.isEmpty {
            emptyMessage(String(localized: "Type a query"))
        } else if let reason = model.emptyReason, model.results.isEmpty, !model.isSearching {
            emptyMessage(reason)
        } else if model.results.isEmpty && !model.isSearching {
            emptyMessage(String(localized: "Nothing found"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.results) { file in
                        fileGroup(file)
                    }
                    if model.truncated {
                        Text("Showing the first \(model.results.count) files — refine the query")
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
            Text("match in the file name")
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
                Text("Searching…")
            } else if model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Disk · unsaved buffers not included")
            } else {
                Text(String(localized: "\(model.results.count) files"))
                if model.skippedOversized > 0 {
                    Text("·")
                    Text("\(model.skippedOversized) skipped")
                }
                Text("·")
                Text("\(model.elapsedMs) ms")
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .editMDHelp(String(localized: "Searches the disk; unsaved changes in other windows are not included"))
    }


    // MARK: - Actions

    private func refreshContextAndMaybeSearch() {
        workspace.ensureTagIndex()
        let roots = workspace.workspaces.map(\.url)
        let bridge = WorkspaceSearchGitBridge.shared
        model.updateContext(
            roots: roots,
            tagIndex: workspace.tagIndex,
            modifiedPaths: bridge.modifiedPaths,
            gitAvailable: bridge.gitAvailable
        )
        if !model.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.runSearchNow()
        }
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

// MARK: - Shared git cache for search (`is:modified`)

/// Cache of workspace-scoped dirty paths. Filled by the Git sidebar on its
/// normal refresh and by Search only when stale — never a new Process on every
/// keystroke.
@MainActor
final class WorkspaceSearchGitBridge {
    static let shared = WorkspaceSearchGitBridge()

    private(set) var modifiedPaths: Set<String> = []
    private(set) var gitAvailable: Bool = false
    private(set) var revision: Int = 0

    private var rootsKey: String = ""
    private var isFresh = false
    private var loadTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: .gitRepositoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.invalidate()
            }
        }
    }

    func invalidate() {
        isFresh = false
    }

    func needsRefresh(roots: [URL]) -> Bool {
        let key = Self.key(for: roots)
        return !isFresh || key != rootsKey
    }

    /// Install a snapshot produced elsewhere (Git sidebar). Avoids a second Process.
    func apply(snapshot: GitWorkspaceSnapshot, roots: [URL]) {
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
        rootsKey = Self.key(for: roots)
        isFresh = true
        revision += 1
    }

    /// Load via `GitWorkspaceStatus.snapshotAsync` only if cache is stale.
    func ensureFresh(roots: [URL], openURLs: [URL]) async {
        let key = Self.key(for: roots)
        if isFresh, key == rootsKey { return }
        if roots.isEmpty {
            modifiedPaths = []
            gitAvailable = false
            rootsKey = key
            isFresh = true
            revision += 1
            return
        }
        // Coalesce concurrent callers.
        if let existing = loadTask {
            await existing.value
            if isFresh, rootsKey == key { return }
        }
        let task = Task { @MainActor in
            let snap = await GitWorkspaceStatus.snapshotAsync(
                workspaceRoots: roots,
                openURLs: openURLs
            )
            self.apply(snapshot: snap, roots: roots)
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    func clear() {
        modifiedPaths = []
        gitAvailable = false
        rootsKey = ""
        isFresh = false
        revision += 1
    }

    private static func key(for roots: [URL]) -> String {
        roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\u{1F}")
    }
}
