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

    static let shared = WorkspaceModel()

    struct Workspace: Codable, Equatable, Identifiable {
        var folderPath: String
        var collapsed: Bool = false
        /// Optional display name; nil / empty → folder basename (legacy decode OK).
        var customName: String? = nil
        var id: String { folderPath }
        var url: URL { URL(fileURLWithPath: folderPath) }
        var name: String {
            if let customName, !customName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return customName
            }
            return url.lastPathComponent
        }
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
    /// Paths of subfolders the user expanded in the tree (persisted). The tree
    /// is lazy — a subfolder's contents are only scanned while it is expanded —
    /// so adopting a folder with thousands of nested files stays cheap.
    @Published var expandedFolders: Set<String> { didSet { persist(expandedFolders, Keys.expanded) } }

    /// D11: tag → files (frontmatter only). Filled off-main; read from UI.
    @Published private(set) var tagIndex: [String: [URL]] = [:]
    private var tagScanInFlight = false
    private var tagScanPending = false
    private var tagIndexKey = ""

    private let defaults: UserDefaults

    private enum Keys {
        static let folders = "workspace.folders"
        static let hidden = "workspace.hidden"
        static let pinned = "workspace.pinned"
        static let expanded = "workspace.expanded"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        workspaces = Self.load(defaults, Keys.folders) ?? []
        hiddenFiles = Self.load(defaults, Keys.hidden) ?? [:]
        pinnedLoosePaths = Self.load(defaults, Keys.pinned) ?? []
        expandedFolders = Self.load(defaults, Keys.expanded) ?? []
        // Folder contents may change in Finder/Terminal while EditMD is in the
        // background — re-validate listings lazily on return (selector-based:
        // the block API's @Sendable closure clashes with @MainActor).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil)
    }

    @objc private func appDidBecomeActive() {
        noteFilesystemChange()
    }

    // MARK: - Folder scan

    nonisolated private static let markdownExtensions: Set<String> = ["md", "markdown", "textbundle"]

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
        return []
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
            .filter { markdownExtensions.contains($0.pathExtension.lowercased()) }
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
    func renameWorkspace(_ ws: Workspace, to name: String) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[i].customName = trimmed.isEmpty ? nil : trimmed
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

    /// Runs the folder open panel and adopts the choice — shared by the sidebar
    /// button and File ▸ Open Folder.
    func promptAddFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            addWorkspace(url)
        }
    }

    // MARK: - Create file / folder (folder info card)

    /// Bumped when the tree must re-scan disk (new file/folder). Views that
    /// list children observe the model; reading this forces a refresh pass.
    @Published private(set) var contentEpoch: Int = 0

    func noteFilesystemChange() { contentEpoch += 1 }

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
