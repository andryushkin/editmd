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
    /// Item-based sheet target (NOT `isPresented` + optional). Dual-state
    /// `showCommit`/`commitURL` raced: sheet content could evaluate with a nil
    /// URL, hit the "No file" fallback, and `onAppear` immediately dismissed —
    /// first Commit click looked like a no-op (needed a second click).
    @State private var commitTarget: GitSidebarCommitTarget?
    @State private var diffTarget: GitSidebarDiffTarget?
    @State private var hoverCommitURL: URL?
    @State private var hoverSectionID: String?
    /// Disclosure state per workspace section. Default is derived (clean →
    /// collapsed, has changes → expanded), so only folders the user toggled
    /// by hand are remembered — a folder that becomes dirty opens by itself.
    @State private var manuallyExpanded: Set<String> = GitSidebarDisclosureStore.load(.expanded)
    @State private var manuallyCollapsed: Set<String> = GitSidebarDisclosureStore.load(.collapsed)

    @ObservedObject private var lineChanges = LineChangeTracker.shared

    var body: some View {
        VStack(spacing: 0) {
            if !snapshot.hasWorkspaces {
                emptyNoWorkspace
            } else if !snapshot.hasAnyRepo {
                emptyNoRepo
            } else {
                summaryBar
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSections) { section in
                            workspaceHeader(section)
                            if isExpanded(section) {
                                ForEach(section.files.filter { nameMatches($0) }) { file in
                                    changedRow(file, allowsCommit: true)
                                }
                                sectionFooter(section)
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
        .sheet(item: $commitTarget) { target in
            GitCommitSheet(
                fileURLs: target.urls,
                onClose: {
                    commitTarget = nil
                    refresh(immediate: true)
                },
                onCommitted: { refresh(immediate: true) }
            )
        }
        .sheet(item: $diffTarget) { target in
            UnifiedDiffSheet(content: target.content) {
                diffTarget = nil
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
            // Keep section if its name / branch / path matches, or it has
            // matching files.
            let metaMatch = section.name.localizedCaseInsensitiveContains(filterQuery)
                || (section.branch ?? "").localizedCaseInsensitiveContains(filterQuery)
                || section.shortRoot.localizedCaseInsensitiveContains(filterQuery)
            if files.isEmpty && !metaMatch { return nil }
            return GitRepoSection(
                workspace: section.workspace,
                name: section.name,
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

    // MARK: - Disclosure state

    /// Derived default (clean → collapsed) unless the user toggled this folder.
    /// While filtering every surviving group is open so matches stay visible.
    private func isExpanded(_ section: GitRepoSection) -> Bool {
        if isFiltering { return true }
        if manuallyExpanded.contains(section.id) { return true }
        if manuallyCollapsed.contains(section.id) { return false }
        return !section.files.isEmpty
    }

    private func toggleExpanded(_ section: GitRepoSection) {
        // Filtering forces every group open; a toggle then has no visible
        // effect and would silently record the wrong state.
        guard !isFiltering else { return }
        if isExpanded(section) {
            manuallyExpanded.remove(section.id)
            manuallyCollapsed.insert(section.id)
        } else {
            manuallyCollapsed.remove(section.id)
            manuallyExpanded.insert(section.id)
        }
        GitSidebarDisclosureStore.save(manuallyExpanded, for: .expanded)
        GitSidebarDisclosureStore.save(manuallyCollapsed, for: .collapsed)
    }

    // MARK: - Header / rows

    /// Thin overview line: how much is dirty across all adopted folders.
    private var summaryBar: some View {
        HStack(spacing: 6) {
            let changed = snapshot.changedCount
            if changed > 0 {
                Text("Changed: \(changed)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text("All folders clean")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Group header = one adopted workspace folder. Branch and ahead/behind are
    /// secondary metadata here; the folder name is what identifies the group.
    @ViewBuilder
    private func workspaceHeader(_ section: GitRepoSection) -> some View {
        let expanded = isExpanded(section)
        let hovering = hoverSectionID == section.id
        let count = section.files.count

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 10)

                Text(section.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                // Actions appear on hover so the resting panel stays readable.
                // Tap gestures (not Buttons) so the first click after entering
                // the Git tab lands — see the row Diff/Commit note.
                if hovering {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { if !isRefreshing { refresh(immediate: true) } }
                        .editMDHelp("Refresh git status")
                        .opacity(isRefreshing ? 0.5 : 1)

                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle((section.ahead ?? 0) > 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                        .onTapGesture { pushRepo(section.root) }
                        .editMDHelp("Push to remote…")
                }

                branchLabel(section)

                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.15))
                        )
                } else if !expanded {
                    Text("Clean")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }

            // Path only when open — collapsed rows stay one line tall.
            if expanded {
                Text(section.shortRoot)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 15)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hoverSectionID = $0 ? section.id : nil }
        .onTapGesture { toggleExpanded(section) }
        .editMDHelp(section.shortRoot)
    }

    @ViewBuilder
    private func branchLabel(_ section: GitRepoSection) -> some View {
        HStack(spacing: 3) {
            Text(section.branch ?? String(localized: "detached"))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let ahead = section.ahead, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .help("\(ahead) commit(s) to push")
            }
            if let behind = section.behind, behind > 0 {
                Text("↓\(behind)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("\(behind) commit(s) to pull")
            }
        }
        .layoutPriority(-1)
    }

    /// Bottom of an expanded group: either the clean note or bulk commit.
    @ViewBuilder
    private func sectionFooter(_ section: GitRepoSection) -> some View {
        if section.files.isEmpty {
            Text("Working tree clean")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 4)
        } else if section.files.count > 1 {
            // One commit for every markdown file listed under this folder.
            // Same sheet as the per-row action.
            Text("Commit all")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { presentCommit(urls: section.files.map(\.url)) }
                .editMDHelp("Commit all changed files in this folder…")
        }
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
            // Open region — its OWN tap target that does NOT overlap the Diff /
            // Commit buttons. Overlapping interactive elements (row tap gesture
            // OR a full-row button behind the content) each swallow the first
            // click, so Commit needed two clicks. Keeping the open gesture on
            // just this sub-area lets the sibling buttons win their clicks.
            HStack(spacing: 6) {
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
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen(file.url) }

            // Diff / Commit use `.onTapGesture`, not `Button`, on purpose. An
            // NSButton-backed SwiftUI Button ignores the first click after its
            // view gains focus (acceptsFirstMouse == false), so the first Commit
            // after (re)entering the Git tab needed two clicks. A tap gesture
            // fires on the first mouse-down regardless — the same reason the
            // row-open above already worked on the first click.
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .onTapGesture { presentDiff(file.url) }
                .editMDHelp("Show diff…")
                .opacity(hovering || active ? 1 : 0.7)

            if allowsCommit, file.canCommit {
                Text("Commit")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture { presentCommit(file.url) }
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
            Button("Move to Trash", role: .destructive) {
                confirmAndMoveFilesToTrash([file.url], workspace: workspace)
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
        presentCommit(urls: [url])
    }

    private func presentCommit(urls: [URL]) {
        // Single assignment → sheet(item:) always receives a non-nil payload.
        let unique = urls.map(\.standardizedFileURL)
        guard !unique.isEmpty else { return }
        commitTarget = GitSidebarCommitTarget(urls: unique)
    }

    private func presentDiff(_ url: URL) {
        Task { @MainActor in
            // git show runs off-main; open the sheet when content is ready.
            let content = await GitWorkspaceStatus.diffSheetContent(for: url)
            diffTarget = GitSidebarDiffTarget(content: content)
        }
    }

    /// Cheap: update session/buffer badges without spawning git.
    private func patchOpenDirtyMarks() {
        guard !snapshot.sections.isEmpty || !snapshot.openDirty.isEmpty else { return }
        let openURLs = DocumentRegistry.shared.openURLs
        var sections = snapshot.sections
        for si in sections.indices {
            // Drop rows whose path vanished (trashed while this tab stayed open).
            var files = sections[si].files.filter {
                FileManager.default.fileExists(atPath: $0.url.path)
            }
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
                workspace: sections[si].workspace,
                name: sections[si].name,
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
            guard FileManager.default.fileExists(atPath: key.path) else { continue }
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
        // Sections are workspace folders, so they carry the sidebar's names.
        let folders = workspace.workspaces.map {
            GitWorkspaceInput(url: $0.url, name: $0.name)
        }
        let roots = folders.map(\.url)
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
                workspaces: folders,
                openURLs: open
            )
            guard !Task.isCancelled else {
                isRefreshing = false
                return
            }
            snapshot = built
            // Share with workspace Search `is:modified` so it need not re-run git.
            WorkspaceSearchGitBridge.shared.apply(snapshot: built, roots: roots)
            isRefreshing = false
        }
    }

    private func pushRepo(_ root: URL) {
        // Push runs off-main; a successful push posts .gitRepositoryDidChange,
        // which already triggers refresh(immediate:) above.
        GitPushConfirm.run(for: root)
    }
}

// MARK: - Sheet targets (item-based presentation)

/// Payload for `.sheet(item:)` so Commit always opens with concrete path(s) —
/// avoids the dual-state race of `isPresented` + optional `commitURL`.
/// One URL = per-row Commit; several = repo-header “Commit all”.
private struct GitSidebarCommitTarget: Identifiable {
    let urls: [URL]
    var id: String {
        urls.map(\.standardizedFileURL.path).sorted().joined(separator: "\n")
    }
}

/// Fresh id per presentation so re-opening the same file's diff still animates.
private struct GitSidebarDiffTarget: Identifiable {
    let id = UUID()
    let content: DiffSheetContent
}

// MARK: - Disclosure persistence

/// Remembers only folders the user toggled away from the derived default
/// (clean → collapsed). Storing the *overrides* rather than the open set keeps
/// a folder that just became dirty opening by itself across launches.
enum GitSidebarDisclosureStore {
    enum Kind: String {
        case expanded = "git.sidebar.expandedWorkspaces"
        case collapsed = "git.sidebar.collapsedWorkspaces"
    }

    static func load(_ kind: Kind) -> Set<String> {
        let paths = UserDefaults.standard.stringArray(forKey: kind.rawValue) ?? []
        return Set(paths)
    }

    static func save(_ paths: Set<String>, for kind: Kind) {
        UserDefaults.standard.set(Array(paths), forKey: kind.rawValue)
    }
}
