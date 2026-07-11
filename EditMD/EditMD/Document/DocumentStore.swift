import Foundation
import Darwin
import AppKit

// Serialization + IO layer for markdown / textbundle files, extracted so that
// both the DocumentGroup-era `MarkdownDocument` and the new `DocumentRegistry`
// share ONE read/write format (they can never diverge). Phase 1 of the move off
// DocumentGroup — see plan `bright-launching-stonebraker.md`.

// MARK: - textbundle info.json

private struct TextBundleInfo: Encodable {
    var version: Int = 2
    var type: String = "net.daringfireball.markdown"
    var creatorIdentifier: String?
}

// MARK: - Serialization core (FileWrapper ⇄ content)

/// Parses a loaded file wrapper into `(content, assets)`. Mirrors the read
/// branches of `MarkdownDocument.init(configuration:)`; the single place the
/// read format lives.
func parseMarkdownWrapper(_ file: FileWrapper, isTextBundle: Bool) throws -> (content: String, assets: FileWrapper?) {
    if isTextBundle {
        guard let wrappers = file.fileWrappers,
              let textWrapper = wrappers.first(where: { $0.key.hasPrefix("text.") })?.value,
              let data = textWrapper.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadCorruptFile) }
        return (text, wrappers["assets"])
    } else {
        guard let data = file.regularFileContents,
              let text = String(data: data, encoding: .utf8)
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, nil)
    }
}

/// Builds the file wrapper to persist. Mirrors
/// `MarkdownDocument.fileWrapper(snapshot:configuration:)` — the single place
/// the write format lives.
func makeMarkdownWrapper(content: String, assets: FileWrapper?, isTextBundle: Bool) -> FileWrapper {
    guard isTextBundle else {
        return FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    }
    let root = FileWrapper(directoryWithFileWrappers: [:])

    let infoData = (try? JSONEncoder().encode(
        TextBundleInfo(creatorIdentifier: Bundle.main.bundleIdentifier))) ?? Data()
    let infoWrapper = FileWrapper(regularFileWithContents: infoData)
    infoWrapper.preferredFilename = "info.json"
    root.addFileWrapper(infoWrapper)

    let textWrapper = FileWrapper(regularFileWithContents: content.data(using: .utf8) ?? Data())
    textWrapper.preferredFilename = "text.md"
    root.addFileWrapper(textWrapper)

    if let assets {
        assets.preferredFilename = "assets"
        root.addFileWrapper(assets)
    }
    return root
}

// MARK: - Disk IO

/// Reads a `.md`/`.markdown` file or `.textbundle` package from disk.
/// textbundle is detected by extension or directory shape.
///
/// Plain files use `String(contentsOf:)` — `FileWrapper(.immediate)` walks
/// xattrs/resource forks and is far too expensive on the hot disk-watch path
/// (continuous `.attrib` events + FileWrapper was freezing the main thread
/// when opening large notes like `Claude.md`).
func loadMarkdownDocument(from url: URL) throws -> (content: String, assets: FileWrapper?) {
    let ext = url.pathExtension.lowercased()
    if ext == "textbundle" {
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try parseMarkdownWrapper(wrapper, isTextBundle: true)
    }
    // Regular file (or anything that isn't a package): cheap UTF-8 read.
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, nil)
    }
    // Directory-shaped / odd cases still go through FileWrapper.
    let wrapper = try FileWrapper(url: url, options: .immediate)
    return try parseMarkdownWrapper(wrapper, isTextBundle: wrapper.isDirectory)
}

/// Atomically writes content (+ optional textbundle assets) to `url`. For an
/// existing file the original URL is passed so unchanged sub-wrappers (assets)
/// can be reused instead of rewritten.
func writeMarkdownDocument(content: String, assets: FileWrapper?, to url: URL) throws {
    let isBundle = url.pathExtension.lowercased() == "textbundle"
    let wrapper = makeMarkdownWrapper(content: content, assets: assets, isTextBundle: isBundle)
    let original = FileManager.default.fileExists(atPath: url.path) ? url : nil
    try wrapper.write(to: url, options: .atomic, originalContentsURL: original)
}

// MARK: - DocumentRegistry

/// One in-memory `MarkdownDocument` per file URL, reference-counted for open
/// windows. Every open (Finder, sidebar, lite window) resolves its document
/// HERE so the same file in several windows shares one model, one `content`,
/// one save path, and one **undo stack**.
///
/// When the last window leaves a file the model is **not discarded** — it goes
/// into a session LRU cache so switching A → B → A keeps independent ⌘Z
/// histories. `isOpen` only reflects windows that currently hold a refcount
/// (the "already open elsewhere" modal).
///
/// Autosave is debounced via `markDirty(_:)` (owner view on content change).
/// Last `release` flushes dirty content to disk before parking the model.
///
/// **External disk changes** (another app / agent writing the open file) are
/// picked up automatically: each live entry watches its path via
/// `DispatchSource`, and `syncFromDiskIfNeeded` also runs on re-acquire from
/// the session cache and when the app becomes active.
///
/// - **Clean** buffer → auto-reload + `ExternalChangeNotice.applied` (banner + Diff).
/// - **Dirty** buffer → keep local text, post `.conflict` (Keep Mine / Take Disk).
@MainActor
final class DocumentRegistry {

    static let shared = DocumentRegistry()

    /// How many recently closed documents keep their undo stack in memory.
    static let sessionCacheLimit = 24

    /// Internal (not private) so tests can spin up an isolated registry instead
    /// of mutating the shared singleton.
    init() {
        // Belt-and-suspenders: FS events can miss on some volumes; re-check
        // every open file when the user returns to EditMD.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncAllOpenFromDisk() }
        }
    }

    private final class Entry {
        let url: URL
        let document: MarkdownDocument
        var refcount = 1
        var isDirty = false
        var autosaveTask: Task<Void, Never>?
        /// Last known `contentModificationDate` — used to skip no-op reloads
        /// and to ignore our own autosave writes when the event races.
        var knownModDate: Date?
        /// After external apply / conflict: ignore `markDirty` from residual
        /// `objectWillChange` (and don't autosave) until the user actually types.
        /// A single `suppressNextDirty` was not enough — two publishes or a
        /// follow-up autosave wiped the status chip and/or overwrote disk.
        var holdAutosaveUntilUserEdit = false
        /// Disk content already announced as a conflict (avoid re-posting).
        var pendingConflictDiskContent: String?
        /// Last external notice payload we posted (applied or conflict) — used
        /// so we never auto-dismiss while the user still needs Diff stats.
        var hasOpenExternalNotice = false
        var fileWatch: DispatchSourceFileSystemObject?
        var fileDescriptor: Int32 = -1
        /// Coalesces bursty FS events (Spotlight xattr, atomic rewrite, git).
        var diskEventDebounce: Task<Void, Never>?
        /// Accumulated `DispatchSource.FileSystemEvent` flags for the burst.
        var pendingDiskFlags: DispatchSource.FileSystemEvent?
        /// Content we last wrote ourselves (autosave / ⌘S). An FS echo of the
        /// same bytes must not re-baseline dirty-line marks (C2 / v34).
        var lastSelfWriteContent: String?
        init(url: URL, document: MarkdownDocument) {
            self.url = url
            self.document = document
        }
    }

    /// Windows currently showing the file (refcount > 0).
    private var entries: [URL: Entry] = [:]
    /// Recently released documents (undo history), most-recent first.
    /// `knownModDate` is the last disk mtime we synced — on re-acquire we only
    /// re-read the file when it is *newer* (agent edit while parked), so an
    /// in-memory buffer that wasn't flushed is not clobbered by a stale disk.
    private var sessionCache: [(url: URL, document: MarkdownDocument, knownModDate: Date?)] = []
    private let autosaveDelayNanos: UInt64 = 600_000_000

    /// URLs currently held by at least one window (used to detect "already open
    /// in another window" for the sidebar-click modal).
    var openURLs: [URL] { Array(entries.keys) }
    func isOpen(_ url: URL) -> Bool { entries[url.standardizedFileURL] != nil }
    func isDirty(_ url: URL) -> Bool { entries[url.standardizedFileURL]?.isDirty ?? false }

    /// In-memory buffer for an open (refcount > 0) document, if any.
    func contentIfOpen(_ url: URL) -> String? {
        entries[url.standardizedFileURL]?.document.content
    }

    /// Returns the shared document for `url`: live entry → session cache → disk.
    /// Balance with `release`.
    func acquire(_ url: URL) throws -> MarkdownDocument {
        let key = url.standardizedFileURL
        if let entry = entries[key] {
            entry.refcount += 1
            // Another window opened the same file — still re-check disk in case
            // the live model is stale (watch may have missed a write).
            syncFromDisk(entry, skipIfNotNewer: true)
            return entry.document
        }
        // Re-open within the session: same model + undo stack as last time.
        // Reload from disk only when the file is newer than when we parked
        // (external agent edit). Otherwise keep the cached buffer + undo.
        if let cached = takeFromSessionCache(key) {
            let entry = Entry(url: key, document: cached.document)
            entry.knownModDate = cached.knownModDate
            entries[key] = entry
            if diskIsNewerThanKnown(entry) {
                syncFromDisk(entry, skipIfNotNewer: true)
            }
            startWatching(entry)
            return cached.document
        }
        let (content, assets) = try loadMarkdownDocument(from: key)
        let document = MarkdownDocument()
        document.content = content
        document.assetsFileWrapper = assets
        let entry = Entry(url: key, document: document)
        entry.knownModDate = contentModificationDate(of: key)
        entries[key] = entry
        startWatching(entry)
        return document
    }

    /// Balances `acquire`. On the last release: flush dirty, then park the
    /// document in the session cache (keeps per-file undo). Not in `isOpen`.
    func release(_ url: URL) {
        let key = url.standardizedFileURL
        guard let entry = entries[key] else { return }
        entry.refcount -= 1
        guard entry.refcount <= 0 else { return }
        entry.autosaveTask?.cancel()
        entry.document.commitContentEdit()
        if entry.isDirty { try? flush(entry) }
        stopWatching(entry)
        entries.removeValue(forKey: key)
        parkInSessionCache(key, document: entry.document, knownModDate: entry.knownModDate)
    }

    /// Marks the document dirty and (re)schedules a debounced autosave. The
    /// owning view calls this when `document.content` changes.
    func markDirty(_ url: URL) {
        guard let entry = entries[url.standardizedFileURL] else { return }
        // Residual publishes after external reload / conflict must not
        // re-dirty or schedule an autosave that races the status chip.
        if entry.holdAutosaveUntilUserEdit { return }
        entry.isDirty = true
        scheduleAutosave(entry)
    }

    /// Call from editor typing paths so the next edits autosave again after
    /// an external apply held the flag.
    func noteUserEdit(_ url: URL?) {
        guard let url, let entry = entries[url.standardizedFileURL] else { return }
        entry.holdAutosaveUntilUserEdit = false
        entry.isDirty = true
        scheduleAutosave(entry)
    }

    /// Writes immediately, cancelling any pending autosave — for ⌘S and
    /// save-on-switch / save-on-close.
    func saveNow(_ url: URL) throws {
        guard let entry = entries[url.standardizedFileURL] else { return }
        entry.autosaveTask?.cancel()
        entry.document.commitContentEdit()
        try flush(entry)
    }

    /// Public re-check for a single open file (window focus, tests).
    /// Always attempts a content compare when the file exists — callers that
    /// already know the disk changed (tests, explicit refresh) must not be
    /// blocked by mtime resolution quirks. The watch path uses the mtime gate.
    @discardableResult
    func syncFromDiskIfNeeded(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL] else { return false }
        return syncFromDisk(entry, skipIfNotNewer: false)
    }

    /// Dismiss the banner for `url` without changing buffer or disk.
    func dismissExternalChange(_ url: URL) {
        ExternalChangeCenter.shared.dismiss(url)
        if let entry = entries[url.standardizedFileURL] {
            entry.pendingConflictDiskContent = nil
            entry.hasOpenExternalNotice = false
        }
    }

    /// Conflict: write the in-memory buffer over the external file.
    func keepMineOverDisk(_ url: URL) throws {
        let key = url.standardizedFileURL
        guard let entry = entries[key] else { return }
        entry.autosaveTask?.cancel()
        entry.holdAutosaveUntilUserEdit = false
        entry.document.commitContentEdit()
        try flush(entry)
        entry.pendingConflictDiskContent = nil
        entry.hasOpenExternalNotice = false
        ExternalChangeCenter.shared.dismiss(key)
        LineChangeTracker.shared.noteBaseline(url: key, content: entry.document.content)
    }

    /// Conflict or post-apply: replace the buffer with `content` from disk/notice.
    /// `content` just came from disk, so a failed re-persist loses nothing.
    func applyExternalContent(_ url: URL, content: String, assets: FileWrapper? = nil) {
        guard let entry = entries[url.standardizedFileURL] else { return }
        try? replaceBufferAndPersist(entry, content: content, assets: assets)
    }

    /// Shared core of external reload and agent accept: swap the buffer, then
    /// write it out. Throws only from the final disk write — the buffer is
    /// already swapped by then, so callers decide what a failed write means.
    private func replaceBufferAndPersist(_ entry: Entry, content: String,
                                         assets: FileWrapper?) throws {
        entry.document.commitContentEdit()
        entry.holdAutosaveUntilUserEdit = true
        entry.autosaveTask?.cancel()
        entry.document.content = content
        if let assets {
            entry.document.assetsFileWrapper = assets
        }
        entry.document.contentUndoManager.removeAllActions()
        entry.isDirty = false
        entry.pendingConflictDiskContent = nil
        entry.hasOpenExternalNotice = false
        entry.knownModDate = contentModificationDate(of: entry.url)
        ExternalChangeCenter.shared.dismiss(entry.url)
        LineChangeTracker.shared.noteBaseline(url: entry.url, content: content)
        // Persist so the next FS event doesn't look like another external write.
        try flush(entry)
    }

    /// After a clean auto-reload: restore the pre-reload snapshot and write it.
    func revertAppliedExternalChange(_ url: URL, previousContent: String) {
        applyExternalContent(url, content: previousContent)
    }

    /// Applies an agent-proposed edit the user accepted (Claude's `openDiff`).
    ///
    /// The whole point of routing it here: `flush` advances `knownModDate` and
    /// re-arms the watch, so our own write is not mistaken for an external
    /// change (v34). A plain `writeMarkdownDocument` from a tool handler would
    /// pop the conflict chip on the file the user just approved.
    ///
    /// Closed files are written directly — nothing holds a buffer to reconcile,
    /// but existing `.textbundle` assets must survive the rewrite.
    func applyAgentEdit(_ url: URL, content: String) throws {
        let key = url.standardizedFileURL
        if let entry = entries[key] {
            do {
                try replaceBufferAndPersist(entry, content: content, assets: nil)
            } catch {
                // Disk still holds the old bytes but the buffer already shows
                // Claude's. Surface it as an ordinary unsaved edit (autosave/⌘S
                // retry the write) and rethrow so accept() answers
                // DIFF_REJECTED — FILE_SAVED must mean bytes on disk.
                entry.isDirty = true
                entry.holdAutosaveUntilUserEdit = false
                throw error
            }
            return
        }
        let existingAssets = (try? loadMarkdownDocument(from: key))?.assets
        try writeMarkdownDocument(content: content, assets: existingAssets, to: key)
        LineChangeTracker.shared.noteBaseline(url: key, content: content)
        // A brand-new file has to appear in the sidebar without a manual refresh.
        WorkspaceModel.shared.noteFilesystemChange()
    }

    /// Drops the session cache (tests / low-memory). Live window entries stay.
    func clearSessionCache() {
        sessionCache.removeAll()
    }

    // MARK: Session cache (per-file undo across switches)

    private func takeFromSessionCache(_ key: URL) -> (document: MarkdownDocument, knownModDate: Date?)? {
        guard let idx = sessionCache.firstIndex(where: { $0.url == key }) else { return nil }
        let item = sessionCache.remove(at: idx)
        return (item.document, item.knownModDate)
    }

    private func parkInSessionCache(_ key: URL, document: MarkdownDocument, knownModDate: Date?) {
        sessionCache.removeAll { $0.url == key }
        sessionCache.insert((key, document, knownModDate), at: 0)
        let limit = Self.sessionCacheLimit
        if sessionCache.count > limit {
            sessionCache.removeLast(sessionCache.count - limit)
        }
    }

    private func scheduleAutosave(_ entry: Entry) {
        entry.autosaveTask?.cancel()
        let delay = autosaveDelayNanos
        entry.autosaveTask = Task { [weak self, weak entry] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, let entry else { return }
            try? self.flush(entry)
        }
    }

    private func flush(_ entry: Entry) throws {
        let content = entry.document.content
        try writeMarkdownDocument(content: content,
                                  assets: entry.document.assetsFileWrapper,
                                  to: entry.url)
        entry.isDirty = false
        // Own write: keep session dirty-line baseline (marks live until close /
        // external apply / commit). Remember payload so a racing FS echo is
        // not treated as external reload (C2).
        entry.lastSelfWriteContent = content
        // Remember our write so a racing FS event doesn't re-load the same bytes
        // as an "external" change (and so mtime compares stay correct).
        entry.knownModDate = contentModificationDate(of: entry.url)
        // Atomic replace may invalidate the watched inode — re-arm.
        rearmWatch(entry)
        // After save, a concurrent `git commit` (or hook) may have advanced;
        // re-check path hash so dirty-line marks can clear on real commits only.
        GitCommitWatcher.shared.check(url: entry.url)
    }

    // MARK: - External disk sync

    private func syncAllOpenFromDisk() {
        for entry in entries.values {
            // App became active: cheap mtime gate is enough (and necessary —
            // re-reading every open buffer would hitch).
            syncFromDisk(entry, skipIfNotNewer: true)
        }
    }

    /// Returns true when `document.content` was replaced from disk (clean path).
    /// - Parameter skipIfNotNewer: when true (watch / become-active), skip the
    ///   full read if mtime has not advanced — protects against FS event storms.
    @discardableResult
    private func syncFromDisk(_ entry: Entry, skipIfNotNewer: Bool = true) -> Bool {
        // Fast path: no newer mtime → skip the full read. Without this, every
        // FS event re-read the whole file on the main thread and could peg the
        // UI (Claude.md + continuous FS spam).
        if skipIfNotNewer,
           let diskDate = contentModificationDate(of: entry.url),
           let known = entry.knownModDate,
           diskDate <= known {
            return false
        }

        guard let loaded = try? loadMarkdownDocument(from: entry.url) else {
            rearmWatch(entry)
            return false
        }
        let disk = loaded.content
        let mem = entry.document.content
        // Own autosave/⌘S echo: mtime advanced but bytes are what we wrote.
        // Never re-baseline session dirty marks for our own flush (C2).
        if let selfWrite = entry.lastSelfWriteContent, disk == selfWrite {
            entry.lastSelfWriteContent = nil
            entry.knownModDate = contentModificationDate(of: entry.url)
            return false
        }
        let contentChanged = disk != mem
        let assetsChanged = !fileWrappersEqual(loaded.assets, entry.document.assetsFileWrapper)
        entry.knownModDate = contentModificationDate(of: entry.url)

        guard contentChanged || assetsChanged else {
            // Disk == memory: do NOT auto-dismiss an open notice. A follow-up
            // FS event after reload used to clear the status chip immediately.
            return false
        }

        if entry.isDirty {
            // Conflict: keep the buffer, announce once per distinct disk payload.
            if !contentChanged {
                return false
            }
            if entry.pendingConflictDiskContent == disk {
                return false
            }
            // Critical: cancel pending autosave so we don't overwrite the
            // external file with the old buffer a moment later (that also
            // made the chip vanish when disk snapped back to mem).
            entry.autosaveTask?.cancel()
            entry.holdAutosaveUntilUserEdit = true
            entry.pendingConflictDiskContent = disk
            entry.hasOpenExternalNotice = true
            let stats = lineDiff(before: mem, after: disk)
            ExternalChangeCenter.shared.post(ExternalChangeNotice(
                url: entry.url,
                before: mem,
                after: disk,
                kind: .conflict,
                added: stats.added,
                removed: stats.removed
            ))
            return false
        }

        // Clean: auto-apply, then offer a review chip in the status bar.
        let before = mem
        entry.document.commitContentEdit()
        entry.holdAutosaveUntilUserEdit = true
        entry.autosaveTask?.cancel()
        entry.document.content = disk
        entry.document.assetsFileWrapper = loaded.assets
        entry.document.contentUndoManager.removeAllActions()
        entry.isDirty = false
        entry.pendingConflictDiskContent = nil
        // New session baseline after external reload — clear dirty-line marks.
        LineChangeTracker.shared.noteBaseline(url: entry.url, content: disk)

        if contentChanged {
            entry.hasOpenExternalNotice = true
            let stats = lineDiff(before: before, after: disk)
            ExternalChangeCenter.shared.post(ExternalChangeNotice(
                url: entry.url,
                before: before,
                after: disk,
                kind: .applied,
                added: stats.added,
                removed: stats.removed
            ))
        }
        return true
    }

    private func contentModificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// True when on-disk mtime is strictly newer than the last sync — used when
    /// re-opening a session-cached document so we don't wipe an unflushed buffer.
    private func diskIsNewerThanKnown(_ entry: Entry) -> Bool {
        guard let diskDate = contentModificationDate(of: entry.url) else { return true }
        guard let known = entry.knownModDate else { return true }
        return diskDate > known
    }

    private func fileWrappersEqual(_ a: FileWrapper?, _ b: FileWrapper?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case let (a?, b?):
            return a.regularFileContents == b.regularFileContents
                && a.fileWrappers?.keys.sorted() == b.fileWrappers?.keys.sorted()
        }
    }

    private func startWatching(_ entry: Entry) {
        stopWatching(entry)
        // O_EVTONLY: event-only fd (no read), standard for path watches on Darwin.
        let fd = open(entry.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        entry.fileDescriptor = fd
        // Note: omit `.attrib` — Spotlight / xattr noise was firing continuous
        // reloads. Content changes arrive as write/extend; atomic replace as
        // rename/delete. App-activate still does a full mtime re-check.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .link, .revoke],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self, weak entry, weak source] in
            // Capture flags before hopping — `source.data` is only valid here.
            let flags = source?.data ?? []
            Task { @MainActor in
                guard let self, let entry else { return }
                self.handleDiskEvent(entry, flags: flags)
            }
        }
        source.setCancelHandler {
            if fd >= 0 { close(fd) }
        }
        entry.fileWatch = source
        source.resume()
    }

    private func stopWatching(_ entry: Entry) {
        entry.diskEventDebounce?.cancel()
        entry.diskEventDebounce = nil
        entry.fileWatch?.cancel()
        entry.fileWatch = nil
        entry.fileDescriptor = -1
        // cancelHandler closes the fd.
    }

    private func rearmWatch(_ entry: Entry) {
        // Only while a window still holds the file.
        guard entries[entry.url] != nil, entry.refcount > 0 else { return }
        startWatching(entry)
    }

    private func handleDiskEvent(_ entry: Entry, flags: DispatchSource.FileSystemEvent) {
        // Coalesce bursty events (atomic rewrite = delete+rename+write).
        entry.diskEventDebounce?.cancel()
        // OR-accumulate flags across the burst so a write+rename pair is seen.
        let prior = entry.pendingDiskFlags ?? []
        entry.pendingDiskFlags = prior.union(flags)
        entry.diskEventDebounce = Task { [weak self, weak entry] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            guard !Task.isCancelled, let self, let entry,
                  self.entries[entry.url] != nil else { return }
            let burst = entry.pendingDiskFlags ?? []
            entry.pendingDiskFlags = nil
            // Only re-arm when the inode may be gone. Rearming on every write
            // (close+open O_EVTONLY) generated more events → main-thread storm
            // at >100% CPU even in Source (Claude.md).
            let inodeMaybeReplaced = !burst.isDisjoint(with: [.rename, .delete, .revoke, .link])
            if inodeMaybeReplaced {
                self.rearmWatch(entry)
            }
            let applied = self.syncFromDisk(entry, skipIfNotNewer: true)
            // Content changed via atomic replace often shows up as write on a
            // new inode without rename flags — re-arm if we actually reloaded.
            if applied, !inodeMaybeReplaced {
                self.rearmWatch(entry)
            }
        }
    }
}
