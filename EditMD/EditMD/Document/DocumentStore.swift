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
func loadMarkdownDocument(from url: URL) throws -> (content: String, assets: FileWrapper?) {
    let wrapper = try FileWrapper(url: url, options: .immediate)
    let isBundle = url.pathExtension.lowercased() == "textbundle" || wrapper.isDirectory
    return try parseMarkdownWrapper(wrapper, isTextBundle: isBundle)
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
/// the session cache and when the app becomes active. Clean documents reload
/// in place; dirty ones keep the user's unsaved buffer (no silent clobber).
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
        /// When true, the next `markDirty` is dropped (external reload just
        /// updated `document.content`; that must not schedule autosave).
        var suppressNextDirty = false
        var fileWatch: DispatchSourceFileSystemObject?
        var fileDescriptor: Int32 = -1
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

    /// Returns the shared document for `url`: live entry → session cache → disk.
    /// Balance with `release`.
    func acquire(_ url: URL) throws -> MarkdownDocument {
        let key = url.standardizedFileURL
        if let entry = entries[key] {
            entry.refcount += 1
            // Another window opened the same file — still re-check disk in case
            // the live model is stale (watch may have missed a write).
            syncFromDisk(entry)
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
                syncFromDisk(entry)
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
        if entry.suppressNextDirty {
            entry.suppressNextDirty = false
            return
        }
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

    /// Public re-check for a single open file (window focus, tests). No-op when
    /// the document is dirty or the on-disk mtime matches `knownModDate`.
    @discardableResult
    func syncFromDiskIfNeeded(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL] else { return false }
        return syncFromDisk(entry)
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
        try writeMarkdownDocument(content: entry.document.content,
                                  assets: entry.document.assetsFileWrapper,
                                  to: entry.url)
        entry.isDirty = false
        // Remember our write so a racing FS event doesn't re-load the same bytes
        // as an "external" change (and so mtime compares stay correct).
        entry.knownModDate = contentModificationDate(of: entry.url)
        // Atomic replace may invalidate the watched inode — re-arm.
        rearmWatch(entry)
    }

    // MARK: - External disk sync

    private func syncAllOpenFromDisk() {
        for entry in entries.values {
            syncFromDisk(entry)
        }
    }

    /// Returns true when `document.content` was replaced from disk.
    ///
    /// Always reads the file and compares bytes — mtime alone is unreliable
    /// (1s resolution, atomic replace races, agent writes in the same second).
    /// Open-file count is small, so the cost is fine.
    @discardableResult
    private func syncFromDisk(_ entry: Entry) -> Bool {
        // Never clobber unsaved edits. User can Save / discard explicitly later.
        guard !entry.isDirty else { return false }
        guard let loaded = try? loadMarkdownDocument(from: entry.url) else {
            // File vanished or unreadable — leave the buffer; re-arm watch.
            rearmWatch(entry)
            return false
        }
        entry.knownModDate = contentModificationDate(of: entry.url)
        guard loaded.content != entry.document.content
                || !fileWrappersEqual(loaded.assets, entry.document.assetsFileWrapper) else {
            return false
        }
        entry.document.commitContentEdit()
        entry.suppressNextDirty = true
        entry.document.content = loaded.content
        entry.document.assetsFileWrapper = loaded.assets
        entry.document.contentUndoManager.removeAllActions()
        entry.isDirty = false
        entry.autosaveTask?.cancel()
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
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .link, .revoke],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self, weak entry] in
            // Source is on the main queue; hop to MainActor for isolation.
            Task { @MainActor in
                guard let self, let entry else { return }
                self.handleDiskEvent(entry)
            }
        }
        source.setCancelHandler {
            if fd >= 0 { close(fd) }
        }
        entry.fileWatch = source
        source.resume()
    }

    private func stopWatching(_ entry: Entry) {
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

    private func handleDiskEvent(_ entry: Entry) {
        // Atomic writers (ours and agents) replace the inode — always re-arm.
        rearmWatch(entry)
        syncFromDisk(entry)
    }
}
