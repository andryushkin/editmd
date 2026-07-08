import SwiftUI
import AppKit

/// The left sidebar's Files tab: adopted workspace folders (always visible,
/// collapsible) on top, loose Finder-opened files below; an eye toggle reveals
/// hidden files with a restore action. The Outline tab reuses `OutlineSidebar`.
/// Matches the reviewed mockup `docs/design/10_workspace_sidebar.html`.
struct WorkspaceSidebar: View {
    @ObservedObject var workspace: WorkspaceModel
    let outlineContent: String
    let activeURL: URL?
    /// Left-click a file: the host decides (replace in place, or the
    /// "already open in another window" modal).
    let onOpen: (URL) -> Void
    let onJump: (Int) -> Void

    @AppStorage("sidebarTab") private var tab = "files"
    @AppStorage("sidebarShowHidden") private var showHidden = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Files").tag("files")
                Text("Outline").tag("outline")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)

            if tab == "files" {
                filesTab
            } else {
                OutlineSidebar(content: outlineContent, onJump: onJump)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: - Files tab

    private var filesTab: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                let hidden = workspace.totalHiddenCount
                if hidden > 0 {
                    Text("\(hidden) hidden")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if hidden > 0 {
                    Button { showHidden.toggle() } label: {
                        Image(systemName: showHidden ? "eye" : "eye.slash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(showHidden ? Color.accentColor : Color.secondary)
                    .help(showHidden ? "Спрятать скрытые" : "Показать скрытые")
                }
                Button { workspace.promptAddFolder() } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Folder… (⇧⌘O)")
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if workspace.workspaces.isEmpty && workspace.looseFilesToShow.isEmpty {
                        emptyState
                    }
                    ForEach(workspace.workspaces) { ws in
                        workspaceGroup(ws)
                    }
                    if !workspace.looseFilesToShow.isEmpty {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor))
                            .frame(height: 1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                        sectionHeader("Открытые файлы")
                        ForEach(workspace.looseFilesToShow, id: \.self) { url in
                            looseRow(url)
                        }
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
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
        Button { workspace.toggleCollapsed(ws) } label: {
            HStack(spacing: 6) {
                Image(systemName: ws.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(ws.name.uppercased())
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([ws.url])
            }
            Button("Убрать из сайдбара") { workspace.removeWorkspace(ws) }
        }

        if !ws.collapsed {
            ForEach(workspace.visibleFiles(ws), id: \.self) { url in
                fileRow(url, in: ws, hidden: false)
            }
            if showHidden {
                ForEach(workspace.hiddenFilesList(ws), id: \.self) { url in
                    fileRow(url, in: ws, hidden: true)
                }
            }
            // Nested subfolders as a lazy, collapsible tree.
            ForEach(workspace.subfolders(in: ws.url), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: 1,
                              activeURL: activeURL, onOpen: onOpen)
            }
        }
    }

    private func fileRow(_ url: URL, in ws: WorkspaceModel.Workspace, hidden: Bool) -> some View {
        FileRow(name: url.lastPathComponent,
                subtitle: nil,
                isActive: isActive(url),
                dimmed: hidden,
                trailing: hidden ? .restore : .hide,
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

// MARK: - Subfolder tree node

/// One node of the lazy subfolder tree: a disclosure header (chevron + folder)
/// that, when expanded, renders its own subfolders (recursively) and its direct
/// markdown files. Contents are scanned only while expanded, so a workspace with
/// thousands of nested files costs nothing until the user drills in.
private struct SubfolderNode: View {
    @ObservedObject var workspace: WorkspaceModel
    let folder: URL
    let depth: Int
    let activeURL: URL?
    let onOpen: (URL) -> Void

    private var indent: CGFloat { CGFloat(depth) * 14 }

    var body: some View {
        let expanded = workspace.isExpanded(folder)
        Button { workspace.toggleExpanded(folder) } label: {
            HStack(spacing: 6) {
                if indent > 0 { Spacer().frame(width: indent) }
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Image(systemName: expanded ? "folder.fill" : "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(folder.lastPathComponent)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        }

        if expanded {
            ForEach(workspace.subfolders(in: folder), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1,
                              activeURL: activeURL, onOpen: onOpen)
            }
            ForEach(workspace.markdownFiles(in: folder), id: \.self) { file in
                FileRow(name: file.lastPathComponent,
                        isActive: file.standardizedFileURL == activeURL?.standardizedFileURL,
                        indent: indent + 14,
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
/// wash, and a trailing action (hide / restore / pin). The row is a tappable
/// surface; the trailing control is a real button that consumes its own taps.
private struct FileRow: View {
    enum Trailing: Equatable { case hide, restore, pin(Bool), none }

    let name: String
    var subtitle: String?
    let isActive: Bool
    var dimmed = false
    var indent: CGFloat = 0
    let trailing: Trailing
    let onTap: () -> Void
    var onTrailing: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if indent > 0 { Spacer().frame(width: indent) }
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
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
        .opacity(dimmed ? 0.5 : 1)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var trailingButton: some View {
        switch trailing {
        case .hide:
            if hovering { iconButton("eye.slash", "Скрыть из списка") }
        case .restore:
            iconButton("arrow.uturn.left", "Вернуть в список")
        case .pin(let pinned):
            if pinned || hovering {
                iconButton(pinned ? "pin.fill" : "pin",
                           pinned ? "Открепить" : "Закрепить")
                    .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
            }
        case .none:
            EmptyView()
        }
    }

    private func iconButton(_ systemName: String, _ help: String) -> some View {
        Button(action: onTrailing) {
            Image(systemName: systemName).font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}
