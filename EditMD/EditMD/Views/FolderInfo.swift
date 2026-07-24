import SwiftUI
import AppKit
import UniformTypeIdentifiers


/// One source of truth for folder context commands across the sidebar and the
/// folder info card. Root-only identity/removal actions appear only for an
/// adopted workspace root; creation and path actions work for every folder.
struct FolderContextMenu: View {
    @ObservedObject var workspace: WorkspaceModel
    let folder: URL
    var showsOpen = false

    private var rootWorkspace: WorkspaceModel.Workspace? {
        workspace.workspaceRoot(at: folder)
    }

    var body: some View {
        if showsOpen {
            Button("Open") { AppState.shared.openInMainWindow(folder) }
            Divider()
        }
        Button("New File…") {
            promptCreateMarkdownFile(in: folder, workspace: workspace)
        }
        Button("New Folder…") {
            promptCreateSubfolder(in: folder, workspace: workspace)
        }
        Divider()
        if let rootWorkspace {
            Button("Change Display Name…") {
                promptForWorkspaceDisplayName(rootWorkspace, workspace: workspace)
            }
            Button("Rename Folder on Disk…") {
                promptForWorkspaceFolderRename(rootWorkspace, workspace: workspace)
            }
            Divider()
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        Divider()
        if let rootWorkspace {
            Button("Remove from Sidebar") {
                workspace.removeWorkspace(rootWorkspace)
            }
        }
        Button("Move to Trash", role: .destructive) {
            confirmAndMoveFolderToTrash(folder, workspace: workspace)
        }
    }
}


// MARK: - Main-window host (sidebar + card)

/// Main-window content when `AppState.currentURL` is a directory: same
/// workspace sidebar as the editor, center pane = folder card.
struct FolderInfoHost: View {
    let folderURL: URL

    @ObservedObject private var workspace = WorkspaceModel.shared
    // Shared with the editor's right inspector — the toggle lives in `MainChrome`
    // (enabled on the folder branch too); this host renders the folder pane.
    @AppStorage("inspectorVisible") private var inspectorVisible = false
    @AppStorage("inspectorWidth") private var inspectorWidth = InspectorPane.defaultWidth

    private var windowTitle: String {
        workspace.workspaceRoot(at: folderURL)?.name ?? folderURL.lastPathComponent
    }

    // The workspace sidebar + its toggle are provided by `MainChrome`; this
    // host renders the folder card plus an optional right inspector pane. No
    // document / editor — File▸Save and Format stay disabled via nil focus.
    var body: some View {
        GeometryReader { geo in
            // Same single-side clamp as the editor: the card keeps its floor as
            // the window narrows, the inspector absorbs the deficit.
            let panes = resolveSidePaneWidths(
                available: geo.size.width,
                sidebarWidth: 0,
                inspectorWidth: InspectorPane.clampWidth(inspectorWidth),
                sidebarVisible: false,
                inspectorVisible: inspectorVisible)
            HStack(spacing: 0) {
                FolderInfoCard(folderURL: folderURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspectorVisible {
                    PaneDivider(space: .named("folderPanes")) { x in
                        inspectorWidth = preferredPaneWidthFromDrag(
                            displayWidth: geo.size.width - x, scale: panes.scale,
                            range: InspectorPane.widthRange)
                    }
                    .zIndex(1)
                    FolderInspectorPanel(folderURL: folderURL)
                        .frame(width: panes.inspector)
                }
            }
            .coordinateSpace(name: "folderPanes")
            .animation(.easeInOut(duration: 0.15), value: inspectorVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowAccessor { window in
            window.representedURL = folderURL
            window.title = windowTitle
        })
    }

}

// MARK: - Nested tree row (separate type — recursive `some View` is illegal)

private struct FolderTreeRowView: View {
    @ObservedObject var workspace: WorkspaceModel
    let node: FolderTreeNode
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                AppState.shared.openInMainWindow(node.url)
            } label: {
                HStack(spacing: 6) {
                    if depth > 0 {
                        Spacer().frame(width: CGFloat(depth) * 14)
                    }
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(node.url.lastPathComponent)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(node.markdownCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, 2)
            .contextMenu {
                FolderContextMenu(
                    workspace: workspace,
                    folder: node.url,
                    showsOpen: true)
            }
            ForEach(node.children) { child in
                FolderTreeRowView(workspace: workspace, node: child, depth: depth + 1)
            }
        }
    }
}

// MARK: - Card

struct FolderInfoCard: View {
    let folderURL: URL

    @ObservedObject private var workspace = WorkspaceModel.shared
    @ObservedObject private var editorSettings = EditorSettings.shared
    @State private var showCopiedToast = false
    @State private var toastHideTask: Task<Void, Never>?
    @State private var treeStats: FolderTreeStats?
    /// Folder `treeStats` was computed for. A body render can briefly see a new
    /// `folderURL` paired with the previous folder's stats (before `onChange`
    /// reloads); `currentStats` treats that mismatch as no data.
    @State private var loadedPath: String?
    @State private var statsLoading = true
    @State private var statsTask: Task<Void, Never>?
    /// README/index of the folder — refreshed with the stats scan; the body
    /// must not list the directory synchronously (1600-file folders).
    @State private var homeDoc: URL?
    /// Folder `homeDoc` was probed for — like `loadedPath`, guards the frame
    /// where `folderURL` changed but the probe hasn't returned (the README/index
    /// button would otherwise briefly point at the previous folder's home doc).
    @State private var homeDocPath: String?

    /// Preview H1 pixel size: body `fontSize` × `elements.h1.sizeScale`
    /// (same formula as CSS `h1 { font-size: Nem }` in `previewHTMLPage`).
    private var previewH1Size: CGFloat {
        let p = editorSettings.preview
        return p.fontSize * p.elements.h1.sizeScale
    }

    private var previewH1Font: Font {
        let weight = (editorSettings.preview.elements.h1.weight ?? .bold).swiftUIWeight
        let family = editorSettings.preview.fontFamily
        if !family.isEmpty {
            return .custom(family, size: previewH1Size).weight(weight)
        }
        return .system(size: previewH1Size, weight: weight)
    }

    private var displayPath: String {
        (folderURL.path as NSString).abbreviatingWithTildeInPath
    }

    private var rootWorkspace: WorkspaceModel.Workspace? {
        workspace.workspaceRoot(at: folderURL)
    }

    /// `treeStats`, but only when it belongs to the folder on screen — guards the
    /// one-frame window where `folderURL` has changed but the reload hasn't run.
    private var currentStats: FolderTreeStats? {
        loadedPath == folderURL.standardizedFileURL.path ? treeStats : nil
    }

    /// `homeDoc`, but only when it belongs to the folder on screen (same guard as
    /// `currentStats`, for the README/index button in the action strip).
    private var currentHomeDoc: URL? {
        homeDocPath == folderURL.standardizedFileURL.path ? homeDoc : nil
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: FolderGridTile.width, maximum: FolderGridTile.width),
                  spacing: 10)]
    }

    var body: some View {
        // Top action strip shares SidebarChrome padding with Files/Outline so
        // both pills sit on one horizontal band across the split.
        VStack(spacing: 0) {
            actionStrip
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    // Future: git status strip (branch / dirty / pull·push) when git lands.
                    contentList
                    nestedFolderTree
                    Spacer(minLength: 0)
                }
                // Cap the reading column so full-width rows (subfolder tree)
                // don't stretch edge-to-edge on a wide window — the trailing
                // count would otherwise drift far from its folder name.
                .frame(maxWidth: SidebarChrome.maxReadingWidth, alignment: .leading)
                // Left (and right) field = Preview mode insetH.
                .padding(.horizontal, contentLeading)
                // Top matches first workspace row under the sidebar navigator.
                .padding(.top, SidebarChrome.firstContentTop)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .contextMenu {
            FolderContextMenu(workspace: workspace, folder: folderURL)
        }
        .fileMoveDropTarget(folder: folderURL, workspace: workspace)
        .overlay(alignment: .bottom) { copiedToast }
        .onAppear { reloadTreeStats() }
        .onChange(of: folderURL) { _ in
            // New folder: `currentStats` / `currentHomeDoc` already hide the old
            // tree and README button (path mismatch) until reload lands.
            reloadTreeStats()
        }
        .onChange(of: workspace.contentEpoch) { _ in reloadTreeStats() }
        .onDisappear {
            toastHideTask?.cancel()
            statsTask?.cancel()
        }
    }

    /// Always async: cache hit paints immediately; miss shows "Counting…"
    /// while a utility Task walks the tree (cancellable on folder/epoch change).
    private func reloadTreeStats() {
        let path = folderURL.standardizedFileURL.path
        let epoch = workspace.contentEpoch
        if let cached = FolderStatsCache.lookup(path: path, epoch: epoch) {
            treeStats = cached
            loadedPath = path
            statsLoading = false
            // Stats came from cache, but README/index still needs a (cheap)
            // async probe — never a synchronous listing on the main actor.
            statsTask?.cancel()
            let root = folderURL.standardizedFileURL
            statsTask = Task {
                let home = await Task.detached(priority: .utility) {
                    homeDocument(in: root)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard path == folderURL.standardizedFileURL.path else { return }
                    homeDoc = home
                    homeDocPath = path
                }
            }
            return
        }
        // Miss (epoch bumped, or @State dropped on view recreation). Seed from
        // any cached entry for this path so we revalidate against a visible tree
        // rather than a blank one — keeps activation `contentEpoch` bumps (e.g.
        // swiping back from another Space) and re-mounts flicker-free.
        if currentStats == nil, let any = FolderStatsCache.lookupAny(path: path) {
            treeStats = any.stats
            loadedPath = path
        }
        // Cold load (no data for this folder at all) shows the counting state;
        // a visible stale tree keeps its real counts — the spinner over an
        // already-drawn tree is exactly what SWR is meant to avoid.
        statsLoading = currentStats == nil
        // Detached task owns cancellation: cancelling `statsTask` propagates into
        // `scanFolderTreeStats`'s `Task.isCancelled` checks, actually aborting the
        // walk (a nested `Task.detached` would not inherit the cancel).
        statsTask?.cancel()
        let root = folderURL.standardizedFileURL
        statsTask = Task.detached(priority: .utility) {
            let stats = scanFolderTreeStats(at: root)
            let home = homeDocument(in: root)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Drop result if the card moved on (new folder / epoch).
                guard path == folderURL.standardizedFileURL.path,
                      epoch == workspace.contentEpoch else { return }
                FolderStatsCache.store(path: path, epoch: epoch, stats: stats)
                treeStats = stats
                loadedPath = path
                homeDoc = home
                homeDocPath = path
                statsLoading = false
            }
        }
    }

    // MARK: Action strip (buttons + compact tree counts)

    private var actionStrip: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 2) {
                iconButton("doc.badge.plus", String(localized: "New File"), action: newFile)
                iconButton("folder.badge.plus", String(localized: "New Folder"), action: newFolder)
                iconButton("arrow.up.right.square", String(localized: "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                }
                if let rootWorkspace {
                    folderIdentityMenu(rootWorkspace)
                }
                if let home = currentHomeDoc {
                    let isReadme = home.lastPathComponent.lowercased().hasPrefix("readme")
                    iconButton("book", isReadme
                               ? String(localized: "Open README")
                               : String(localized: "Open index")) {
                        AppState.shared.openInMainWindow(home)
                    }
                }
            }
            // Counts flush after the buttons — whole group stays on the left.
            compactStats
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same left rail as title / first grid icon / section headers.
        .padding(.leading, contentLeading + contentIconRail)
        .padding(.trailing, contentLeading)
        .frame(height: SidebarChrome.barHeight)
    }

    /// Preview horizontal field (Settings ▸ Preview ▸ inset).
    private var contentLeading: CGFloat { editorSettings.preview.insetH }

    /// Shared left rail for title icon, section headers, and first grid icons
    /// (grid icons sit centered in each tile → inset from the cell edge).
    private var contentIconRail: CGFloat {
        max(0, FolderGridTile.iconLeadingInset - FolderGridTile.headerOpticalNudge)
    }

    /// Full-tree counts on the action row — small secondary text so it fits.
    private var compactStats: some View {
        HStack(spacing: 2) {
            if statsLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            // No per-stat editMDHelp — AppKit tooltip views inflate spacing.
            compactStat(systemImage: "doc.text",
                        value: statsLoading ? "…" : "\(currentStats?.markdownCount ?? 0)")
            Text("·")
                .foregroundStyle(.quaternary)
                .font(.system(size: 11))
                .padding(.horizontal, 1)
            compactStat(systemImage: "folder",
                        value: statsLoading ? "…" : "\(currentStats?.subfolderCount ?? 0)")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .fixedSize(horizontal: true, vertical: false)
        .editMDHelp(statsLoading
                    ? String(localized: "Counting…")
                    : String(localized: "Whole tree: \(currentStats?.markdownCount ?? 0) files, \(currentStats?.subfolderCount ?? 0) subfolders"))
    }

    private func compactStat(systemImage: String, value: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .medium))
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
    }

    /// System accessory-bar button; tooltip = gray AppKit plaque.
    private func iconButton(_ systemImage: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        AccessoryBarButton(glyph: .symbol(systemImage), help: help, action: action)
    }

    private func folderIdentityMenu(_ ws: WorkspaceModel.Workspace) -> some View {
        AccessoryBarMenu(systemImage: "pencil",
                         help: String(localized: "Folder name")) {
            Button("Change Display Name…") {
                promptForWorkspaceDisplayName(ws, workspace: workspace)
            }
            Button("Rename Folder on Disk…") {
                promptForWorkspaceFolderRename(ws, workspace: workspace)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: previewH1Size))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                Text(rootWorkspace?.name ?? folderURL.lastPathComponent)
                    .font(previewH1Font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let ws = rootWorkspace,
               let displayName = ws.displayName,
               displayName != ws.folderName {
                Text("Folder: \(ws.folderName)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            // Path under the folder icon (same leading as the glyph).
            Button(action: copyPath) {
                Text(displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .editMDHelp(String(localized: "Copy Path"))
        }
        .padding(.leading, contentIconRail)
    }

    // MARK: Nested folder tree (D8)

    /// Full-depth tree of folders with .md counts — data only from cached scan.
    @ViewBuilder private var nestedFolderTree: some View {
        let nodes = currentStats?.folderTree ?? []
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(String(localized: "SUBFOLDERS"))
                ForEach(nodes) { node in
                    FolderTreeRowView(workspace: workspace, node: node, depth: 0)
                }
            }
            .padding(.leading, contentIconRail)
        }
    }

    // MARK: Content grid (direct children + hidden section)

    /// Main grid: folders with md + visible files.
    /// Bottom sections (like hidden files): "Empty Folders", then "Hidden".
    private var contentList: some View {
        let _ = workspace.contentEpoch
        let mdFolders = currentStats?.directMarkdownFolders ?? []
        let allEmpty = currentStats?.directEmptyFolders ?? []
        // User-created empty folders join the main grid; the rest sink to the
        // dimmed "Empty Folders" section (matching the sidebar's split).
        let folders = mdFolders + allEmpty.filter(workspace.isKeptOrHoldsKept)
        let emptyFolders = allEmpty.filter { !workspace.isKeptOrHoldsKept($0) }
        let visible = workspace.visibleMarkdown(in: folderURL)
        let hidden = workspace.hiddenMarkdown(in: folderURL)
        let empty = !statsLoading
            && folders.isEmpty && emptyFolders.isEmpty
            && visible.isEmpty && hidden.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            if empty {
                Text("No files")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .padding(.leading, FolderGridTile.iconLeadingInset)
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                    ForEach(folders, id: \.self) { sub in
                        folderTile(sub, dimmed: false)
                    }
                    ForEach(visible, id: \.self) { file in
                        FolderGridTile(kind: .file, name: file.lastPathComponent,
                                       fileIcon: sidebarFileIcon(for: file),
                                       dimmed: false, showHide: true, showUnhide: false,
                                       onTap: { AppState.shared.openInMainWindow(file) },
                                       onTrailing: { workspace.hide(file) })
                        .contextMenu {
                            FolderInfoFileContextMenu(
                                workspace: workspace, file: file, hidden: false)
                        }
                    }
                }
                if !emptyFolders.isEmpty {
                    sectionHeader(String(localized: "EMPTY FOLDERS"))
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                        ForEach(emptyFolders, id: \.self) { sub in
                            folderTile(sub, dimmed: true)
                        }
                    }
                }
                if !hidden.isEmpty {
                    sectionHeader(String(localized: "HIDDEN"))
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                        ForEach(hidden, id: \.self) { file in
                            FolderGridTile(kind: .file, name: file.lastPathComponent,
                                           fileIcon: sidebarFileIcon(for: file),
                                           dimmed: true, showHide: false, showUnhide: true,
                                           onTap: { AppState.shared.openInMainWindow(file) },
                                           onTrailing: { workspace.unhide(file) })
                            .contextMenu {
                                FolderInfoFileContextMenu(
                                    workspace: workspace, file: file, hidden: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            // Align with first grid icon (tile centers the glyph).
            .padding(.leading, FolderGridTile.iconLeadingInset)
    }

    private func folderTile(_ sub: URL, dimmed: Bool) -> some View {
        FolderGridTile(kind: .folder, name: sub.lastPathComponent,
                       dimmed: dimmed, showHide: false, showUnhide: false,
                       onTap: { AppState.shared.openInMainWindow(sub) },
                       onTrailing: {})
        .contextMenu {
            FolderContextMenu(workspace: workspace, folder: sub, showsOpen: true)
        }
    }

    // MARK: Copy path + toast

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folderURL.path, forType: .string)
        showCopiedToast = true
        toastHideTask?.cancel()
        toastHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            guard !Task.isCancelled else { return }
            showCopiedToast = false
        }
    }

    @ViewBuilder private var copiedToast: some View {
        if showCopiedToast {
            Text("Path copied")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                )
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .animation(.easeInOut(duration: 0.15), value: showCopiedToast)
        }
    }

    // MARK: Create actions

    private func newFile() {
        promptCreateMarkdownFile(in: folderURL, workspace: workspace)
    }

    private func newFolder() {
        promptCreateSubfolder(in: folderURL, workspace: workspace)
    }
}

private struct FolderInfoFileContextMenu: View {
    @ObservedObject var workspace: WorkspaceModel
    let file: URL
    let hidden: Bool

    var body: some View {
        Button("Open in Separate Window") {
            AppState.shared.openInSeparateWindow(file)
        }
        Divider()
        Button("Rename…") {
            promptForFileRename(file, workspace: workspace)
        }
        Button("Move…") {
            promptForFileMove(file, workspace: workspace)
        }
        Button(hidden ? "Return to List" : "Hide from List") {
            if hidden { workspace.unhide(file) } else { workspace.hide(file) }
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        }
    }
}

// MARK: - Grid tile (folder info card)

/// Fixed-width Finder-style cell: icon + label both centered in the tile
/// (label centered under the icon). Header uses `iconLeadingInset` so its
/// glyph lines up with the first tile’s icon.
private struct FolderGridTile: View {
    enum Kind { case folder, file }

    static let width: CGFloat = 84
    static let iconSize: CGFloat = 30
    /// Fixed label band (2 lines @ 11pt) so 1-line names don’t shrink the tile
    /// and push the icon up relative to neighbours in the grid row.
    static let labelHeight: CGFloat = 28
    static let iconRowHeight: CGFloat = 34

    /// Leading inset of a grid icon inside its tile (icon is centered in `width`).
    static var iconLeadingInset: CGFloat { max(0, (width - iconSize) / 2) }

    /// Large H1 folder symbols sit optically right of a 30pt grid icon — pull rail left.
    static let headerOpticalNudge: CGFloat = 5

    let kind: Kind
    let name: String
    /// SF Symbol for `.file` tiles (PDF tiles pass `sidebarFileIcon(for:)`).
    var fileIcon: String = "doc.text"
    var dimmed = false
    var showHide = false
    var showUnhide = false
    let onTap: () -> Void
    var onTrailing: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: kind == .folder ? "folder.fill" : fileIcon)
                    .font(.system(size: Self.iconSize))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(kind == .folder ? Color.accentColor : Color.secondary)
                    .opacity(dimmed ? 0.5 : 1)
                    .frame(width: Self.width, height: Self.iconRowHeight)
                if showUnhide || (showHide && hovering) {
                    Button(action: onTrailing) {
                        Image(systemName: showUnhide ? "eye" : "eye.slash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(showUnhide ? Color.accentColor : Color.secondary)
                            .padding(3)
                            .background(
                                Circle()
                                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.9))
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .editMDHelp(showUnhide
                        ? String(localized: "Return to List")
                        : String(localized: "Hide from List"))
                    .padding(2)
                }
            }
            .frame(height: Self.iconRowHeight)
            Text(name)
                .font(.system(size: 11))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: Self.width - 4, height: Self.labelHeight, alignment: .top)
        }
        // Fixed footprint + top alignment: icons stay on one row baseline.
        .frame(width: Self.width, height: Self.iconRowHeight + 4 + Self.labelHeight,
               alignment: .top)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovering
                      ? Color(nsColor: .quaternaryLabelColor).opacity(0.14)
                      : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: onTap)
        .onHover { hovering = $0 }
    }
}
