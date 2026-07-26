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

    /// User name → renamed file name. Finder semantics: the field is prefilled
    /// with the full current name (extension included) and edited freely. When
    /// the user drops the extension, `original`'s extension is restored so a
    /// managed document does not silently leave the sidebar.
    static func renamedFileName(from raw: String, keepingExtensionOf original: URL) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FolderCreateError.emptyName }
        try validateBaseName(trimmed)
        let ext = (trimmed as NSString).pathExtension
        let originalExt = original.pathExtension
        if ext.isEmpty && !originalExt.isEmpty {
            return trimmed + "." + originalExt
        }
        return trimmed
    }

    private static func validateBaseName(_ name: String) throws {
        if name == "." || name == ".." { throw FolderCreateError.invalidName }
        if name.contains("/") || name.contains(":") || name.contains("\0") {
            throw FolderCreateError.invalidName
        }
        // Every listing skips hidden files, so a dot-prefixed create/rename
        // would make the item silently vanish from the sidebar while staying
        // open in the editor. Refuse instead of hiding.
        if name.hasPrefix(".") { throw FolderCreateError.hiddenName }
    }
}

enum FolderCreateError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case hiddenName
    case alreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return String(localized: "The name cannot be empty.")
        case .invalidName: return String(localized: "Invalid name.")
        case .hiddenName: return String(localized: "Names that start with a dot are hidden files and would disappear from the list.")
        case .alreadyExists(let n): return String(localized: "“\(n)” already exists.")
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
            return String(localized: "This folder is no longer open in the sidebar.")
        case .folderNoLongerExists:
            return String(localized: "The folder no longer exists at its previous path.")
        case .openDocuments(let count):
            return String(localized: "Close the open files inside the folder first (\(count) documents).")
        case .renameInProgress:
            return String(localized: "This folder is already being renamed.")
        case .diskFailure(let survivor):
            if let survivor {
                return String(localized: "Could not finish the rename. The folder survived at “\(survivor.path)”; EditMD state now points there.")
            }
            return String(localized: "Could not finish the rename, and the on-disk state of the folder is ambiguous. Check the old and new paths in Finder.")
        }
    }
}

// `homeDocument(in:)` moved to Editor/VaultLint.swift (pure — shared
// with the offline editmdctl engine).

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
    /// Direct child folders with no markdown in the tree (bottom section, like "Hidden").
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
                      confirmTitle: String = String(localized: "Create"), allowsEmpty: Bool = false) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: String(localized: "Cancel"))
    let field = NSTextField(string: defaultName)
    field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
    alert.accessoryView = field
    guard runModal(alert, focusing: field) == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty && !allowsEmpty ? nil : name
}

@MainActor
func promptForNewMarkdownFile(in folder: URL) -> (name: String, template: FileTemplate)? {
    let alert = NSAlert()
    alert.messageText = String(localized: "New Markdown File")
    alert.informativeText = String(localized: "The file will be created in “\(folder.lastPathComponent)”.")
    alert.addButton(withTitle: String(localized: "Create"))
    alert.addButton(withTitle: String(localized: "Cancel"))

    let field = NSTextField(string: String(localized: "Untitled") + ".md")
    field.placeholderString = String(localized: "File name")
    let templatePicker = NSPopUpButton(frame: .zero, pullsDown: false)
    for template in FileTemplate.allCases {
        templatePicker.addItem(withTitle: template.title)
        templatePicker.lastItem?.representedObject = template.rawValue
    }

    let nameLabel = NSTextField(labelWithString: String(localized: "Name:"))
    let templateLabel = NSTextField(labelWithString: String(localized: "Template:"))
    let grid = NSGridView(views: [
        [nameLabel, field],
        [templateLabel, templatePicker]
    ])
    grid.column(at: 0).xPlacement = .trailing
    grid.column(at: 1).width = 230
    grid.rowSpacing = 8
    grid.frame = NSRect(x: 0, y: 0, width: 300, height: 58)
    alert.accessoryView = grid

    guard runModal(alert, focusing: field) == .alertFirstButtonReturn else { return nil }
    let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty,
          let rawTemplate = templatePicker.selectedItem?.representedObject as? String,
          let template = FileTemplate(rawValue: rawTemplate) else { return nil }
    return (name, template)
}

@MainActor
func presentFolderError(_ error: Error, title: String = String(localized: "Could not create")) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = error.localizedDescription
    alert.alertStyle = .warning
    alert.addButton(withTitle: String(localized: "OK"))
    alert.runModal()
}

@MainActor
func promptForWorkspaceDisplayName(_ ws: WorkspaceModel.Workspace,
                                   workspace: WorkspaceModel) {
    guard let name = promptForNewName(
        title: String(localized: "Display Name"),
        message: String(localized: "This name is visible only in EditMD. An empty field restores the real folder name."),
        defaultName: ws.displayName ?? ws.folderName,
        confirmTitle: String(localized: "Save"),
        allowsEmpty: true
    ) else { return }
    workspace.setDisplayName(name, for: ws)
}

@MainActor
func promptForWorkspaceFolderRename(_ ws: WorkspaceModel.Workspace,
                                    workspace: WorkspaceModel) {
    guard let name = promptForNewName(
        title: String(localized: "Rename Folder on Disk"),
        message: String(localized: "The name will change in Finder as well. Close files from this folder before renaming."),
        defaultName: ws.folderName,
        confirmTitle: String(localized: "Rename")
    ) else { return }

    Task { @MainActor in
        let oldURL = ws.url.standardizedFileURL
        let expectedNewURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
        do {
            try await LongRunningOperationCenter.shared.run(
                title: String(localized: "Renaming “\(oldURL.lastPathComponent)”…")
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
            presentFolderError(error, title: String(localized: "Could not rename the folder"))
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
        title: String(localized: "New Folder"),
        message: String(localized: "The folder will be created in “\(folder.lastPathComponent)”."),
        defaultName: String(localized: "New Folder")
    ) else { return }
    do {
        _ = try workspace.createSubfolder(named: name, in: folder)
    } catch {
        presentFolderError(error)
    }
}
