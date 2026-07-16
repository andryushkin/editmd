import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
    let names = Dictionary(uniqueKeysWithValues: items.map {
        ($0.lastPathComponent.lowercased(), $0)
    })
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
    guard let name = promptForNewName(
        title: "Новый markdown-файл",
        message: "Файл будет создан в «\(folder.lastPathComponent)».",
        defaultName: "Untitled.md"
    ) else { return }
    do {
        let url = try workspace.createMarkdownFile(named: name, in: folder)
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
            Button("Открыть") { AppState.shared.openInMainWindow(folder) }
            Divider()
        }
        Button("Новый файл…") {
            promptCreateMarkdownFile(in: folder, workspace: workspace)
        }
        Button("Новая папка…") {
            promptCreateSubfolder(in: folder, workspace: workspace)
        }
        Divider()
        if let rootWorkspace {
            Button("Изменить отображаемое имя…") {
                promptForWorkspaceDisplayName(rootWorkspace, workspace: workspace)
            }
            Button("Переименовать папку на диске…") {
                promptForWorkspaceFolderRename(rootWorkspace, workspace: workspace)
            }
            Divider()
        }
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
        Button("Показать в Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
        if let rootWorkspace {
            Divider()
            Button("Убрать из сайдбара") {
                workspace.removeWorkspace(rootWorkspace)
            }
        }
    }
}

@MainActor
@discardableResult
func promptForFileMove(_ file: URL, workspace: WorkspaceModel) -> Bool {
    promptForFileMove([file], workspace: workspace)
}

@MainActor
@discardableResult
func promptForFileMove(_ rawFiles: [URL], workspace: WorkspaceModel) -> Bool {
    let files = uniqueStandardizedFiles(rawFiles)
    guard let first = files.first else { return false }
    let panel = NSOpenPanel()
    panel.title = files.count == 1 ? "Переместить файл" : "Переместить файлы"
    panel.message = files.count == 1
        ? "Выберите папку назначения для «\(first.lastPathComponent)»."
        : "Выберите общую папку назначения для \(files.count) выбранных файлов."
    panel.prompt = "Переместить"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    panel.treatsFilePackagesAsDirectories = false
    panel.directoryURL = first.deletingLastPathComponent()
    guard panel.runModal() == .OK, let folder = panel.url else { return false }
    performFileMoves(files, to: folder, workspace: workspace)
    return true
}

/// Shared completion path for context-menu and drag-and-drop moves.
@MainActor
func performFileMove(_ file: URL, to folder: URL, workspace: WorkspaceModel) {
    performFileMoves([file], to: folder, workspace: workspace)
}

private struct PreparedFileMove {
    let source: URL
    let presentation: AppState.FilePresentationState
    let preparation: DocumentMovePreparation?
}

private struct FileMovePathMutation {
    let source: URL
    let destination: URL
    let sourceToken: UUID
    let destinationToken: UUID

    var tokens: Set<UUID> { [sourceToken, destinationToken] }
}

/// Where a parked presentation can safely resume after a move rollback failed.
/// Ambiguous disk or sidecar state deliberately has no automatic reopen path.
enum FileMoveRecoveryResolution: Equatable, Sendable {
    case source
    case destination(URL)
    case unresolved
}

func fileMoveRecoveryResolutions(
    for rawFiles: [URL],
    after error: Error
) -> [URL: FileMoveRecoveryResolution] {
    var resolutions: [URL: FileMoveRecoveryResolution] = [:]
    for file in rawFiles {
        resolutions[file.standardizedFileURL] = .source
    }

    guard let moveError = error as? FileMoveError,
          case .rollbackFailed(let states) = moveError else {
        return resolutions
    }

    for state in states {
        let source = state.move.source.standardizedFileURL
        guard resolutions[source] != nil else { continue }

        let sidecarCanStayAtSource = !state.reviewSidecarAtDestination
            && (!state.expectedReviewSidecar || state.reviewSidecarAtSource)
        let sidecarCanStayAtDestination = !state.reviewSidecarAtSource
            && (!state.expectedReviewSidecar || state.reviewSidecarAtDestination)

        if state.fileAtSource, !state.fileAtDestination,
           sidecarCanStayAtSource {
            resolutions[source] = .source
        } else if !state.fileAtSource, state.fileAtDestination,
                  sidecarCanStayAtDestination {
            resolutions[source] = .destination(
                state.move.destination.standardizedFileURL)
        } else {
            resolutions[source] = .unresolved
        }
    }
    return resolutions
}

/// Shared transactional completion path for context-menu and drag-and-drop.
/// Every open document is parked before disk I/O, then the whole presentation
/// topology is restored at either all new paths or all original paths.
@MainActor
func performFileMoves(_ rawFiles: [URL], to rawFolder: URL, workspace: WorkspaceModel) {
    let folder = rawFolder.standardizedFileURL
    let files = uniqueStandardizedFiles(rawFiles).filter {
        $0.deletingLastPathComponent() != folder
    }
    guard !files.isEmpty else { return }
    Task { @MainActor in
        do {
            try await LongRunningOperationCenter.shared.run(
                title: files.count == 1
                    ? "Перемещаем «\(files[0].lastPathComponent)»…"
                    : "Перемещаем файлы (\(files.count))…"
            ) {
                // Acquire the global FIFO permit before installing path gates.
                // A transaction queued behind an earlier rename must not keep
                // gates that the earlier transaction can relocate underneath
                // its still-stale source arguments.
                let review = ReviewModel.shared
                let reviewToken = await review.beginPathMutation()
                var reviewMutationResolved = false
                defer {
                    if !reviewMutationResolved {
                        review.cancelPathMutation(reviewToken)
                    }
                }

                let registry = DocumentRegistry.shared
                let appState = AppState.shared
                let pathMutations = files.map { source in
                    let destination = folder
                        .appendingPathComponent(source.lastPathComponent)
                        .standardizedFileURL
                    return FileMovePathMutation(
                        source: source,
                        destination: destination,
                        sourceToken: appState.beginPathMutation(at: source),
                        destinationToken: appState.beginPathMutation(at: destination))
                }
                let routeTokensBySource = Dictionary(
                    uniqueKeysWithValues: pathMutations.map {
                        ($0.source, $0.tokens)
                    })
                var discardedRouteTokens = Set<UUID>()
                defer {
                    appState.finishPathMutations(
                        Set(pathMutations.flatMap(\.tokens)),
                        discardingRouteIDs: discardedRouteTokens)
                }

                var prepared: [PreparedFileMove] = []
                var destinationPreparations: [URL: DocumentMovePreparation] = [:]
                do {
                    // Reserve every future path before extracting any live
                    // source model. If one destination is occupied, every
                    // editor remains attached to its ordinary registry entry.
                    for mutation in pathMutations {
                        destinationPreparations[mutation.source] = try registry
                            .reserveMoveDestination(mutation.destination)
                    }

                    // No suspension in this pass: the whole batch becomes
                    // registry-owned before the first dirty snapshot write.
                    // A control/agent edit cannot slip into a later source
                    // while an earlier source is persisting off-main.
                    for source in files {
                        let preparation = try registry.beginMovePreparation(source)
                        prepared.append(PreparedFileMove(
                            source: source,
                            presentation: appState.detachFileForMove(source),
                            preparation: preparation))
                    }
                    for item in prepared {
                        if let preparation = item.preparation {
                            try await registry.persistMovePreparation(preparation)
                        }
                    }
                    let moves = try await workspace.moveFilesOnDisk(files, to: folder)
                    let destinations = Dictionary(
                        uniqueKeysWithValues: moves.map { ($0.source, $0.destination) })
                    for reservation in destinationPreparations.values {
                        registry.discardMovePreparation(reservation)
                    }
                    for move in moves {
                        registry.relocatePreparedDocument(
                            from: move.source, to: move.destination)
                        appState.relocateFile(from: move.source, to: move.destination)
                        DocumentHistory.shared.relocateFile(
                            from: move.source, to: move.destination)
                    }
                    review.completePathMutation(
                        reviewToken,
                        relocatingFiles: moves.map {
                            ReviewModel.FileRelocation(
                                from: $0.source, to: $0.destination)
                        })
                    reviewMutationResolved = true
                    restorePreparedFiles(
                        prepared,
                        destinations: destinations,
                        routeTokens: routeTokensBySource)
                } catch {
                    var resolutions = fileMoveRecoveryResolutions(
                        for: files, after: error)
                    let pathsToProbe = pathMutations.flatMap {
                        [$0.source, $0.destination]
                    }
                    let existingPaths = await Task.detached(
                        priority: .userInitiated
                    ) {
                        Set(pathsToProbe.filter {
                            FileManager.default.fileExists(atPath: $0.path)
                        })
                    }.value
                    for source in files {
                        switch resolutions[source] ?? .source {
                        case .source where !existingPaths.contains(source):
                            resolutions[source] = .unresolved
                        case .destination(let destination)
                            where !existingPaths.contains(destination):
                            resolutions[source] = .unresolved
                        default:
                            break
                        }
                    }
                    // Keep every destination reserved through the awaited
                    // filesystem probe. Release them only now, immediately
                    // before applying the final source/destination outcomes.
                    for reservation in destinationPreparations.values {
                        registry.discardMovePreparation(reservation)
                    }
                    var destinations: [URL: URL] = [:]
                    var reviewRelocations: [ReviewModel.FileRelocation] = []
                    var unresolved = Set<URL>()

                    for item in prepared {
                        switch resolutions[item.source] ?? .source {
                        case .source:
                            registry.cancelMovePreparation(item.preparation)
                        case .destination(let destination):
                            registry.relocatePreparedDocument(
                                from: item.source, to: destination)
                            appState.relocateFile(
                                from: item.source, to: destination)
                            DocumentHistory.shared.relocateFile(
                                from: item.source, to: destination)
                            destinations[item.source] = destination
                            reviewRelocations.append(.init(
                                from: item.source, to: destination))
                        case .unresolved:
                            registry.discardMovePreparation(item.preparation)
                            unresolved.insert(item.source)
                        }
                    }

                    var reviewDroppedPaths = unresolved
                    for mutation in pathMutations {
                        switch resolutions[mutation.source] ?? .source {
                        case .source:
                            if !existingPaths.contains(mutation.destination) {
                                discardedRouteTokens.insert(
                                    mutation.destinationToken)
                                reviewDroppedPaths.insert(
                                    mutation.destination)
                            }
                        case .destination:
                            break
                        case .unresolved:
                            discardedRouteTokens.formUnion(mutation.tokens)
                            reviewDroppedPaths.formUnion([
                                mutation.source, mutation.destination
                            ])
                        }
                    }
                    let isRollbackFailure: Bool = {
                        guard let moveError = error as? FileMoveError,
                              case .rollbackFailed = moveError else {
                            return false
                        }
                        return true
                    }()
                    if !reviewRelocations.isEmpty
                        || !reviewDroppedPaths.isEmpty
                        || isRollbackFailure {
                        review.completePathMutation(
                            reviewToken,
                            relocatingFiles: reviewRelocations,
                            droppingFiles: Array(reviewDroppedPaths))
                    } else {
                        review.cancelPathMutation(reviewToken)
                    }
                    reviewMutationResolved = true
                    restorePreparedFiles(
                        prepared,
                        destinations: destinations,
                        skipping: unresolved,
                        routeTokens: routeTokensBySource)
                    throw error
                }
            }
        } catch {
            presentFolderError(
                error,
                title: files.count == 1
                    ? "Не удалось переместить файл"
                    : "Не удалось переместить файлы")
        }
    }
}

private func uniqueStandardizedFiles(_ rawFiles: [URL]) -> [URL] {
    var seen = Set<URL>()
    return rawFiles.compactMap { raw in
        let file = raw.standardizedFileURL
        return seen.insert(file).inserted ? file : nil
    }
}

@MainActor
private func restorePreparedFiles(
    _ prepared: [PreparedFileMove],
    destinations: [URL: URL],
    skipping skippedSources: Set<URL> = [],
    routeTokens: [URL: Set<UUID>] = [:]
) {
    // The globally focused presentation is reopened last, after the rest of
    // the batch can no longer steal focus from it.
    let ordered = prepared.filter {
        !skippedSources.contains($0.source)
    }.sorted { lhs, rhs in
        lhs.presentation.focus == .neither && rhs.presentation.focus != .neither
    }
    for item in ordered {
        AppState.shared.restoreFilePresentation(
            item.presentation,
            at: destinations[item.source] ?? item.source,
            ignoringPathMutationIDs: routeTokens[item.source] ?? [])
    }
}

private struct FileMoveDropTargetModifier: ViewModifier {
    @ObservedObject var workspace: WorkspaceModel
    let folder: URL
    let onMoveStarted: () -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: 2)
                    .allowsHitTesting(false)
            }
            .onDrop(of: [sidebarFileDragContentType], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(sidebarFileDragContentType.identifier)
                }) else { return false }
                provider.loadDataRepresentation(
                    forTypeIdentifier: sidebarFileDragContentType.identifier
                ) { data, _ in
                    guard let data,
                          let payload = try? decodeSidebarFileDragPayload(data),
                          !payload.files.isEmpty else { return }
                    Task { @MainActor in
                        performFileMoves(payload.files, to: folder, workspace: workspace)
                        onMoveStarted()
                    }
                }
                return true
            }
    }
}

extension View {
    func fileMoveDropTarget(
        folder: URL,
        workspace: WorkspaceModel,
        onMoveStarted: @escaping () -> Void = {}
    ) -> some View {
        modifier(FileMoveDropTargetModifier(
            workspace: workspace,
            folder: folder,
            onMoveStarted: onMoveStarted))
    }
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

    private var windowTitle: String {
        workspace.workspaceRoot(at: folderURL)?.name ?? folderURL.lastPathComponent
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                WorkspaceSidebar(
                    workspace: workspace,
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
            window.title = windowTitle
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
    @State private var statsLoading = true
    @State private var statsTask: Task<Void, Never>?

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

    private var rootWorkspace: WorkspaceModel.Workspace? {
        workspace.workspaceRoot(at: folderURL)
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

    // MARK: Action strip (buttons + compact tree counts)

    private var actionStrip: some View {
        HStack(alignment: .center, spacing: 6) {
            HStack(spacing: 0) {
                iconButton("doc.badge.plus", "Новый файл", action: newFile)
                pillSeparator
                iconButton("folder.badge.plus", "Новая папка", action: newFolder)
                pillSeparator
                iconButton("arrow.up.right.square", "Показать в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folderURL])
                }
                if let rootWorkspace {
                    pillSeparator
                    folderIdentityMenu(rootWorkspace)
                }
                if let home = homeDoc {
                    let isReadme = home.lastPathComponent.lowercased().hasPrefix("readme")
                    pillSeparator
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
            // Counts flush after the pill — whole group stays on the left.
            compactStats
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same left rail as title / first grid icon / section headers.
        .padding(.leading, contentLeading + contentIconRail)
        .padding(.trailing, contentLeading)
        .padding(.top, SidebarChrome.barPaddingTop)
        .padding(.bottom, SidebarChrome.barPaddingBottom)
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
                        value: statsLoading ? "…" : "\(treeStats?.markdownCount ?? 0)")
            Text("·")
                .foregroundStyle(.quaternary)
                .font(.system(size: 11))
                .padding(.horizontal, 1)
            compactStat(systemImage: "folder",
                        value: statsLoading ? "…" : "\(treeStats?.subfolderCount ?? 0)")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .fixedSize(horizontal: true, vertical: false)
        .editMDHelp(statsLoading
                    ? "Подсчитывается…"
                    : "Во всём дереве: \(treeStats?.markdownCount ?? 0) файлов, \(treeStats?.subfolderCount ?? 0) подпапок")
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

    /// Hairline between pill buttons — same as Files/Outline in the sidebar.
    private var pillSeparator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 14)
            .padding(.horizontal, 3)
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

    private func folderIdentityMenu(_ ws: WorkspaceModel.Workspace) -> some View {
        Menu {
            Button("Изменить отображаемое имя…") {
                promptForWorkspaceDisplayName(ws, workspace: workspace)
            }
            Button("Переименовать папку на диске…") {
                promptForWorkspaceFolderRename(ws, workspace: workspace)
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.primary)
                .frame(width: SidebarChrome.iconButtonWidth,
                       height: SidebarChrome.iconButtonHeight)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .editMDHelp("Имя папки")
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
                Text("Папка: \(ws.folderName)")
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
            .editMDHelp("Скопировать путь")
        }
        .padding(.leading, contentIconRail)
    }

    // MARK: Nested folder tree (D8)

    /// Full-depth tree of folders with .md counts — data only from cached scan.
    @ViewBuilder private var nestedFolderTree: some View {
        let nodes = treeStats?.folderTree ?? []
        if !nodes.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("ПОДПАПКИ")
                ForEach(nodes) { node in
                    FolderTreeRowView(workspace: workspace, node: node, depth: 0)
                }
            }
            .padding(.leading, contentIconRail)
        }
    }

    // MARK: Content grid (direct children + hidden section)

    /// Main grid: folders with md + visible files.
    /// Bottom sections (like hidden files): «Пустые папки», then «Скрытые».
    private var contentList: some View {
        let _ = workspace.contentEpoch
        let folders = treeStats?.directMarkdownFolders ?? []
        let emptyFolders = treeStats?.directEmptyFolders ?? []
        let visible = workspace.visibleMarkdown(in: folderURL)
        let hidden = workspace.hiddenMarkdown(in: folderURL)
        let empty = !statsLoading
            && folders.isEmpty && emptyFolders.isEmpty
            && visible.isEmpty && hidden.isEmpty

        return VStack(alignment: .leading, spacing: 12) {
            if empty {
                Text("Нет файлов")
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
                    sectionHeader("ПУСТЫЕ ПАПКИ")
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 8) {
                        ForEach(emptyFolders, id: \.self) { sub in
                            folderTile(sub, dimmed: true)
                        }
                    }
                }
                if !hidden.isEmpty {
                    sectionHeader("СКРЫТЫЕ")
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
        Button("Открыть в отдельном окне") {
            AppState.shared.openInSeparateWindow(file)
        }
        Divider()
        Button("Переместить…") {
            promptForFileMove(file, workspace: workspace)
        }
        Button(hidden ? "Вернуть в список" : "Скрыть из списка") {
            if hidden { workspace.unhide(file) } else { workspace.hide(file) }
        }
        Button("Скопировать путь") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(file.path, forType: .string)
        }
        Button("Показать в Finder") {
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
                    .editMDHelp(showUnhide ? "Вернуть в список" : "Скрыть из списка")
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
