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
    /// Live sidebar width; 0 until the first layout pass.
    @State private var panelWidth: CGFloat = 0

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
                        ForEach(filteredGroups) { group in
                            workspaceHeader(group)
                            if isExpanded(group) {
                                ForEach(group.files) { file in
                                    changedRow(file, allowsCommit: true)
                                }
                                sectionFooter(group)
                            }
                        }

                        let open = filteredOpenGlobal
                        if !open.isEmpty {
                            sectionHeader(String(localized: "Open in editor"))
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
        // Panel width drives what a header can afford to show. Measured in the
        // background layer so it never takes part in layout itself.
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: GitSidebarWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(GitSidebarWidthKey.self) { width in
            panelWidth = width
        }
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

    private var filteredGroups: [GitSidebarGroup] {
        if !isFiltering {
            return snapshot.sections.map { GitSidebarGroup(section: $0, files: $0.files) }
        }
        return snapshot.sections.compactMap { section in
            let files = section.files.filter { nameMatches($0) }
            // Keep section if its name / branch / path matches, or it has
            // matching files.
            let metaMatch = section.name.localizedCaseInsensitiveContains(filterQuery)
                || (section.branch ?? "").localizedCaseInsensitiveContains(filterQuery)
                || section.shortRoot.localizedCaseInsensitiveContains(filterQuery)
            if files.isEmpty && !metaMatch { return nil }
            // Carries the full section: a filter narrows what is listed, it
            // must never make a dirty folder read as clean.
            return GitSidebarGroup(section: section, files: files)
        }
    }

    private var filteredOpenGlobal: [GitChangedFile] {
        snapshot.openDirty.filter { nameMatches($0) }
    }

    // MARK: - Adaptive layout

    /// Below this the header only has room for the folder name, ↑N/↓M and the
    /// count; branch name and the hover action slots are dropped. 0 means the
    /// first layout pass has not landed yet — assume roomy.
    private var isNarrowPanel: Bool { panelWidth > 0 && panelWidth < 240 }

    // MARK: - Disclosure state

    private func isExpanded(_ group: GitSidebarGroup) -> Bool {
        GitSidebarDisclosure.isExpanded(
            id: group.id,
            hasChanges: group.hasChanges,
            expanded: manuallyExpanded,
            collapsed: manuallyCollapsed,
            filtering: isFiltering
        )
    }

    private func toggleExpanded(_ group: GitSidebarGroup) {
        // Filtering forces every group open; a toggle then has no visible
        // effect and would silently record the wrong state.
        guard !isFiltering else { return }
        let next = GitSidebarDisclosure.toggled(
            id: group.id,
            hasChanges: group.hasChanges,
            expanded: manuallyExpanded,
            collapsed: manuallyCollapsed
        )
        applyDisclosure(next)
    }

    /// Drop overrides that agree with the derived default, so a folder the user
    /// once collapsed while dirty does not stay pinned closed the next time it
    /// becomes dirty. Called after every snapshot.
    private func pruneDisclosure(for sections: [GitRepoSection]) {
        let defaults = Dictionary(
            sections.map { ($0.id, !$0.files.isEmpty) },
            uniquingKeysWith: { a, _ in a }
        )
        applyDisclosure(GitSidebarDisclosure.pruned(
            expanded: manuallyExpanded,
            collapsed: manuallyCollapsed,
            defaults: defaults
        ))
    }

    private func applyDisclosure(_ next: GitSidebarDisclosure.State) {
        guard next.expanded != manuallyExpanded || next.collapsed != manuallyCollapsed else {
            return
        }
        manuallyExpanded = next.expanded
        manuallyCollapsed = next.collapsed
        GitSidebarDisclosureStore.save(next.expanded, for: .expanded)
        GitSidebarDisclosureStore.save(next.collapsed, for: .collapsed)
    }

    // MARK: - Header / rows

    /// Thin overview line: how much is dirty across all adopted folders.
    /// Must agree with the list below — open buffers with unsaved / session
    /// changes are listed under "Open in editor" even when git is clean, so
    /// they count as not-clean here too.
    private var summaryBar: some View {
        HStack(spacing: 6) {
            let changed = snapshot.changedCount
            let unsaved = snapshot.openDirty.count
            if changed > 0 {
                Text("Changed: \(changed)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                if unsaved > 0 {
                    Text("Unsaved: \(unsaved)")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            } else if unsaved > 0 {
                Text("Unsaved: \(unsaved)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
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
    private func workspaceHeader(_ group: GitSidebarGroup) -> some View {
        let section = group.section
        let expanded = isExpanded(group)
        let hovering = hoverSectionID == group.id
        // Always the full section count: a filter narrows the listing, it does
        // not make the folder clean.
        let count = section.files.count

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                // Disclosure hit target. It is a *sibling* of the action icons,
                // never their ancestor — overlapping tap targets each swallow
                // the first click (see the changedRow note).
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)

                    // A clean folder is dimmed so the eye lands on the dirty ones.
                    Text(section.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded(group) }
                // The folder name is what identifies the group, so it is the
                // last thing allowed to shrink. NO Spacer inside this zone: a
                // Spacer asks for unbounded width, and at priority 1 it took
                // every point, leaving the branch/count zone 0pt wide — its
                // text then wrapped per character and inflated the row.
                .layoutPriority(1)

                // Flexible gap, and a disclosure hit target of its own so the
                // empty middle of the header still toggles the group.
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .contentShape(Rectangle())
                    .onTapGesture { toggleExpanded(group) }

                // Icons keep their slots at rest (fixed frames + opacity), so
                // the branch label and count never shift under the cursor.
                // Hit testing follows visibility — an invisible icon must not
                // catch a click meant for the header. A narrow panel cannot
                // afford the slots at all: there the context menu is the way in.
                if !isNarrowPanel {
                    headerAction(
                        systemName: "arrow.clockwise",
                        tint: .secondary,
                        visible: hovering,
                        dimmed: isRefreshing,
                        help: String(localized: "Refresh git status")
                    ) {
                        if !isRefreshing { refresh(immediate: true) }
                    }

                    headerAction(
                        systemName: "arrow.up.circle",
                        tint: (section.ahead ?? 0) > 0 ? Color.accentColor : Color.secondary,
                        visible: hovering,
                        dimmed: false,
                        help: String(localized: "Push to remote…")
                    ) {
                        pushRepo(section.root)
                    }
                }

                HStack(spacing: 5) {
                    // Branch name is the first thing dropped when narrow — a
                    // truncated "m…n" carries no information, ↑N still does.
                    branchLabel(section, showsName: !isNarrowPanel)

                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.15))
                            )
                    } else if !expanded {
                        // fixedSize: never let a squeezed layout wrap these per
                        // character — that is what blew up the row height.
                        Text("Clean")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleExpanded(group) }
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
        .onHover { hoverSectionID = $0 ? group.id : nil }
        .editMDHelp(section.shortRoot)
        // Same actions without hover, for keyboard / VoiceOver users and for
        // anyone who never discovers the hover icons.
        .contextMenu {
            Button("Refresh git status") { refresh(immediate: true) }
            Button("Push to remote…") { pushRepo(section.root) }
            if !section.files.isEmpty {
                // Whole folder on purpose: the menu hangs off the folder, not
                // off the filtered listing. The footer's "Commit all" instead
                // takes what is on screen (`group.files`) — commit what you see.
                Button("Commit all changed files in this folder…") {
                    presentCommit(urls: section.files.map(\.url))
                }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([section.workspace])
            }
        }
    }

    /// Header action icon: fixed slot, visibility by opacity, hit testing tied
    /// to that visibility.
    private func headerAction(
        systemName: String,
        tint: Color,
        visible: Bool,
        dimmed: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 10.5))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            // Tap gesture (not Button) so the first click after entering the
            // Git tab lands — see the changedRow note on acceptsFirstMouse.
            .onTapGesture(perform: action)
            .editMDHelp(help)
            .opacity(visible ? (dimmed ? 0.5 : 1) : 0)
            .allowsHitTesting(visible)
            .accessibilityHidden(!visible)
    }

    @ViewBuilder
    private func branchLabel(_ section: GitRepoSection, showsName: Bool) -> some View {
        HStack(spacing: 3) {
            if showsName {
                Text(section.branch ?? String(localized: "detached"))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // ↑N/↓M are short and always worth their few points — pinned so a
            // tight header trims the branch name instead.
            if let ahead = section.ahead, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .fixedSize()
                    .help(String(localized: "\(ahead) commit(s) to push"))
            }
            if let behind = section.behind, behind > 0 {
                Text("↓\(behind)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .help(String(localized: "\(behind) commit(s) to pull"))
            }
        }
        // Never squeeze the folder name for branch metadata.
        .layoutPriority(-1)
        .editMDHelp(section.branch ?? String(localized: "detached"))
    }

    /// Bottom of an expanded group: clean note, filter note, or bulk commit.
    @ViewBuilder
    private func sectionFooter(_ group: GitSidebarGroup) -> some View {
        if group.hiddenByFilter {
            // Dirty folder kept by a name/branch/path match: say the filter hid
            // the files rather than claiming the folder is clean.
            footerNote(Text("No files match the filter"))
        } else if !group.hasChanges {
            // Scoped to this folder — a sibling folder in the same repository
            // can still be dirty.
            footerNote(Text("No changes in this folder"))
        } else if group.files.count > 1 {
            // One commit for every markdown file listed under this folder.
            // Same sheet as the per-row action.
            Text("Commit all")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 12)
                .padding(.top, 1)
                .padding(.bottom, 4)
                .contentShape(Rectangle())
                .onTapGesture { presentCommit(urls: group.files.map(\.url)) }
                .editMDHelp(String(localized: "Commit all changed files in this folder…"))
        }
    }

    private func footerNote(_ text: Text) -> some View {
        text
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 1)
            .padding(.bottom, 4)
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
                .editMDHelp(String(localized: "Show diff…"))
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
            pruneDisclosure(for: built.sections)
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

// MARK: - Panel width

/// Sidebar width, reported from a background geometry layer.
struct GitSidebarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Group model

/// One rendered group: the snapshot section plus the files currently listed.
/// "Is this folder dirty" and the header count always come from `section`, so
/// a filter can hide rows without ever making a dirty folder look clean.
struct GitSidebarGroup: Identifiable {
    let section: GitRepoSection
    let files: [GitChangedFile]

    var id: String { section.id }
    var hasChanges: Bool { !section.files.isEmpty }
    /// Dirty folder whose files were all filtered out.
    var hiddenByFilter: Bool { files.isEmpty && hasChanges }
}

// MARK: - Disclosure rules

/// Pure expand/collapse rules for the workspace groups. The stored sets are
/// *overrides* on top of the derived default (dirty open / clean collapsed).
enum GitSidebarDisclosure {
    struct State: Equatable {
        var expanded: Set<String>
        var collapsed: Set<String>
    }

    /// While filtering every surviving group is open so matches stay visible.
    static func isExpanded(
        id: String,
        hasChanges: Bool,
        expanded: Set<String>,
        collapsed: Set<String>,
        filtering: Bool
    ) -> Bool {
        if filtering { return true }
        if expanded.contains(id) { return true }
        if collapsed.contains(id) { return false }
        return hasChanges
    }

    /// Flip one group. An override equal to the derived default is not stored —
    /// otherwise collapsing a dirty folder would keep it closed even after it
    /// goes clean and becomes dirty again.
    static func toggled(
        id: String,
        hasChanges: Bool,
        expanded: Set<String>,
        collapsed: Set<String>
    ) -> State {
        let target = !isExpanded(
            id: id, hasChanges: hasChanges,
            expanded: expanded, collapsed: collapsed, filtering: false
        )
        var next = State(expanded: expanded, collapsed: collapsed)
        next.expanded.remove(id)
        next.collapsed.remove(id)
        guard target != hasChanges else { return next }
        if target {
            next.expanded.insert(id)
        } else {
            next.collapsed.insert(id)
        }
        return next
    }

    /// Drop overrides that now agree with the derived default (`defaults[id]` =
    /// folder has changes). Unknown ids are left alone — a workspace folder can
    /// be temporarily absent from a snapshot.
    static func pruned(
        expanded: Set<String>,
        collapsed: Set<String>,
        defaults: [String: Bool]
    ) -> State {
        State(
            expanded: expanded.filter { defaults[$0] != true },
            collapsed: collapsed.filter { defaults[$0] != false }
        )
    }
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
