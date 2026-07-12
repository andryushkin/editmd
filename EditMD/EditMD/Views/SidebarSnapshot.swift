import Foundation

/// What the sidebar knew about one folder when the app last quit: its direct
/// documents and its direct subfolders, already split by the «has markdown in
/// the subtree» rule the tree applies.
///
/// The in-memory caches (`WorkspaceModel.folderListings`, `FolderStatsCache`)
/// start empty on launch, so an expanded root used to render as an empty root
/// until the recursive `scanFolderTreeStats` walk came back — seconds on a big
/// vault. This snapshot is the first frame: it is read once at startup and
/// served until the real scan lands, which then overwrites it.
///
/// Paths are absolute and standardized. Only folders the sidebar actually
/// listed end up here, so the file stays proportional to what was on screen,
/// not to the whole vault.
struct SidebarSnapshotEntry: Codable, Equatable, Sendable {
    /// Direct md/pdf/textbundle children.
    var files: [String] = []
    /// Direct subfolders whose subtree holds at least one document.
    var mdFolders: [String] = []
    /// Direct subfolders with no documents anywhere below (shown under the eye).
    var emptyFolders: [String] = []
    /// Documents in the whole subtree (folder card + tree stats).
    var markdownCount: Int = 0
    /// Subfolders in the whole subtree that hold documents.
    var subfolderCount: Int = 0

    var urls: (files: [URL], mdFolders: [URL], emptyFolders: [URL]) {
        (files.map { URL(fileURLWithPath: $0) },
         mdFolders.map { URL(fileURLWithPath: $0) },
         emptyFolders.map { URL(fileURLWithPath: $0) })
    }
}

/// Disk-backed store for the startup snapshot: `~/Library/Application
/// Support/EditMD/sidebar-snapshot.json`.
///
/// Reads happen once, in `WorkspaceModel.init` — a few dozen KB from our own
/// container, before any window is on screen. Writes are debounced and run off
/// the main actor: the sidebar must never block on disk (v35.3).
@MainActor
final class SidebarSnapshotStore {

    private var entries: [String: SidebarSnapshotEntry]
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?
    /// Nothing to write until a real scan replaced a loaded entry.
    private var dirty = false

    static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home
            .appendingPathComponent("Library/Application Support/EditMD", isDirectory: true)
            .appendingPathComponent("sidebar-snapshot.json")
    }

    /// `fileURL: nil` → in-memory only (tests, and the XCTest host, which must
    /// not touch the developer's Application Support).
    init(fileURL: URL?) {
        self.fileURL = fileURL ?? URL(fileURLWithPath: "/dev/null")
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: SidebarSnapshotEntry].self, from: data)
        else {
            entries = [:]
            return
        }
        entries = decoded
    }

    func entry(for path: String) -> SidebarSnapshotEntry? { entries[path] }

    /// Records what a completed scan found. Only folders that were scanned —
    /// i.e. folders the tree rendered — are kept.
    func update(path: String, _ transform: (inout SidebarSnapshotEntry) -> Void) {
        var entry = entries[path] ?? SidebarSnapshotEntry()
        let before = entry
        transform(&entry)
        guard entry != before else { return }
        entries[path] = entry
        dirty = true
        scheduleSave()
    }

    /// Coalesces the burst of scans a launch produces into one write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard dirty, let (snapshot, url) = takeWrite() else { return }
        Task.detached(priority: .utility) {
            Self.write(snapshot, to: url, pruningDeleted: true)
        }
    }

    /// Termination cannot outlive a detached task — write on the calling thread.
    /// No `stat` pass here: quitting must not wait on one `fileExists` per
    /// remembered folder (a stale mount would hang the quit). The next
    /// background write prunes whatever is gone.
    func flushSync() {
        guard let (snapshot, url) = takeWrite() else { return }
        saveTask?.cancel()
        Self.write(snapshot, to: url, pruningDeleted: false)
    }

    private func takeWrite() -> ([String: SidebarSnapshotEntry], URL)? {
        guard dirty, fileURL.path != "/dev/null" else { return nil }
        dirty = false
        return (entries, fileURL)
    }

    /// Folders deleted since the last write are dropped when pruning: nothing
    /// rescans a gone folder, so its entry would otherwise stay in the file and
    /// redraw a dead branch on the next launch.
    private nonisolated static func write(_ entries: [String: SidebarSnapshotEntry],
                                          to url: URL,
                                          pruningDeleted: Bool) {
        let live = pruningDeleted
            ? entries.filter { FileManager.default.fileExists(atPath: $0.key) }
            : entries
        guard let data = try? JSONEncoder().encode(live) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
