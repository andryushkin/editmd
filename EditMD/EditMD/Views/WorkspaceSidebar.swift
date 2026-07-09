import SwiftUI
import AppKit

/// The left sidebar: Xcode-style icon toolbar switches Files / Outline;
/// Files shows adopted workspace folders (collapsible tree) + loose
/// Finder-opened files; Outline reuses `OutlineSidebar`.
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

    @AppStorage("sidebarTab") private var tab = "files"
    @AppStorage("sidebarShowHidden") private var showHidden = false
    /// Bottom filter field — filters Files tree / Outline headings by name.
    @State private var filterText = ""

    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .padding(.top, SidebarChrome.barPaddingTop)
                .padding(.bottom, SidebarChrome.barPaddingBottom)

            if tab == "files" {
                filesTab
            } else {
                OutlineSidebar(content: outlineContent, filter: filterText, onJump: onJump)
            }

            // Xcode-style bottom strip: + · Filter · eye
            bottomBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the window chrome (toolbar / titlebar), not the greyer
        // under-page fill that made the sidebar look like a separate sheet.
        .background(Color(nsColor: .windowBackgroundColor))
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
            // Xcode-style hairline between navigator modes.
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 3)
            navTabButton(id: "outline",
                         systemImage: "list.bullet.indent",
                         help: "Outline")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color(nsColor: SidebarChrome.wellColor))
        )
    }

    private func navTabButton(id: String, systemImage: String, help: String) -> some View {
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
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    // MARK: - Bottom bar (+ · Filter · eye)

    private var bottomBar: some View {
        HStack(spacing: 6) {
            Menu {
                Button("New Workspace…") { workspace.promptAddFolder() }
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
            .editMDHelp("New Workspace…")

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

            // Review mode: list hidden files so each can be un-hidden via its row eye.
            let hidden = workspace.totalHiddenCount
            Button { showHidden.toggle() } label: {
                Image(systemName: showHidden ? "eye" : "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(showHidden ? Color.accentColor : Color.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(hidden == 0 && !showHidden)
            .opacity(hidden == 0 && !showHidden ? 0.35 : 1)
            .editMDHelp(showHidden
                  ? "Скрыть снова (режим просмотра скрытых)"
                  : (hidden > 0
                     ? "Показать скрытые (\(hidden)) — затем глаз у файла вернёт его в список"
                     : "Нет скрытых файлов"))
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
                    Image(systemName: selected ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    Text(ws.name.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary)
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
                .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([ws.url])
            }
            Button("Убрать из сайдбара") { workspace.removeWorkspace(ws) }
        }

        if !ws.collapsed {
            // Folders first, then root files (Finder / VS Code order).
            // contentEpoch: re-scan when New File/Folder mutates disk.
            let _ = workspace.contentEpoch
            ForEach(filteredSubfolders(in: ws.url), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: 1,
                              filter: filterQuery, activeURL: activeURL,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
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

    /// Folders whose name matches the filter, or that are expanded (children may match).
    private func filteredSubfolders(in folder: URL) -> [URL] {
        workspace.subfolders(in: folder).filter { sub in
            !isFiltering
                || nameMatches(sub.lastPathComponent)
                || workspace.isExpanded(sub)
        }
    }

    private func fileRow(_ url: URL, in ws: WorkspaceModel.Workspace, hidden: Bool) -> some View {
        // depth 1 = same column as root subfolders (chevron slot reserved).
        // Visible → eye.slash hides. Hidden (only listed in review mode) → eye unhides.
        FileRow(name: url.lastPathComponent,
                subtitle: nil,
                isActive: isActive(url),
                dimmed: hidden,
                depth: 1,
                trailing: hidden ? .unhide : .hide,
                onTap: { onOpen(url) },
                onTrailing: { hidden ? workspace.unhide(url, in: ws) : workspace.hide(url, in: ws) })
        .contextMenu {
            Button("Открыть в отдельном окне") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            if hidden {
                Button("Вернуть в список") { workspace.unhide(url, in: ws) }
            } else {
                Button("Скрыть из списка") { workspace.hide(url, in: ws) }
            }
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    // MARK: - Loose row

    private func looseRow(_ url: URL) -> some View {
        let pinned = workspace.isPinned(url)
        let dir = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return FileRow(name: url.lastPathComponent,
                       subtitle: dir,
                       isActive: isActive(url),
                       dimmed: false,
                       trailing: .pin(pinned),
                       onTap: { onOpen(url) },
                       onTrailing: { pinned ? workspace.unpin(url) : workspace.pin(url) })
        .contextMenu {
            Button("Открыть в отдельном окне") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button(pinned ? "Открепить" : "Закрепить") {
                pinned ? workspace.unpin(url) : workspace.pin(url)
            }
            Button("Убрать из списка") { workspace.removeLoose(url) }
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func isActive(_ url: URL) -> Bool {
        url.standardizedFileURL == activeURL?.standardizedFileURL
    }
}

// MARK: - Tree layout

/// Shared metrics so folder headers and file rows at the same depth line up:
/// leading indent → fixed chevron column (real or empty) → icon → name.
private enum SidebarTree {
    static let indentStep: CGFloat = 14
    static let chevronWidth: CGFloat = 10
    static let rowSpacing: CGFloat = 6
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

    private func visibleSubfolders(in folder: URL) -> [URL] {
        workspace.subfolders(in: folder).filter { sub in
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
                    Text(folder.lastPathComponent)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Color.accentColor : Color.primary)
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
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }

        if expanded {
            // Folders first, then files — same order as the workspace root.
            ForEach(visibleSubfolders(in: folder), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1,
                              filter: filter, activeURL: activeURL,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
            }
            ForEach(workspace.markdownFiles(in: folder).filter { nameMatches($0.lastPathComponent) },
                    id: \.self) { file in
                FileRow(name: file.lastPathComponent,
                        isActive: file.standardizedFileURL == activeURL?.standardizedFileURL,
                        depth: depth + 1,
                        trailing: .none,
                        onTap: { onOpen(file) })
                    .contextMenu {
                        Button("Открыть в отдельном окне") {
                            AppState.shared.openInSeparateWindow(file)
                        }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
            }
        }
    }
}

// MARK: - Row

/// One file row: doc icon, name (+ optional path subtitle), active tint, hover
/// wash, and a trailing action (hide / unhide / pin). The row is a tappable
/// surface; the trailing control is a real button that consumes its own taps.
///
/// `depth > 0` places the row in the folder tree: leading indent + empty chevron
/// slot so the doc icon lines up with folder icons at the same depth.
/// `depth == 0` is for loose / non-tree rows (no chevron column).
private struct FileRow: View {
    /// Per-row trailing control.
    /// - `hide`: eye.slash on hover → remove from normal list
    /// - `unhide`: eye always visible (review mode) → return to list
    enum Trailing: Equatable { case hide, unhide, pin(Bool), none }

    let name: String
    var subtitle: String?
    let isActive: Bool
    /// Hidden file shown in review mode — soften label, keep eye button crisp.
    var dimmed = false
    var depth: Int = 0
    let trailing: Trailing
    let onTap: () -> Void
    var onTrailing: () -> Void = {}

    @State private var hovering = false

    private var indent: CGFloat { CGFloat(depth) * SidebarTree.indentStep }

    var body: some View {
        HStack(spacing: SidebarTree.rowSpacing) {
            if indent > 0 { Spacer().frame(width: indent) }
            // Reserve the chevron column so file icons align with folder icons.
            if depth > 0 {
                Color.clear.frame(width: SidebarTree.chevronWidth, height: 1)
            }
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .opacity(dimmed ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive
                                     ? AnyShapeStyle(Color.accentColor)
                                     : (dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
            trailingButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive
                      ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                      : (hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        )
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailingButton: some View {
        switch trailing {
        case .hide:
            // Only on hover — keep the normal list clean.
            if hovering {
                iconButton("eye.slash", "Скрыть из списка", accent: false)
            }
        case .unhide:
            // Always on: this is how you restore a file after bottom-eye review.
            iconButton("eye", "Вернуть в список", accent: true)
        case .pin(let pinned):
            if pinned || hovering {
                iconButton(pinned ? "pin.fill" : "pin",
                           pinned ? "Открепить" : "Закрепить",
                           accent: pinned)
            }
        case .none:
            EmptyView()
        }
    }

    private func iconButton(_ systemName: String, _ help: String, accent: Bool) -> some View {
        Button(action: onTrailing) {
            Image(systemName: systemName).font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent ? Color.accentColor : Color.secondary)
        .editMDHelp(help)
    }
}
