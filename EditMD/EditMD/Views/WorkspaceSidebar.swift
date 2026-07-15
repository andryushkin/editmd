import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static let editMDFileMove = UTType(exportedAs: "com.editmd.file-move")
}

/// Internal drag payload. One item provider carries the complete selection so
/// a folder drop starts one transactional move instead of N independent moves.
struct SidebarFileDragPayload: Codable, Equatable, Sendable {
    let files: [URL]
}

func encodeSidebarFileDragPayload(_ payload: SidebarFileDragPayload) throws -> Data {
    try JSONEncoder().encode(payload)
}

func decodeSidebarFileDragPayload(_ data: Data) throws -> SidebarFileDragPayload {
    try JSONDecoder().decode(SidebarFileDragPayload.self, from: data)
}

/// Explicit provider registration avoids the custom Codable Transferable
/// import failure seen in live SwiftUI drag sessions. The one provider still
/// carries the complete group, so the destination starts one batch move.
@MainActor
func sidebarFileItemProvider(files: [URL]) -> NSItemProvider {
    let payload = SidebarFileDragPayload(files: files.map(\.standardizedFileURL))
    let provider = NSItemProvider()
    guard let data = try? encodeSidebarFileDragPayload(payload) else { return provider }
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.editMDFileMove.identifier,
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

/// The left sidebar: Xcode-style icon toolbar switches Files / Outline / Git;
/// Files shows adopted workspace folders (collapsible tree) + loose
/// Finder-opened files; Outline reuses `OutlineSidebar`; Git is
/// workspace-scoped status + Commit/Push.
struct WorkspaceSidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    let outlineContent: String
    let activeURL: URL?
    /// Left-click a file: the host decides (replace in place, or the
    /// "already open in another window" modal).
    let onOpen: (URL) -> Void
    /// Left-click a workspace root or subfolder: open the folder info card
    /// in the main window (and the click also toggles expand — see handlers).
    let onOpenFolder: (URL) -> Void
    let onJump: (Int) -> Void

    @ObservedObject private var review = ReviewModel.shared
    @AppStorage("sidebarTab") private var tab = "files"
    @AppStorage("sidebarShowHidden") private var showHidden = false
    /// Bottom filter field — filters Files tree / Outline headings / Git paths.
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
                case "outline":
                    OutlineSidebar(content: outlineContent, filter: filterText, onJump: onJump)
                case "git":
                    GitSidebar(
                        workspace: workspace,
                        activeURL: activeURL,
                        filter: filterText,
                        onOpen: onOpen
                    )
                case "review":
                    ReviewSidebar(review: review, filter: filterText, onJump: onJump)
                case "tags":
                    TagsSidebar(workspace: workspace, filter: filterText, onOpen: onOpen)
                default:
                    filesTab
                }
            }
            // Fill remaining height so bottomBar stays pinned even when the
            // active tab has little content (empty Outline / short Review).
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // Xcode-style bottom strip: + · Filter · eye
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the window chrome (toolbar / titlebar), not the greyer
        // under-page fill that made the sidebar look like a separate sheet.
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: tab) { _ in clearFileSelection() }
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
            navTabButton(id: "outline",
                         systemImage: "list.bullet.indent",
                         help: "Outline")
            navDivider
            navTabButton(id: "git",
                         systemImage: "arrow.triangle.branch",
                         help: "Git")
            navDivider
            navTabButton(id: "review",
                         systemImage: "text.bubble",
                         help: "Review — метки (удобнее в Preview)",
                         badge: review.openCount)
            navDivider
            navTabButton(id: "tags",
                         systemImage: "tag",
                         help: "Tags — frontmatter")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    /// Xcode-style hairline between navigator modes.
    private var navDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
    }

    private func navTabButton(id: String, systemImage: String, help: String,
                              badge: Int = 0) -> some View {
        let selected = tab == id
        return Button {
            tab = id
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .background(
                    Circle()
                        .fill(selected ? Color.accentColor : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if badge > 0 && !selected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .editMDHelp(badge > 0 ? "\(help) · \(badge) открытых" : help)
    }

    // MARK: - Bottom bar (+ · Filter · eye)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            // "+" is Files-only (folder creation/adoption). Filter stays global —
            // it also filters Outline / Git / Review.
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
                      ? "Скрыть снова (скрытые файлы и пустые папки)"
                      : (hidden > 0
                         ? "Показать скрытые файлы (\(hidden)) и пустые папки"
                         : "Показать скрытые файлы и пустые папки"))
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
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                if workspace.workspaces.isEmpty && workspace.looseFilesToShow.isEmpty {
                    emptyState
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
                    sectionHeader("Открытые файлы")
                    ForEach(filteredLoose, id: \.self) { url in
                        looseRow(url)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
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
        // A6: also highlight the root when the open file lives inside this workspace.
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
                        .font(.system(size: 10.5, weight: ownsActive ? .bold : .semibold))
                        .foregroundStyle(ownsActive ? Color.accentColor : Color.secondary)
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
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(ownsActive ? Color.accentColor.opacity(0.14) : Color.clear)
        )
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
            Button("Открыть в отдельном окне") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button(moveMenuTitle(for: url)) { promptToMoveSelection(anchoredAt: url) }
            if hidden {
                Button("Вернуть в список") { workspace.unhide(url, in: ws) }
            } else {
                Button("Скрыть из списка") { workspace.hide(url, in: ws) }
            }
            copyPathMenuItem(url)
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .onDrag {
            sidebarFileItemProvider(files: moveFiles(anchoredAt: url))
        }
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
            Button("Открыть в отдельном окне") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button(moveMenuTitle(for: url)) { promptToMoveSelection(anchoredAt: url) }
            Button(pinned ? "Открепить" : "Закрепить") {
                pinned ? workspace.unpin(url) : workspace.pin(url)
            }
            Button("Убрать из списка") { workspace.removeLoose(url) }
            copyPathMenuItem(url)
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
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
        let count = moveFiles(anchoredAt: url).count
        return count > 1 ? "Переместить \(count) файла…" : "Переместить…"
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
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        }
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
            Button("Открыть в отдельном окне") {
                AppState.shared.openInSeparateWindow(file)
            }
            Divider()
            Button(moveMenuTitle(for: file)) { promptToMoveSelection(anchoredAt: file) }
            if hidden {
                Button("Вернуть в список") { workspace.unhide(file) }
            } else {
                Button("Скрыть из списка") { workspace.hide(file) }
            }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        }
        .onDrag {
            sidebarFileItemProvider(files: moveFiles(anchoredAt: file))
        }
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
        let count = moveFiles(anchoredAt: file).count
        return count > 1 ? "Переместить \(count) файла…" : "Переместить…"
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
