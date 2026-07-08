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
        var id: String { folderPath }
        var url: URL { URL(fileURLWithPath: folderPath) }
        var name: String { url.lastPathComponent }
    }

    /// Adopted folders, always visible, collapsible.
    @Published var workspaces: [Workspace] { didSet { persist(workspaces, Keys.folders) } }
    /// folderPath → hidden file names.
    @Published var hiddenFiles: [String: Set<String>] { didSet { persist(hiddenFiles, Keys.hidden) } }
    /// Pinned loose files (persist across launches), stored as paths.
    @Published var pinnedLoosePaths: [String] { didSet { persist(pinnedLoosePaths, Keys.pinned) } }
    /// Session-only loose files (opened this run, not in any workspace).
    @Published var looseFiles: [URL] = []
    /// Paths of subfolders the user expanded in the tree (persisted). The tree
    /// is lazy — a subfolder's contents are only scanned while it is expanded —
    /// so adopting a folder with thousands of nested files stays cheap.
    @Published var expandedFolders: Set<String> { didSet { persist(expandedFolders, Keys.expanded) } }

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
    }

    // MARK: - Folder scan

    private static let markdownExtensions: Set<String> = ["md", "markdown", "textbundle"]

    /// Direct markdown children of a folder (flat, non-recursive), name-sorted.
    func markdownFiles(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { Self.markdownExtensions.contains($0.pathExtension.lowercased()) }
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

    func isExpanded(_ folder: URL) -> Bool {
        expandedFolders.contains(folder.standardizedFileURL.path)
    }

    func toggleExpanded(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        if expandedFolders.contains(path) { expandedFolders.remove(path) }
        else { expandedFolders.insert(path) }
    }

    func visibleFiles(_ ws: Workspace) -> [URL] {
        let hidden = hiddenFiles[ws.folderPath] ?? []
        return markdownFiles(in: ws.url).filter { !hidden.contains($0.lastPathComponent) }
    }

    func hiddenFilesList(_ ws: Workspace) -> [URL] {
        let hidden = hiddenFiles[ws.folderPath] ?? []
        return markdownFiles(in: ws.url).filter { hidden.contains($0.lastPathComponent) }
    }

    /// Count of hidden entries that still exist on disk (for the "N hidden" label).
    var totalHiddenCount: Int {
        workspaces.reduce(0) { $0 + hiddenFilesList($1).count }
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

    func toggleCollapsed(_ ws: Workspace) {
        guard let i = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        workspaces[i].collapsed.toggle()
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

    // MARK: - Hide / unhide

    func hide(_ url: URL, in ws: Workspace) {
        var set = hiddenFiles[ws.folderPath] ?? []
        set.insert(url.lastPathComponent)
        hiddenFiles[ws.folderPath] = set
    }

    func unhide(_ url: URL, in ws: Workspace) {
        guard var set = hiddenFiles[ws.folderPath] else { return }
        set.remove(url.lastPathComponent)
        if set.isEmpty { hiddenFiles[ws.folderPath] = nil } else { hiddenFiles[ws.folderPath] = set }
    }

    // MARK: - Loose files

    /// Records a file opened outside any workspace so it shows under
    /// "Открытые файлы". No-op for files that belong to an adopted folder.
    func noteOpened(_ url: URL) {
        let std = url.standardizedFileURL
        guard workspaceContaining(std) == nil else { return }
        guard !pinnedLoosePaths.contains(std.path),
              !looseFiles.contains(where: { $0.standardizedFileURL == std }) else { return }
        looseFiles.append(std)
    }

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
