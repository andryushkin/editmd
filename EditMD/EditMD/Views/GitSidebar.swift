import SwiftUI
import AppKit

/// Sidebar tab: workspace-scoped git status + Commit / Push actions
/// (moved out of the status bar, which is info-only).
struct GitSidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    let activeURL: URL?
    let filter: String
    let onOpen: (URL) -> Void

    @State private var snapshot = GitWorkspaceSnapshot.empty
    @State private var refreshTask: Task<Void, Never>?
    @State private var isRefreshing = false
    @State private var commitURL: URL?
    @State private var showCommit = false
    @State private var diffContent: DiffSheetContent?
    @State private var showDiff = false
    @State private var hoverCommitURL: URL?

    @ObservedObject private var lineChanges = LineChangeTracker.shared

    var body: some View {
        VStack(spacing: 0) {
            if !snapshot.hasWorkspaces {
                emptyNoWorkspace
            } else if !snapshot.hasAnyRepo {
                emptyNoRepo
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSections) { section in
                            repoHeader(section)
                            if section.files.isEmpty {
                                Text("Working tree clean")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(section.files.filter { nameMatches($0) }) { file in
                                    changedRow(file, allowsCommit: true)
                                }
                            }
                        }

                        let open = filteredOpenGlobal
                        if !open.isEmpty {
                            sectionHeader("Open in editor")
                            ForEach(open) { file in
                                changedRow(file, allowsCommit: file.canCommit)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh(immediate: true) }
        .onChange(of: workspace.workspaces) { _ in refresh(immediate: true) }
        // Do NOT re-run `git status` on every keystroke — only patch dirty badges.
        .onChange(of: lineChanges.revision) { _ in patchOpenDirtyMarks() }
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { _ in
            GitHeadContentCache.invalidate()
            refresh(immediate: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh(immediate: false)
        }
        .sheet(isPresented: $showCommit) {
            if let url = commitURL {
                GitCommitSheet(
                    fileURL: url,
                    documentContent: DocumentRegistry.shared.contentIfOpen(url) ?? "",
                    onClose: {
                        showCommit = false
                        commitURL = nil
                        refresh(immediate: true)
                    },
                    onCommitted: { refresh(immediate: true) }
                )
            } else {
                Text("No file")
                    .padding()
                    .onAppear {
                        showCommit = false
                        commitURL = nil
                    }
            }
        }
        .sheet(isPresented: $showDiff) {
            if let content = diffContent {
                UnifiedDiffSheet(content: content) {
                    showDiff = false
                    diffContent = nil
                }
            } else {
                Text("No diff")
                    .padding()
                    .onAppear {
                        showDiff = false
                        diffContent = nil
                    }
            }
        }
    }

    // MARK: - Filtering

    private var filterQuery: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool { !filterQuery.isEmpty }

    private func nameMatches(_ file: GitChangedFile) -> Bool {
        !isFiltering
            || file.displayPath.localizedCaseInsensitiveContains(filterQuery)
            || file.url.lastPathComponent.localizedCaseInsensitiveContains(filterQuery)
    }

    private var filteredSections: [GitRepoSection] {
        if !isFiltering { return snapshot.sections }
        return snapshot.sections.compactMap { section in
            let files = section.files.filter { nameMatches($0) }
            // Keep section if branch/root matches or it has matching files.
            let metaMatch = (section.branch ?? "").localizedCaseInsensitiveContains(filterQuery)
                || section.shortRoot.localizedCaseInsensitiveContains(filterQuery)
            if files.isEmpty && !metaMatch { return nil }
            return GitRepoSection(
                root: section.root,
                branch: section.branch,
                ahead: section.ahead,
                behind: section.behind,
                files: files
            )
        }
    }

    private var filteredOpenGlobal: [GitChangedFile] {
        snapshot.openDirty.filter { nameMatches($0) }
    }

    // MARK: - Header / rows

    @ViewBuilder
    private func repoHeader(_ section: GitRepoSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let branch = section.branch {
                    Text(branch)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                } else {
                    Text("detached")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let ahead = section.ahead, ahead > 0 {
                    Text("↑\(ahead)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .help("\(ahead) commit(s) to push")
                }
                if let behind = section.behind, behind > 0 {
                    Text("↓\(behind)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("\(behind) commit(s) to pull")
                }
            }

            Text(section.shortRoot)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    refresh(immediate: true)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                        .labelStyle(.iconOnly)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .editMDHelp("Refresh git status")
                .disabled(isRefreshing)

                Spacer(minLength: 0)

                Button("Push") {
                    pushRepo(section.root)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: (section.ahead ?? 0) > 0 ? .semibold : .regular))
                .foregroundStyle((section.ahead ?? 0) > 0 ? Color.accentColor : Color.secondary)
                .editMDHelp("Push to remote…")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)

        sectionHeader("Changed (\(section.files.count))")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func changedRow(_ file: GitChangedFile, allowsCommit: Bool) -> some View {
        let active = file.url.standardizedFileURL == activeURL?.standardizedFileURL
        let hovering = hoverCommitURL == file.url
        return HStack(spacing: 6) {
            Text(file.statusBadge)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(badgeColor(file.pathStatus))
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if file.displayPath != file.url.lastPathComponent {
                    Text(file.displayPath)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            Spacer(minLength: 0)

            if file.bufferDirty {
                Text("unsaved")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            } else if file.sessionDirtyLines > 0 {
                Text("\(file.sessionDirtyLines)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Session dirty lines")
            }

            // Diff always available for porcelain / open-dirty rows.
            Button {
                presentDiff(file.url)
            } label: {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .editMDHelp("Show diff…")
            .opacity(hovering || active ? 1 : 0.7)

            if allowsCommit, file.canCommit {
                Button("Commit") {
                    presentCommit(file.url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .opacity(hovering || active ? 1 : 0.85)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : (hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(file.url) }
        .onHover { hoverCommitURL = $0 ? file.url : nil }
        .contextMenu {
            Button("Open") { onOpen(file.url) }
            Button("Open in Separate Window") {
                AppState.shared.openInSeparateWindow(file.url)
            }
            Divider()
            Button("Show Diff…") { presentDiff(file.url) }
            if file.canCommit {
                Button("Commit File…") { presentCommit(file.url) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

    private func badgeColor(_ status: GitCLI.PathStatus) -> Color {
        switch status {
        case .untracked: return .green
        case .deleted: return .red
        case .modified: return .orange
        case .clean, .notInRepo: return .secondary
        }
    }

    // MARK: - Empty states

    private var emptyNoWorkspace: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No workspace folder")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Add a folder to see git status for its markdown files.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Button("Open Folder…") { workspace.promptAddFolder() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyNoRepo: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No git repository")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Workspace folders are not inside a git work tree.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func presentCommit(_ url: URL) {
        commitURL = url
        showCommit = true
    }

    private func presentDiff(_ url: URL) {
        diffContent = GitWorkspaceStatus.diffSheetContent(for: url)
        showDiff = true
    }

    /// Cheap: update session/buffer badges without spawning git.
    private func patchOpenDirtyMarks() {
        guard !snapshot.sections.isEmpty || !snapshot.openDirty.isEmpty else { return }
        let openURLs = DocumentRegistry.shared.openURLs
        var sections = snapshot.sections
        for si in sections.indices {
            var files = sections[si].files
            for fi in files.indices {
                let u = files[fi].url
                files[fi] = GitChangedFile(
                    url: u,
                    displayPath: files[fi].displayPath,
                    pathStatus: files[fi].pathStatus,
                    sessionDirtyLines: LineChangeTracker.shared.dirtyLines(for: u).count,
                    bufferDirty: DocumentRegistry.shared.isDirty(u)
                )
            }
            sections[si] = GitRepoSection(
                root: sections[si].root,
                branch: sections[si].branch,
                ahead: sections[si].ahead,
                behind: sections[si].behind,
                files: files
            )
        }
        // Rebuild open-dirty list from registry (still no git).
        let changed = Set(sections.flatMap { $0.files.map(\.url) })
        let roots = workspace.workspaces.map { $0.url.standardizedFileURL }
        var openDirty: [GitChangedFile] = []
        for open in openURLs {
            let key = open.standardizedFileURL
            guard !changed.contains(key) else { continue }
            let bufferDirty = DocumentRegistry.shared.isDirty(key)
            let sessionLines = LineChangeTracker.shared.dirtyLines(for: key).count
            guard bufferDirty || sessionLines > 0 else { continue }
            // Keep existing row metadata if present; else minimal.
            if let existing = snapshot.openDirty.first(where: { $0.url == key }) {
                openDirty.append(GitChangedFile(
                    url: key,
                    displayPath: existing.displayPath,
                    pathStatus: existing.pathStatus,
                    sessionDirtyLines: sessionLines,
                    bufferDirty: bufferDirty
                ))
            } else if let ws = roots.first(where: {
                key.path == $0.path || key.path.hasPrefix($0.path + "/")
            }) {
                let rel = GitCLI.relativePath(of: key, to: ws)
                openDirty.append(GitChangedFile(
                    url: key,
                    displayPath: rel.isEmpty ? key.lastPathComponent : rel,
                    pathStatus: .clean,
                    sessionDirtyLines: sessionLines,
                    bufferDirty: bufferDirty
                ))
            }
        }
        snapshot = GitWorkspaceSnapshot(
            sections: sections,
            openDirty: openDirty,
            hasAnyRepo: snapshot.hasAnyRepo,
            hasWorkspaces: snapshot.hasWorkspaces
        )
    }

    private func refresh(immediate: Bool = false) {
        refreshTask?.cancel()
        let roots = workspace.workspaces.map(\.url)
        let open = DocumentRegistry.shared.openURLs
        // Non-immediate: longer debounce so becomeActive storms don't thrash git.
        let delay: UInt64 = immediate ? 0 : 600_000_000
        refreshTask = Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            isRefreshing = true
            // Snapshot git Process off the main actor; re-enter only for UI state.
            let built = await GitWorkspaceStatus.snapshotAsync(
                workspaceRoots: roots,
                openURLs: open
            )
            guard !Task.isCancelled else {
                isRefreshing = false
                return
            }
            snapshot = built
            isRefreshing = false
        }
    }

    private func pushRepo(_ root: URL) {
        // Push is blocking (credential helper); same path as File menu.
        GitPushConfirm.run(for: root)
        refresh(immediate: true)
    }
}
