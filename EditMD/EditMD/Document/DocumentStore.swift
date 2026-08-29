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

/// Opaque token for a document parked during a path change. Carries only the
/// immutable snapshot that may cross off MainActor; model + undo stack stay
/// inside DocumentRegistry.
struct DocumentMovePreparation: Sendable {
    fileprivate let id: UUID
    fileprivate let url: URL
    fileprivate let snapshot: MarkdownDocument.Snapshot?
}

/// One in-memory `MarkdownDocument` per file URL, refcounted per open window.
/// Every open path resolves HERE so several windows on one file share one
/// model, one `content`, one save path, one undo stack.
///
/// Last release does NOT discard the model — it parks in a session LRU so
/// A → B → A keeps independent ⌘Z histories. `isOpen` reflects only refcount
/// holders (the "already open elsewhere" modal).
///
/// Autosave: debounced via `markDirty(_:)`; last `release` flushes dirty
/// content before parking.
///
/// External disk changes: each live entry watches its path via
/// `DispatchSource`; `syncFromDiskIfNeeded` also runs on cache re-acquire and
/// app-becomes-active.
/// - Clean buffer → auto-reload + `ExternalChangeNotice.applied`.
/// - Dirty buffer → keep local text, post `.conflict` (Keep Mine / Take Disk).
@MainActor
final class DocumentRegistry {

    static let shared = DocumentRegistry()

    /// Recently closed documents that keep their undo stack in memory.
    static let sessionCacheLimit = 24

    typealias MoveWriter = @Sendable (MarkdownDocument.Snapshot, URL) throws -> Void

    /// Local history snapshots. Injectable for tests.
    private let revisionStore: FileRevisionStore

    /// Internal (not private): tests spin up isolated registries instead of
    /// mutating the shared singleton.
    init(moveWriter: @escaping MoveWriter = DocumentRegistry.writeSnapshot,
         revisionStore: FileRevisionStore = .shared) {
        self.moveWriter = moveWriter
        self.revisionStore = revisionStore
        // FS events can miss on some volumes; re-check every open file on
        // return to EditMD.
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
        /// Last known `contentModificationDate` — skips no-op reloads; ignores
        /// our own autosave writes when the event races.
        var knownModDate: Date?
        /// After external apply/conflict: ignore `markDirty` from residual
        /// `objectWillChange` (and don't autosave) until the user types. A
        /// single suppress-next flag was not enough — two publishes or a
        /// follow-up autosave wiped the status chip and/or overwrote disk.
        var holdAutosaveUntilUserEdit = false
        /// Disk content already announced as a conflict (avoid re-posting).
        var pendingConflictDiskContent: String?
        var pendingConflictDiskAssets: FileWrapper?
        var pendingConflictDiskAssetsFingerprint: DocumentAssetsFingerprint?
        /// Never auto-dismiss while the user still needs Diff stats.
        var hasOpenExternalNotice = false
        var fileWatch: DispatchSourceFileSystemObject?
        var fileDescriptor: Int32 = -1
        /// Coalesces bursty FS events (Spotlight xattr, atomic rewrite, git).
        var diskEventDebounce: Task<Void, Never>?
        /// Accumulated `DispatchSource.FileSystemEvent` flags for the burst.
        var pendingDiskFlags: DispatchSource.FileSystemEvent?
        /// Content we last wrote (autosave / ⌘S): an FS echo of the same bytes
        /// must not re-baseline dirty-line marks.
        var lastSelfWriteContent: String?
        /// Echo guard honours the self-write only briefly — a LATER external
        /// writer landing identical bytes (git checkout of the saved state)
        /// still counts as external.
        var lastSelfWriteAt: Date?
        /// Last text actually observed on disk. Unlike `document.content` it
        /// stays the pre-edit baseline while a dirty buffer exists, so move
        /// preflight can tell "our unsaved edit differs from disk" from "disk
        /// changed behind our edit" without trusting fs timestamp resolution.
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

    /// Owned by a move transaction until its presentation is restored at old
    /// or new URL. Deliberately separate from the capped session LRU: a batch
    /// may hold any number of open documents; evicting one loses identity +
    /// undo stack.
    private struct PreparedDocument {
        let id: UUID
        let document: MarkdownDocument?
        /// Live presentations need an uncapped hand-off until DocHost
        /// re-acquires; a recently closed model returns to the LRU on
        /// cancel/relocate.
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
        /// A path transaction may change the URL (or let a writer race while
        /// parked): the next acquire must read the actual path even when the
        /// mtime equals the old one.
        let requiresDiskReconciliation: Bool
    }

    /// Windows currently showing the file (refcount > 0).
    private var entries: [URL: Entry] = [:]
    /// Recently released documents (undo history), most-recent first.
    /// `knownModDate`/`knownDiskContent` = last synced disk state. Ordinary
    /// re-acquire reads only a newer file; a path transaction marks its item
    /// for one mandatory actual-path reconciliation.
    private var sessionCache: [CachedDocument] = []
    private var preparedDocuments: [URL: PreparedDocument] = [:]
    private let moveWriter: MoveWriter
    private let autosaveDelayNanos: UInt64 = 600_000_000

    /// URLs held by at least one window ("already open elsewhere" detection).
    var openURLs: [URL] { Array(entries.keys) }
    func isOpen(_ url: URL) -> Bool { entries[url.standardizedFileURL] != nil }
    func isDirty(_ url: URL) -> Bool { entries[url.standardizedFileURL]?.isDirty ?? false }

    /// Unsaved changes in any live, session-cached, or parked-move document at
    /// or under `root`. Folder trash warns from this — the open-document guard
    /// cannot see closed dirty buffers.
    func hasUnsavedChanges(inside rawRoot: URL) -> Bool {
        let root = rawRoot.standardizedFileURL
        if entries.contains(where: {
            $0.value.isDirty && Self.isPath($0.key, inside: root)
        }) { return true }
        if sessionCache.contains(where: {
            $0.isDirty && Self.isPath($0.url, inside: root)
        }) { return true }
        return preparedDocuments.contains {
            $0.value.isDirty && Self.isPath($0.key, inside: root)
        }
    }

    /// In-memory buffer for an open (refcount > 0) document, if any.
    func contentIfOpen(_ url: URL) -> String? {
        entries[url.standardizedFileURL]?.document.content
    }

    /// Last disk text we synced for an open file (History "Unsaved Changes").
    func knownDiskContent(of url: URL) -> String? {
        entries[url.standardizedFileURL]?.knownDiskContent
    }

    /// Returns the shared document for `url`: live entry → session cache → disk.
    /// Balance with `release`.
    func acquire(_ url: URL) throws -> MarkdownDocument {
        let key = url.standardizedFileURL
        if let entry = entries[key] {
            entry.refcount += 1
            // Second window on the same file: still re-check disk — the watch
            // may have missed a write.
            syncFromDisk(entry, skipIfNotNewer: true)
            return entry.document
        }
        if let prepared = preparedDocuments[key] {
            guard prepared.state == .available else {
                throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
            }
            guard let document = prepared.document else {
                // Terminal URL-only reservation: no identity to restore —
                // consume it, load the actual path.
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
            // An external write can land between cancel/relocate and restore:
            // read the CURRENT path before making the parked model live.
            // knownDiskContent keeps the expected stale disk after a failed
            // dirty write from becoming a false conflict.
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
        // Session re-open: same model + undo stack. Reload from disk only when
        // the file is newer than at park time (external agent edit).
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

    /// Balances `acquire`. Last release: flush dirty, park in session cache
    /// (keeps per-file undo). No longer in `isOpen`.
    func release(_ url: URL) {
        let key = url.standardizedFileURL
        guard let entry = entries[key] else { return }
        entry.refcount -= 1
        guard entry.refcount <= 0 else { return }
        entry.autosaveTask?.cancel()
        entry.document.commitContentEdit()
        if entry.isDirty { try? flush(entry) }
        // Forced last revision: history must capture the final on-disk state
        // even when close fell inside the debounce window. Dedup drops repeats.
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

    /// Dirty + debounced autosave; owner view calls on `content` change.
    func markDirty(_ url: URL) {
        guard let entry = entries[url.standardizedFileURL] else { return }
        // Residual publishes after external reload/conflict must not re-dirty
        // or schedule an autosave racing the status chip.
        if entry.holdAutosaveUntilUserEdit { return }
        entry.isDirty = true
        scheduleAutosave(entry)
    }

    /// Editor typing paths call this so edits autosave again after an external
    /// apply held the flag.
    func noteUserEdit(_ url: URL?) {
        guard let url, let entry = entries[url.standardizedFileURL] else { return }
        entry.holdAutosaveUntilUserEdit = false
        entry.isDirty = true
        scheduleAutosave(entry)
    }

    /// Immediate write, cancels pending autosave (⌘S, save-on-switch/close).
    func saveNow(_ url: URL) throws {
        guard let entry = entries[url.standardizedFileURL] else { return }
        entry.autosaveTask?.cancel()
        entry.document.commitContentEdit()
        try flush(entry)
    }

    /// Synchronously reserves a URL before its path changes: live entry
    /// removed, cached model pulled from the LRU, even a model-less URL gets
    /// an opaque reservation — so a re-entrant acquire/agent edit cannot slip
    /// between filesystem preflight and the disk transaction.
    ///
    /// Caller contract: detach all presentations with NO intervening
    /// suspension, then `persistMovePreparation`; on failure
    /// `cancelMovePreparation`; after the disk move `relocatePreparedDocument`.
    func beginMovePreparation(_ url: URL) throws -> DocumentMovePreparation? {
        let key = url.standardizedFileURL
        if preparedDocuments[key] != nil {
            throw DocumentMovePreparationError.moveInProgress(key.lastPathComponent)
        }
        let id = UUID()

        if let entry = entries[key] {
            // Explicit Move is the correctness boundary for a pending/debounced
            // file event. Sync read is deliberate, bounded to this one document;
            // writes stay detached. knownDiskContent makes the forced read safe
            // for an ordinary dirty buffer whose disk bytes did not change.
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

    /// Reserves a destination path without adopting/evicting any identity.
    /// Live, cached, or already-reserved destination = transaction conflict; a
    /// free path gets an opaque URL-only token blocking `acquire` and
    /// `applyAgentEdit` until cancel/discard.
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

    /// Persists the immutable dirty snapshot after presentations detach.
    /// Clean documents take the no-I/O branch; dirty serialization + atomic
    /// I/O run detached so the move overlay renders and MainActor stays live.
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
                // No disk move happened. The model becomes available at the
                // source only after the caller cancels; until then re-entrant
                // acquire/agent edits stay blocked.
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

    /// Transaction abort: reserved/prepared live model becomes available at
    /// its original path; cached models return to the LRU; URL-only
    /// reservations vanish. Idempotent — one cleanup loop per batch.
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

    /// Forgets a parked model when rollback left neither a trustworthy source
    /// nor destination. The dirty snapshot was persisted pre-mutation, so a
    /// later open must load whichever path the user repairs — never revive an
    /// ambiguously keyed in-memory model.
    func discardMovePreparation(_ preparation: DocumentMovePreparation?) {
        guard let preparation,
              let prepared = preparedDocuments[preparation.url],
              prepared.id == preparation.id,
              prepared.state != .writing else { return }
        preparedDocuments.removeValue(forKey: preparation.url)
    }

    /// Re-keys the prepared model after a successful disk move; next acquire
    /// at `newURL` restores the same document and undo manager.
    func relocatePreparedDocument(from oldURL: URL, to newURL: URL) {
        let old = oldURL.standardizedFileURL
        let new = newURL.standardizedFileURL
        guard let prepared = preparedDocuments.removeValue(forKey: old) else { return }
        guard prepared.state == .prepared else {
            preparedDocuments[old] = prepared
            return
        }
        // Destination preflight guarantees this; if a caller violates the
        // contract, keep the existing prepared model rather than discarding
        // either identity.
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

    /// Re-keys closed identities after an adopted root moves. Root rename
    /// rejects live entries pre-disk, but session-cached models carry undo and
    /// must follow the folder; a stale cache entry parked under the
    /// destination loses to the just-moved source identity.
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
            // Destination root did not exist at preflight; any identity parked
            // under it is stale from an older tree.
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

    /// Drops parked identities after an ambiguous root outcome — a later open
    /// must load the repaired path, never revive a model keyed to one of the
    /// transaction's unsafe candidates.
    func discardFolderCaches(at rawRoots: [URL]) {
        let roots = rawRoots.map(\.standardizedFileURL)
        sessionCache.removeAll { cached in
            roots.contains { Self.isPath(cached.url, inside: $0) }
        }
        preparedDocuments = preparedDocuments.filter { url, _ in
            !roots.contains { Self.isPath(url, inside: $0) }
        }
    }

    /// Public re-check for one open file (window focus, tests). Always
    /// compares content when the file exists — callers who KNOW disk changed
    /// must not be blocked by mtime resolution quirks; the watch path keeps
    /// the mtime gate.
    @discardableResult
    func syncFromDiskIfNeeded(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL] else { return false }
        return syncFromDisk(entry, skipIfNotNewer: false)
    }

    /// Dismiss the banner for `url` without changing buffer or disk.
    func dismissExternalChange(_ url: URL) {
        ExternalChangeCenter.shared.dismiss(url)
        if let entry = entries[url.standardizedFileURL] {
            // Hides presentation only. The disk/local choice stays unresolved
            // until Disk, Mine, or a successful write; move preflight keeps
            // blocking meanwhile.
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

    /// Conflict or post-apply: buffer ← `content` from disk/notice. `content`
    /// just came from disk, so a failed re-persist loses nothing.
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

    /// Shared core of external reload + agent accept: swap buffer, write out.
    /// Throws only from the final disk write — buffer already swapped by then;
    /// callers decide what a failed write means.
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

    /// Applies an accepted agent edit (Claude's `openDiff`). Routing it here is
    /// the point: `flush` advances `knownModDate` and re-arms the watch so our
    /// own write is not mistaken for external — a plain `writeMarkdownDocument`
    /// would pop the conflict chip on the file the user just approved.
    /// Closed files are written directly (no buffer to reconcile), but existing
    /// `.textbundle` assets must survive the rewrite.
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
                // Live-entry contract: accepted buffer stays dirty/retryable;
                // the failed call never claims disk has the new bytes.
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
                // Disk still old, buffer already Claude's: surface as an
                // ordinary unsaved edit (autosave/⌘S retry) and rethrow so
                // accept() answers DIFF_REJECTED — FILE_SAVED must mean bytes
                // on disk.
                entry.isDirty = true
                entry.holdAutosaveUntilUserEdit = false
                throw error
            }
            return
        }
        let isNewFile = !FileManager.default.fileExists(atPath: key.path)
        let existingAssets = (try? loadMarkdownDocument(from: key))?.assets
        try writeMarkdownDocument(content: content, assets: existingAssets, to: key)
        LineChangeTracker.shared.noteBaseline(url: key, content: content)
        // Closed-file agent edit: same incremental index path as flush.
        LinkIndex.shared.noteDocumentPersisted(url: key, content: content)
        // New file must appear in the sidebar unprompted. Existing files must
        // NOT bump the epoch — that invalidates the whole link graph, and the
        // incremental path above already reindexed this file.
        if isNewFile {
            WorkspaceModel.shared.noteFilesystemChange()
        }
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

    /// Undo-driven/test edits can mutate the model before the SwiftUI owner
    /// delivers `markDirty` — a move boundary cannot trust that transient flag;
    /// compare buffer vs last observed disk baseline explicitly.
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
        // external apply / commit); remember payload + time so a racing FS echo
        // is not treated as an external reload and mtime compares stay correct.
        entry.lastSelfWriteContent = content
        entry.lastSelfWriteAt = Date()
        entry.knownModDate = contentModificationDate(of: entry.url)
        entry.knownDiskContent = content
        entry.knownDiskAssetsFingerprint = DocumentAssetsFingerprint(
            entry.document.assetsFileWrapper)
        clearPendingConflict(entry)
        // Atomic replace may invalidate the watched inode — re-arm.
        rearmWatch(entry)
        // A concurrent `git commit` (or hook) may have advanced HEAD; re-check
        // so dirty-line marks clear on real commits only.
        GitCommitWatcher.shared.check(url: entry.url)
        // Link index: incremental rescan of this file only.
        LinkIndex.shared.noteDocumentPersisted(url: entry.url, content: content)
        // Local revision history — background, debounced in store.
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

    /// FileWrapper is not Sendable; MarkdownDocument.Snapshot is an immutable,
    /// exclusively-owned transfer value by project contract.
    nonisolated private static func writeSnapshot(
        _ snapshot: MarkdownDocument.Snapshot,
        to url: URL
    ) throws {
        try writeMarkdownDocument(
            content: snapshot.content,
            assets: snapshot.assetsFileWrapper,
            to: url)
    }

    /// Atomic writes intentionally finish even if the UI task is cancelled:
    /// abandoning one midway leaves the move transaction unable to know
    /// whether disk holds old or new bytes.
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
            // Become-active: cheap mtime gate is enough (and necessary —
            // re-reading every open buffer would hitch).
            syncFromDisk(entry, skipIfNotNewer: true)
        }
    }

    /// True when clean content or assets were replaced from disk.
    /// - Parameter skipIfNotNewer: true (watch / become-active) skips the full
    ///   read unless mtime advanced — guards against FS event storms.
    @discardableResult
    private func syncFromDisk(_ entry: Entry, skipIfNotNewer: Bool = true) -> Bool {
        // Fast path: no newer mtime → no full read. Without it every FS event
        // re-read the whole file on main and could peg the UI.
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

    /// Mandatory transaction-boundary read: propagates an unreadable/missing
    /// path (watcher refresh does not) and never trusts an mtime copied from
    /// the source path before a relocation.
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
        // Own autosave/⌘S echo: mtime advanced, bytes are what we wrote —
        // never re-baseline session dirty marks for our own flush. Guard
        // window: an echo arrives within seconds; identical bytes long after
        // (git checkout back to the saved state) are a real external change.
        // Assets must match too — a .textbundle image swap with unchanged
        // text.md is external.
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
            // Disk is still the observed baseline: do not mistake a normal
            // unsaved buffer (or failed move write) for an external conflict
            // just because memory differs from disk, and do not auto-dismiss
            // an open notice on a follow-up FS echo.
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
            // Critical: cancel pending autosave — else the old buffer
            // overwrites the external file a moment later (and the chip
            // vanished when disk snapped back to mem).
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
                // Quiet toast + popover event line. Deliberately NOT a harness
                // status: the disk write is usually the agent's own edit, and
                // stamping idle here wiped its live active/blocked.
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

    /// On-disk mtime strictly newer than last sync — session-cache re-open
    /// must not wipe an unflushed buffer.
    private func diskIsNewerThanKnown(_ entry: Entry) -> Bool {
        guard let diskDate = contentModificationDate(of: entry.url) else { return true }
        guard let known = entry.knownModDate else { return true }
        return diskDate > known
    }

    nonisolated private static func isPath(_ rawURL: URL, inside rawRoot: URL) -> Bool {
        PathScope.contains(rawURL.standardizedFileURL.path,
                           under: rawRoot.standardizedFileURL.path)
    }

    private func startWatching(_ entry: Entry) {
        stopWatching(entry)
        // O_EVTONLY: event-only fd (no read), standard for path watches on Darwin.
        let fd = open(entry.url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        entry.fileDescriptor = fd
        // Omit `.attrib`: Spotlight/xattr noise fired continuous reloads.
        // Content changes arrive as write/extend; atomic replace as
        // rename/delete. Become-active still does a full mtime re-check.
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
        // Coalesce bursty events (atomic rewrite = delete+rename+write);
        // OR-accumulate flags so a write+rename pair is seen as one burst.
        entry.diskEventDebounce?.cancel()
        let prior = entry.pendingDiskFlags ?? []
        entry.pendingDiskFlags = prior.union(flags)
        entry.diskEventDebounce = Task { [weak self, weak entry] in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms
            guard !Task.isCancelled, let self, let entry,
                  self.entries[entry.url] != nil else { return }
            let burst = entry.pendingDiskFlags ?? []
            entry.pendingDiskFlags = nil
            // Re-arm only when the inode may be gone: rearming on every write
            // (close+open O_EVTONLY) generated more events → main-thread storm
            // at >100% CPU.
            let inodeMaybeReplaced = !burst.isDisjoint(with: [.rename, .delete, .revoke, .link])
            if inodeMaybeReplaced {
                self.rearmWatch(entry)
            }
            let applied = self.syncFromDisk(entry, skipIfNotNewer: true)
            // Atomic replace often shows up as write on a NEW inode without
            // rename flags — re-arm if we actually reloaded.
            if applied, !inodeMaybeReplaced {
                self.rearmWatch(entry)
            }
        }
    }
}
