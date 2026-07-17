import Foundation
import Darwin
import AppKit


// MARK: - DocumentRegistry

enum DocumentMovePreparationError: LocalizedError, Equatable, Sendable {
    case unresolvedExternalConflict(String)
    case moveInProgress(String)

    var errorDescription: String? {
        switch self {
        case .unresolvedExternalConflict(let name):
            return String(localized: "Resolve the external change conflict in “\(name)” first.")
        case .moveInProgress(let name):
            return String(localized: "The file “\(name)” is already being prepared for a move.")
        }
    }
}

/// Opaque ownership token for a document parked while its path is changing.
/// The token carries only the immutable snapshot that may cross off MainActor;
/// the document model and undo stack stay isolated inside DocumentRegistry.
struct DocumentMovePreparation: Sendable {
    fileprivate let id: UUID
    fileprivate let url: URL
    fileprivate let snapshot: MarkdownDocument.Snapshot?
}

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

    typealias MoveWriter = @Sendable (MarkdownDocument.Snapshot, URL) throws -> Void

    /// Local history snapshots (plan 05). Injectable for tests.
    private let revisionStore: FileRevisionStore

    /// Internal (not private) so tests can spin up an isolated registry instead
    /// of mutating the shared singleton.
    init(moveWriter: @escaping MoveWriter = DocumentRegistry.writeSnapshot,
         revisionStore: FileRevisionStore = .shared) {
        self.moveWriter = moveWriter
        self.revisionStore = revisionStore
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
        var pendingConflictDiskAssets: FileWrapper?
        var pendingConflictDiskAssetsFingerprint: DocumentAssetsFingerprint?
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
        /// When that write happened — the echo guard honours it only briefly,
        /// so a LATER external writer landing identical bytes (git checkout of
        /// the saved state) is still reported as external.
        var lastSelfWriteAt: Date?
        /// Last text payload actually observed on disk. Unlike `document.content`,
        /// this remains the pre-edit baseline while a local dirty buffer exists,
        /// so a forced move preflight can distinguish "our unsaved edit differs
        /// from disk" from "disk changed behind our unsaved edit" without
        /// relying on filesystem timestamp resolution.
        var knownDiskContent: String?
        var knownDiskAssetsFingerprint: DocumentAssetsFingerprint?
        init(
            url: URL,
            document: MarkdownDocument,
            knownDiskContent: String? = nil,
            knownDiskAssetsFingerprint: DocumentAssetsFingerprint? = nil
        ) {
            self.url = url
            self.document = document
            self.knownDiskContent = knownDiskContent
            self.knownDiskAssetsFingerprint = knownDiskAssetsFingerprint
        }
    }

    private enum PreparedState: Equatable {
        case reserved
        case writing
        case writeFailed
        case prepared
        case available
    }

    /// A move transaction owns these models until its presentation is restored
    /// at either the old or the new URL. This store is deliberately separate
    /// from the ordinary 24-entry session LRU: a batch may contain any number
    /// of open documents, and evicting one would lose its identity + undo stack.
    private struct PreparedDocument {
        let id: UUID
        let document: MarkdownDocument?
        /// Live presentations need an uncapped hand-off until DocHost re-acquires
        /// the model. A recently closed model can return to the ordinary LRU as
        /// soon as the transaction is cancelled or relocated.
        let wasOpen: Bool
        var knownModDate: Date?
        var knownDiskContent: String?
        var knownDiskAssetsFingerprint: DocumentAssetsFingerprint?
        var isDirty: Bool
        var state: PreparedState
    }

    private struct CachedDocument {
        let url: URL
        let document: MarkdownDocument
        let knownModDate: Date?
        let knownDiskContent: String?
        let knownDiskAssetsFingerprint: DocumentAssetsFingerprint?
        let isDirty: Bool
        /// A path transaction may change the URL (or allow a writer to race
        /// while the model is parked). The next acquire must therefore read the
        /// actual path even when its mtime happens to equal the old one.
        let requiresDiskReconciliation: Bool
    }

    /// Windows currently showing the file (refcount > 0).
    private var entries: [URL: Entry] = [:]
    /// Recently released documents (undo history), most-recent first.
    /// `knownModDate`/`knownDiskContent` describe the last disk state we synced.
    /// Ordinary re-acquire reads only a newer file; a path transaction marks its
    /// cache item for one mandatory actual-path reconciliation.
    private var sessionCache: [CachedDocument] = []
    private var preparedDocuments: [URL: PreparedDocument] = [:]
    private let moveWriter: MoveWriter
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

    /// Last disk text we synced for an open file (History «Не сохранено»).
    func knownDiskContent(of url: URL) -> String? {
        entries[url.standardizedFileURL]?.knownDiskContent
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
        if let prepared = preparedDocuments[key] {
            guard prepared.state == .available else {
                throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
            }
            guard let document = prepared.document else {
                // A URL-only reservation has reached its terminal state. There
                // is no identity to restore; consume it and load the actual path.
                preparedDocuments.removeValue(forKey: key)
                return try acquire(key)
            }
            let entry = Entry(
                url: key,
                document: document,
                knownDiskContent: prepared.knownDiskContent,
                knownDiskAssetsFingerprint: prepared.knownDiskAssetsFingerprint)
            entry.knownModDate = prepared.knownModDate
            entry.isDirty = prepared.isDirty
            markDirtyIfBufferDiffersFromKnownDisk(entry)
            // Cancel/relocate can be followed by an external write before the
            // presentation is restored. Read the *current* path before making
            // the parked model live; knownDiskContent prevents the expected
            // stale disk after a failed dirty write from becoming a false conflict.
            do {
                try reconcileFromDisk(entry)
            } catch {
                throw error
            }
            preparedDocuments.removeValue(forKey: key)
            entries[key] = entry
            startWatching(entry)
            if entry.isDirty, entry.pendingConflictDiskContent == nil {
                scheduleAutosave(entry)
            }
            return document
        }
        // Re-open within the session: same model + undo stack as last time.
        // Reload from disk only when the file is newer than when we parked
        // (external agent edit). Otherwise keep the cached buffer + undo.
        if let cached = takeFromSessionCache(key) {
            let entry = Entry(
                url: key,
                document: cached.document,
                knownDiskContent: cached.knownDiskContent,
                knownDiskAssetsFingerprint: cached.knownDiskAssetsFingerprint)
            entry.knownModDate = cached.knownModDate
            entry.isDirty = cached.isDirty
            markDirtyIfBufferDiffersFromKnownDisk(entry)
            do {
                if cached.requiresDiskReconciliation {
                    try reconcileFromDisk(entry)
                } else if diskIsNewerThanKnown(entry) {
                    syncFromDisk(entry, skipIfNotNewer: true)
                }
            } catch {
                parkInSessionCache(cached)
                throw error
            }
            entries[key] = entry
            startWatching(entry)
            return cached.document
        }
        let (content, assets) = try loadMarkdownDocument(from: key)
        let document = MarkdownDocument()
        document.content = content
        document.assetsFileWrapper = assets
        let entry = Entry(
            url: key,
            document: document,
            knownDiskContent: content,
            knownDiskAssetsFingerprint: DocumentAssetsFingerprint(assets))
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
        // Closing a document: force a last local revision so history captures
        // the final on-disk state even when the flush path (or a clean close)
        // fell inside the debounce window. Content dedup drops duplicates.
        noteLocalRevision(url: key, content: entry.document.content, force: true)
        stopWatching(entry)
        entries.removeValue(forKey: key)
        parkInSessionCache(
            key,
            document: entry.document,
            knownModDate: entry.knownModDate,
            knownDiskContent: entry.knownDiskContent,
            knownDiskAssetsFingerprint: entry.knownDiskAssetsFingerprint,
            isDirty: entry.isDirty)
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

    /// Synchronously reserves a URL before its path changes. A live entry is
    /// removed before its presentation closes, a recently closed model leaves
    /// the session LRU, and even a URL with no in-memory model receives an
    /// opaque reservation. Thus a re-entrant acquire/agent edit cannot slip
    /// between filesystem preflight and the disk transaction.
    ///
    /// After this returns, the caller must detach all presentations without an
    /// intervening suspension and then call `persistMovePreparation`. On any
    /// later transaction failure call `cancelMovePreparation`; after a disk
    /// move call `relocatePreparedDocument`.
    func beginMovePreparation(_ url: URL) throws -> DocumentMovePreparation? {
        let key = url.standardizedFileURL
        if preparedDocuments[key] != nil {
            throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
        }
        let id = UUID()

        if let entry = entries[key] {
            // This explicit Move action is the correctness boundary for a
            // pending/debounced file event. The synchronous read is deliberate
            // and bounded to this one user-selected document; writes remain
            // detached below. knownDiskContent makes the forced read safe for
            // an ordinary dirty buffer whose disk bytes have not changed.
            markDirtyIfBufferDiffersFromKnownDisk(entry)
            try reconcileFromDisk(entry)
            guard entry.pendingConflictDiskContent == nil else {
                throw DocumentMovePreparationError.unresolvedExternalConflict(
                    key.lastPathComponent)
            }
            entry.autosaveTask?.cancel()
            entry.document.commitContentEdit()
            let snapshot = entry.isDirty
                ? MarkdownDocument.Snapshot(
                    content: entry.document.content,
                    assetsFileWrapper: entry.document.assetsFileWrapper)
                : nil
            stopWatching(entry)
            entries.removeValue(forKey: key)
            preparedDocuments[key] = PreparedDocument(
                id: id,
                document: entry.document,
                wasOpen: true,
                knownModDate: entry.knownModDate,
                knownDiskContent: entry.knownDiskContent,
                knownDiskAssetsFingerprint: entry.knownDiskAssetsFingerprint,
                isDirty: entry.isDirty,
                state: .reserved)
            return DocumentMovePreparation(id: id, url: key, snapshot: snapshot)
        }

        if let cached = takeFromSessionCache(key) {
            let entry = Entry(
                url: key,
                document: cached.document,
                knownDiskContent: cached.knownDiskContent,
                knownDiskAssetsFingerprint: cached.knownDiskAssetsFingerprint)
            entry.knownModDate = cached.knownModDate
            entry.isDirty = cached.isDirty
            markDirtyIfBufferDiffersFromKnownDisk(entry)
            do {
                try reconcileFromDisk(entry)
            } catch {
                parkInSessionCache(cached)
                throw error
            }
            guard entry.pendingConflictDiskContent == nil else {
                parkInSessionCache(cached)
                throw DocumentMovePreparationError.unresolvedExternalConflict(
                    key.lastPathComponent)
            }
            let snapshot = entry.isDirty
                ? MarkdownDocument.Snapshot(
                    content: entry.document.content,
                    assetsFileWrapper: entry.document.assetsFileWrapper)
                : nil
            preparedDocuments[key] = PreparedDocument(
                id: id,
                document: cached.document,
                wasOpen: false,
                knownModDate: entry.knownModDate,
                knownDiskContent: entry.knownDiskContent,
                knownDiskAssetsFingerprint: entry.knownDiskAssetsFingerprint,
                isDirty: entry.isDirty,
                state: .reserved)
            return DocumentMovePreparation(id: id, url: key, snapshot: snapshot)
        }

        preparedDocuments[key] = PreparedDocument(
            id: id,
            document: nil,
            wasOpen: false,
            knownModDate: contentModificationDate(of: key),
            knownDiskContent: nil,
            knownDiskAssetsFingerprint: nil,
            isDirty: false,
            state: .reserved)
        return DocumentMovePreparation(id: id, url: key, snapshot: nil)
    }

    /// Reserves a destination path without adopting or evicting an existing
    /// document identity. A live, cached, or already-reserved destination is a
    /// transaction conflict; a free path receives an opaque URL-only token that
    /// blocks `acquire` and `applyAgentEdit` until cancel/discard releases it.
    func reserveMoveDestination(_ url: URL) throws -> DocumentMovePreparation {
        let key = url.standardizedFileURL
        guard entries[key] == nil,
              !sessionCache.contains(where: { $0.url == key }),
              preparedDocuments[key] == nil else {
            throw DocumentMovePreparationError.moveInProgress(
                key.lastPathComponent)
        }

        let id = UUID()
        preparedDocuments[key] = PreparedDocument(
            id: id,
            document: nil,
            wasOpen: false,
            knownModDate: contentModificationDate(of: key),
            knownDiskContent: nil,
            knownDiskAssetsFingerprint: nil,
            isDirty: false,
            state: .reserved)
        return DocumentMovePreparation(id: id, url: key, snapshot: nil)
    }

    /// Persists the immutable dirty snapshot after the presentation has been
    /// detached. Clean documents take the no-I/O branch. Dirty serialization
    /// and atomic disk I/O always run in a detached task, so the move overlay
    /// can render and MainActor stays responsive.
    func persistMovePreparation(_ preparation: DocumentMovePreparation) async throws {
        let key = preparation.url
        guard var prepared = preparedDocuments[key],
              prepared.id == preparation.id,
              prepared.state == .reserved else {
            throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
        }

        if let snapshot = preparation.snapshot {
            prepared.state = .writing
            preparedDocuments[key] = prepared
            do {
                try await Self.performMoveWrite(
                    snapshot, to: key, writer: moveWriter)
            } catch {
                // No disk move has happened. Make the exact model available at
                // the source only after the caller closes the transaction via
                // cancel; until then a re-entrant acquire/agent edit stays blocked.
                if var current = preparedDocuments[key],
                   current.id == preparation.id {
                    current.state = .writeFailed
                    current.isDirty = true
                    preparedDocuments[key] = current
                }
                throw error
            }

            guard var current = preparedDocuments[key],
                  current.id == preparation.id,
                  current.state == .writing else {
                throw DocumentMovePreparationError.moveInProgress(
                    key.lastPathComponent)
            }
            current.state = .prepared
            current.isDirty = false
            current.knownModDate = contentModificationDate(of: key)
            current.knownDiskContent = snapshot.content
            current.knownDiskAssetsFingerprint = DocumentAssetsFingerprint(
                snapshot.assetsFileWrapper)
            preparedDocuments[key] = current
            GitCommitWatcher.shared.check(url: key)
        } else {
            prepared.state = .prepared
            preparedDocuments[key] = prepared
        }
        ExternalChangeCenter.shared.dismiss(key)
    }

    /// Makes a reserved/prepared live model available at its original path
    /// after a transaction abort. Cached models return to the LRU and URL-only
    /// reservations disappear. The method remains idempotent so callers can use
    /// one cleanup loop for the entire batch.
    func cancelMovePreparation(_ preparation: DocumentMovePreparation?) {
        guard let preparation,
              let prepared = preparedDocuments[preparation.url],
              prepared.id == preparation.id,
              prepared.state != .writing else { return }
        if prepared.wasOpen {
            var available = prepared
            available.state = .available
            preparedDocuments[preparation.url] = available
        } else {
            preparedDocuments.removeValue(forKey: preparation.url)
            if let document = prepared.document {
                parkInSessionCache(
                    preparation.url,
                    document: document,
                    knownModDate: prepared.knownModDate,
                    knownDiskContent: prepared.knownDiskContent,
                    knownDiskAssetsFingerprint: prepared.knownDiskAssetsFingerprint,
                    isDirty: prepared.isDirty,
                    requiresDiskReconciliation: true)
            }
        }
    }

    /// Forgets a parked model when rollback left the filesystem at neither a
    /// trustworthy source nor a trustworthy destination. The dirty snapshot
    /// was persisted before disk mutation, so a later explicit open must load
    /// whichever path the user repairs instead of reviving an ambiguously
    /// keyed in-memory model.
    func discardMovePreparation(_ preparation: DocumentMovePreparation?) {
        guard let preparation,
              let prepared = preparedDocuments[preparation.url],
              prepared.id == preparation.id,
              prepared.state != .writing else { return }
        preparedDocuments.removeValue(forKey: preparation.url)
    }

    /// Re-keys the prepared model after a successful disk move. The next acquire
    /// at `newURL` restores the same document and undo manager.
    func relocatePreparedDocument(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL
        let new = newURL.standardizedFileURL
        guard let prepared = preparedDocuments.removeValue(forKey: old) else { return }
        guard prepared.state == .prepared else {
            preparedDocuments[old] = prepared
            return
        }
        // Destination preflight guarantees this in the move transaction. Keep
        // an existing prepared model intact defensively instead of discarding
        // either identity if a caller violates that contract.
        guard preparedDocuments[new] == nil else {
            preparedDocuments[old] = prepared
            return
        }
        sessionCache.removeAll { $0.url == new }
        if prepared.wasOpen {
            var relocated = prepared
            relocated.state = .available
            preparedDocuments[new] = relocated
        } else if let document = prepared.document {
            parkInSessionCache(
                new,
                document: document,
                knownModDate: prepared.knownModDate,
                knownDiskContent: prepared.knownDiskContent,
                knownDiskAssetsFingerprint: prepared.knownDiskAssetsFingerprint,
                isDirty: prepared.isDirty,
                requiresDiskReconciliation: true)
        }
    }

    /// Re-keys closed document identities after an adopted root moves. Root
    /// rename rejects live entries before touching disk, but session-cached
    /// models still carry undo and must follow the folder. A stale cache entry
    /// already parked under the destination loses to the source identity that
    /// belongs to the filesystem item just moved there.
    func relocateFolder(from oldRoot: URL, to newRoot: URL) {
        let old = oldRoot.standardizedFileURL
        let new = newRoot.standardizedFileURL

        let originalCache = sessionCache
        sessionCache = originalCache.compactMap { cached in
            if Self.isPath(cached.url, inside: old) {
                return CachedDocument(
                    url: WorkspaceModel.relocatedURL(cached.url, from: old, to: new),
                    document: cached.document,
                    knownModDate: cached.knownModDate,
                    knownDiskContent: cached.knownDiskContent,
                    knownDiskAssetsFingerprint: cached.knownDiskAssetsFingerprint,
                    isDirty: cached.isDirty,
                    requiresDiskReconciliation: true)
            }
            // The destination root did not exist at transaction preflight;
            // any other identity parked under it is stale from an older tree.
            return Self.isPath(cached.url, inside: new) ? nil : cached
        }

        let movingPrepared = preparedDocuments.filter {
            Self.isPath($0.key, inside: old)
        }
        preparedDocuments = preparedDocuments.filter {
            !Self.isPath($0.key, inside: old)
                && !Self.isPath($0.key, inside: new)
        }
        for (source, prepared) in movingPrepared {
            let destination = WorkspaceModel.relocatedURL(
                source, from: old, to: new)
            preparedDocuments[destination] = prepared
        }
    }

    /// Drops parked identities after an ambiguous root outcome. A later open
    /// must load the path the user repaired on disk, never revive a model still
    /// keyed to one of the transaction's unsafe candidates.
    func discardFolderCaches(at rawRoots: [URL]) {
        let roots = rawRoots.map(\.standardizedFileURL)
        sessionCache.removeAll { cached in
            roots.contains { Self.isPath(cached.url, inside: $0) }
        }
        preparedDocuments = preparedDocuments.filter { url, _ in
            !roots.contains { Self.isPath(url, inside: $0) }
        }
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
            // Dismiss hides presentation only. The disk/local choice remains
            // unresolved until Disk, Mine, or a successful explicit/local
            // write; move preflight must continue to block meanwhile.
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
        LineChangeTracker.shared.noteBaseline(url: key, content: entry.document.content)
    }

    /// Conflict or post-apply: replace the buffer with `content` from disk/notice.
    /// `content` just came from disk, so a failed re-persist loses nothing.
    func applyExternalContent(_ url: URL, content: String, assets: FileWrapper? = nil) {
        guard let entry = entries[url.standardizedFileURL] else { return }
        let hasPendingConflict = entry.pendingConflictDiskContent != nil
        let resolvedAssets = assets ?? entry.pendingConflictDiskAssets
        try? replaceBufferAndPersist(
            entry,
            content: content,
            assets: resolvedAssets,
            replaceAssets: hasPendingConflict || assets != nil)
    }

    /// Shared core of external reload and agent accept: swap the buffer, then
    /// write it out. Throws only from the final disk write — the buffer is
    /// already swapped by then, so callers decide what a failed write means.
    private func replaceBufferAndPersist(
        _ entry: Entry,
        content: String,
        assets: FileWrapper?,
        replaceAssets: Bool = false
    ) throws {
        entry.document.commitContentEdit()
        entry.holdAutosaveUntilUserEdit = true
        entry.autosaveTask?.cancel()
        entry.document.content = content
        if replaceAssets {
            entry.document.assetsFileWrapper = assets
        } else if let assets {
            entry.document.assetsFileWrapper = assets
        }
        entry.document.contentUndoManager.removeAllActions()
        entry.isDirty = false
        clearPendingConflict(entry)
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
        if var prepared = preparedDocuments[key] {
            guard prepared.state == .available else {
                throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
            }
            guard let document = prepared.document else {
                preparedDocuments.removeValue(forKey: key)
                return try applyAgentEdit(key, content: content)
            }
            let entry = Entry(
                url: key,
                document: document,
                knownDiskContent: prepared.knownDiskContent,
                knownDiskAssetsFingerprint: prepared.knownDiskAssetsFingerprint)
            entry.knownModDate = prepared.knownModDate
            entry.isDirty = prepared.isDirty
            markDirtyIfBufferDiffersFromKnownDisk(entry)
            try reconcileFromDisk(entry)
            guard entry.pendingConflictDiskContent == nil else {
                throw DocumentMovePreparationError.unresolvedExternalConflict(
                    key.lastPathComponent)
            }
            do {
                try replaceBufferAndPersist(entry, content: content, assets: nil)
            } catch {
                // Match the live-entry contract: the accepted buffer remains
                // dirty and retryable, while the failed API call never claims
                // that disk contains the new bytes.
                entry.isDirty = true
                entry.holdAutosaveUntilUserEdit = false
                prepared.isDirty = true
                prepared.knownModDate = entry.knownModDate
                prepared.knownDiskContent = entry.knownDiskContent
                prepared.knownDiskAssetsFingerprint = entry.knownDiskAssetsFingerprint
                preparedDocuments[key] = prepared
                throw error
            }
            prepared.isDirty = entry.isDirty
            prepared.knownModDate = entry.knownModDate
            prepared.knownDiskContent = entry.knownDiskContent
            prepared.knownDiskAssetsFingerprint = entry.knownDiskAssetsFingerprint
            preparedDocuments[key] = prepared
            return
        }
        if let entry = entries[key] {
            guard entry.pendingConflictDiskContent == nil else {
                throw DocumentMovePreparationError.unresolvedExternalConflict(
                    key.lastPathComponent)
            }
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
        // Closed-file agent edit: same incremental index path as flush.
        LinkIndex.shared.noteDocumentPersisted(url: key, content: content)
        // A brand-new file has to appear in the sidebar without a manual refresh.
        WorkspaceModel.shared.noteFilesystemChange()
    }

    /// Drops the session cache (tests / low-memory). Live window entries stay.
    func clearSessionCache() {
        sessionCache.removeAll()
    }

    // MARK: Session cache (per-file undo across switches)

    private func takeFromSessionCache(_ key: URL) -> CachedDocument? {
        guard let idx = sessionCache.firstIndex(where: { $0.url == key }) else { return nil }
        return sessionCache.remove(at: idx)
    }

    private func parkInSessionCache(
        _ key: URL,
        document: MarkdownDocument,
        knownModDate: Date?,
        knownDiskContent: String?,
        knownDiskAssetsFingerprint: DocumentAssetsFingerprint?,
        isDirty: Bool,
        requiresDiskReconciliation: Bool = false
    ) {
        sessionCache.removeAll { $0.url == key }
        sessionCache.insert(CachedDocument(
            url: key,
            document: document,
            knownModDate: knownModDate,
            knownDiskContent: knownDiskContent,
            knownDiskAssetsFingerprint: knownDiskAssetsFingerprint,
            isDirty: isDirty,
            requiresDiskReconciliation: requiresDiskReconciliation), at: 0)
        let limit = Self.sessionCacheLimit
        if sessionCache.count > limit {
            sessionCache.removeLast(sessionCache.count - limit)
        }
    }

    private func parkInSessionCache(_ cached: CachedDocument) {
        parkInSessionCache(
            cached.url,
            document: cached.document,
            knownModDate: cached.knownModDate,
            knownDiskContent: cached.knownDiskContent,
            knownDiskAssetsFingerprint: cached.knownDiskAssetsFingerprint,
            isDirty: cached.isDirty,
            requiresDiskReconciliation: cached.requiresDiskReconciliation)
    }

    /// Undo-driven/test edits can change the model before the SwiftUI owner
    /// delivers `markDirty`. A move boundary cannot trust that transient flag;
    /// compare the buffer with the last observed disk baseline explicitly.
    private func markDirtyIfBufferDiffersFromKnownDisk(_ entry: Entry) {
        let contentDiffers = entry.knownDiskContent.map {
            $0 != entry.document.content
        } ?? false
        let assetsDiffers = entry.knownDiskAssetsFingerprint.map {
            $0 != DocumentAssetsFingerprint(entry.document.assetsFileWrapper)
        } ?? false
        if contentDiffers || assetsDiffers {
            entry.isDirty = true
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
        entry.lastSelfWriteAt = Date()
        // Remember our write so a racing FS event doesn't re-load the same bytes
        // as an "external" change (and so mtime compares stay correct).
        entry.knownModDate = contentModificationDate(of: entry.url)
        entry.knownDiskContent = content
        entry.knownDiskAssetsFingerprint = DocumentAssetsFingerprint(
            entry.document.assetsFileWrapper)
        clearPendingConflict(entry)
        // Atomic replace may invalidate the watched inode — re-arm.
        rearmWatch(entry)
        // After save, a concurrent `git commit` (or hook) may have advanced;
        // re-check path hash so dirty-line marks can clear on real commits only.
        GitCommitWatcher.shared.check(url: entry.url)
        // Link index: incremental rescan of this file only (plan 02).
        LinkIndex.shared.noteDocumentPersisted(url: entry.url, content: content)
        // Local revision history (plan 05) — background, debounced in store.
        noteLocalRevision(url: entry.url, content: content, force: false)
    }

    /// Snapshot saved markdown for the History tab. Off-main via the store.
    private func noteLocalRevision(url: URL, content: String, force: Bool) {
        revisionStore.notePersistedAsync(url: url, content: content, force: force)
    }

    private func clearPendingConflict(_ entry: Entry) {
        entry.pendingConflictDiskContent = nil
        entry.pendingConflictDiskAssets = nil
        entry.pendingConflictDiskAssetsFingerprint = nil
        entry.hasOpenExternalNotice = false
        ExternalChangeCenter.shared.dismiss(entry.url)
    }

    /// `FileWrapper` is not Sendable, but MarkdownDocument.Snapshot is an
    /// immutable, exclusively-owned transfer value by project contract.
    nonisolated private static func writeSnapshot(
        _ snapshot: MarkdownDocument.Snapshot,
        to url: URL
    ) throws {
        try writeMarkdownDocument(
            content: snapshot.content,
            assets: snapshot.assetsFileWrapper,
            to: url)
    }

    /// Atomic document writes are intentionally allowed to finish even if the
    /// surrounding UI task is cancelled: abandoning one midway would leave the
    /// move transaction unable to know whether disk contains old or new bytes.
    nonisolated private static func performMoveWrite(
        _ snapshot: MarkdownDocument.Snapshot,
        to url: URL,
        writer: @escaping MoveWriter
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            try writer(snapshot, url)
        }.value
    }

    // MARK: - External disk sync

    private func syncAllOpenFromDisk() {
        for entry in entries.values {
            // App became active: cheap mtime gate is enough (and necessary —
            // re-reading every open buffer would hitch).
            syncFromDisk(entry, skipIfNotNewer: true)
        }
    }

    /// Returns true when clean document content or assets were replaced from disk.
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
        return reconcileLoadedDocument(loaded, with: entry)
    }

    /// Mandatory transaction-boundary read. Unlike watcher refresh this
    /// propagates an unreadable/missing path to the caller and never trusts an
    /// mtime copied from the source path before a relocation.
    @discardableResult
    private func reconcileFromDisk(_ entry: Entry) throws -> Bool {
        let loaded = try loadMarkdownDocument(from: entry.url)
        return reconcileLoadedDocument(loaded, with: entry)
    }

    @discardableResult
    private func reconcileLoadedDocument(
        _ loaded: (content: String, assets: FileWrapper?),
        with entry: Entry
    ) -> Bool {
        let disk = loaded.content
        let mem = entry.document.content
        let diskAssetsFingerprint = DocumentAssetsFingerprint(loaded.assets)
        let memoryAssetsFingerprint = DocumentAssetsFingerprint(
            entry.document.assetsFileWrapper)
        // Own autosave/⌘S echo: mtime advanced but bytes are what we wrote.
        // Never re-baseline session dirty marks for our own flush (C2).
        // Guard window: an echo arrives within seconds; identical bytes long
        // after (git checkout back to the saved state) are a real external
        // change. Assets must match too — a .textbundle image swap with an
        // unchanged text.md is external.
        if let selfWrite = entry.lastSelfWriteContent,
           let writtenAt = entry.lastSelfWriteAt,
           disk == selfWrite,
           Date().timeIntervalSince(writtenAt) < 10,
           diskAssetsFingerprint == memoryAssetsFingerprint {
            entry.lastSelfWriteContent = nil
            entry.lastSelfWriteAt = nil
            entry.knownModDate = contentModificationDate(of: entry.url)
            entry.knownDiskContent = disk
            entry.knownDiskAssetsFingerprint = diskAssetsFingerprint
            return false
        }
        let contentChanged = disk != mem
        let diskContentChanged = entry.knownDiskContent.map { $0 != disk }
            ?? contentChanged
        let diskAssetsChanged = entry.knownDiskAssetsFingerprint.map {
            $0 != diskAssetsFingerprint
        } ?? (diskAssetsFingerprint != memoryAssetsFingerprint)
        let assetsDifferFromBuffer = diskAssetsFingerprint != memoryAssetsFingerprint
        entry.knownModDate = contentModificationDate(of: entry.url)
        entry.knownDiskContent = disk
        entry.knownDiskAssetsFingerprint = diskAssetsFingerprint

        guard diskContentChanged || diskAssetsChanged else {
            // Disk is still the baseline we already observed. In particular,
            // do not mistake a normal unsaved buffer (or a failed move write)
            // for an external conflict merely because memory differs from disk.
            // Also do not auto-dismiss an open notice on a follow-up FS echo.
            return false
        }

        if entry.isDirty {
            // Conflict: keep the buffer, announce once per distinct disk payload.
            if !contentChanged, !assetsDifferFromBuffer {
                entry.isDirty = false
                clearPendingConflict(entry)
                return false
            }
            if entry.pendingConflictDiskContent == disk,
               entry.pendingConflictDiskAssetsFingerprint == diskAssetsFingerprint {
                return false
            }
            // Critical: cancel pending autosave so we don't overwrite the
            // external file with the old buffer a moment later (that also
            // made the chip vanish when disk snapped back to mem).
            entry.autosaveTask?.cancel()
            entry.holdAutosaveUntilUserEdit = true
            entry.pendingConflictDiskContent = disk
            entry.pendingConflictDiskAssets = loaded.assets
            entry.pendingConflictDiskAssetsFingerprint = diskAssetsFingerprint
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
        entry.pendingConflictDiskAssets = nil
        entry.pendingConflictDiskAssetsFingerprint = nil
        // New session baseline after external reload — clear dirty-line marks.
        LineChangeTracker.shared.noteBaseline(url: entry.url, content: disk)

        if contentChanged {
            if EditorSettings.shared.general.autoReloadCleanExternal {
                // Stage 7: quiet toast + popover event line. Deliberately NOT
                // a harness status — the disk write is usually the agent's own
                // edit, and stamping idle here wiped its live active/blocked.
                AgentActivityModel.shared.noteDiskReload(
                    fileName: entry.url.lastPathComponent)
            }
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

    nonisolated private static func isPath(_ rawURL: URL, inside rawRoot: URL) -> Bool {
        let path = rawURL.standardizedFileURL.path
        let root = rawRoot.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
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
