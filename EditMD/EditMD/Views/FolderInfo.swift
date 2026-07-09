import SwiftUI
import AppKit

// MARK: - Pure naming / home-doc helpers

/// Validation for New File / New Folder names from the folder info card.
/// Rejects empty, path separators, and `..` so the result always stays inside
/// the parent directory.
enum FolderNaming {
    /// User name → file name with a `.md` extension when missing.
    static func markdownFileName(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderCreateError.emptyName }
        try validateBaseName(trimmed)
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" { return trimmed }
        return trimmed + ".md"
    }

    /// User name → folder name (no extension munging).
    static func folderName(from raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderCreateError.emptyName }
        try validateBaseName(trimmed)
        return trimmed
    }

    private static func validateBaseName(_ name: String) throws {
        if name == "." || name == ".." { throw FolderCreateError.invalidName }
        if name.contains("/") || name.contains(":") || name.contains("\0") {
            throw FolderCreateError.invalidName
        }
    }
}

enum FolderCreateError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Имя не может быть пустым."
        case .invalidName: return "Недопустимое имя."
        case .alreadyExists(let n): return "«\(n)» уже существует."
        }
    }
}

/// Prefer `README.md` over `index.md` (case-insensitive), only direct children.
func homeDocument(in folder: URL, fileManager: FileManager = .default) -> URL? {
    let items = (try? fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
    let names = Dictionary(uniqueKeysWithValues: items.map {
        ($0.lastPathComponent.lowercased(), $0)
    })
    if let readme = names["readme.md"] { return readme }
    if let index = names["index.md"] { return index }
    return nil
}

// MARK: - Recursive tree stats

/// Full-tree counts under a folder (any depth). The root itself is not counted
/// as a subfolder. A subfolder is counted only if its subtree contains at least
/// one markdown file (empty / non-md folders are ignored). `.textbundle`
/// packages count as markdown and are not descended into. Hidden items skipped.
struct FolderTreeStats: Equatable, Sendable {
    var markdownCount: Int
    var subfolderCount: Int
}

/// Synchronous post-order scan. Call off the main actor for large trees.
/// Checks `Task.isCancelled` so the UI can abandon a stale scan.
func scanFolderTreeStats(at root: URL,
                         fileManager: FileManager = .default) -> FolderTreeStats {
    let mdExt: Set<String> = ["md", "markdown", "textbundle"]
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

    /// `hasMarkdown` — this directory's subtree has ≥1 md (not counting the
    /// directory as a subfolder; callers count children that report true).
    func walk(_ dir: URL) -> (markdown: Int, foldersWithMd: Int, hasMarkdown: Bool) {
        if Task.isCancelled { return (0, 0, false) }
        let items = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []
        var markdown = 0
        var foldersWithMd = 0
        var hasMarkdown = false
        for url in items {
            if Task.isCancelled { break }
            let vals = try? url.resourceValues(forKeys: keys)
            let isDir = vals?.isDirectory ?? false
            let isPackage = vals?.isPackage ?? false
            if isDir && !isPackage {
                let child = walk(url)
                markdown += child.markdown
                foldersWithMd += child.foldersWithMd
                if child.hasMarkdown {
                    // Count only subfolders that actually hold markdown somewhere.
                    foldersWithMd += 1
                    hasMarkdown = true
                }
            } else if mdExt.contains(url.pathExtension.lowercased()) {
                markdown += 1
                hasMarkdown = true
            }
        }
        return (markdown, foldersWithMd, hasMarkdown)
    }

    let result = walk(root.standardizedFileURL)
    return FolderTreeStats(markdownCount: result.markdown,
                           subfolderCount: result.foldersWithMd)
}

/// Path → (contentEpoch, stats). Invalidated when `WorkspaceModel.contentEpoch`
/// bumps (New File/Folder). Lookups require an epoch match.
@MainActor
enum FolderStatsCache {
    private static var store: [String: (epoch: Int, stats: FolderTreeStats)] = [:]

    static func lookup(path: String, epoch: Int) -> FolderTreeStats? {
        guard let entry = store[path], entry.epoch == epoch else { return nil }
        return entry.stats
    }

    static func store(path: String, epoch: Int, stats: FolderTreeStats) {
        store[path] = (epoch, stats)
    }
}

// MARK: - Name prompt (AppKit)

@MainActor
func promptForNewName(title: String, message: String, defaultName: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: "Создать")
    alert.addButton(withTitle: "Отмена")
    let field = NSTextField(string: defaultName)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? nil : name
}

@MainActor
func presentFolderError(_ error: Error) {
    let alert = NSAlert()
    alert.messageText = "Не удалось создать"
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

// MARK: - Main-window host (sidebar + card)

/// Main-window content when `AppState.currentURL` is a directory: same
/// workspace sidebar as the editor, center pane = folder card.
struct FolderInfoHost: View {
    let folderURL: URL

    @ObservedObject private var workspace = WorkspaceModel.shared
    @AppStorage("sidebarVisible") private var sidebarVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 220.0

    private static let sidebarWidthRange = 150.0...400.0

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                WorkspaceSidebar(
                    workspace: workspace,
                    outlineContent: "",
                    activeURL: folderURL,
                    onOpen: { AppState.shared.openInMainWindow($0) },
                    onOpenFolder: { AppState.shared.openInMainWindow($0) },
                    onJump: { _ in }
                )
                .frame(width: sidebarWidth)
                paneDivider { x in
                    sidebarWidth = min(Self.sidebarWidthRange.upperBound,
                                       max(Self.sidebarWidthRange.lowerBound, Double(x)))
                }
                .zIndex(1)
            }
            FolderInfoCard(folderURL: folderURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.15), value: sidebarVisible)
        .background(WindowAccessor { window in
            window.representedURL = folderURL
            window.title = folderURL.lastPathComponent
        })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .help("Toggle Sidebar (⌃⌘S)")
            }
        }
        .focusedSceneValue(\.sidebarVisible, $sidebarVisible)
        // No document / editor — File▸Save and Format stay disabled via nil focus.
    }

    private func paneDivider(onDrag: @escaping (CGFloat) -> Void) -> some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onDrag($0.location.x) }
                    )
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
    @State private var statsLoading = true
    @State private var statsTask: Task<Void, Never>?

    /// Shared leading inset for action strip + title/stats (one left edge).
    private static let contentLeading: CGFloat = 32

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

    private var homeDoc: URL? {
        _ = workspace.contentEpoch
        return homeDocument(in: folderURL)
    }

    private var displayPath: String {
        (folderURL.path as NSString).abbreviatingWithTildeInPath
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
                    stats
                    contentList
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.horizontal, Self.contentLeading)
                // Top matches first workspace row under the sidebar navigator.
                .padding(.top, SidebarChrome.firstContentTop)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { copiedToast }
        .onAppear { reloadTreeStats() }
        .onChange(of: folderURL) { _ in reloadTreeStats() }
        .onChange(of: workspace.contentEpoch) { _ in reloadTreeStats() }
        .onDisappear {
            toastHideTask?.cancel()
            statsTask?.cancel()
        }
    }

    /// Always async: cache hit paints immediately; miss shows «Подсчитывается…»
    /// while a utility Task walks the tree (cancellable on folder/epoch change).
    private func reloadTreeStats() {
        let path = folderURL.standardizedFileURL.path
        let epoch = workspace.contentEpoch
        if let cached = FolderStatsCache.lookup(path: path, epoch: epoch) {
            treeStats = cached
            statsLoading = false
            return
        }
        statsLoading = true
        treeStats = nil
        statsTask?.cancel()
        let root = folderURL.standardizedFileURL
        statsTask = Task {
            let stats = await Task.detached(priority: .utility) {
                scanFolderTreeStats(at: root)
            }.value
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Drop result if the card moved on (new folder / epoch).
                guard path == folderURL.standardizedFileURL.path,
                      epoch == workspace.contentEpoch else { return }
                FolderStatsCache.store(path: path, epoch: epoch, stats: stats)
                treeStats = stats
                statsLoading = false
            }
        }
    }

    // MARK: Action strip (same leading edge as title below)

    private var actionStrip: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                iconButton("doc.badge.plus", "Новый файл", action: newFile)
                iconButton("folder.badge.plus", "Новая папка", action: newFolder)
                iconButton("arrow.up.right.square", "Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                }
                if let home = homeDoc {
                    let isReadme = home.lastPathComponent.lowercased().hasPrefix("readme")
                    iconButton("book", isReadme ? "Открыть README" : "Открыть index") {
                        AppState.shared.openInMainWindow(home)
                    }
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(nsColor: SidebarChrome.wellColor))
            )
            Spacer(minLength: 0)
        }
        // Same horizontal inset as header/stats — one left edge with the title.
        .padding(.horizontal, Self.contentLeading)
        .padding(.top, SidebarChrome.barPaddingTop)
        .padding(.bottom, SidebarChrome.barPaddingBottom)
    }

    /// Same metrics as Files/Outline nav tabs; tooltip = gray AppKit plaque.
    private func iconButton(_ systemImage: String, _ help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .editMDHelp(help)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: previewH1Size))
                    .foregroundStyle(Color.accentColor)
                    .symbolRenderingMode(.hierarchical)
                Text(folderURL.lastPathComponent)
                    .font(previewH1Font)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            // Click path → copy absolute path + short toast (no separate button).
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
            .editMDHelp("Скопировать путь")
        }
    }

    // MARK: Stats (full tree, async)

    private var stats: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                statChip(
                    value: statsLoading ? "…" : "\(treeStats?.markdownCount ?? 0)",
                    label: ".md файлов")
                statChip(
                    value: statsLoading ? "…" : "\(treeStats?.subfolderCount ?? 0)",
                    label: "подпапок")
            }
            if statsLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Подсчитывается…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Content list (direct children + hidden section)

    /// Direct subfolders + visible md, then always-on «Скрытые» for hidden md
    /// in this folder. Hide store is shared with the sidebar (relative paths).
    private var contentList: some View {
        // contentEpoch: re-read directory after New File/Folder.
        let _ = workspace.contentEpoch
        let folders = workspace.subfolders(in: folderURL)
        let visible = workspace.visibleMarkdown(in: folderURL)
        let hidden = workspace.hiddenMarkdown(in: folderURL)
        let empty = folders.isEmpty && visible.isEmpty && hidden.isEmpty

        return VStack(alignment: .leading, spacing: 4) {
            if empty {
                Text("Нет файлов")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
            } else {
                ForEach(folders, id: \.self) { sub in
                    FolderRow(name: sub.lastPathComponent) {
                        AppState.shared.openInMainWindow(sub)
                    }
                }
                ForEach(visible, id: \.self) { file in
                    FileRow(name: file.lastPathComponent,
                            isActive: false,
                            trailing: .hide,
                            onTap: { AppState.shared.openInMainWindow(file) },
                            onTrailing: { workspace.hide(file) })
                    .contextMenu {
                        Button("Открыть в отдельном окне") {
                            AppState.shared.openInSeparateWindow(file)
                        }
                        Button("Скрыть из списка") { workspace.hide(file) }
                        Button("Показать в Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([file])
                        }
                    }
                }
                if !hidden.isEmpty {
                    Text("СКРЫТЫЕ")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(hidden, id: \.self) { file in
                        FileRow(name: file.lastPathComponent,
                                isActive: false,
                                dimmed: true,
                                trailing: .unhide,
                                onTap: { AppState.shared.openInMainWindow(file) },
                                onTrailing: { workspace.unhide(file) })
                        .contextMenu {
                            Button("Вернуть в список") { workspace.unhide(file) }
                            Button("Показать в Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([file])
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private func statChip(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .foregroundStyle(statsLoading ? Color.secondary : Color.primary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
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
            Text("Путь скопирован")
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
        guard let name = promptForNewName(
            title: "Новый markdown-файл",
            message: "Файл будет создан в «\(folderURL.lastPathComponent)».",
            defaultName: "Untitled.md"
        ) else { return }
        do {
            let url = try workspace.createMarkdownFile(named: name, in: folderURL)
            AppState.shared.openInMainWindow(url)
        } catch {
            presentFolderError(error)
        }
    }

    private func newFolder() {
        guard let name = promptForNewName(
            title: "Новая папка",
            message: "Папка будет создана в «\(folderURL.lastPathComponent)».",
            defaultName: "New Folder"
        ) else { return }
        do {
            _ = try workspace.createSubfolder(named: name, in: folderURL)
            // Stay on the parent card; tree expands so the new folder is visible.
        } catch {
            presentFolderError(error)
        }
    }
}
