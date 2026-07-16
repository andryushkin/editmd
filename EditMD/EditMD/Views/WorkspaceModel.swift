import SwiftUI
import AppKit

struct FileMoveResult: Equatable, Sendable {
    let source: URL
    let destination: URL
}

typealias FileMoveItemOperation = @Sendable (
    _ source: URL, _ destination: URL
) throws -> Void

/// Filesystem state left behind when a move transaction could not be rolled
/// back completely. Callers use the file flags to relocate any parked/open
/// document to the path that actually survived; the sidecar flags make a split
/// document/review state explicit instead of hiding a second rollback failure.
struct FileMoveRollbackState: Equatable, Sendable {
    let move: FileMoveResult
    let expectedReviewSidecar: Bool
    let fileAtSource: Bool
    let fileAtDestination: Bool
    let reviewSidecarAtSource: Bool
    let reviewSidecarAtDestination: Bool

    var fileRemainsAtDestination: Bool {
        fileAtDestination && !fileAtSource
    }

    var isFullyRolledBack: Bool {
        fileAtSource && !fileAtDestination
            && (!expectedReviewSidecar
                || (reviewSidecarAtSource && !reviewSidecarAtDestination))
    }
}

enum FileMoveError: LocalizedError, Equatable, Sendable {
    case sourceNoLongerExists
    case unsupportedSource
    case destinationNotFolder
    case alreadyExists(String)
    case moveInProgress
    case rollbackFailed([FileMoveRollbackState])

    var errorDescription: String? {
        switch self {
        case .sourceNoLongerExists:
            return "Файл больше не существует по прежнему пути."
        case .unsupportedSource:
            return "Можно перемещать только файлы, которые EditMD показывает в сайдбаре."
        case .destinationNotFolder:
            return "Папка назначения больше не существует."
        case .alreadyExists(let name):
            return "В папке назначения уже существует «\(name)»."
        case .moveInProgress:
            return "Этот файл уже перемещается."
        case .rollbackFailed(let states):
            let names = states.map { "«\($0.move.destination.lastPathComponent)»" }
                .joined(separator: ", ")
            return "Не удалось полностью отменить перенос \(names). Пути на диске были перепроверены; обновите открытые документы перед продолжением."
        }
    }
}

/// Backing state for the file sidebar (Phase 3): the adopted workspace folders,
/// which files are hidden per folder, pinned loose files, and the session's
/// loose (Finder-opened, not-in-a-workspace) files. Persisted to UserDefaults
/// keyed by folder path so the folders on disk stay clean (no dotfiles).
///
/// UserDefaults is injectable so tests get an isolated store.
@MainActor
final class WorkspaceModel: ObservableObject {

    /// The XCTest host must not write the developer's real snapshot file — it
    /// runs with `.standard` defaults like the app does (see `AppDelegate`).
    static let shared = WorkspaceModel(
        snapshotURL: AppDelegate.isRunningUnitTests ? nil : SidebarSnapshotStore.defaultURL())

    struct Workspace: Codable, Equatable, Identifiable {
        var folderPath: String
        var collapsed: Bool = false
        /// Optional display name; nil / empty → folder basename (legacy decode OK).
        var customName: String? = nil
        var id: String { folderPath }
        var url: URL { URL(fileURLWithPath: folderPath) }
        var folderName: String { url.lastPathComponent }
        var displayName: String? {
            guard let customName else { return nil }
            let trimmed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        var name: String { displayName ?? folderName }
    }

    /// Adopted folders, always visible, collapsible.
    @Published var workspaces: [Workspace] { didSet { persist(workspaces, Keys.folders) } }
    /// workspace root path → set of **relative paths** of hidden markdown files
    /// (e.g. `note.md`, `sub/a.md`). Legacy entries without `/` are root basenames.
    @Published var hiddenFiles: [String: Set<String>] { didSet { persist(hiddenFiles, Keys.hidden) } }
    /// Pinned loose files (persist across launches), stored as paths.
    @Published var pinnedLoosePaths: [String] { didSet { persist(pinnedLoosePaths, Keys.pinned) } }
    /// Session-only loose files (opened this run, not in any workspace).
    @Published var looseFiles: [URL] = []
    /// Paths of subfolders expanded in the tree. Session state, not persisted:
    /// a launch derives the open branch from `lastActivePath` instead (see
    /// `normalizeStartupTree`). The tree is lazy — a subfolder's contents are
    /// only scanned while it is expanded — so adopting a folder with thousands
    /// of nested files stays cheap.
    @Published var expandedFolders: Set<String> = []

    /// Last file or folder the main window showed (persisted). Startup reopens
    /// this branch and collapses everything else — see `normalizeStartupTree`.
    @Published private(set) var lastActivePath: String? { didSet { persist(lastActivePath, Keys.lastActive) } }

    /// D11: tag → files (frontmatter only). Filled off-main; read from UI.
    @Published private(set) var tagIndex: [String: [URL]] = [:]
    private var tagScanInFlight = false
    private var tagScanPending = false
    private var tagIndexKey = ""
    private var folderRenamesInFlight = Set<String>()
    private var fileMovesInFlight = Set<String>()

    private let defaults: UserDefaults

    private enum Keys {
        static let folders = "workspace.folders"
        static let hidden = "workspace.hidden"
        static let pinned = "workspace.pinned"
        static let lastActive = "workspace.lastActive"
    }

    /// First frame of the tree, carried over from the previous run.
    /// `snapshotURL: nil` keeps it in memory — the default, so only the app's
    /// `shared` instance (and a test that asks for a temp file) touches disk.
    let snapshot: SidebarSnapshotStore

    init(defaults: UserDefaults = .standard, snapshotURL: URL? = nil) {
        self.defaults = defaults
        snapshot = SidebarSnapshotStore(fileURL: snapshotURL)
        workspaces = Self.load(defaults, Keys.folders) ?? []
        hiddenFiles = Self.load(defaults, Keys.hidden) ?? [:]
        pinnedLoosePaths = Self.load(defaults, Keys.pinned) ?? []
        lastActivePath = Self.load(defaults, Keys.lastActive)
        normalizeStartupTree()
        // Folder contents may change in Finder/Terminal while EditMD is in the
        // background — re-validate listings lazily on return (selector-based:
        // the block API's @Sendable closure clashes with @MainActor).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    // MARK: - Startup tree

    /// Records the main window's target so the next launch reopens this branch.
    func noteActive(_ url: URL) {
        lastActivePath = url.standardizedFileURL.path
    }

    /// Launch state of the tree: exactly one branch open — the one holding
    /// `lastActivePath` — and every other root collapsed.
    ///
    /// Restoring every expanded folder verbatim (the old behaviour) meant the
    /// first frame asked for a recursive scan of every open root at once, and
    /// each of those roots showed up empty until its walk returned. Reopening
    /// one branch is both what the user left behind and the cheapest scan.
    private func normalizeStartupTree() {
        guard !workspaces.isEmpty else {
            expandedFolders = []
            return
        }
        guard let active = lastActivePath,
              let owner = workspaceOwning(URL(fileURLWithPath: active)) else {
            // No remembered branch: show the first root's own contents, nothing
            // nested (a fresh adopt looks the same way).
            for i in workspaces.indices { workspaces[i].collapsed = (i != 0) }
            expandedFolders = []
            return
        }
        for i in workspaces.indices {
            workspaces[i].collapsed = (workspaces[i].id != owner.id)
        }
        expandedFolders = Self.ancestorFolders(of: active, under: owner.folderPath)
    }

    /// Folders between a workspace root (exclusive) and `path` — plus `path`
    /// itself when it is a folder — as expanded-tree paths.
    static func ancestorFolders(of path: String, under root: String) -> Set<String> {
        var result: Set<String> = []
        var url = URL(fileURLWithPath: path).standardizedFileURL
        if !AppState.isFolder(url) {
            url = url.deletingLastPathComponent()
        }
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        while url.path != rootPath, url.path.hasPrefix(rootPath + "/") {
            result.insert(url.path)
            url = url.deletingLastPathComponent()
        }
        return result
    }

    @objc private func appDidBecomeActive() {
        noteFilesystemChange()
    }

    // MARK: - Folder scan

    /// Everything the sidebar lists and the app opens in place: Markdown,
    /// read-only PDF, and common image formats.
    nonisolated private static let listedExtensions: Set<String> =
        Set(["md", "markdown", "textbundle", "pdf"]).union(supportedImageFileExtensions)

    /// path → (epoch, direct md children). Views read listings through this
    /// cache: a single blocked `contentsOfDirectory` (TCC arbitration, dead
    /// network mount, huge directory) used to freeze the whole app because the
    /// sidebar listed folders synchronously in its SwiftUI body.
    private var folderListings: [String: (epoch: Int, files: [URL])] = [:]
    private var listingScansInFlight = Set<String>()

    /// Direct markdown children of a folder (flat, non-recursive), name-sorted.
    /// Non-blocking, stale-while-revalidate: a cache miss returns [] and fills
    /// off the main actor; an out-of-epoch hit is served as-is while a refresh
    /// runs (no flicker on `contentEpoch` bumps).
    func markdownFiles(in folder: URL) -> [URL] {
        let key = folder.standardizedFileURL
        let path = key.path
        if let hit = folderListings[path] {
            if hit.epoch != contentEpoch {
                scheduleListingScan(path: path, folder: key, epoch: contentEpoch)
            }
            return hit.files
        }
        scheduleListingScan(path: path, folder: key, epoch: contentEpoch)
        // Cold launch: serve last run's listing while the scan runs, so a
        // restored branch draws its files in the first frame.
        return snapshot.entry(for: path)?.urls.files ?? []
    }

    /// Synchronous list + cache fill — for tests and explicit refresh paths
    /// that need the result immediately.
    @discardableResult
    func primeFolderListing(_ folder: URL) -> [URL] {
        let key = folder.standardizedFileURL
        let files = Self.listMarkdownFiles(in: key)
        folderListings[key.path] = (contentEpoch, files)
        return files
    }

    private func scheduleListingScan(path: String, folder: URL, epoch: Int) {
        guard !listingScansInFlight.contains(path) else { return }
        listingScansInFlight.insert(path)
        Task { [weak self] in
            let files = await Task.detached(priority: .userInitiated) {
                Self.listMarkdownFiles(in: folder)
            }.value
            guard let self else { return }
            self.listingScansInFlight.remove(path)
            guard self.contentEpoch == epoch else { return }
            let changed = self.folderListings[path]?.files != files
            self.folderListings[path] = (epoch, files)
            self.snapshot.update(path: path) { $0.files = files.map(\.path) }
            if changed {
                self.objectWillChange.send()
            }
        }
    }

    nonisolated private static func listMarkdownFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { listedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Immediate subfolders of `folder` (non-recursive), name-sorted. Skips
    /// hidden folders and packages (a `.textbundle` is a document, listed by
    /// `markdownFiles`, not a folder to descend into).
    func subfolders(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { url in
                let vals = try? url.resourceValues(forKeys: Set(keys))
                return (vals?.isDirectory ?? false) && !(vals?.isPackage ?? false)
            }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Paths with a background tree-stats scan in flight (no duplicate walks).
    private var treeStatsScansInFlight = Set<String>()

    /// Tree stats for `folder` (counts + direct md/empty child folders). Uses
    /// `FolderStatsCache` keyed by path + `contentEpoch` so the sidebar and
    /// folder card share one scan.
    ///
    /// Non-blocking: this is called from SwiftUI body (sidebar), so a cache
    /// miss returns empty stats and fills the cache off the main actor — a
    /// synchronous full-tree walk here froze app startup for minutes on a big
    /// workspace (sample: `contentsOfDirectory` on the main thread).
    func treeStats(for folder: URL) -> FolderTreeStats {
        let path = folder.standardizedFileURL.path
        let epoch = contentEpoch
        if let entry = FolderStatsCache.lookupAny(path: path) {
            // Stale-while-revalidate: keep showing the old tree while the
            // rescan runs so an epoch bump doesn't blank the sidebar.
            if entry.epoch != epoch {
                scheduleTreeStatsScan(path: path, folder: folder.standardizedFileURL, epoch: epoch)
            }
            return entry.stats
        }
        scheduleTreeStatsScan(path: path, folder: folder.standardizedFileURL, epoch: epoch)
        // Cold launch: last run's subfolder split (md-bearing vs empty) stands
        // in until the recursive walk lands — that walk is what used to leave a
        // restored root drawn open but empty for seconds. `folderTree` stays
        // empty: only the folder card reads it, and it rescans on appear.
        if let entry = snapshot.entry(for: path) {
            let urls = entry.urls
            return FolderTreeStats(markdownCount: entry.markdownCount,
                                   subfolderCount: entry.subfolderCount,
                                   directMarkdownFolders: urls.mdFolders,
                                   directEmptyFolders: urls.emptyFolders)
        }
        return FolderTreeStats(markdownCount: 0, subfolderCount: 0,
                               directMarkdownFolders: [], directEmptyFolders: [])
    }

    /// One background scan per path; publishes when the cache fills so the
    /// sidebar re-renders with the real subfolder lists.
    private func scheduleTreeStatsScan(path: String, folder: URL, epoch: Int) {
        guard !treeStatsScansInFlight.contains(path) else { return }
        treeStatsScansInFlight.insert(path)
        Task { [weak self] in
            let stats = await Task.detached(priority: .userInitiated) {
                scanFolderTreeStats(at: folder)
            }.value
            guard let self else { return }
            self.treeStatsScansInFlight.remove(path)
            // Epoch advanced while scanning (New File/Folder) — stale result;
            // the next body pass re-requests against the new epoch.
            guard self.contentEpoch == epoch else { return }
            let changed = FolderStatsCache.lookupAny(path: path)?.stats != stats
            FolderStatsCache.store(path: path, epoch: epoch, stats: stats)
            self.snapshot.update(path: path) {
                $0.mdFolders = stats.directMarkdownFolders.map(\.path)
                $0.emptyFolders = stats.directEmptyFolders.map(\.path)
                $0.markdownCount = stats.markdownCount
                $0.subfolderCount = stats.subfolderCount
            }
            if changed {
                self.objectWillChange.send()
            }
        }
    }

    /// D11: ensure `tagIndex` is current for both filesystem contents and the
    /// adopted root set (stale-while-revalidate).
    func ensureTagIndex() {
        let epoch = contentEpoch
        let roots = workspaces.map(\.url)
        let key = tagScanKey(epoch: epoch, roots: roots)
        if tagIndexKey == key { return }
        guard !tagScanInFlight else {
            tagScanPending = true
            return
        }
        tagScanInFlight = true
        Task { [weak self] in
            let index = await Task.detached(priority: .utility) {
                scanWorkspaceTags(roots: roots)
            }.value
            guard let self else { return }
            self.tagScanInFlight = false
            let currentRoots = self.workspaces.map(\.url)
            let currentKey = self.tagScanKey(epoch: self.contentEpoch, roots: currentRoots)
            guard currentKey == key, !self.tagScanPending else {
                // A change notification may have arrived while this scan was
                // running. It could not start another scan then, so do it now.
                self.tagScanPending = false
                self.ensureTagIndex()
                return
            }
            self.tagIndex = index
            self.tagIndexKey = key
        }
    }

    private func tagScanKey(epoch: Int, roots: [URL]) -> String {
        "\(epoch):" + roots.map { $0.standardizedFileURL.path }.joined(separator: "\u{1F}")
    }

    /// Direct child folders that contain markdown somewhere in their tree.
    func markdownSubfolders(in folder: URL) -> [URL] {
        treeStats(for: folder).directMarkdownFolders
    }

    /// Direct child folders with no markdown (shown when sidebar eye is on).
    func emptySubfolders(in folder: URL) -> [URL] {
        treeStats(for: folder).directEmptyFolders
    }

    func isExpanded(_ folder: URL) -> Bool {
        expandedFolders.contains(folder.standardizedFileURL.path)
    }

    func toggleExpanded(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if expandedFolders.contains(path) { expandedFolders.remove(path) }
        else { expandedFolders.insert(path) }
    }

    func visibleFiles(_ ws: Workspace) -> [URL] {
        markdownFiles(in: ws.url).filter { !isHidden($0) }
    }

    /// Direct markdown children of the workspace root that are hidden (sidebar review).
    func hiddenFilesList(_ ws: Workspace) -> [URL] {
        markdownFiles(in: ws.url).filter { isHidden($0) }
    }

    /// Direct visible markdown children of any folder (card + nested sidebar).
    func visibleMarkdown(in folder: URL) -> [URL] {
        markdownFiles(in: folder).filter { !isHidden($0) }
    }

    /// Direct hidden markdown children of any folder.
    func hiddenMarkdown(in folder: URL) -> [URL] {
        markdownFiles(in: folder).filter { isHidden($0) }
    }

    /// Count of hidden entries that still exist on disk (for the "N hidden" label).
    var totalHiddenCount: Int {
        workspaces.reduce(0) { partial, ws in
            partial + existingHiddenCount(in: ws)
        }
    }

    /// Hidden relative paths under `ws` that still resolve to a file on disk.
    func existingHiddenCount(in ws: Workspace) -> Int {
        let set = hiddenFiles[ws.folderPath] ?? []
        return set.reduce(0) { count, rel in
            let url = ws.url.appendingPathComponent(rel)
            return count + (FileManager.default.fileExists(atPath: url.path) ? 1 : 0)
        }
    }

    // MARK: - Workspaces

    func addWorkspace(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        guard !workspaces.contains(where: { $0.folderPath == path }) else { return }
        workspaces.append(Workspace(folderPath: path))
        // A loose file that now lives inside an adopted folder is no longer loose.
        looseFiles.removeAll { $0.deletingLastPathComponent().path == path }
    }

    func removeWorkspace(_ ws: Workspace) {
        workspaces.removeAll { $0.id == ws.id }
    }

    /// Set a custom display name; empty / whitespace clears back to folder basename.
    func setDisplayName(_ name: String, for ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[i].customName = trimmed.isEmpty ? nil : trimmed
    }

    /// The adopted root at exactly `folder` (not merely an ancestor root).
    func workspaceRoot(at folder: URL) -> Workspace? {
        let path = folder.standardizedFileURL.path
        return workspaces.first { $0.folderPath == path }
    }

    /// Renames an adopted root on disk, then migrates all path-keyed sidebar
    /// state. Open documents are rejected because DocumentRegistry entries,
    /// undo stacks, autosave and file watchers are URL-bound.
    @discardableResult
    func renameFolderOnDisk(
        _ ws: Workspace,
        to rawName: String,
        openDocumentURLs: [URL]
    ) async throws -> URL {
        guard workspaces.contains(where: { $0.id == ws.id }) else {
            throw FolderRenameError.folderNoLongerOpen
        }
        let oldURL = ws.url.standardizedFileURL
        let newName = try FolderNaming.folderName(from: rawName)
        if newName == oldURL.lastPathComponent { return oldURL }

        let openCount = openDocumentURLs.reduce(into: 0) { count, url in
            if Self.path(url.standardizedFileURL.path, isInside: oldURL.path) {
                count += 1
            }
        }
        guard openCount == 0 else {
            throw FolderRenameError.openDocuments(openCount)
        }
        guard folderRenamesInFlight.insert(oldURL.path).inserted else {
            throw FolderRenameError.renameInProgress
        }
        defer { folderRenamesInFlight.remove(oldURL.path) }

        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(newName, isDirectory: true)
            .standardizedFileURL
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.moveFolderOnDisk(from: oldURL, to: newURL)
            }.value
        } catch let error as FolderRenameError {
            if case .diskFailure(let survivor?) = error,
               survivor.standardizedFileURL != oldURL {
                migrateRootState(from: oldURL.path, to: survivor.path)
            }
            throw error
        }

        migrateRootState(from: oldURL.path, to: newURL.path)
        return newURL
    }

    nonisolated static func relocatedPath(_ path: String, from oldRoot: String,
                                          to newRoot: String) -> String {
        if path == oldRoot { return newRoot }
        let prefix = oldRoot + "/"
        guard path.hasPrefix(prefix) else { return path }
        return newRoot + path.dropFirst(oldRoot.count)
    }

    nonisolated static func relocatedURL(_ url: URL, from oldRoot: URL,
                                         to newRoot: URL) -> URL {
        URL(fileURLWithPath: relocatedPath(url.standardizedFileURL.path,
                                           from: oldRoot.standardizedFileURL.path,
                                           to: newRoot.standardizedFileURL.path))
            .standardizedFileURL
    }

    nonisolated private static func path(_ path: String, isInside root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    nonisolated static func moveFolderOnDisk(
        from oldURL: URL,
        to newURL: URL,
        moveItem: FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: oldURL.path) else {
            // No filesystem mutation has started, so an existing destination
            // is not a survivor of this transaction — it may be an unrelated
            // folder and must never inherit the workspace identity.
            throw FolderRenameError.folderNoLongerExists
        }
        if fileManager.fileExists(atPath: newURL.path) {
            guard sameFilesystemItem(oldURL, newURL) else {
                throw FolderCreateError.alreadyExists(newURL.lastPathComponent)
            }
            try moveFolderThroughTemporary(
                from: oldURL, to: newURL, moveItem: moveItem)
            return
        }
        do {
            try moveItem(oldURL, newURL)
        } catch {
            throw FolderRenameError.diskFailure(
                probedFolderSurvivor([oldURL, newURL]))
        }
    }

    /// A case-insensitive volume reports `Notes` and `notes` as the same
    /// existing item. Move through a unique sibling so the final component is
    /// really updated, and surface the probed survivor if either later step
    /// and its recovery fail.
    nonisolated static func moveFolderThroughTemporary(
        from oldURL: URL,
        to newURL: URL,
        moveItem: FileMoveItemOperation
    ) throws {
        var temporaryURL: URL
        repeat {
            temporaryURL = oldURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".editmd-rename-\(UUID().uuidString)",
                    isDirectory: true)
        } while FileManager.default.fileExists(atPath: temporaryURL.path)

        do {
            try moveItem(oldURL, temporaryURL)
        } catch {
            throw FolderRenameError.diskFailure(
                probedFolderSurvivor([oldURL, newURL, temporaryURL]))
        }
        do {
            try moveItem(temporaryURL, newURL)
        } catch {
            do {
                try moveItem(temporaryURL, oldURL)
            } catch {
                throw FolderRenameError.diskFailure(
                    probedFolderSurvivor([oldURL, newURL, temporaryURL]))
            }
            throw FolderRenameError.diskFailure(oldURL)
        }
    }

    nonisolated private static func sameFilesystemItem(_ lhs: URL, _ rhs: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let lhsID = try? lhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let rhsID = try? rhs.resourceValues(forKeys: keys).fileResourceIdentifier,
              let lhsObject = lhsID as? NSObject,
              let rhsObject = rhsID as? NSObject else { return false }
        return lhsObject == rhsObject
    }

    /// Returns the actual on-disk spelling of one unambiguous survivor. On a
    /// case-insensitive volume the resource `name` reveals the real casing.
    nonisolated private static func probedFolderSurvivor(
        _ candidates: [URL]
    ) -> URL? {
        var survivors: [URL] = []
        for candidate in candidates where FileManager.default.fileExists(
            atPath: candidate.path) {
            let actualName = (try? candidate.resourceValues(
                forKeys: [.nameKey]))?.name
            let actual = actualName.map {
                candidate.deletingLastPathComponent()
                    .appendingPathComponent($0, isDirectory: true)
                    .standardizedFileURL
            } ?? candidate.standardizedFileURL
            if !survivors.contains(where: { sameFilesystemItem($0, actual) }) {
                survivors.append(actual)
            }
        }
        return survivors.count == 1 ? survivors[0] : nil
    }

    private struct FileMoveState {
        let source: URL
        let oldWorkspace: Workspace?
        let oldRelative: String?
        let wasHidden: Bool
        let wasPinned: Bool
    }

    /// Moves one sidebar document to another folder on disk.
    @discardableResult
    func moveFileOnDisk(
        _ rawSource: URL,
        to rawDestinationFolder: URL
    ) async throws -> URL {
        let source = rawSource.standardizedFileURL
        return try await moveFilesOnDisk([source], to: rawDestinationFolder)
            .first?.destination ?? source
    }

    /// Moves a sidebar selection as one logical transaction. Every source and
    /// destination is preflighted before the first mutation. A mid-batch disk
    /// failure rolls completed items back before the error reaches the UI.
    @discardableResult
    func moveFilesOnDisk(
        _ rawSources: [URL],
        to rawDestinationFolder: URL,
        moveItem: @escaping FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) async throws -> [FileMoveResult] {
        let destinationFolder = rawDestinationFolder.standardizedFileURL
        var seen = Set<URL>()
        let sources = rawSources.compactMap { raw -> URL? in
            let source = raw.standardizedFileURL
            guard seen.insert(source).inserted,
                  source.deletingLastPathComponent() != destinationFolder else { return nil }
            return source
        }
        guard !sources.isEmpty else { return [] }

        guard sources.allSatisfy({
            Self.listedExtensions.contains($0.pathExtension.lowercased())
        }) else {
            throw FileMoveError.unsupportedSource
        }
        let paths = Set(sources.map(\.path))
        guard paths.isDisjoint(with: fileMovesInFlight) else {
            throw FileMoveError.moveInProgress
        }
        fileMovesInFlight.formUnion(paths)
        defer { fileMovesInFlight.subtract(paths) }

        let moves = sources.map { source in
            FileMoveResult(
                source: source,
                destination: destinationFolder
                    .appendingPathComponent(source.lastPathComponent)
                    .standardizedFileURL)
        }
        let states = sources.map { source in
            let oldWorkspace = workspaceOwning(source)
            let oldRelative = oldWorkspace.flatMap { relativePath(of: source, in: $0) }
            let wasHidden = oldWorkspace.flatMap { ws in
                oldRelative.map { hiddenFiles[ws.folderPath]?.contains($0) == true }
            } ?? false
            return FileMoveState(
                source: source,
                oldWorkspace: oldWorkspace,
                oldRelative: oldRelative,
                wasHidden: wasHidden,
                wasPinned: pinnedLoosePaths.contains(source.path))
        }

        // FileManager is synchronous and destination folders may live on slow
        // external volumes, so keep the move off the main actor.
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.moveFilesAndReviewSidecars(
                    moves,
                    destinationFolder: destinationFolder,
                    moveItem: moveItem)
            }.value
        } catch {
            if let moveError = error as? FileMoveError,
               case .rollbackFailed(let rollbackStates) = moveError {
                for rollbackState in rollbackStates where rollbackState.fileRemainsAtDestination {
                    guard let state = states.first(where: {
                        $0.source == rollbackState.move.source
                    }) else { continue }
                    migrateFileState(
                        from: state.source,
                        to: rollbackState.move.destination,
                        oldWorkspace: state.oldWorkspace,
                        oldRelative: state.oldRelative,
                        wasHidden: state.wasHidden,
                        wasPinned: state.wasPinned)
                }
                finishFileMoves()
                await WikiLinkResolver.shared.invalidate()
            }
            throw error
        }

        for (state, move) in zip(states, moves) {
            migrateFileState(
                from: state.source,
                to: move.destination,
                oldWorkspace: state.oldWorkspace,
                oldRelative: state.oldRelative,
                wasHidden: state.wasHidden,
                wasPinned: state.wasPinned)
        }
        finishFileMoves()
        await WikiLinkResolver.shared.invalidate()
        return moves
    }

    /// Internal disk core so tests can inject a failing move primitive and
    /// verify rollback reporting without relying on filesystem permissions.
    nonisolated static func moveFilesAndReviewSidecars(
        _ moves: [FileMoveResult],
        destinationFolder: URL,
        moveItem: FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) throws {
        let fileManager = FileManager.default
        guard AppState.isFolder(destinationFolder) else {
            throw FileMoveError.destinationNotFolder
        }

        // Preflight the whole batch. Duplicate basenames from different source
        // folders are a collision even when the destination is initially empty.
        var destinations = Set<String>()
        for move in moves {
            var sourceIsDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: move.source.path, isDirectory: &sourceIsDirectory) else {
                throw FileMoveError.sourceNoLongerExists
            }
            let sourceIsPackage = (try? move.source.resourceValues(
                forKeys: [.isPackageKey]))?.isPackage ?? false
            guard !sourceIsDirectory.boolValue || sourceIsPackage else {
                throw FileMoveError.unsupportedSource
            }
            guard destinations.insert(move.destination.path).inserted,
                  !fileManager.fileExists(atPath: move.destination.path) else {
                throw FileMoveError.alreadyExists(move.destination.lastPathComponent)
            }
            let newSidecar = ReviewSidecar.url(for: move.destination)
            if fileManager.fileExists(atPath: newSidecar.path) {
                throw FileMoveError.alreadyExists(newSidecar.lastPathComponent)
            }
        }

        var completed: [(move: FileMoveResult, hadReviewSidecar: Bool)] = []
        do {
            for move in moves {
                let hadReviewSidecar = try moveFileAndReviewSidecar(
                    from: move.source,
                    to: move.destination,
                    destinationFolder: destinationFolder,
                    moveItem: moveItem)
                completed.append((move, hadReviewSidecar))
            }
        } catch {
            var rollbackStates: [FileMoveRollbackState]
            if let moveError = error as? FileMoveError,
               case .rollbackFailed(let states) = moveError {
                rollbackStates = states
            } else {
                rollbackStates = []
            }

            for completedMove in completed.reversed() {
                do {
                    try rollbackCompletedMove(
                        completedMove.move,
                        hadReviewSidecar: completedMove.hadReviewSidecar,
                        moveItem: moveItem)
                } catch let rollbackError as FileMoveError {
                    if case .rollbackFailed(let states) = rollbackError {
                        rollbackStates.append(contentsOf: states)
                    } else {
                        rollbackStates.append(rollbackState(
                            for: completedMove.move,
                            expectedReviewSidecar: completedMove.hadReviewSidecar))
                    }
                } catch {
                    rollbackStates.append(rollbackState(
                        for: completedMove.move,
                        expectedReviewSidecar: completedMove.hadReviewSidecar))
                }
            }
            if !rollbackStates.isEmpty {
                var seen = Set<String>()
                let uniqueStates = rollbackStates.filter {
                    seen.insert($0.move.source.path).inserted
                }
                throw FileMoveError.rollbackFailed(uniqueStates)
            }
            throw error
        }
    }

    nonisolated private static func moveFileAndReviewSidecar(
        from source: URL,
        to destination: URL,
        destinationFolder: URL,
        moveItem: FileMoveItemOperation
    ) throws -> Bool {
        let fileManager = FileManager.default
        var sourceIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: source.path, isDirectory: &sourceIsDirectory) else {
            throw FileMoveError.sourceNoLongerExists
        }
        let sourceIsPackage = (try? source.resourceValues(forKeys: [.isPackageKey]))?.isPackage
            ?? false
        guard !sourceIsDirectory.boolValue || sourceIsPackage else {
            throw FileMoveError.unsupportedSource
        }
        guard AppState.isFolder(destinationFolder) else {
            throw FileMoveError.destinationNotFolder
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw FileMoveError.alreadyExists(destination.lastPathComponent)
        }

        let oldSidecar = ReviewSidecar.url(for: source)
        let newSidecar = ReviewSidecar.url(for: destination)
        let hasSidecar = fileManager.fileExists(atPath: oldSidecar.path)
        if fileManager.fileExists(atPath: newSidecar.path) {
            throw FileMoveError.alreadyExists(newSidecar.lastPathComponent)
        }

        do {
            try moveItem(source, destination)
        } catch {
            let moveError = error
            let move = FileMoveResult(source: source, destination: destination)
            let state = rollbackState(
                for: move, expectedReviewSidecar: hasSidecar)
            guard state.isFullyRolledBack else {
                if state.fileRemainsAtDestination {
                    do {
                        try moveItem(destination, source)
                    } catch {
                        throw FileMoveError.rollbackFailed([
                            rollbackState(
                                for: move,
                                expectedReviewSidecar: hasSidecar)
                        ])
                    }
                    let recovered = rollbackState(
                        for: move, expectedReviewSidecar: hasSidecar)
                    guard recovered.isFullyRolledBack else {
                        throw FileMoveError.rollbackFailed([recovered])
                    }
                    throw moveError
                }
                throw FileMoveError.rollbackFailed([state])
            }
            throw moveError
        }
        guard hasSidecar else { return false }
        do {
            try moveItem(oldSidecar, newSidecar)
        } catch {
            let sidecarError = error
            // The file and its review marks are one logical document. Restore
            // the original file path when the sidecar cannot follow it.
            do {
                try moveItem(destination, source)
            } catch {
                throw FileMoveError.rollbackFailed([
                    rollbackState(for: FileMoveResult(
                        source: source, destination: destination),
                    expectedReviewSidecar: true)
                ])
            }
            let state = rollbackState(
                for: FileMoveResult(source: source, destination: destination),
                expectedReviewSidecar: true)
            guard state.isFullyRolledBack else {
                throw FileMoveError.rollbackFailed([state])
            }
            throw sidecarError
        }
        return true
    }

    nonisolated private static func rollbackCompletedMove(
        _ move: FileMoveResult,
        hadReviewSidecar: Bool,
        moveItem: FileMoveItemOperation
    ) throws {
        do {
            try moveItem(move.destination, move.source)
        } catch {
            throw FileMoveError.rollbackFailed([
                rollbackState(for: move, expectedReviewSidecar: hadReviewSidecar)
            ])
        }

        if hadReviewSidecar {
            let oldSidecar = ReviewSidecar.url(for: move.source)
            let newSidecar = ReviewSidecar.url(for: move.destination)
            do {
                try moveItem(newSidecar, oldSidecar)
            } catch {
                // Keep the document and its sidecar at the destination when
                // possible. Whether this recovery succeeds or not, report the
                // probed state instead of hiding either failure.
                do {
                    try moveItem(move.source, move.destination)
                } catch {
                    throw FileMoveError.rollbackFailed([
                        rollbackState(for: move, expectedReviewSidecar: true)
                    ])
                }
                throw FileMoveError.rollbackFailed([
                    rollbackState(for: move, expectedReviewSidecar: true)
                ])
            }
        }

        let state = rollbackState(
            for: move, expectedReviewSidecar: hadReviewSidecar)
        guard state.isFullyRolledBack else {
            throw FileMoveError.rollbackFailed([state])
        }
    }

    nonisolated private static func rollbackState(
        for move: FileMoveResult,
        expectedReviewSidecar: Bool
    ) -> FileMoveRollbackState {
        let fileManager = FileManager.default
        let oldSidecar = ReviewSidecar.url(for: move.source)
        let newSidecar = ReviewSidecar.url(for: move.destination)
        return FileMoveRollbackState(
            move: move,
            expectedReviewSidecar: expectedReviewSidecar,
            fileAtSource: fileManager.fileExists(atPath: move.source.path),
            fileAtDestination: fileManager.fileExists(atPath: move.destination.path),
            reviewSidecarAtSource: fileManager.fileExists(atPath: oldSidecar.path),
            reviewSidecarAtDestination: fileManager.fileExists(atPath: newSidecar.path))
    }

    private func migrateFileState(
        from source: URL,
        to destination: URL,
        oldWorkspace: Workspace?,
        oldRelative: String?,
        wasHidden: Bool,
        wasPinned: Bool
    ) {
        if let oldWorkspace, let oldRelative {
            var oldSet = hiddenFiles[oldWorkspace.folderPath] ?? []
            oldSet.remove(oldRelative)
            hiddenFiles[oldWorkspace.folderPath] = oldSet.isEmpty ? nil : oldSet
        }
        if let newWorkspace = workspaceOwning(destination),
           let newRelative = relativePath(of: destination, in: newWorkspace) {
            var newSet = hiddenFiles[newWorkspace.folderPath] ?? []
            if wasHidden { newSet.insert(newRelative) } else { newSet.remove(newRelative) }
            hiddenFiles[newWorkspace.folderPath] = newSet.isEmpty ? nil : newSet
        }

        pinnedLoosePaths.removeAll { $0 == source.path }
        looseFiles.removeAll { $0.standardizedFileURL == source }
        if workspaceOwning(destination) == nil {
            if wasPinned { pinnedLoosePaths.append(destination.path) }
            looseFiles.append(destination)
        }
        if lastActivePath == source.path { lastActivePath = destination.path }

        snapshot.relocateFile(from: source.path, to: destination.path)
    }

    private func finishFileMoves() {
        folderListings.removeAll()
        listingScansInFlight.removeAll()
        treeStatsScansInFlight.removeAll()
        tagIndex = [:]
        tagIndexKey = ""
        if tagScanInFlight { tagScanPending = true }
        noteFilesystemChange()
    }

    private func migrateRootState(from oldRoot: String, to newRoot: String) {
        workspaces = workspaces.map { workspace in
            var relocated = workspace
            relocated.folderPath = Self.relocatedPath(
                workspace.folderPath, from: oldRoot, to: newRoot)
            return relocated
        }

        var relocatedHidden: [String: Set<String>] = [:]
        for (root, hidden) in hiddenFiles {
            let relocatedRoot = Self.relocatedPath(root, from: oldRoot, to: newRoot)
            relocatedHidden[relocatedRoot, default: []].formUnion(hidden)
        }
        hiddenFiles = relocatedHidden
        expandedFolders = Set(expandedFolders.map {
            Self.relocatedPath($0, from: oldRoot, to: newRoot)
        })
        if let lastActivePath {
            self.lastActivePath = Self.relocatedPath(lastActivePath,
                                                     from: oldRoot, to: newRoot)
        }
        pinnedLoosePaths = pinnedLoosePaths.map {
            Self.relocatedPath($0, from: oldRoot, to: newRoot)
        }
        looseFiles = looseFiles.map {
            URL(fileURLWithPath: Self.relocatedPath($0.standardizedFileURL.path,
                                                    from: oldRoot, to: newRoot))
        }

        folderListings.removeAll()
        listingScansInFlight.removeAll()
        treeStatsScansInFlight.removeAll()
        tagIndex = [:]
        tagIndexKey = ""
        if tagScanInFlight { tagScanPending = true }
        snapshot.relocateRoot(from: oldRoot, to: newRoot)
        noteFilesystemChange()
    }

    func toggleCollapsed(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[i].collapsed.toggle()
    }

    /// Expand a workspace root (show its children). No-op if already expanded.
    func expandWorkspace(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        if workspaces[i].collapsed { workspaces[i].collapsed = false }
    }

    /// Collapse a workspace root. No-op if already collapsed.
    func collapseWorkspace(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        if !workspaces[i].collapsed { workspaces[i].collapsed = true }
    }

    /// Expand a subfolder in the tree (lazy contents become visible).
    func expandFolder(_ folder: URL) {
        expandedFolders.insert(folder.standardizedFileURL.path)
    }

    /// Collapse a subfolder in the tree. No-op if already collapsed.
    func collapseFolder(_ folder: URL) {
        expandedFolders.remove(folder.standardizedFileURL.path)
    }

    /// Runs the folder open panel and adopts an existing folder — shared by the
    /// sidebar and File ▸ Open Folder.
    func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            addWorkspace(url)
        }
    }

    /// Runs a save-style panel so the user can choose a parent location and
    /// enter the name of a folder that does not exist yet. The created folder
    /// is adopted by the sidebar and opened in the main window.
    func promptCreateFolder() {
        let panel = NSSavePanel()
        panel.title = "New Folder"
        panel.message = "Choose where to create the folder and enter its name."
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "New Folder"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let folder = try createWorkspaceFolder(
                named: url.lastPathComponent,
                in: url.deletingLastPathComponent())
            AppState.shared.openInMainWindow(folder)
        } catch {
            presentFolderError(error)
        }
    }

    // MARK: - Create file / folder (folder info card)

    /// Bumped when the tree must re-scan disk (new file/folder). Views that
    /// list children observe the model; reading this forces a refresh pass.
    @Published private(set) var contentEpoch: Int = 0

    func noteFilesystemChange() {
        contentEpoch += 1
        // Link graph is presentation state over the tree — rebuild in background.
        LinkIndex.shared.invalidate(workspace: self)
    }

    /// Creates an empty markdown file in `folder`. `name` is the user-facing
    /// name (`.md` is appended when missing). Returns the new file URL.
    @discardableResult
    func createMarkdownFile(named name: String, in folder: URL) throws -> URL {
        let fileName = try FolderNaming.markdownFileName(from: name)
        let dest = folder.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw FolderCreateError.alreadyExists(fileName)
        }
        FileManager.default.createFile(atPath: dest.path, contents: Data(), attributes: nil)
        noteFilesystemChange()
        return dest.standardizedFileURL
    }

    /// Creates a subfolder in `folder`. Returns the new folder URL.
    @discardableResult
    func createSubfolder(named name: String, in folder: URL) throws -> URL {
        let folderName = try FolderNaming.folderName(from: name)
        let dest = folder.appendingPathComponent(folderName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw FolderCreateError.alreadyExists(folderName)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        noteFilesystemChange()
        // Ensure the new folder is visible: expand parent in the tree (or the
        // workspace root's collapsed flag when the parent is a workspace).
        if let ws = workspaces.first(where: {
            $0.folderPath == folder.standardizedFileURL.path
        }) {
            expandWorkspace(ws)
        } else {
            expandFolder(folder)
        }
        return dest.standardizedFileURL
    }

    /// Creates a new root folder on disk and adopts it in the sidebar.
    @discardableResult
    func createWorkspaceFolder(named name: String, in parent: URL) throws -> URL {
        let folderName = try FolderNaming.folderName(from: name)
        let dest = parent.appendingPathComponent(folderName)
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw FolderCreateError.alreadyExists(folderName)
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        let folder = dest.standardizedFileURL
        addWorkspace(folder)
        noteFilesystemChange()
        return folder
    }

    // MARK: - Hide / unhide (relative paths from workspace root)

    /// Longest-prefix workspace that contains `url` (file or directory).
    func workspaceOwning(_ url: URL) -> Workspace? {
        let path = url.standardizedFileURL.path
        return workspaces
            .filter { path == $0.folderPath || path.hasPrefix($0.folderPath + "/") }
            .max(by: { $0.folderPath.count < $1.folderPath.count })
    }

    /// Path of `url` relative to `ws` root (`note.md`, `sub/a.md`), or nil.
    func relativePath(of url: URL, in ws: Workspace) -> String? {
        let base = ws.folderPath
        let path = url.standardizedFileURL.path
        if path == base { return nil }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    func isHidden(_ url: URL) -> Bool {
        guard let ws = workspaceOwning(url),
              let rel = relativePath(of: url, in: ws) else { return false }
        return hiddenFiles[ws.folderPath]?.contains(rel) == true
    }

    func hide(_ url: URL, in ws: Workspace) {
        guard let rel = relativePath(of: url, in: ws) else { return }
        var set = hiddenFiles[ws.folderPath] ?? []
        set.insert(rel)
        hiddenFiles[ws.folderPath] = set
    }

    func unhide(_ url: URL, in ws: Workspace) {
        guard let rel = relativePath(of: url, in: ws) else { return }
        guard var set = hiddenFiles[ws.folderPath] else { return }
        set.remove(rel)
        if set.isEmpty { hiddenFiles[ws.folderPath] = nil } else { hiddenFiles[ws.folderPath] = set }
    }

    /// Resolve owning workspace and hide. No-op outside any workspace.
    func hide(_ url: URL) {
        guard let ws = workspaceOwning(url) else { return }
        hide(url, in: ws)
    }

    func unhide(_ url: URL) {
        guard let ws = workspaceOwning(url) else { return }
        unhide(url, in: ws)
    }

    // MARK: - Loose files

    /// Records a file opened outside any workspace so it shows under
    /// "Открытые файлы". No-op for files that belong to an adopted folder.
    func noteOpened(_ url: URL) {
        let std = url.standardizedFileURL
        // Nested files under a workspace root are also not "loose".
        guard workspaceOwning(std) == nil else { return }
        guard !pinnedLoosePaths.contains(std.path),
              !looseFiles.contains(where: { $0.standardizedFileURL == std }) else { return }
        looseFiles.append(std)
    }

    /// True only when the file's **parent** is exactly a workspace root
    /// (legacy helper for root-level bookkeeping). Prefer `workspaceOwning` for hide.
    func workspaceContaining(_ url: URL) -> Workspace? {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return workspaces.first { $0.folderPath == parent }
    }

    /// Loose files to show: pinned (persisted) first, then session ones, deduped.
    var looseFilesToShow: [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in pinnedLoosePaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            if seen.insert(url.path).inserted { result.append(url) }
        }
        for url in looseFiles {
            let std = url.standardizedFileURL
            if seen.insert(std.path).inserted { result.append(std) }
        }
        return result
    }

    func isPinned(_ url: URL) -> Bool {
        pinnedLoosePaths.contains(url.standardizedFileURL.path)
    }

    func pin(_ url: URL) {
        let std = url.standardizedFileURL
        guard !pinnedLoosePaths.contains(std.path) else { return }
        pinnedLoosePaths.append(std.path)
    }

    func unpin(_ url: URL) {
        let std = url.standardizedFileURL
        pinnedLoosePaths.removeAll { $0 == std.path }
        // Keep it visible this session.
        if !looseFiles.contains(where: { $0.standardizedFileURL == std }) {
            looseFiles.append(std)
        }
    }

    func removeLoose(_ url: URL) {
        let std = url.standardizedFileURL
        pinnedLoosePaths.removeAll { $0 == std.path }
        looseFiles.removeAll { $0.standardizedFileURL == std }
    }

    // MARK: - Persistence

    private static func load<T: Codable>(_ defaults: UserDefaults, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func persist<T: Codable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
