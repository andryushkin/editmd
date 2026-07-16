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

enum FolderRenameError: LocalizedError, Equatable {
    case folderNoLongerOpen
    case folderNoLongerExists
    case openDocuments(Int)
    case renameInProgress
    /// A filesystem operation failed after probing every path it may have
    /// touched. A non-nil URL is the one unambiguous surviving folder.
    case diskFailure(URL?)

    var errorDescription: String? {
        switch self {
        case .folderNoLongerOpen:
            return "Эта папка больше не открыта в сайдбаре."
        case .folderNoLongerExists:
            return "Папка больше не существует по прежнему пути."
        case .openDocuments(let count):
            let suffix: String
            if count % 10 == 1, count % 100 != 11 {
                suffix = "документ"
            } else if (2...4).contains(count % 10), !(12...14).contains(count % 100) {
                suffix = "документа"
            } else {
                suffix = "документов"
            }
            return "Сначала закройте открытые файлы внутри папки (\(count) \(suffix))."
        case .renameInProgress:
            return "Эта папка уже переименовывается."
        case .diskFailure(let survivor):
            if let survivor {
                return "Не удалось завершить переименование. Папка сохранена по пути «\(survivor.path)»; состояние EditMD обновлено на этот путь."
            }
            return "Не удалось завершить переименование, а состояние папки на диске неоднозначно. Проверьте исходный и новый пути в Finder."
        }
    }
}

/// Prefer `README.md` over `index.md` (case-insensitive), only direct children.
func homeDocument(in folder: URL, fileManager: FileManager = .default) -> URL? {
    let items = (try? fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles])) ?? []
    // Case-sensitive volumes can hold README.md and readme.md side by side —
    // uniqueKeysWithValues would trap on the duplicate lowercased key.
    let names = Dictionary(items.map { ($0.lastPathComponent.lowercased(), $0) },
                           uniquingKeysWith: { first, _ in first })
    if let readme = names["readme.md"] { return readme }
    if let index = names["index.md"] { return index }
    return nil
}

// MARK: - Recursive tree stats

/// One node in the nested-folder tree (D8). `markdownCount` is the number of
/// Displayable files DIRECTLY in this folder — descendants report their own counts.
struct FolderTreeNode: Equatable, Sendable, Identifiable {
    var url: URL
    var markdownCount: Int
    var children: [FolderTreeNode]
    var id: String { url.path }
}

/// Full-tree counts under a folder (any depth). The root itself is not counted
/// as a subfolder. A subfolder is counted only if its subtree contains at least
/// one displayable file (empty / unrelated folders are ignored). `.textbundle`
/// packages count as one document and are not descended into. Hidden items skipped.
struct FolderTreeStats: Equatable, Sendable {
    var markdownCount: Int
    var subfolderCount: Int
    /// Direct child folders that contain markdown somewhere (main grid).
    var directMarkdownFolders: [URL]
    /// Direct child folders with no markdown in the tree (bottom section, like «Скрытые»).
    var directEmptyFolders: [URL]
    /// Full nested tree of folders that contain markdown (D8).
    var folderTree: [FolderTreeNode] = []
}

/// Synchronous post-order scan. Call off the main actor for large trees.
/// Checks `Task.isCancelled` so the UI can abandon a stale scan.
func scanFolderTreeStats(at root: URL,
                         fileManager: FileManager = .default) -> FolderTreeStats {
    // Every file the sidebar displays counts as a document, so a folder holding
    // only PDFs or images must not be classified as "empty".
    let mdExt: Set<String> =
        Set(["md", "markdown", "textbundle", "pdf"]).union(supportedImageFileExtensions)
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey]

    /// `hasMarkdown` — this directory's subtree has ≥1 md (not counting the
    /// directory as a subfolder; callers count children that report true).
    /// Also builds nested tree nodes for D8.
    func walk(_ dir: URL) -> (markdown: Int, foldersWithMd: Int, hasMarkdown: Bool,
                              tree: [FolderTreeNode]) {
        if Task.isCancelled { return (0, 0, false, []) }
        let items = (try? fileManager.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles])) ?? []
        var markdown = 0
        var foldersWithMd = 0
        var hasMarkdown = false
        var tree: [FolderTreeNode] = []
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
                    tree.append(FolderTreeNode(url: url,
                                               markdownCount: child.markdown,
                                               children: child.tree))
                }
            } else if mdExt.contains(url.pathExtension.lowercased()) {
                markdown += 1
                hasMarkdown = true
            }
        }
        tree.sort {
            $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
                == .orderedAscending
        }
        return (markdown, foldersWithMd, hasMarkdown, tree)
    }

    // Root pass: collect direct child folders that have markdown (for the grid).
    let rootURL = root.standardizedFileURL
    let items = (try? fileManager.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: Array(keys),
        options: [.skipsHiddenFiles])) ?? []
    var markdown = 0
    var foldersWithMd = 0
    var directMarkdownFolders: [URL] = []
    var directEmptyFolders: [URL] = []
    var folderTree: [FolderTreeNode] = []
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
                foldersWithMd += 1
                directMarkdownFolders.append(url)
                folderTree.append(FolderTreeNode(url: url,
                                                 markdownCount: child.markdown,
                                                 children: child.tree))
            } else {
                directEmptyFolders.append(url)
            }
        } else if mdExt.contains(url.pathExtension.lowercased()) {
            markdown += 1
        }
    }
    let byName: (URL, URL) -> Bool = {
        $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent)
            == .orderedAscending
    }
    directMarkdownFolders.sort(by: byName)
    directEmptyFolders.sort(by: byName)
    folderTree.sort {
        $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent)
            == .orderedAscending
    }
    return FolderTreeStats(markdownCount: markdown,
                           subfolderCount: foldersWithMd,
                           directMarkdownFolders: directMarkdownFolders,
                           directEmptyFolders: directEmptyFolders,
                           folderTree: folderTree)
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

    /// Entry regardless of epoch — stale-while-revalidate readers.
    static func lookupAny(path: String) -> (epoch: Int, stats: FolderTreeStats)? {
        store[path]
    }

    static func store(path: String, epoch: Int, stats: FolderTreeStats) {
        store[path] = (epoch, stats)
    }
}

// MARK: - Name prompt (AppKit)

@MainActor
func promptForNewName(title: String, message: String, defaultName: String,
                      confirmTitle: String = "Создать", allowsEmpty: Bool = false) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Отмена")
    let field = NSTextField(string: defaultName)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty && !allowsEmpty ? nil : name
}

@MainActor
func promptForNewMarkdownFile(in folder: URL) -> (name: String, template: FileTemplate)? {
    let alert = NSAlert()
    alert.messageText = "Новый markdown-файл"
    alert.informativeText = "Файл будет создан в «\(folder.lastPathComponent)»."
    alert.addButton(withTitle: "Создать")
    alert.addButton(withTitle: "Отмена")

    let field = NSTextField(string: "Untitled.md")
    field.placeholderString = "Имя файла"
    let templatePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    for template in FileTemplate.allCases {
        templatePicker.addItem(withTitle: template.title)
        templatePicker.lastItem?.representedObject = template.rawValue
    }

    let nameLabel = NSTextField(labelWithString: "Имя:")
    let templateLabel = NSTextField(labelWithString: "Шаблон:")
    let grid = NSGridView(views: [
        [nameLabel, field],
        [templateLabel, templatePicker]
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).width = 230
    grid.rowSpacing = 8
    grid.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
    alert.accessoryView = grid
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
          let rawTemplate = templatePicker.selectedItem?.representedObject as? String,
          let template = FileTemplate(rawValue: rawTemplate) else { return nil }
    return (name, template)
}

@MainActor
func presentFolderError(_ error: Error, title: String = "Не удалось создать") {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

@MainActor
func promptForWorkspaceDisplayName(_ ws: WorkspaceModel.Workspace,
                                   workspace: WorkspaceModel) {
    guard let name = promptForNewName(
        title: "Отображаемое имя",
        message: "Это имя видно только в EditMD. Пустое поле вернёт настоящее имя папки.",
        defaultName: ws.displayName ?? ws.folderName,
        confirmTitle: "Сохранить",
        allowsEmpty: true
    ) else { return }
    workspace.setDisplayName(name, for: ws)
}

@MainActor
func promptForWorkspaceFolderRename(_ ws: WorkspaceModel.Workspace,
                                    workspace: WorkspaceModel) {
    guard let name = promptForNewName(
        title: "Переименовать папку на диске",
        message: "Имя изменится также в Finder. Перед переименованием закройте файлы из этой папки.",
        defaultName: ws.folderName,
        confirmTitle: "Переименовать"
    ) else { return }

    Task { @MainActor in
        let oldURL = ws.url.standardizedFileURL
        let expectedNewURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
        do {
            try await LongRunningOperationCenter.shared.run(
                title: "Переименовываем «\(oldURL.lastPathComponent)»…"
            ) {
                let review = ReviewModel.shared
                let reviewToken = await review.beginPathMutation()
                let appState = AppState.shared
                let pathMutations = [
                    (url: oldURL,
                     token: appState.beginPathMutation(at: oldURL)),
                    (url: expectedNewURL,
                     token: appState.beginPathMutation(at: expectedNewURL))
                ]
                var discardedRouteTokens = Set<UUID>()
                defer {
                    appState.finishPathMutations(
                        Set(pathMutations.map(\.token)),
                        discardingRouteIDs: discardedRouteTokens)
                }
                do {
                    let newURL = try await workspace.renameFolderOnDisk(
                        ws, to: name,
                        openDocumentURLs: AppState.openDocumentURLsForDiskMutation())
                    guard newURL != oldURL else {
                        review.cancelPathMutation(reviewToken)
                        return
                    }
                    DocumentRegistry.shared.relocateFolder(
                        from: oldURL, to: newURL)
                    review.completePathMutation(
                        reviewToken,
                        relocatingFolderFrom: oldURL,
                        to: newURL)
                    appState.relocateFolder(from: oldURL, to: newURL)
                    DocumentHistory.shared.relocateFolder(
                        from: oldURL, to: newURL)
                } catch let error as FolderRenameError {
                    if case .diskFailure(let survivor) = error {
                        if let survivor {
                            let survivor = survivor.standardizedFileURL
                            if survivor == oldURL {
                                review.completePathMutation(
                                    reviewToken,
                                    droppingFoldersAt: [expectedNewURL])
                            } else {
                                let droppedRoots = survivor == expectedNewURL
                                    ? []
                                    : [expectedNewURL]
                                DocumentRegistry.shared.relocateFolder(
                                    from: oldURL, to: survivor)
                                review.completePathMutation(
                                    reviewToken,
                                    relocatingFolderFrom: oldURL,
                                    to: survivor,
                                    droppingFoldersAt: droppedRoots)
                                appState.relocateFolder(
                                    from: oldURL, to: survivor)
                                DocumentHistory.shared.relocateFolder(
                                    from: oldURL, to: survivor)
                            }
                            if survivor != expectedNewURL {
                                discardedRouteTokens.insert(
                                    pathMutations[1].token)
                            }
                        } else {
                            DocumentRegistry.shared.discardFolderCaches(
                                at: [oldURL, expectedNewURL])
                            review.completePathMutation(
                                reviewToken,
                                droppingFoldersAt: [oldURL, expectedNewURL])
                            discardedRouteTokens.formUnion(
                                pathMutations.map(\.token))
                        }
                    } else {
                        review.cancelPathMutation(reviewToken)
                    }
                    throw error
                } catch {
                    review.cancelPathMutation(reviewToken)
                    throw error
                }
            }
        } catch {
            presentFolderError(error, title: "Не удалось переименовать папку")
        }
    }
}

@MainActor
func promptCreateMarkdownFile(in folder: URL, workspace: WorkspaceModel) {
    guard let request = promptForNewMarkdownFile(in: folder) else { return }
    do {
        let url = try workspace.createMarkdownFile(
            named: request.name,
            in: folder,
            template: request.template)
        AppState.shared.openCreatedFile(url)
    } catch {
        presentFolderError(error)
    }
}

@MainActor
func promptCreateSubfolder(in folder: URL, workspace: WorkspaceModel) {
    guard let name = promptForNewName(
        title: "Новая папка",
        message: "Папка будет создана в «\(folder.lastPathComponent)».",
        defaultName: "New Folder"
    ) else { return }
    do {
        _ = try workspace.createSubfolder(named: name, in: folder)
    } catch {
        presentFolderError(error)
    }
}
