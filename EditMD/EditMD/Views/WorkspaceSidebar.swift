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

/// Roots travel under their own drag type (declared in `Info.plist`): a
/// file-move target never lights up for a root drag and vice versa — the
/// system refuses the drop instead of accepting and ignoring it.
/// docs/vault.md § Collections.
let sidebarRootDragContentType = UTType(exportedAs: "com.editmd.sidebar-root")

struct SidebarRootDragPayload: Codable, Equatable, Sendable {
    static let format = "com.editmd.root-group.v1"

    let format: String
    let processToken: String
    let path: String

    init(path: String) {
        format = Self.format
        processToken = SidebarFileDragPayload.processToken
        self.path = path
    }
}

func encodeSidebarRootDragPayload(_ payload: SidebarRootDragPayload) throws -> Data {
    try JSONEncoder().encode(payload)
}

/// The dragged root's path, or nil for anything this process did not write.
func decodeSidebarRootDragPayload(_ data: Data) -> String? {
    guard let payload = try? JSONDecoder().decode(SidebarRootDragPayload.self, from: data),
          payload.format == SidebarRootDragPayload.format,
          payload.processToken == SidebarFileDragPayload.processToken
    else { return nil }
    return payload.path
}

@MainActor
func sidebarRootItemProvider(root: URL) -> NSItemProvider {
    let provider = NSItemProvider()
    let payload = SidebarRootDragPayload(path: root.standardizedFileURL.path)
    guard let data = try? encodeSidebarRootDragPayload(payload) else { return provider }
    provider.registerDataRepresentation(
        forTypeIdentifier: sidebarRootDragContentType.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(data, nil)
        return nil
    }
    return provider
}

/// Move Up/Down availability from position in the movable list. Same answer
/// as `WorkspaceModel.canMove…` at O(1) per row — `WorkspaceCollectionsTests`
/// holds the two in agreement.
struct SidebarMoves: Equatable {
    let up: Bool
    let down: Bool

    init(position: Int, count: Int) {
        up = position > 0
        down = position < count - 1
    }
}

/// What dropping one adopted root onto another should do. Pure so the rules —
/// no self-drop, no re-adding a member, join the target's collection when it
/// has one — are testable without a drag session.
enum RootDropOutcome: Equatable {
    case ignore
    /// Target already belongs to a collection: the dragged root joins it.
    case join(collectionID: String)
    /// Neither root is grouped yet: ask for a name and make one for both.
    case createCollection(dragged: String, target: String)
}

func rootDropOutcome(
    dragged rawDragged: String,
    onto rawTarget: String,
    workspaces: [WorkspaceModel.Workspace]
) -> RootDropOutcome {
    // Same normalization the adopted roots use. `NSString.standardizingPath`
    // is NOT it — it expands `~` and strips `/private`, so identity
    // comparison could never match such a path.
    let dragged = URL(fileURLWithPath: rawDragged).standardizedFileURL.path
    let target = URL(fileURLWithPath: rawTarget).standardizedFileURL.path
    guard dragged != target,
          let draggedRoot = workspaces.first(where: { $0.folderPath == dragged }),
          let targetRoot = workspaces.first(where: { $0.folderPath == target })
    else { return .ignore }
    if let id = targetRoot.collectionID {
        return draggedRoot.collectionID == id ? .ignore : .join(collectionID: id)
    }
    return .createCollection(dragged: dragged, target: target)
}

/// Root dropped on a root row: create a collection (asks for a name) or join
/// the target's. File drags are a different type → `fileMoveDropTarget`.
private struct RootGroupDropTargetModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    let root: URL
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [sidebarRootDragContentType], isTargeted: $isTargeted) { providers in
                loadDraggedRoot(from: providers) { path in
                    groupRoot(path)
                }
            }
    }

    @MainActor private func groupRoot(_ path: String) {
        let target = root.standardizedFileURL.path
        switch rootDropOutcome(dragged: path, onto: target, workspaces: workspace.workspaces) {
        case .ignore:
            return
        case .join(let collectionID):
            let dropped = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let dragged = workspace.workspaces.first(where: { $0.folderPath == dropped }),
                  let collection = workspace.collection(withID: collectionID)
            else { return }
            workspace.assign(dragged, to: collection)
        case .createCollection(let draggedPath, let targetPath):
            guard let dragged = workspace.workspaces.first(where: { $0.folderPath == draggedPath }),
                  let anchor = workspace.workspaces.first(where: { $0.folderPath == targetPath }),
                  let name = promptForNewName(
                    title: String(localized: "New Collection"),
                    message: String(localized: "Group “\(anchor.name)” and “\(dragged.name)” in the sidebar under a name. This does not move anything on disk."),
                    defaultName: String(localized: "Collection"),
                    confirmTitle: String(localized: "Create")),
                  let collection = workspace.createCollection(named: name, with: anchor)
            else { return }
            workspace.assign(dragged, to: collection)
        }
    }
}

/// Drop target for a collection header: a root dropped on it joins.
private struct CollectionDropTargetModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    let collection: WorkspaceCollection
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [sidebarRootDragContentType], isTargeted: $isTargeted) { providers in
                loadDraggedRoot(from: providers) { path in
                    let dropped = URL(fileURLWithPath: path).standardizedFileURL.path
                    guard let dragged = workspace.workspaces.first(where: {
                        $0.folderPath == dropped
                    }), dragged.collectionID != collection.id else { return }
                    workspace.assign(dragged, to: collection)
                }
            }
    }
}

/// Shared plumbing for both root drop targets.
private func loadDraggedRoot(
    from providers: [NSItemProvider],
    then apply: @escaping @MainActor (String) -> Void
) -> Bool {
    let identifier = sidebarRootDragContentType.identifier
    guard let provider = providers.first(where: {
        $0.hasItemConformingToTypeIdentifier(identifier)
    }) else { return false }
    provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
        guard let data, let path = decodeSidebarRootDragPayload(data) else { return }
        Task { @MainActor in apply(path) }
    }
    return true
}

extension View {
    /// Root rows accept both kinds of drag: files move into the folder, a root
    /// makes or joins a collection.
    func rootGroupDropTarget(root: URL, workspace: WorkspaceModel) -> some View {
        modifier(RootGroupDropTargetModifier(workspace: workspace, root: root))
    }

    func collectionDropTarget(
        _ collection: WorkspaceCollection,
        workspace: WorkspaceModel
    ) -> some View {
        modifier(CollectionDropTargetModifier(workspace: workspace, collection: collection))
    }
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

/// Drop the multi-select highlight when the newly active URL is not one of
/// the selected files; keep it when it is. Pure for testing.
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

/// Count comes from the selection alone — SwiftUI builds `.contextMenu`
/// content eagerly for EVERY row, and walking `sidebarVisibleFileOrder` here
/// made sidebar render O(rows²).
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

    // Collapsed-collection members are off screen — they must not enter the
    // order a Shift-click range walks.
    for root in workspace.visibleWorkspaces where !root.collapsed {
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

/// Left sidebar: segmented navigator over Files / Search / Git / Tags
/// (workspace-scope); Outline and Review live in the right inspector.
struct WorkspaceSidebar: View {
    /// Narrowest pane that still shows all tabs — same floor rule as
    /// `InspectorSidebar.minimumPaneWidth`.
    nonisolated static let navigatorTabCount = 4

    nonisolated static var minimumPaneWidth: CGFloat {
        SidebarChrome.navigatorStripWidth(tabs: navigatorTabCount)
            + 2 * SidebarChrome.barPaddingH
    }

    @ObservedObject var workspace: WorkspaceModel
    let activeURL: URL?
    /// Required, not defaulted: a caller that forgets it would silently
    /// accent the parent of an open folder (`sidebarFolderMark`).
    let activeIsFolder: Bool
    /// File click: host decides (replace in place, or "already open" modal).
    let onOpen: (URL) -> Void
    /// Folder click: open the folder info card (click also toggles expand).
    let onOpenFolder: (URL) -> Void
    @ObservedObject private var searchModel = WorkspaceSearchModel.shared
    @AppStorage("sidebarTab") private var tab = "files"
    @AppStorage("inspectorTab") private var inspectorTab = "outline"
    @AppStorage("sidebarShowHidden") private var showHidden = false
    /// Filters Files tree / Git paths / Tags; hidden on Search (own field).
    @State private var filterText = ""
    @State private var selectedFiles = Set<URL>()
    @State private var selectionAnchor: URL?
    var body: some View {
        VStack(spacing: 0) {
            navigatorToolbar
                .padding(.horizontal, SidebarChrome.barPaddingH)
                .frame(height: SidebarChrome.barHeight)

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
                    // "files" and retired keys → Files.
                    filesTab
                }
            }
            // Fill remaining height so bottomBar stays pinned on sparse tabs.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if tab != "search" {
                bottomBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the window chrome, not the greyer under-page fill that made
        // the sidebar look like a separate sheet.
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { applySidebarTabMigration() }
        .onChange(of: tab) { _ in
            clearFileSelection()
            applySidebarTabMigration()
        }
    }

    /// Outline and Review left the workspace navigator for the inspector.
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

    // MARK: - Navigator toolbar

    /// Stock segmented control: equal-width tabs that follow the pane.
    private var navigatorToolbar: some View {
        SidebarNavStrip(
            tabs: [
                SidebarNavTab(id: "files",
                              systemImage: "folder",
                              help: String(localized: "Files")),
                SidebarNavTab(id: "search",
                              systemImage: "magnifyingglass",
                              help: String(localized: "Search — search the workspace")),
                SidebarNavTab(id: "git",
                              systemImage: "arrow.triangle.branch",
                              help: String(localized: "Git")),
                SidebarNavTab(id: "tags",
                              systemImage: "tag",
                              help: String(localized: "Tags — frontmatter"))
            ],
            selection: $tab
        )
    }

    // MARK: - Bottom bar (+ · Filter · eye)

    private var bottomBar: some View {
        HStack(spacing: 4) {
            // "+" is Files-only; Filter also covers Git / Tags.
            if tab == "files" {
                AccessoryBarMenu(systemImage: "plus",
                                 help: String(localized: "Add Folder…")) {
                    Button("New Folder…") { workspace.promptCreateFolder() }
                    Button("Open Folder…") { workspace.promptAddFolder() }
                }
            }

            FilterSearchField(prompt: String(localized: "Filter"), text: $filterText)

            if tab == "files" {
                let hidden = workspace.totalHiddenCount
                AccessoryBarButton(
                    glyph: .symbol(showHidden ? "eye" : "eye.slash"),
                    help: showHidden
                        ? String(localized: "Hide again (hidden files and empty folders)")
                        : (hidden > 0
                           ? String(localized: "Show hidden files (\(hidden)) and empty folders")
                           : String(localized: "Show hidden files and empty folders")),
                    active: showHidden
                ) {
                    showHidden.toggle()
                }
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
        // Opening a file can rebuild this sidebar (editor subtree is
        // `.id(url)`-swapped) and a plain ScrollView snaps to top. The
        // just-opened file is the anchor: scroll it back into view; a
        // missing/unrealized row is a no-op, never a wrong scroll.
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
                    // One projection per render; Move Up/Down flags come from
                    // positions in it — asking the model per row rebuilds the
                    // arrangement twice per row (context menus build eagerly).
                    let items = workspace.sidebarTopLevelItems
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        let moves = SidebarMoves(position: index, count: items.count)
                        switch item {
                        case .root(let ws):
                            workspaceGroup(ws, moves: moves)
                        case .collection(let collection, let members):
                            collectionHeader(collection,
                                             ownsActive: collectionOwnsActive(members),
                                             moves: moves)
                            if !collection.collapsed {
                                ForEach(Array(members.enumerated()), id: \.element.id) { i, ws in
                                    workspaceGroup(
                                        ws,
                                        inCollection: true,
                                        moves: SidebarMoves(position: i, count: members.count))
                                }
                            }
                        }
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

    /// Nudge a newly-active off-screen file into view (wiki-link, search,
    /// editmdctl). nil anchor = minimal scroll, so a visible row does not
    /// move. Deferred one run-loop turn so lazy rows exist as targets;
    /// anchored by the standardized URL the tree rows tag with `.id`.
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

    // MARK: - Collections

    /// Collapsing hides every member root at once; roots keep their own
    /// expanded state. `ownsActive` fills the glyph while the open document
    /// lives in a member — the mark travels with the active file.
    private func collectionHeader(
        _ collection: WorkspaceCollection, ownsActive: Bool, moves: SidebarMoves
    ) -> some View {
        HStack(spacing: SidebarTree.rowSpacing) {
            Button {
                workspace.toggleCollapsed(collection)
            } label: {
                Image(systemName: collection.collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .frame(width: SidebarTree.chevronWidth, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                workspace.toggleCollapsed(collection)
            } label: {
                HStack(spacing: SidebarTree.rowSpacing) {
                    Image(systemName: ownsActive ? "tray.2.fill" : "tray.2")
                        .font(.system(size: 11))
                        .foregroundStyle(ownsActive ? Color.accentColor : Color.secondary)
                    Text(collection.name.uppercased())
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .collectionDropTarget(collection, workspace: workspace)
        .contextMenu {
            Button("Rename Collection…") { promptToRenameCollection(collection) }
            Button("Ungroup Collection") { workspace.dissolveCollection(collection) }
            Divider()
            Button("Move Up") { workspace.moveCollection(collection, by: -1) }
                .disabled(!moves.up)
            Button("Move Down") { workspace.moveCollection(collection, by: 1) }
                .disabled(!moves.down)
        }
    }

    /// Per-root collection commands, appended to the folder context menu.
    @ViewBuilder private func collectionMenu(
        for ws: WorkspaceModel.Workspace, moves: SidebarMoves
    ) -> some View {
        let current = workspace.collection(of: ws)
        Menu("Collection") {
            Button("New Collection…") { promptToCreateCollection(with: ws) }
            let others = workspace.collections.filter { $0.id != current?.id }
            if !others.isEmpty {
                Divider()
                ForEach(others) { collection in
                    Button(collection.name) { workspace.assign(ws, to: collection) }
                }
            }
            if current != nil {
                Divider()
                Button("Remove from Collection") { workspace.assign(ws, to: nil) }
            }
        }
        Button("Move Up") { workspace.moveWorkspace(ws, by: -1) }
            .disabled(!moves.up)
        Button("Move Down") { workspace.moveWorkspace(ws, by: 1) }
            .disabled(!moves.down)
    }

    private func promptToCreateCollection(with ws: WorkspaceModel.Workspace) {
        guard let name = promptForNewName(
            title: String(localized: "New Collection"),
            message: String(localized: "Group folders in the sidebar under a name. This does not move anything on disk."),
            defaultName: String(localized: "Collection"),
            confirmTitle: String(localized: "Create")
        ) else { return }
        workspace.createCollection(named: name, with: ws)
    }

    private func promptToRenameCollection(_ collection: WorkspaceCollection) {
        guard let name = promptForNewName(
            title: String(localized: "Rename Collection"),
            message: String(localized: "Enter a new name for “\(collection.name)”."),
            defaultName: collection.name,
            confirmTitle: String(localized: "Rename")
        ) else { return }
        workspace.renameCollection(collection, to: name)
    }

    // MARK: - Workspace group

    /// A root inside a collection offsets its whole subtree by `baseIndent`;
    /// rows carry that placement in their identity (`SidebarSubtreeRowID`).
    @ViewBuilder private func workspaceGroup(
        _ ws: WorkspaceModel.Workspace, inCollection: Bool = false, moves: SidebarMoves
    ) -> some View {
        let baseIndent: CGFloat = inCollection ? SidebarTree.collectionIndent : 0
        let selected = isActive(ws.url)
        let ownsActive = rootOwnsActive(ws)
        let expanded = !ws.collapsed
        HStack(spacing: SidebarTree.rowSpacing) {
            if baseIndent > 0 { Spacer().frame(width: baseIndent) }
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

            // Name: open card + ensure expanded. Re-click while active AND
            // expanded → collapse; a first click never collapses.
            Button {
                if selected && expanded {
                    workspace.collapseWorkspace(ws)
                } else {
                    workspace.expandWorkspace(ws)
                    onOpenFolder(ws.url)
                }
            } label: {
                HStack(spacing: SidebarTree.rowSpacing) {
                    Image(systemName: ownsActive ? "tray.full.fill" : "tray.full")
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
            Divider()
            collectionMenu(for: ws, moves: moves)
        }
        .fileMoveDropTarget(folder: ws.url, workspace: workspace) {
            clearFileSelection()
        }
        .rootGroupDropTarget(root: ws.url, workspace: workspace)
        .onDrag { sidebarRootItemProvider(root: ws.url) }

        if !ws.collapsed {
            // contentEpoch read forces re-scan when disk mutates.
            let _ = workspace.contentEpoch
            // `.id` carries the root's placement (`SidebarSubtreeRowID`):
            // without it a root that joins/leaves a collection keeps its
            // realized subtree on the old column.
            ForEach(filteredFolders(workspace.markdownSubfolders(in: ws.url)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: 1, baseIndent: baseIndent,
                              filter: filterQuery, activeURL: activeURL,
                              activeIsFolder: activeIsFolder,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
                    .id(SidebarSubtreeRowID(sub, inCollection: inCollection))
            }
            ForEach(filteredFolders(workspace.keptEmptySubfolders(in: ws.url)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: 1, baseIndent: baseIndent,
                              filter: filterQuery, activeURL: activeURL,
                              activeIsFolder: activeIsFolder,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
                    .id(SidebarSubtreeRowID(sub, inCollection: inCollection))
            }
            if showHidden {
                ForEach(filteredFolders(workspace.unkeptEmptySubfolders(in: ws.url)), id: \.self) { sub in
                    SubfolderNode(workspace: workspace, folder: sub, depth: 1, baseIndent: baseIndent,
                                  filter: filterQuery, activeURL: activeURL,
                                  activeIsFolder: activeIsFolder,
                                  showHidden: showHidden, isEmptyFolder: true,
                                  selectedFiles: $selectedFiles,
                                  selectionAnchor: $selectionAnchor,
                                  onOpen: onOpen, onOpenFolder: onOpenFolder)
                        .id(SidebarSubtreeRowID(sub, inCollection: inCollection))
                }
            }
            ForEach(workspace.visibleFiles(ws).filter { nameMatches($0.lastPathComponent) },
                    id: \.self) { url in
                fileRow(url, in: ws, hidden: false, baseIndent: baseIndent)
                    .id(SidebarSubtreeRowID(url, inCollection: inCollection))
            }
            if showHidden {
                ForEach(workspace.hiddenFilesList(ws).filter { nameMatches($0.lastPathComponent) },
                        id: \.self) { url in
                    fileRow(url, in: ws, hidden: true, baseIndent: baseIndent)
                        .id(SidebarSubtreeRowID(url, inCollection: inCollection))
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

    private func fileRow(_ url: URL, in ws: WorkspaceModel.Workspace,
                         hidden: Bool, baseIndent: CGFloat = 0) -> some View {
        // depth 1 = same column as root subfolders (chevron slot reserved).
        FileRow(name: url.lastPathComponent,
                icon: sidebarFileIcon(for: url),
                subtitle: nil,
                isActive: isActive(url),
                isSelected: selectedFiles.contains(url.standardizedFileURL),
                dimmed: hidden,
                depth: 1,
                baseIndent: baseIndent,
                trailing: hidden ? .unhide : .hide,
                onTap: { handleFileTap(url) },
                onTrailing: { hidden ? workspace.unhide(url, in: ws) : workspace.hide(url, in: ws) })
        .contextMenu {
            Button("Open in Separate Window") { AppState.shared.openInSeparateWindow(url) }
            Divider()
            Button("Rename…") { promptForFileRename(url, workspace: workspace) }
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
        // Scroll anchor — matches scrollTo(active.standardized).
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
            Button("Rename…") { promptForFileRename(url, workspace: workspace) }
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

    /// Drop the multi-select highlight when the active target moves off the
    /// selection (it survives navigation otherwise and stays wrongly lit).
    private func clearStaleFileSelection() {
        if shouldClearSidebarSelection(activeURL: activeURL, selectedFiles: selectedFiles) {
            clearFileSelection()
        }
    }

    private func isActive(_ url: URL) -> Bool {
        url.standardizedFileURL == activeURL?.standardizedFileURL
    }

    /// Open document is this root or below it. A root marks its whole branch,
    /// so unlike a subfolder it is accented as soon as it is filled.
    private func rootOwnsActive(_ ws: WorkspaceModel.Workspace) -> Bool {
        sidebarFolderMark(folder: ws.url, activeURL: activeURL,
                          activeIsFolder: activeIsFolder).filled
    }

    /// "Here" when any member root is — including while collapsed and the
    /// owning root is off screen.
    private func collectionOwnsActive(_ members: [WorkspaceModel.Workspace]) -> Bool {
        members.contains { rootOwnsActive($0) }
    }

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
    /// Leading offset inherited from the workspace root (collections indent
    /// their members' whole subtree).
    var baseIndent: CGFloat = 0
    /// Empty = no filter. Same rules as the root: name match, or expanded so
    /// matching children stay reachable without a full recursive scan.
    let filter: String
    let activeURL: URL?
    /// See `sidebarFolderMark`: an open folder accents itself, not its parent.
    let activeIsFolder: Bool
    let showHidden: Bool
    /// No markdown in this folder’s tree — dimmed; only listed when eye is on.
    var isEmptyFolder: Bool = false
    @Binding var selectedFiles: Set<URL>
    @Binding var selectionAnchor: URL?
    let onOpen: (URL) -> Void
    let onOpenFolder: (URL) -> Void

    private var indent: CGFloat { CGFloat(depth) * SidebarTree.indentStep + baseIndent }
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
        let mark = sidebarFolderMark(folder: folder, activeURL: activeURL,
                                     activeIsFolder: activeIsFolder)
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
                    // The mark follows the open document, not the disclosure
                    // state: every folder above it is filled, the one holding
                    // it is accented (`sidebarFolderMark`). Expansion says its
                    // own thing through the chevron.
                    Image(systemName: mark.filled ? "folder.fill" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(mark.accented ? Color.accentColor : Color.secondary)
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
            // md folders → kept empty folders → found-on-disk empty folders (eye)
            // → visible files → hidden files (eye).
            ForEach(filteredFolders(workspace.markdownSubfolders(in: folder)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1, baseIndent: baseIndent,
                              filter: filter, activeURL: activeURL,
                              activeIsFolder: activeIsFolder,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
            }
            ForEach(filteredFolders(workspace.keptEmptySubfolders(in: folder)), id: \.self) { sub in
                SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1, baseIndent: baseIndent,
                              filter: filter, activeURL: activeURL,
                              activeIsFolder: activeIsFolder,
                              showHidden: showHidden, isEmptyFolder: false,
                              selectedFiles: $selectedFiles,
                              selectionAnchor: $selectionAnchor,
                              onOpen: onOpen, onOpenFolder: onOpenFolder)
            }
            if showHidden {
                ForEach(filteredFolders(workspace.unkeptEmptySubfolders(in: folder)), id: \.self) { sub in
                    SubfolderNode(workspace: workspace, folder: sub, depth: depth + 1, baseIndent: baseIndent,
                                  filter: filter, activeURL: activeURL,
                                  activeIsFolder: activeIsFolder,
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
                baseIndent: baseIndent,
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
