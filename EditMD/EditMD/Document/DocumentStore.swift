import Foundation

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
@MainActor
final class DocumentRegistry {

    static let shared = DocumentRegistry()

    /// How many recently closed documents keep their undo stack in memory.
    static let sessionCacheLimit = 24

    /// Internal (not private) so tests can spin up an isolated registry instead
    /// of mutating the shared singleton.
    init() {}

    private final class Entry {
        let url: URL
        let document: MarkdownDocument
        var refcount = 1
        var isDirty = false
        var autosaveTask: Task<Void, Never>?
        init(url: URL, document: MarkdownDocument) {
            self.url = url
            self.document = document
        }
    }

    /// Windows currently showing the file (refcount > 0).
    private var entries: [URL: Entry] = [:]
    /// Recently released documents (undo history), most-recent first.
    private var sessionCache: [(url: URL, document: MarkdownDocument)] = []
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
            return entry.document
        }
        // Re-open within the session: same model + undo stack as last time.
        if let cached = takeFromSessionCache(key) {
            entries[key] = Entry(url: key, document: cached)
            return cached
        }
        let (content, assets) = try loadMarkdownDocument(from: key)
        let document = MarkdownDocument()
        document.content = content
        document.assetsFileWrapper = assets
        entries[key] = Entry(url: key, document: document)
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
        entries.removeValue(forKey: key)
        parkInSessionCache(key, document: entry.document)
    }

    /// Marks the document dirty and (re)schedules a debounced autosave. The
    /// owning view calls this when `document.content` changes.
    func markDirty(_ url: URL) {
        guard let entry = entries[url.standardizedFileURL] else { return }
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

    /// Drops the session cache (tests / low-memory). Live window entries stay.
    func clearSessionCache() {
        sessionCache.removeAll()
    }

    // MARK: Session cache (per-file undo across switches)

    private func takeFromSessionCache(_ key: URL) -> MarkdownDocument? {
        guard let idx = sessionCache.firstIndex(where: { $0.url == key }) else { return nil }
        let doc = sessionCache.remove(at: idx).document
        return doc
    }

    private func parkInSessionCache(_ key: URL, document: MarkdownDocument) {
        sessionCache.removeAll { $0.url == key }
        sessionCache.insert((key, document), at: 0)
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
    }
}
