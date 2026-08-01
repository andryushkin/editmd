import SwiftUI
import AppKit

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
        /// Collection this root sits in, `nil` for a root of its own (legacy
        /// decode OK — every install before collections has ungrouped roots).
        var collectionID: String? = nil
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
    /// Named containers grouping roots in the sidebar (`WorkspaceCollections`).
    /// Presentation only — never a search, link or index boundary.
    @Published var collections: [WorkspaceCollection] { didSet { persist(collections, Keys.collections) } }
    /// workspace root path → set of **relative paths** of hidden markdown files
    /// (e.g. `note.md`, `sub/a.md`). Legacy entries without `/` are root basenames.
    @Published var hiddenFiles: [String: Set<String>] { didSet { persist(hiddenFiles, Keys.hidden) } }
    /// workspace root path → set of **relative paths** of folders the user created
    /// in-app that must stay visible even while they hold no documents. Without
    /// this a freshly made folder is classified "empty" and hidden behind the eye
    /// the moment it is created. Stale entries (folder deleted/renamed) are
    /// harmless: `keptEmptySubfolders` intersects them with folders that actually
    /// exist and are empty, mirroring how `hiddenFiles` tolerates staleness.
    @Published var keptFolders: [String: Set<String>] { didSet { persist(keptFolders, Keys.kept) } }
    /// Pinned loose files (persist across launches), stored as paths.
    @Published var pinnedLoosePaths: [String] { didSet { persist(pinnedLoosePaths, Keys.pinned) } }
    /// Adopted workspace root path → favorite document paths (maximum 50 per root).
    @Published private(set) var favoritePathsByWorkspace: [String: [String]] {
        didSet { persist(favoritePathsByWorkspace, Keys.favorites) }
    }
    /// Availability is refreshed off-main; SwiftUI body never stats favorite files.
    @Published private(set) var missingFavoritePaths: Set<String> = []
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
    /// The link graph this sidebar re-keys when the effective vault moves.
    /// Injectable so a test can watch the re-key without the shared index.
    let linkIndex: LinkIndex

    private enum Keys {
        static let folders = "workspace.folders"
        static let collections = "workspace.collections"
        static let hidden = "workspace.hidden"
        static let kept = "workspace.keptFolders"
        static let pinned = "workspace.pinned"
        static let favorites = "workspace.favorites"
        static let lastActive = "workspace.lastActive"
    }

    /// First frame of the tree, carried over from the previous run.
    /// `snapshotURL: nil` keeps it in memory — the default, so only the app's
    /// `shared` instance (and a test that asks for a temp file) touches disk.
    let snapshot: SidebarSnapshotStore

    /// `index: nil` → the shared graph in the app, a private one under XCTest:
    /// adopting a root re-keys the index, and a test's temporary roots must
    /// never start a scan in the shared one (same rule as `snapshotURL`).
    init(defaults: UserDefaults = .standard, snapshotURL: URL? = nil,
         index: LinkIndex? = nil) {
        self.defaults = defaults
        linkIndex = index ?? (AppDelegate.isRunningUnitTests ? LinkIndex() : .shared)
        snapshot = SidebarSnapshotStore(fileURL: snapshotURL)
        let storedWorkspaces: [Workspace] = Self.load(defaults, Keys.folders) ?? []
        let storedCollections: [WorkspaceCollection] = Self.load(defaults, Keys.collections) ?? []
        let liveCollections = Self.prunedCollections(storedCollections, workspaces: storedWorkspaces)
        collections = liveCollections
        workspaces = Self.normalizedWorkspaces(storedWorkspaces, collections: liveCollections)
        hiddenFiles = Self.load(defaults, Keys.hidden) ?? [:]
        keptFolders = Self.load(defaults, Keys.kept) ?? [:]
        pinnedLoosePaths = Self.load(defaults, Keys.pinned) ?? []
        favoritePathsByWorkspace = Self.load(defaults, Keys.favorites) ?? [:]
        lastActivePath = Self.load(defaults, Keys.lastActive)
        normalizeStartupTree()
        refreshFavoriteAvailability()
        // Folder contents may change in Finder/Terminal while EditMD is in the
        // background — re-validate listings lazily on return (selector-based:
        // the block API's @Sendable closure clashes with @MainActor).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification,
            object: nil)
    }

    // MARK: - Startup tree

    /// Records the main window's target so the next launch reopens this branch.
    func noteActive(_ url: URL) {
        lastActivePath = url.standardizedFileURL.path
        // The active document may live in a different workspace — the link
        // graph is scoped to one workspace at a time (`linkIndexRoots`).
        // Lazy: a no-op unless someone already built (or is building) it.
        linkIndex.noteActiveDocumentChanged(workspace: self)
    }

    /// The workspace the app currently works in: the one owning the active
    /// document, falling back to the first adopted root (which is also the
    /// branch a fresh launch opens). `nil` only when nothing is adopted.
    var activeWorkspaceRoot: URL? {
        if let path = lastActivePath,
           let owner = workspaceOwning(URL(fileURLWithPath: path)) {
            return owner.url
        }
        return workspaces.first?.url
    }

    /// Roots automatic link indexing covers: ONE workspace — the active one.
    /// Scanning every adopted workspace made launch/rebuild cost the sum of
    /// all vaults, while backlinks and vault-lint are per-vault questions
    /// anyway (Obsidian semantics: the vault is the resolution unit;
    /// cross-workspace edges never resolved reliably — wiki targets were
    /// ambiguous across vaults).
    var linkIndexRoots: [URL] {
        activeWorkspaceRoot.map { [$0] } ?? []
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
        // A collapsed collection hides its members outright, so the branch the
        // launch reopens would be invisible — open the one that owns it.
        if let collection = collection(of: owner) { expandCollection(collection) }
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
        contentEpoch += 1
        pruneStaleKeptFolders()
        refreshFavoriteAvailability()
        handleAppActivation()
    }

    @objc private func appDidResignActive() {
        noteAppResignedActive()
    }

    /// External editors can only touch files while EditMD is NOT frontmost —
    /// so an activation matters to the link graph only after a resign.
    private var wasBackgrounded = false

    func noteAppResignedActive() {
        wasBackgrounded = true
    }

    /// The process's FIRST activation arrives moments after launch, while the
    /// warm scan (`applicationDidFinishLaunching`) is still running — nothing
    /// external can have changed since that scan started reading the disk,
    /// and deferring against it made every cold launch run two consecutive
    /// full scans. Only a real background → foreground transition re-keys.
    func handleAppActivation(index: LinkIndex = .shared) {
        guard wasBackgrounded else { return }
        wasBackgrounded = false
        refreshLinkGraphAfterActivation(index: index)
    }

    /// External editors can change closed files while EditMD is in the
    /// background (open files are covered by the DocumentRegistry watcher).
    /// Re-key the link graph so its (mtime, size) parse cache and resolve
    /// cache revalidate against disk — a no-change rebuild is a walk plus
    /// stats, not a re-parse. While a scan is in flight the re-key is
    /// DEFERRED, not dropped: a key change now would cancel the scan and
    /// throw away its work (cancelled scans keep no partial cache), but the
    /// running scan may already have read a file the external editor changed
    /// afterwards — LinkIndex replays the refresh once the scan finishes.
    /// A cold index (never built, not building) stays lazy.
    func refreshLinkGraphAfterActivation(index: LinkIndex = .shared) {
        guard index.hasCompletedFullScan || index.isScanning else { return }
        guard !index.isScanning else {
            index.deferActivationRefresh(workspace: self)
            return
        }
        linkEpoch += 1
        index.invalidate(workspace: self)
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

    /// No-document child folders shown alongside the markdown-bearing ones
    /// rather than behind the eye: the ones the user created in-app, plus any
    /// empty folder on the path to such a folder (otherwise a kept folder nested
    /// inside a found-on-disk empty parent would be unreachable — the parent
    /// would stay hidden and take the kept child down with it).
    func keptEmptySubfolders(in folder: URL) -> [URL] {
        emptySubfolders(in: folder).filter(isKeptOrHoldsKept)
    }

    /// No-document child folders that stay behind the eye with the hidden files:
    /// found on disk (assets, stray dirs) with no kept folder anywhere inside.
    func unkeptEmptySubfolders(in folder: URL) -> [URL] {
        emptySubfolders(in: folder).filter { !isKeptOrHoldsKept($0) }
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
        // Adopting can change the vault under the open document (a nested root
        // becomes its closer owner) or the fallback first root.
        trackingEffectiveRoot {
            workspaces.append(Workspace(folderPath: path))
        }
        // A loose file that now lives inside an adopted folder is no longer loose.
        looseFiles.removeAll { $0.deletingLastPathComponent().path == path }
    }

    func removeWorkspace(_ ws: Workspace) {
        trackingEffectiveRoot {
            workspaces.removeAll { $0.id == ws.id }
            rearrange()
        }
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

    private struct FileMoveState {
        let source: URL
        let oldWorkspace: Workspace?
        let oldRelative: String?
        let wasHidden: Bool
        let wasPinned: Bool
        let wasFavorite: Bool
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
                wasPinned: pinnedLoosePaths.contains(source.path),
                wasFavorite: isFavorite(source))
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
                        wasPinned: state.wasPinned,
                        wasFavorite: state.wasFavorite)
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
                wasPinned: state.wasPinned,
                wasFavorite: state.wasFavorite)
        }
        finishFileMoves()
        await WikiLinkResolver.shared.invalidate()
        return moves
    }

    /// The one derivation of a rename's destination URL — the UI transaction
    /// (gates, registry reservation) and the disk core must agree on it
    /// structurally, not by re-deriving the same string twice.
    nonisolated static func renameDestination(
        for rawSource: URL, newName rawName: String
    ) throws -> URL {
        let source = rawSource.standardizedFileURL
        let newName = try FolderNaming.renamedFileName(
            from: rawName, keepingExtensionOf: source)
        return source.deletingLastPathComponent()
            .appendingPathComponent(newName).standardizedFileURL
    }

    /// Renames one sidebar document in place (same folder, new basename).
    /// Mirrors `moveFilesOnDisk` for a single explicit destination: the review
    /// sidecar follows, path-keyed sidebar state migrates, and a disk failure
    /// rolls back before the error reaches the UI. The extension is preserved
    /// when the new name omits one; case-only renames go through a temporary
    /// sibling (`moveFileForRename`).
    @discardableResult
    func renameFileOnDisk(
        _ rawSource: URL,
        to rawName: String,
        moveItem: @escaping FileMoveItemOperation = { source, destination in
            try FileManager.default.moveItem(at: source, to: destination)
        }
    ) async throws -> URL {
        let source = rawSource.standardizedFileURL
        guard Self.listedExtensions.contains(source.pathExtension.lowercased()) else {
            throw FileMoveError.unsupportedSource
        }
        let folder = source.deletingLastPathComponent()
        let destination = try Self.renameDestination(for: source, newName: rawName)
        if destination == source { return source }

        let paths: Set<String> = [source.path]
        guard paths.isDisjoint(with: fileMovesInFlight) else {
            throw FileMoveError.moveInProgress
        }
        fileMovesInFlight.formUnion(paths)
        defer { fileMovesInFlight.subtract(paths) }

        let move = FileMoveResult(source: source, destination: destination)
        let oldWorkspace = workspaceOwning(source)
        let oldRelative = oldWorkspace.flatMap { relativePath(of: source, in: $0) }
        let wasHidden = oldWorkspace.flatMap { ws in
            oldRelative.map { hiddenFiles[ws.folderPath]?.contains($0) == true }
        } ?? false
        let state = FileMoveState(
            source: source,
            oldWorkspace: oldWorkspace,
            oldRelative: oldRelative,
            wasHidden: wasHidden,
            wasPinned: pinnedLoosePaths.contains(source.path),
            wasFavorite: isFavorite(source))

        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.moveFileForRename(
                    move, destinationFolder: folder, moveItem: moveItem)
            }.value
        } catch {
            if let moveError = error as? FileMoveError,
               case .rollbackFailed(let rollbackStates) = moveError {
                for rollbackState in rollbackStates
                    where rollbackState.fileRemainsAtDestination {
                    migrateFileState(
                        from: state.source,
                        to: rollbackState.move.destination,
                        oldWorkspace: state.oldWorkspace,
                        oldRelative: state.oldRelative,
                        wasHidden: state.wasHidden,
                        wasPinned: state.wasPinned,
                        wasFavorite: state.wasFavorite)
                }
                finishFileMoves()
                await WikiLinkResolver.shared.invalidate()
            }
            throw error
        }

        migrateFileState(
            from: source,
            to: destination,
            oldWorkspace: state.oldWorkspace,
            oldRelative: state.oldRelative,
            wasHidden: state.wasHidden,
            wasPinned: state.wasPinned,
            wasFavorite: state.wasFavorite)
        finishFileMoves()
        await WikiLinkResolver.shared.invalidate()
        return destination
    }

    /// Number of open documents whose path is at or inside `folder`. Callers
    /// pass `AppState.openDocumentURLsForDiskMutation()`; a folder with open
    /// documents inside is refused for trashing, matching disk-rename.
    func openDocumentCount(inside folder: URL, among openURLs: [URL]) -> Int {
        let root = folder.standardizedFileURL.path
        return openURLs.reduce(into: 0) { count, url in
            if Self.path(url.standardizedFileURL.path, isInside: root) { count += 1 }
        }
    }

    /// Purges sidebar state for a folder that was deleted/trashed on disk: drops
    /// any adopted root at or under it and forgets favorites, pins, loose files,
    /// and expansion inside it. Hidden relative paths are left to the next
    /// rescan (a gone file is never listed), matching single-file trash.
    func forgetTrashedFolder(_ rawFolder: URL) {
        let folder = rawFolder.standardizedFileURL
        let root = folder.path

        workspaces.removeAll { Self.path($0.folderPath, isInside: root) }
        rearrange()
        pinnedLoosePaths.removeAll { Self.path($0, isInside: root) }
        looseFiles.removeAll {
            Self.path($0.standardizedFileURL.path, isInside: root)
        }
        expandedFolders = expandedFolders.filter { !Self.path($0, isInside: root) }
        if let lastActivePath, Self.path(lastActivePath, isInside: root) {
            self.lastActivePath = nil
        }

        var relocatedFavorites: [String: [String]] = [:]
        for (wsRoot, favoritePaths) in favoritePathsByWorkspace {
            let kept = favoritePaths.filter { !Self.path($0, isInside: root) }
            if !kept.isEmpty { relocatedFavorites[wsRoot] = kept }
        }
        favoritePathsByWorkspace = relocatedFavorites
        missingFavoritePaths = missingFavoritePaths.filter {
            !Self.path($0, isInside: root)
        }
        // The folder is already off disk, so this drops any kept entry inside
        // it — otherwise a trashed kept folder would hold its ancestors visible.
        pruneStaleKeptFolders()

        noteFilesystemChange()
    }

    private func migrateFileState(
        from source: URL,
        to destination: URL,
        oldWorkspace: Workspace?,
        oldRelative: String?,
        wasHidden: Bool,
        wasPinned: Bool,
        wasFavorite: Bool
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

        removeFavorite(source)
        if wasFavorite { addFavorite(destination) }

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
        // Kept-visible folders are keyed by workspace root too; the relative
        // paths are unchanged, only the root moves.
        var relocatedKept: [String: Set<String>] = [:]
        for (root, kept) in keptFolders {
            let relocatedRoot = Self.relocatedPath(root, from: oldRoot, to: newRoot)
            relocatedKept[relocatedRoot, default: []].formUnion(kept)
        }
        keptFolders = relocatedKept
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
        var relocatedFavorites: [String: [String]] = [:]
        for (root, paths) in favoritePathsByWorkspace {
            let relocatedRoot = Self.relocatedPath(root, from: oldRoot, to: newRoot)
            relocatedFavorites[relocatedRoot, default: []].append(contentsOf: paths.map {
                Self.relocatedPath($0, from: oldRoot, to: newRoot)
            })
        }
        favoritePathsByWorkspace = relocatedFavorites
        missingFavoritePaths = Set(missingFavoritePaths.map {
            Self.relocatedPath($0, from: oldRoot, to: newRoot)
        })
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
        panel.title = String(localized: "New Folder")
        panel.message = String(localized: "Choose where to create the folder and enter its name.")
        panel.nameFieldLabel = "Name:"
        panel.nameFieldStringValue = "New Folder"
        panel.prompt = String(localized: "Create")
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

    /// Bumped on real filesystem mutations (create/delete/rename/agent writes
    /// of NEW files) and on app activation when the index is idle and
    /// complete (`refreshLinkGraphAfterActivation` — external edits of closed
    /// files). Never bumped while a scan is in flight: a key change cancels
    /// the scan and throws away its work. Edits to open files flow through
    /// `noteDocumentPersisted` (incremental single-file path).
    private(set) var linkEpoch: Int = 0

    func noteFilesystemChange() {
        contentEpoch += 1
        linkEpoch += 1
        // Link graph is presentation state over the tree — rebuild in background.
        linkIndex.invalidate(workspace: self)
    }

    /// Creates a markdown file in `folder`. `name` is the user-facing name
    /// (`.md` is appended when missing). Daily notes use the date as their name
    /// and return the existing file instead of creating a duplicate.
    @discardableResult
    func createMarkdownFile(
        named name: String,
        in folder: URL,
        template: FileTemplate = .blank,
        date: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let dateString = fileTemplateDateString(date, calendar: calendar)
        let requestedName = template == .daily ? "\(dateString).md" : name
        let fileName = try FolderNaming.markdownFileName(from: requestedName)
        let dest = folder.appendingPathComponent(fileName)
        if template == .daily, FileManager.default.fileExists(atPath: dest.path) {
            return dest.standardizedFileURL
        }
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw FolderCreateError.alreadyExists(fileName)
        }
        let title = (fileName as NSString).deletingPathExtension
        let content = template.rendered(title: title, date: dateString)
        guard FileManager.default.createFile(
            atPath: dest.path,
            contents: Data(content.utf8),
            attributes: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
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
        // A brand-new folder holds no documents, so it would land in the
        // hidden "empty folders" bucket — keep the one the user just made visible.
        keepVisible(dest.standardizedFileURL)
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

    // MARK: - Kept-visible folders (user-created, empty)

    /// True when `url` is a folder the user made in-app and asked us to keep
    /// visible even while it holds no documents.
    func isKeptVisible(_ url: URL) -> Bool {
        guard let ws = workspaceOwning(url),
              let rel = relativePath(of: url, in: ws) else { return false }
        return keptFolders[ws.folderPath]?.contains(rel) == true
    }

    /// True when some kept folder lives strictly inside `url`. Such a folder is
    /// on the path to content the user made, so it must be drawn even though it
    /// holds no documents of its own.
    func containsKeptFolder(_ url: URL) -> Bool {
        guard let ws = workspaceOwning(url),
              let rel = relativePath(of: url, in: ws) else { return false }
        let prefix = rel + "/"
        return keptFolders[ws.folderPath]?.contains { $0.hasPrefix(prefix) } == true
    }

    /// A no-document folder that should escape the hidden "empty folders"
    /// bucket: kept itself, or an ancestor of a kept folder.
    func isKeptOrHoldsKept(_ url: URL) -> Bool {
        isKeptVisible(url) || containsKeptFolder(url)
    }

    /// Drops kept entries whose folder no longer exists on disk. Without this a
    /// deleted kept folder would keep its (now genuinely empty) ancestors out of
    /// the hidden bucket forever, since `containsKeptFolder` is a pure prefix
    /// check over the persisted set. Called when the folder is known gone
    /// (`forgetTrashedFolder`) and on activation (external deletes). Fire and
    /// forget — the existence probe runs off the main actor.
    func pruneStaleKeptFolders() {
        Task { await pruneStaleKeptFoldersNow() }
    }

    /// Awaitable core of `pruneStaleKeptFolders`: the existence probe runs on a
    /// detached task — a stale, network, or offline workspace volume must never
    /// stall the main actor (CLAUDE.md) — then the result is applied on the main
    /// actor, bailing if the set changed while the probe ran so a folder created
    /// meanwhile is not clobbered.
    func pruneStaleKeptFoldersNow() async {
        let snapshot = keptFolders
        guard !snapshot.isEmpty else { return }
        let pruned = await Task.detached(priority: .utility) {
            Self.keptFoldersDroppingMissing(snapshot)
        }.value
        guard keptFolders == snapshot else { return }
        if pruned != snapshot { keptFolders = pruned }
    }

    /// Pure existence filter over a kept-folders snapshot; safe off the main
    /// actor (touches only `FileManager`).
    nonisolated private static func keptFoldersDroppingMissing(
        _ source: [String: Set<String>]
    ) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for (root, rels) in source {
            let base = URL(fileURLWithPath: root)
            let surviving = rels.filter { rel in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(
                    atPath: base.appendingPathComponent(rel).path, isDirectory: &isDir)
                    && isDir.boolValue
            }
            if !surviving.isEmpty { result[root] = surviving }
        }
        return result
    }

    /// Records `url` so an empty folder the user just created stays in the
    /// visible list. No-op outside any workspace (there is no tree to hide it).
    func keepVisible(_ url: URL) {
        guard let ws = workspaceOwning(url),
              let rel = relativePath(of: url, in: ws) else { return }
        var set = keptFolders[ws.folderPath] ?? []
        set.insert(rel)
        keptFolders[ws.folderPath] = set
    }

    // MARK: - Loose files

    /// Records a file opened outside any workspace so it shows under
    /// "Open Files". No-op for files that belong to an adopted folder.
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

    // MARK: - Workspace favorites

    var favoriteFiles: [URL] {
        workspaces.flatMap { workspace in
            (favoritePathsByWorkspace[workspace.folderPath] ?? []).map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        }
    }

    func isFavorite(_ url: URL) -> Bool {
        let file = url.standardizedFileURL
        guard let workspace = workspaceOwning(file) else { return false }
        return favoritePathsByWorkspace[workspace.folderPath]?.contains(file.path) == true
    }

    func addFavorite(_ url: URL) {
        let file = url.standardizedFileURL
        guard let workspace = workspaceOwning(file) else { return }
        var paths = favoritePathsByWorkspace[workspace.folderPath] ?? []
        guard !paths.contains(file.path), paths.count < 50 else { return }
        paths.append(file.path)
        favoritePathsByWorkspace[workspace.folderPath] = paths
        missingFavoritePaths.remove(file.path)
    }

    func removeFavorite(_ url: URL) {
        let file = url.standardizedFileURL
        for workspace in workspaces {
            guard var paths = favoritePathsByWorkspace[workspace.folderPath],
                  paths.contains(file.path) else { continue }
            paths.removeAll { $0 == file.path }
            favoritePathsByWorkspace[workspace.folderPath] = paths.isEmpty ? nil : paths
        }
        missingFavoritePaths.remove(file.path)
    }

    /// A missing favorite is removed only after the user clicks it.
    func favoriteOpenTarget(_ url: URL) -> URL? {
        let file = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: file.path) else {
            removeFavorite(file)
            return nil
        }
        return file
    }

    func isFavoriteMissing(_ url: URL) -> Bool {
        missingFavoritePaths.contains(url.standardizedFileURL.path)
    }

    func refreshFavoriteAvailability() {
        let paths = favoriteFiles.map(\.path)
        Task { @MainActor in
            let missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
            guard Set(self.favoriteFiles.map(\.path)) == Set(paths) else { return }
            self.missingFavoritePaths = missing
        }
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
