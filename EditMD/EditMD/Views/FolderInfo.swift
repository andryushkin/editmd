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

    /// Direct markdown children + subfolders (non-recursive). Recomputed when
    /// the model notes a filesystem change or the URL changes.
    private var fileCount: Int {
        _ = workspace.contentEpoch
        return workspace.markdownFiles(in: folderURL).count
    }

    private var subfolderCount: Int {
        _ = workspace.contentEpoch
        return workspace.subfolders(in: folderURL).count
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
        .onDisappear { toastHideTask?.cancel() }
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

    // MARK: Stats

    private var stats: some View {
        HStack(spacing: 16) {
            statChip(value: "\(fileCount)", label: ".md файлов")
            statChip(value: "\(subfolderCount)", label: "подпапок")
        }
    }

    private func statChip(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .rounded))
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
