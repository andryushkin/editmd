import SwiftUI
import AppKit
import UniformTypeIdentifiers

let sidebarFileDragContentType: UTType = .json

/// Internal drag payload. One item provider carries the complete selection so
/// a folder drop starts one transactional move instead of N independent moves.
struct SidebarFileDragPayload: Codable, Equatable, Sendable {
    static let format = "com.editmd.file-move.v1"
    static let processToken = UUID().uuidString

    let format: String
    let processToken: String
    let files: [URL]

    init(files: [URL]) {
        format = Self.format
        processToken = Self.processToken
        self.files = files
    }
}

func encodeSidebarFileDragPayload(_ payload: SidebarFileDragPayload) throws -> Data {
    try JSONEncoder().encode(payload)
}

func decodeSidebarFileDragPayload(_ data: Data) throws -> SidebarFileDragPayload {
    let payload = try JSONDecoder().decode(SidebarFileDragPayload.self, from: data)
    guard payload.format == SidebarFileDragPayload.format,
          payload.processToken == SidebarFileDragPayload.processToken else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return payload
}

/// A standard JSON representation lets AppKit negotiate the live drag session;
/// the payload marker keeps unrelated JSON from becoming a file move. The one
/// provider carries the complete group, so the destination starts one batch.
@MainActor
func sidebarFileItemProvider(files: [URL]) -> NSItemProvider {
    let payload = SidebarFileDragPayload(files: files.map(\.standardizedFileURL))
    let provider = NSItemProvider()
    guard let data = try? encodeSidebarFileDragPayload(payload) else { return provider }
    provider.registerDataRepresentation(
        forTypeIdentifier: sidebarFileDragContentType.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

/// Command-click toggles individual rows; Shift-click selects the visible range
/// from the stable anchor. A normal click replaces the group and opens the row,
/// so the visually inspected file is already the selection anchor.
@discardableResult
func updateSidebarFileSelection(
    for rawFile: URL,
    commandHeld: Bool,
    shiftHeld: Bool,
    orderedFiles rawOrderedFiles: [URL],
    selectedFiles: inout Set<URL>,
    selectionAnchor: inout URL?
) -> Bool {
    let file = rawFile.standardizedFileURL
    let orderedFiles = rawOrderedFiles.map(\.standardizedFileURL)
    if shiftHeld {
        let anchor = selectionAnchor?.standardizedFileURL
            ?? selectedFiles.first?.standardizedFileURL
            ?? file
        if let anchorIndex = orderedFiles.firstIndex(of: anchor),
           let fileIndex = orderedFiles.firstIndex(of: file) {
            let bounds = min(anchorIndex, fileIndex)...max(anchorIndex, fileIndex)
            let range = Set(orderedFiles[bounds])
            if commandHeld {
                selectedFiles.formUnion(range)
            } else {
                selectedFiles = range
            }
        } else {
            selectedFiles = [file]
            selectionAnchor = file
        }
        return false
    }
    if commandHeld {
        if selectedFiles.contains(file) {
            selectedFiles.remove(file)
        } else {
            selectedFiles.insert(file)
        }
        selectionAnchor = file
        return false
    }
    selectedFiles = [file]
    selectionAnchor = file
    return true
}

/// Whether the sidebar's multi-select highlight should be dropped when the
/// active target changes. Clears when the selection is non-empty and the newly
/// active URL is not one of the selected files (navigating to a folder, opening
/// a file from outside the sidebar, or clearing to the welcome screen); keeps it
/// when the active file is still in the selection. Pure for testing.
func shouldClearSidebarSelection(activeURL: URL?, selectedFiles: Set<URL>) -> Bool {
    guard !selectedFiles.isEmpty else { return false }
    guard let active = activeURL?.standardizedFileURL else { return true }
    return !selectedFiles.contains(active)
}

/// Dragging or invoking Move on a selected row acts on the whole selection.
/// A non-selected row remains an independent single-file operation.
func sidebarMoveFiles(
    anchor rawAnchor: URL,
    selectedFiles: Set<URL>,
    orderedFiles rawOrderedFiles: [URL]
) -> [URL] {
    let anchor = rawAnchor.standardizedFileURL
    guard selectedFiles.contains(anchor) else { return [anchor] }
    let orderedFiles = rawOrderedFiles.map(\.standardizedFileURL)
    let visible = orderedFiles.filter(selectedFiles.contains)
    let visibleSet = Set(visible)
    let remainder = selectedFiles.subtracting(visibleSet).sorted {
        $0.path.localizedStandardCompare($1.path) == .orderedAscending
    }
    return visible + remainder
}

/// Title for the per-row «Переместить…» context item. The count comes from the
/// selection alone: `sidebarMoveFiles` returns the whole selection when the
/// anchor is selected and `[anchor]` otherwise, so the visible order is not
/// needed. SwiftUI builds `.contextMenu` content eagerly for EVERY row —
/// walking `sidebarVisibleFileOrder` here made sidebar render O(rows²).
func sidebarMoveMenuTitle(anchor: URL, selectedFiles: Set<URL>) -> String {
    let count = selectedFiles.contains(anchor.standardizedFileURL)
        ? max(selectedFiles.count, 1)
        : 1
    return count > 1
        ? String(localized: "Move \(count) Files…")
        : String(localized: "Move…")
}

@MainActor
func sidebarVisibleFileOrder(
    workspace: WorkspaceModel,
    filter rawFilter: String,
    showHidden: Bool
) -> [URL] {
    let filter = rawFilter.trimmingCharacters(in: .whitespacesAndNewlines)
    func nameMatches(_ name: String) -> Bool {
        filter.isEmpty || name.localizedCaseInsensitiveContains(filter)
    }
    func filteredFolders(_ folders: [URL]) -> [URL] {
        folders.filter {
            filter.isEmpty || nameMatches($0.lastPathComponent) || workspace.isExpanded($0)
        }
    }

    var files: [URL] = []
    func appendExpandedFolder(_ folder: URL) {
        guard workspace.isExpanded(folder) else { return }
        for subfolder in filteredFolders(workspace.markdownSubfolders(in: folder)) {
            appendExpandedFolder(subfolder)
        }
        if showHidden {
            for subfolder in filteredFolders(workspace.emptySubfolders(in: folder)) {
                appendExpandedFolder(subfolder)
            }
        }
        files.append(contentsOf: workspace.visibleMarkdown(in: folder).filter {
            nameMatches($0.lastPathComponent)
        })
        if showHidden {
            files.append(contentsOf: workspace.hiddenMarkdown(in: folder).filter {
                nameMatches($0.lastPathComponent)
            })
        }
    }

    for root in workspace.workspaces where !root.collapsed {
        for subfolder in filteredFolders(workspace.markdownSubfolders(in: root.url)) {
            appendExpandedFolder(subfolder)
        }
        if showHidden {
            for subfolder in filteredFolders(workspace.emptySubfolders(in: root.url)) {
                appendExpandedFolder(subfolder)
            }
        }
        files.append(contentsOf: workspace.visibleFiles(root).filter {
            nameMatches($0.lastPathComponent)
        })
        if showHidden {
            files.append(contentsOf: workspace.hiddenFilesList(root).filter {
                nameMatches($0.lastPathComponent)
            })
        }
    }
    files.append(contentsOf: workspace.looseFilesToShow.filter {
        nameMatches($0.lastPathComponent)
    })

    var seen = Set<URL>()
    return files.compactMap {
        let file = $0.standardizedFileURL
        return seen.insert(file).inserted ? file : nil
    }
}

struct SidebarTabMigration: Equatable {
    let workspaceTab: String
    let inspectorTab: String
}

/// Maps retired document-scope tabs from the left navigator to the inspector.
func migrateSidebarTabs(workspaceTab: String, inspectorTab: String) -> SidebarTabMigration {
    switch workspaceTab {
    case "outline":
        SidebarTabMigration(workspaceTab: "files", inspectorTab: inspectorTab)
    case "review":
        SidebarTabMigration(workspaceTab: "files", inspectorTab: "review")
    default:
        SidebarTabMigration(workspaceTab: workspaceTab, inspectorTab: inspectorTab)
    }
}

func migrateWorkspaceSidebarTab(_ tab: String) -> String {
    migrateSidebarTabs(workspaceTab: tab, inspectorTab: "outline").workspaceTab
}

/// The left sidebar: Xcode-style icon toolbar switches Files / Search / Git /
/// Tags (workspace-scope). Outline and Review moved to the right inspector.
struct WorkspaceSidebar: View {
    /// Buttons in the navigator capsule (Files / Search / Git / Tags) and the
    /// narrowest pane that still shows them all — same floor rule as the
    /// inspector, see `InspectorSidebar.minimumPaneWidth`.
    nonisolated static let navigatorTabCount = 4

    nonisolated static var minimumPaneWidth: CGFloat {
        SidebarChrome.navigatorPillWidth(tabs: navigatorTabCount)
            + 2 * SidebarChrome.barPaddingH
    }

    @ObservedObject var workspace: WorkspaceModel
    let activeURL: URL?
    /// Left-click a file: the host decides (replace in place, or the
    /// "already open in another window" modal).
    let onOpen: (URL) -> Void
    /// Left-click a workspace root or subfolder: open the folder info card
    /// in the main window (and the click also toggles expand — see handlers).
    let onOpenFolder: (URL) -> Void
    @ObservedObject private var searchModel = WorkspaceSearchModel.shared
    @AppStorage("sidebarTab") private var tab = "files"
    @AppStorage("inspectorTab") private var inspectorTab = "outline"
    @AppStorage("sidebarShowHidden") private var showHidden = false
    /// Bottom filter field — filters Files tree / Git paths / Tags.
    /// Hidden on the Search tab (it has its own query field).
    @State private var filterText = ""
    @State private var selectedFiles = Set<URL>()
    @State private var selectionAnchor: URL?
    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .padding(.top, SidebarChrome.barPaddingTop)
                .padding(.bottom, SidebarChrome.barPaddingBottom)

            Group {
                switch tab {
                case "search":
                    WorkspaceSearchSidebar(
                        workspace: workspace,
                        model: searchModel,
                        onOpen: onOpen
                    )
                case "git":
                    GitSidebar(
                        workspace: workspace,
                        activeURL: activeURL,
                        filter: filterText,
                        onOpen: onOpen
                    )
                case "tags":
                    TagsSidebar(workspace: workspace, filter: filterText, onOpen: onOpen)
                default:
                    // "files" and retired keys (e.g. pre-inspector "outline") → Files.
                    filesTab
                }
            }
            // Fill remaining height so bottomBar stays pinned even when the
            // active tab has little content (empty Review).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Xcode-style bottom strip: + · Filter · eye — not used on Search.
            if tab != "search" {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the window chrome (toolbar / titlebar), not the greyer
        // under-page fill that made the sidebar look like a separate sheet.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { applySidebarTabMigration() }
        .onChange(of: tab) { _ in
            clearFileSelection()
            applySidebarTabMigration()
        }
    }

    /// Outline (plan 01) and Review (plan 08) left the workspace navigator.
    private func applySidebarTabMigration() {
        let migrated = migrateSidebarTabs(workspaceTab: tab, inspectorTab: inspectorTab)
        if migrated.inspectorTab != inspectorTab { inspectorTab = migrated.inspectorTab }
        if migrated.workspaceTab != tab { tab = migrated.workspaceTab }
    }

    private var filterQuery: String {
        filterText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isFiltering: Bool { !filterQuery.isEmpty }

    private func nameMatches(_ name: String) -> Bool {
        !isFiltering || name.localizedCaseInsensitiveContains(filterQuery)
    }

    // MARK: - Navigator toolbar (Xcode-style)

    /// Pill of icon buttons on a recessed gray well (like Xcode's navigator
    /// strip / filter field). `controlBackgroundColor` is nearly identical to
    /// `windowBackgroundColor`, so we paint an explicit adaptive fill.
    private var navigatorToolbar: some View {
        HStack(spacing: 0) {
            navTabButton(id: "files",
                         systemImage: "folder",
                         help: "Files")
            navDivider
            navTabButton(id: "search",
                         systemImage: "magnifyingglass",
                         help: String(localized: "Search — search the workspace"))
            navDivider
            navTabButton(id: "git",
                         systemImage: "arrow.triangle.branch",
                         help: "Git")
            navDivider
            navTabButton(id: "tags",
                         systemImage: "tag",
                         help: "Tags — frontmatter")
        }
        .padding(.horizontal, SidebarChrome.navPillPaddingH)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private var navDivider: some View { SidebarNavDivider() }

    private func navTabButton(id: String, systemImage: String, help: String,
                              badge: Int = 0) -> some View {
        SidebarNavTabButton(systemImage: systemImage,
                            help: help,
                            selected: tab == id,
                            badge: badge) { tab = id }
    }

    // MARK: - Bottom bar (+ · Filter · eye)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            // "+" is Files-only (folder creation/adoption). Filter stays global —
            // it also filters Git / Tags.
            if tab == "files" {
                Menu {
                    Button("New Folder…") { workspace.promptCreateFolder() }
                    Button("Open Folder…") { workspace.promptAddFolder() }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22, height: 22)
                .editMDHelp("Add Folder…")
            }

            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Filter", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )

            // Review mode: hidden files + empty (no-md) folders (Files tab only).
            if tab == "files" {
                let hidden = workspace.totalHiddenCount
                Button { showHidden.toggle() } label: {
                    Image(systemName: showHidden ? "eye" : "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(showHidden ? Color.accentColor : Color.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .editMDHelp(showHidden
                      ? String(localized: "Hide again (hidden files and empty folders)")
                      : (hidden > 0
                         ? String(localized: "Show hidden files (\(hidden)) and empty folders")
                         : String(localized: "Show hidden files and empty folders")))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Files tab

    private var filteredLoose: [URL] {
        workspace.looseFilesToShow.filter { nameMatches($0.lastPathComponent) }
    }

    private var filesTab: some View {
        // A1: opening a file re-creates the whole editor subtree (MainWindowView
        // tags FileEditor with `.id(url)` for document acquire/release), which
        // tears down and rebuilds this sidebar — a plain ScrollView loses its
        // offset and snaps to the top. We can't cheaply capture the exact prior
        // offset across the teardown, but the just-opened file is the natural
        // anchor: scroll it back into view so a mid-list pick no longer jumps to
        // the top. Worst case (row not realized / not in the tree) is a no-op,
        // i.e. today's behaviour — it never scrolls to the wrong place.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if workspace.workspaces.isEmpty && workspace.looseFilesToShow.isEmpty {
                        emptyState
                    }
                    if !filteredFavorites.isEmpty {
                        sectionHeader(String(localized: "Favorites"))
                        ForEach(filteredFavorites, id: \.self) { favorite in
                            favoriteRow(favorite)
                        }
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    ForEach(workspace.workspaces) { ws in
                        workspaceGroup(ws)
                    }
                    if !filteredLoose.isEmpty {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        sectionHeader(String(localized: "Open Files"))
                        ForEach(filteredLoose, id: \.self) { url in
                            looseRow(url)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .onAppear { scrollActiveFileIntoView(proxy) }
            .onChange(of: activeURL) { _ in
                clearStaleFileSelection()
                scrollActiveFileIntoView(proxy)
            }
        }
    }

    /// Reveal the active file's row (A1 safety net). Since the sidebar now lives
    /// in `MainChrome` and is no longer torn down on file open, its scroll offset
    /// is preserved on its own; this only nudges a newly-active file that is
    /// off-screen (opened via wiki-link, search, editmdctl…) into view. `nil`
    /// anchor = minimal scroll, so a row already visible does not move. Deferred
    /// one run-loop turn so lazy rows exist as scroll targets; anchored by the
    /// standardized URL that the tree rows tag with a matching `.id`.
    private func scrollActiveFileIntoView(_ proxy: ScrollViewProxy) {
        guard let active = activeURL?.standardizedFileURL else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(active)
        }
    }

    private var filteredFavorites: [URL] {
        workspace.favoriteFiles.filter { nameMatches($0.lastPathComponent) }
    }

    private func favoriteRow(_ url: URL) -> some View {
        let missing = workspace.isFavoriteMissing(url)
        return FileRow(
            name: url.lastPathComponent,
            icon: sidebarFileIcon(for: url),
            subtitle: missing ? String(localized: "File not found — click to remove") : nil,
            isActive: isActive(url),
            dimmed: missing,
            trailing: .none,
            onTap: {
                if let target = workspace.favoriteOpenTarget(url) { onOpen(target) }
            })
        .contextMenu {
            Button("Remove from Favorites") { workspace.removeFavorite(url) }
            if !missing {
                copyPathMenuItem(url)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No folder open")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Button("Open Folder…") { workspace.promptAddFolder() }
                .buttonStyle(.link)
                .font(.system(size: 11))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.top, 2)
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Workspace group

    @ViewBuilder private func workspaceGroup(_ ws: WorkspaceModel.Workspace) -> some View {
        let selected = isActive(ws.url)
        // Mark the owning root through its icon when the open file lives inside it.
        let ownsActive = selected || containsActiveFile(ws)
        let expanded = !ws.collapsed
        HStack(spacing: SidebarTree.rowSpacing) {
            // Chevron alone toggles expand/collapse (Finder/VS Code).
            Button {
                workspace.toggleCollapsed(ws)
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: SidebarTree.chevronWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Name: open card + ensure expanded. Re-click while already the
            // active selection AND expanded → collapse (повторное нажатие).
            // A first click on an already-expanded folder never collapses.
            Button {
                if selected && expanded {
                    workspace.collapseWorkspace(ws)
                } else {
                    workspace.expandWorkspace(ws)
                    onOpenFolder(ws.url)
                }
            } label: {
                HStack(spacing: SidebarTree.rowSpacing) {
                    Image(systemName: ownsActive ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(ownsActive ? Color.accentColor : Color.secondary)
                    Text(ws.name.uppercased())
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 3)
        .contextMenu {
            FolderContextMenu(workspace: workspace, folder: ws.url, showsOpen: true)
        }
        .fileMoveDropTarget(folder: ws.url, workspace: workspace) {
            clearFileSelection()
        }

        if !ws.collapsed {
            // Folders first (md-bearing; empty only with eye), then files.
            // contentEpoch: re-scan when New File/Folder mutates disk.
            let _ = workspace.contentEpoch
            ForEach(filteredFolders(workspace.markdownSubfolders(in: ws.url)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: 1,
                              filter: filterQuery, activeURL: activeURL,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
            }
            if showHidden {
                ForEach(filteredFolders(workspace.emptySubfolders(in: ws.url)), id: \.self) { sub in
                    SubfolderNode(workspace: workspace, folder: sub, depth: 1,
                                  filter: filterQuery, activeURL: activeURL,
                                  showHidden: showHidden, isEmptyFolder: true,
                                  selectedFiles: $selectedFiles,
                                  selectionAnchor: $selectionAnchor,
                                  onOpen: onOpen, onOpenFolder: onOpenFolder)
                }
            }
            ForEach(workspace.visibleFiles(ws).filter { nameMatches($0.lastPathComponent) },
                    id: \.self) { url in
                fileRow(url, in: ws, hidden: false)
            }
            if showHidden {
                ForEach(workspace.hiddenFilesList(ws).filter { nameMatches($0.lastPathComponent) },
                        id: \.self) { url in
                    fileRow(url, in: ws, hidden: true)
                }
            }
        }
    }

    /// Name filter: keep match, or expanded so children stay reachable.
    private func filteredFolders(_ urls: [URL]) -> [URL] {
        urls.filter { sub in
            !isFiltering
                || nameMatches(sub.lastPathComponent)
                || workspace.isExpanded(sub)
        }
    }

    private func fileRow(_ url: URL, in ws: WorkspaceModel.Workspace, hidden: Bool) -> some View {
        // depth 1 = same column as root subfolders (chevron slot reserved).
        // Visible → eye.slash hides. Hidden (only listed in review mode) → eye unhides.
        FileRow(name: url.lastPathComponent,
                icon: sidebarFileIcon(for: url),
                subtitle: nil,
                isActive: isActive(url),
                isSelected: selectedFiles.contains(url.standardizedFileURL),
                dimmed: hidden,
                depth: 1,
                trailing: hidden ? .unhide : .hide,
                onTap: { handleFileTap(url) },
                onTrailing: { hidden ? workspace.unhide(url, in: ws) : workspace.hide(url, in: ws) })
        .contextMenu {
            Button("Open in Separate Window") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button(moveMenuTitle(for: url)) { promptToMoveSelection(anchoredAt: url) }
            Button(workspace.isFavorite(url) ? "Remove from Favorites" : "Add to Favorites") {
                workspace.isFavorite(url)
                    ? workspace.removeFavorite(url)
                    : workspace.addFavorite(url)
            }
            if hidden {
                Button("Return to List") { workspace.unhide(url, in: ws) }
            } else {
                Button("Hide from List") { workspace.hide(url, in: ws) }
            }
            copyPathMenuItem(url)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                confirmAndMoveFilesToTrash(moveFiles(anchoredAt: url), workspace: workspace)
            }
        }
        .onDrag {
            sidebarFileItemProvider(files: moveFiles(anchoredAt: url))
        }
        // Scroll anchor for A1 restore — matches scrollTo(active.standardized).
        .id(url.standardizedFileURL)
    }

    // MARK: - Loose row

    private func looseRow(_ url: URL) -> some View {
        let pinned = workspace.isPinned(url)
        let dir = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return FileRow(name: url.lastPathComponent,
                       icon: sidebarFileIcon(for: url),
                       subtitle: dir,
                       isActive: isActive(url),
                       isSelected: selectedFiles.contains(url.standardizedFileURL),
                       dimmed: false,
                       trailing: .pin(pinned),
                       onTap: { handleFileTap(url) },
                       onTrailing: { pinned ? workspace.unpin(url) : workspace.pin(url) })
        .contextMenu {
            Button("Open in Separate Window") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button(moveMenuTitle(for: url)) { promptToMoveSelection(anchoredAt: url) }
            Button(pinned ? "Unpin" : "Pin") {
                pinned ? workspace.unpin(url) : workspace.pin(url)
            }
            Button("Remove from List") { workspace.removeLoose(url) }
            copyPathMenuItem(url)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                confirmAndMoveFilesToTrash(moveFiles(anchoredAt: url), workspace: workspace)
            }
        }
        .onDrag {
            sidebarFileItemProvider(files: moveFiles(anchoredAt: url))
        }
    }

    private func handleFileTap(_ url: URL) {
        let modifiers = NSEvent.modifierFlags
        let shouldOpen = updateSidebarFileSelection(
            for: url,
            commandHeld: modifiers.contains(.command),
            shiftHeld: modifiers.contains(.shift),
            orderedFiles: currentFileOrder(),
            selectedFiles: &selectedFiles,
            selectionAnchor: &selectionAnchor)
        if shouldOpen { onOpen(url) }
    }

    private func moveMenuTitle(for url: URL) -> String {
        sidebarMoveMenuTitle(anchor: url, selectedFiles: selectedFiles)
    }

    private func promptToMoveSelection(anchoredAt url: URL) {
        let files = moveFiles(anchoredAt: url)
        if promptForFileMove(files, workspace: workspace) {
            clearFileSelection()
        }
    }

    private func currentFileOrder() -> [URL] {
        sidebarVisibleFileOrder(
            workspace: workspace, filter: filterQuery, showHidden: showHidden)
    }

    private func moveFiles(anchoredAt url: URL) -> [URL] {
        sidebarMoveFiles(
            anchor: url,
            selectedFiles: selectedFiles,
            orderedFiles: currentFileOrder())
    }

    private func clearFileSelection() {
        selectedFiles.removeAll()
        selectionAnchor = nil
    }

    /// The multi-select highlight (`selectedFiles`) survives navigation, so a
    /// file stayed lit after the user opened a folder or a file from outside the
    /// sidebar. When the active target moves off the selection, drop it — unless
    /// the newly active file is still in `selectedFiles`, which stays highlighted.
    private func clearStaleFileSelection() {
        if shouldClearSidebarSelection(activeURL: activeURL, selectedFiles: selectedFiles) {
            clearFileSelection()
        }
    }

    private func isActive(_ url: URL) -> Bool {
        url.standardizedFileURL == activeURL?.standardizedFileURL
    }

    /// Active file lives under this workspace root (not the root itself).
    private func containsActiveFile(_ ws: WorkspaceModel.Workspace) -> Bool {
        guard let path = activeURL?.standardizedFileURL.path else { return false }
        let root = (ws.folderPath as NSString).standardizingPath
        return path.hasPrefix(root + "/")
    }

    /// Shared context-menu item: absolute path → pasteboard.
    @ViewBuilder
    private func copyPathMenuItem(_ url: URL) -> some View {
        Button("Copy Path") { copyPathToPasteboard(url) }
    }
}

// MARK: - Subfolder tree node

/// One node of the lazy subfolder tree: a disclosure header (chevron + folder)
/// that, when expanded, renders its own subfolders (recursively) and its direct
/// markdown files. Contents are scanned only while expanded, so a workspace with
/// thousands of nested files costs nothing until the user drills in.
private struct SubfolderNode: View {
    @ObservedObject var workspace: WorkspaceModel
    let folder: URL
    let depth: Int
    /// Empty = no filter. Same rules as the root: name match, or expanded so
    /// matching children stay reachable without a full recursive scan.
    let filter: String
    let activeURL: URL?
    let showHidden: Bool
    /// No markdown in this folder’s tree — dimmed; only listed when eye is on.
    var isEmptyFolder: Bool = false
    @Binding var selectedFiles: Set<URL>
    @Binding var selectionAnchor: URL?
    let onOpen: (URL) -> Void
    let onOpenFolder: (URL) -> Void

    private var indent: CGFloat { CGFloat(depth) * SidebarTree.indentStep }
    private var isFiltering: Bool { !filter.isEmpty }
    private var selected: Bool {
        folder.standardizedFileURL == activeURL?.standardizedFileURL
    }

    private func nameMatches(_ name: String) -> Bool {
        !isFiltering || name.localizedCaseInsensitiveContains(filter)
    }

    private func filteredFolders(_ urls: [URL]) -> [URL] {
        urls.filter { sub in
            !isFiltering
                || nameMatches(sub.lastPathComponent)
                || workspace.isExpanded(sub)
        }
    }

    var body: some View {
        let expanded = workspace.isExpanded(folder)
        let _ = workspace.contentEpoch
        HStack(spacing: SidebarTree.rowSpacing) {
            if indent > 0 { Spacer().frame(width: indent) }
            // Chevron alone toggles expand/collapse.
            Button {
                workspace.toggleExpanded(folder)
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: SidebarTree.chevronWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Name: open + expand. Re-click while selected & expanded → collapse.
            Button {
                if selected && expanded {
                    workspace.collapseFolder(folder)
                } else {
                    workspace.expandFolder(folder)
                    onOpenFolder(folder)
                }
            } label: {
                HStack(spacing: SidebarTree.rowSpacing) {
                    Image(systemName: (expanded || selected) ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        .opacity(isEmptyFolder ? 0.55 : 1)
                    Text(folder.lastPathComponent)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected
                                         ? Color.accentColor
                                         : (isEmptyFolder ? Color.secondary : Color.primary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contextMenu {
            FolderContextMenu(workspace: workspace, folder: folder, showsOpen: true)
        }
        .fileMoveDropTarget(folder: folder, workspace: workspace) {
            selectedFiles.removeAll()
            selectionAnchor = nil
        }

        if expanded {
            // md folders → empty folders (eye) → visible files → hidden files (eye).
            ForEach(filteredFolders(workspace.markdownSubfolders(in: folder)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1,
                              filter: filter, activeURL: activeURL,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
            }
            if showHidden {
                ForEach(filteredFolders(workspace.emptySubfolders(in: folder)), id: \.self) { sub in
                    SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1,
                                  filter: filter, activeURL: activeURL,
                                  showHidden: showHidden, isEmptyFolder: true,
                                  selectedFiles: $selectedFiles,
                                  selectionAnchor: $selectionAnchor,
                                  onOpen: onOpen, onOpenFolder: onOpenFolder)
                }
            }
            ForEach(workspace.visibleMarkdown(in: folder).filter { nameMatches($0.lastPathComponent) },
                    id: \.self) { file in
                nestedFileRow(file, hidden: false)
            }
            if showHidden {
                ForEach(workspace.hiddenMarkdown(in: folder).filter { nameMatches($0.lastPathComponent) },
                        id: \.self) { file in
                    nestedFileRow(file, hidden: true)
                }
            }
        }
    }

    private func nestedFileRow(_ file: URL, hidden: Bool) -> some View {
        FileRow(name: file.lastPathComponent,
                icon: sidebarFileIcon(for: file),
                isActive: file.standardizedFileURL == activeURL?.standardizedFileURL,
                isSelected: selectedFiles.contains(file.standardizedFileURL),
                dimmed: hidden,
                depth: depth + 1,
                trailing: hidden ? .unhide : .hide,
                onTap: { handleFileTap(file) },
                onTrailing: {
                    if hidden { workspace.unhide(file) } else { workspace.hide(file) }
                })
        .contextMenu {
            Button("Open in Separate Window") {
                AppState.shared.openInSeparateWindow(file)
            }
            Divider()
            Button(moveMenuTitle(for: file)) { promptToMoveSelection(anchoredAt: file) }
            Button(workspace.isFavorite(file) ? "Remove from Favorites" : "Add to Favorites") {
                workspace.isFavorite(file)
                    ? workspace.removeFavorite(file)
                    : workspace.addFavorite(file)
            }
            if hidden {
                Button("Return to List") { workspace.unhide(file) }
            } else {
                Button("Hide from List") { workspace.hide(file) }
            }
            Button("Copy Path") { copyPathToPasteboard(file) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
            Divider()
            Button("Move to Trash", role: .destructive) {
                confirmAndMoveFilesToTrash(moveFiles(anchoredAt: file), workspace: workspace)
            }
        }
        .onDrag {
            sidebarFileItemProvider(files: moveFiles(anchoredAt: file))
        }
        // Scroll anchor for A1 restore (tree rows are unique per file).
        .id(file.standardizedFileURL)
    }

    private func handleFileTap(_ file: URL) {
        let modifiers = NSEvent.modifierFlags
        let shouldOpen = updateSidebarFileSelection(
            for: file,
            commandHeld: modifiers.contains(.command),
            shiftHeld: modifiers.contains(.shift),
            orderedFiles: currentFileOrder(),
            selectedFiles: &selectedFiles,
            selectionAnchor: &selectionAnchor)
        if shouldOpen { onOpen(file) }
    }

    private func moveMenuTitle(for file: URL) -> String {
        sidebarMoveMenuTitle(anchor: file, selectedFiles: selectedFiles)
    }

    private func promptToMoveSelection(anchoredAt file: URL) {
        let files = moveFiles(anchoredAt: file)
        if promptForFileMove(files, workspace: workspace) {
            selectedFiles.removeAll()
            selectionAnchor = nil
        }
    }

    private func currentFileOrder() -> [URL] {
        sidebarVisibleFileOrder(workspace: workspace, filter: filter, showHidden: showHidden)
    }

    private func moveFiles(anchoredAt file: URL) -> [URL] {
        sidebarMoveFiles(
            anchor: file,
            selectedFiles: selectedFiles,
            orderedFiles: currentFileOrder())
    }
}
