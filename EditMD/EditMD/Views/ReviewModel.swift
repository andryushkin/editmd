import AppKit
import Foundation
import SwiftUI
import os

let reviewLog = Logger(subsystem: "andryushkin.EditMD", category: "review")

struct ReviewControlMarkWriteResult: Equatable, Sendable {
    let url: URL
    let markID: String
    let rev: Int
}

enum ReviewControlOperationError: LocalizedError, Equatable, Sendable {
    case pathUnavailable(URL)
    case writeFailed(String)
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .pathUnavailable(let url):
            return "path became unavailable during file operation: \(url.path)"
        case .writeFailed(let message):
            return "sidecar write failed: \(message)"
        case .modelUnavailable:
            return "review pipeline became unavailable"
        }
    }
}

/// Immutable disk snapshot returned to the socket thread. `ReviewDocument` is
/// a value tree of Codable scalars/collections and is never mutated after the
/// ticket resolves, which makes this cross-thread handoff safe.
struct ReviewControlMarksReadResult: Equatable, @unchecked Sendable {
    let url: URL
    let doc: ReviewDocument
}

/// One control-channel sidecar operation. The request is inserted into ReviewModel's
/// FIFO on MainActor before the socket follow-up receives this ticket. Waiting
/// is thread-safe and may only block a socket/test worker, never MainActor.
///
/// Safety invariant for `@unchecked Sendable`: mutable completion state is
/// accessed exclusively through `OSAllocatedUnfairLock`; `DispatchGroup`
/// provides a thread-safe one-shot completion event.
final class ReviewControlTicket<Success: Sendable>: @unchecked Sendable {
    typealias Outcome = Result<Success, ReviewControlOperationError>

    private let completion = DispatchGroup()
    private let state: OSAllocatedUnfairLock<Outcome?>

    fileprivate init() {
        state = OSAllocatedUnfairLock(initialState: nil)
        completion.enter()
    }

    fileprivate func resolve(_ outcome: Outcome) {
        let didResolve = state.withLock { state in
            guard state == nil else { return false }
            state = outcome
            return true
        }
        if didResolve { completion.leave() }
    }

    /// Returns nil on timeout. The queued operation is not cancelled and may still
    /// finish later, matching the control channel's existing bounded-wait rule.
    nonisolated func wait(timeout: DispatchTime) -> Outcome? {
        guard completion.wait(timeout: timeout) == .success else { return nil }
        return state.withLock { $0 }
    }
}

typealias ReviewControlMarkWriteTicket = ReviewControlTicket<ReviewControlMarkWriteResult>
typealias ReviewControlMarksReadTicket = ReviewControlTicket<ReviewControlMarksReadResult>

/// Drives the Review sidebar (phase 2, v37): loads the active file's
/// smotr-compatible sidecar, exposes its marks, and persists mutations through
/// the optimistic rev-guard. Marks belong to the main-window "active editor",
/// mirroring `ClaudeIDEBridge`.
///
/// Disk IO (load / rev-guard save) never runs on the main actor; only the
/// published state is touched here.
@MainActor
final class ReviewModel: ObservableObject {

    static let shared = ReviewModel()

    /// Which marks the sidebar shows.
    enum StatusFilter: String, CaseIterable {
        case open, all, closed
        var label: String {
            switch self {
            case .open: return String(localized: "Open")
            case .all: return String(localized: "All")
            case .closed: return String(localized: "Closed")
            }
        }
    }

    /// Opaque permit that keeps sidecar loads/saves parked while a caller
    /// mutates paths on disk. Callers must complete or cancel every permit.
    struct PathMutationToken: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    /// One exact file relocation performed by a batch move.
    struct FileRelocation: Equatable, Sendable {
        let source: URL
        let destination: URL

        init(from source: URL, to destination: URL) {
            self.source = source.standardizedFileURL
            self.destination = destination.standardizedFileURL
        }
    }

    @Published private(set) var fileURL: URL?
    @Published private(set) var doc = ReviewDocument() {
        didSet {
            // Discrete doc change (mutation / reload) → fresh anchors + washes.
            scheduleAnchorRecompute(debounce: false)
        }
    }
    /// Raw markdown of the active buffer — anchors resolve against it.
    /// Deliberately NOT @Published: it changes per keystroke, and publishing
    /// it re-rendered the whole sidebar on every key press (v35.3 spirit).
    private(set) var currentText = ""
    /// Resolved anchors (mark id → UTF-16 range in the raw markdown),
    /// recomputed off-main and debounced behind typing. One shared pass —
    /// Source wash, Preview wash and the sidebar cards all read this instead
    /// of each running their own O(text × marks) searches per keystroke.
    @Published private(set) var anchors: [String: NSRange] = [:]
    private var anchorTask: Task<Void, Never>?
    @Published var statusFilter: StatusFilter = .open
    /// nil = every type.
    @Published var typeFilter: ReviewMarkType?
    /// Last queue/agent status line shown under the Review header (cleared by UI).
    @Published var queueStatus: String?
    /// One-shot request from the Preview action strip to open the existing
    /// Review-sidebar compose form. Stored in the model so opening the sidebar
    /// and switching its tab cannot race the request.
    @Published private(set) var composeRequestID: UInt64 = 0
    private var consumedComposeRequestID: UInt64 = 0

    private var baseRev = 0
    /// Guards against a stale async load landing after a newer file switch.
    private var loadToken = 0
    /// FIFO pipeline for sidecar disk steps (saves and reloads): each step
    /// runs after the previous one completed and adopted its result. Kills
    /// the stale-base races of fire-and-forget saves — two rapid mutations
    /// used to overwrite each other and resurrect deleted marks.
    private var pipelineTask: Task<Void, Never>?
    private var pipelineGeneration: UInt64 = 0

    /// Path mutation is a two-phase barrier: install the barrier first, then
    /// drain every already-enqueued sidecar step. New reloads/persists are
    /// retained in FIFO order until the caller supplies the final path map.
    /// This closes the actor-reentrancy gap between `await`ing a flush and the
    /// actual disk rename/move.
    private var nextPathMutationID: UInt64 = 0
    private var pathMutationGateHeld = false
    private var activePathMutationIDs: Set<UInt64> = []
    private var deferredPipelineActions: [DeferredPipelineAction] = []
    private var pathMutationAcquisitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var pathMutationWaiters: [CheckedContinuation<Void, Never>] = []

    private enum DeferredPipelineAction {
        case reload(url: URL, token: Int, expected: ReviewDocument)
        case persist(url: URL, doc: ReviewDocument, baseRev: Int)
        case controlMark(url: URL, mark: ReviewMark,
                         ticket: ReviewControlMarkWriteTicket)
        case controlRead(url: URL, ticket: ReviewControlMarksReadTicket)
    }

    // MARK: Active file

    /// Fed by the main window on file switch and on buffer edits. A same-file
    /// text change keeps the marks (anchors recompute in the views); a new file
    /// reloads the sidecar off-main.
    func setActiveFile(_ url: URL?, text: String) {
        let textChanged = text != currentText
        currentText = text
        let std = url?.standardizedFileURL
        guard std != fileURL else {
            // Typing in the active file: re-anchor behind a debounce, never
            // on the keystroke itself.
            if textChanged { scheduleAnchorRecompute(debounce: true) }
            return
        }
        fileURL = std
        // Synchronous baseline reset: a mutation arriving before the async
        // reload lands (editmdctl `open` + `marks add` back to back) must
        // start from an empty doc — persisting the previous file's marks
        // into this file's sidecar would silently cross-pollute them.
        doc = ReviewDocument()
        baseRev = 0
        reload()
    }

    /// Re-reads the sidecar from disk (file switch, agent finished, manual
    /// refresh, app reactivated — someone else may have written it).
    func reload() {
        guard let url = fileURL else {
            doc = ReviewDocument(); baseRev = 0
            return
        }
        loadToken += 1
        let token = loadToken
        // Snapshot for the adoption guard: a mutation made while the load was
        // in flight must not be wiped by the (older) disk state.
        let expected = doc
        submit(.reload(url: url, token: token, expected: expected))
    }

    /// Awaits every sidecar disk step enqueued so far (saves and reloads).
    /// Control channel uses it to reply only after the write is durable.
    func flushPipeline() async {
        while true {
            if pathMutationGateHeld {
                await waitForPathMutations()
                continue
            }
            let generation = pipelineGeneration
            await pipelineTask?.value
            guard !pathMutationGateHeld,
                  generation == pipelineGeneration else { continue }
            return
        }
    }

    /// Installs a barrier before suspending, then drains the global FIFO. The
    /// returned permit keeps later sidecar work parked until the disk mutation
    /// is completed or cancelled.
    func beginPathMutation() async -> PathMutationToken {
        await acquirePathMutationGate()
        nextPathMutationID &+= 1
        let token = PathMutationToken(id: nextPathMutationID)
        activePathMutationIDs.insert(token.id)
        await pipelineTask?.value
        return token
    }

    /// Completes a batch of exact file moves and resumes deferred sidecar work
    /// against the relocated paths.
    func completePathMutation(
        _ token: PathMutationToken,
        relocatingFiles relocations: [FileRelocation],
        droppingFiles droppedFiles: [URL] = []
    ) {
        guard activePathMutationIDs.contains(token.id) else { return }
        let pathMap = Dictionary(
            relocations.map { ($0.source.standardizedFileURL, $0.destination.standardizedFileURL) },
            uniquingKeysWith: { _, latest in latest }
        )
        let dropped = Set(droppedFiles.map(\.standardizedFileURL))
        relocatePaths { url in
            let standardized = url.standardizedFileURL
            guard !dropped.contains(standardized) else { return nil }
            return pathMap[standardized] ?? standardized
        }
        releasePathMutation(token)
    }

    /// Completes a folder/root rename, preserving the relative path of the
    /// active review file and any sidecar work deferred behind the barrier.
    /// `droppedRoots` rejects concurrent actions aimed at an ambiguous sibling
    /// outcome in the same filesystem transaction.
    func completePathMutation(
        _ token: PathMutationToken,
        relocatingFolderFrom oldRoot: URL,
        to newRoot: URL,
        droppingFoldersAt droppedRoots: [URL] = []
    ) {
        guard activePathMutationIDs.contains(token.id) else { return }
        let old = oldRoot.standardizedFileURL
        let new = newRoot.standardizedFileURL
        let dropped = droppedRoots.map(\.standardizedFileURL)
        relocatePaths { url in
            guard !dropped.contains(where: { Self.isURL(url, inside: $0) }) else {
                return nil
            }
            return Self.relocatedURL(url, from: old, to: new) ?? url
        }
        releasePathMutation(token)
    }

    /// Releases a barrier after a failed/no-op disk mutation. Deferred work
    /// keeps its original paths.
    func cancelPathMutation(_ token: PathMutationToken) {
        guard activePathMutationIDs.contains(token.id) else { return }
        releasePathMutation(token)
    }

    /// Completes an ambiguous folder mutation for which neither old nor
    /// expected-new subtree is safe. Active state is cleared, ordinary deferred
    /// saves are discarded, and durable control tickets fail explicitly.
    func completePathMutation(
        _ token: PathMutationToken,
        droppingFoldersAt rawRoots: [URL]
    ) {
        guard activePathMutationIDs.contains(token.id) else { return }
        let roots = rawRoots.map(\.standardizedFileURL)
        relocatePaths { url in
            roots.contains(where: { Self.isURL(url, inside: $0) }) ? nil : url
        }
        releasePathMutation(token)
    }

    /// Enqueues a control-channel mark in the same global FIFO as UI persists
    /// and reloads. The returned ticket is safe to wait from the socket thread.
    /// Path mutations can relocate or reject this action before any disk write.
    func enqueueControlMarkWrite(
        _ mark: ReviewMark,
        for rawURL: URL
    ) -> ReviewControlMarkWriteTicket {
        let ticket = ReviewControlMarkWriteTicket()
        submit(.controlMark(
            url: rawURL.standardizedFileURL,
            mark: mark,
            ticket: ticket))
        return ticket
    }

    /// Enqueues a disk-truth read behind the same path barrier as saves. The
    /// ticket reports the transformed URL, or an explicit unavailable-path
    /// failure when a transaction drops that subtree.
    func enqueueControlMarksRead(
        for rawURL: URL
    ) -> ReviewControlMarksReadTicket {
        let ticket = ReviewControlMarksReadTicket()
        submit(.controlRead(
            url: rawURL.standardizedFileURL,
            ticket: ticket))
        return ticket
    }

    // MARK: Anchor cache

    /// Recomputes `anchors` for the current doc/text — off-main, debounced
    /// for keystroke-driven text changes, immediate for doc mutations.
    /// Observers repaint on `.reviewMarksDidChange`, posted after the pass.
    private func scheduleAnchorRecompute(debounce: Bool) {
        anchorTask?.cancel()
        guard !doc.marks.isEmpty else {
            // No marks: clear once; don't re-notify on every keystroke.
            if !anchors.isEmpty {
                anchors = [:]
                NotificationCenter.default.post(name: .reviewMarksDidChange, object: self)
            }
            return
        }
        let text = currentText
        let marks = doc.marks
        anchorTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled else { return }
            let resolved = await Self.resolveAnchors(marks: marks, text: text)
            guard let self, !Task.isCancelled else { return }
            self.anchors = resolved
            NotificationCenter.default.post(name: .reviewMarksDidChange, object: self)
        }
    }

    /// Test hook: waits for the in-flight anchor pass (if any).
    func awaitAnchorRecompute() async {
        await anchorTask?.value
    }

    /// All marks (open and closed) resolve, so the sidebar can jump to a
    /// resolved-but-still-anchored thread too.
    nonisolated private static func resolveAnchors(
        marks: [ReviewMark], text: String
    ) async -> [String: NSRange] {
        await Task.detached(priority: .userInitiated) {
            var out: [String: NSRange] = [:]
            for m in marks {
                guard let q = m.quote, !q.isEmpty else { continue }
                if let r = ReviewSidecar.anchorNSRange(for: m, in: text) {
                    out[m.id] = r
                }
            }
            return out
        }.value
    }

    /// Disk revision the model last reconciled with (control-channel replies).
    var lastKnownRev: Int { baseRev }

    /// Appends a step to the FIFO pipeline (runs on the main actor; steps do
    /// their disk IO via the off-main helpers).
    private func enqueue(_ step: @escaping @MainActor () async -> Void) {
        let previous = pipelineTask
        pipelineGeneration &+= 1
        pipelineTask = Task {
            await previous?.value
            await step()
        }
    }

    private func submit(_ action: DeferredPipelineAction) {
        guard !pathMutationGateHeld else {
            deferredPipelineActions.append(action)
            return
        }
        enqueue(action)
    }

    private func enqueue(_ action: DeferredPipelineAction) {
        switch action {
        case let .reload(url, token, expected):
            enqueue { [weak self] in
                guard let self else { return }
                let loaded = await Self.loadOffMain(url)
                guard token == self.loadToken, self.fileURL == url else { return }
                if self.doc == expected {
                    self.doc = loaded
                }
                // Disk rev is the truth either way; a divergent local doc
                // reconciles through the next save's rev-guard merge.
                self.baseRev = loaded.rev
            }
        case let .persist(url, enqueuedDoc, enqueuedBase):
            enqueue { [weak self] in
                guard let self else { return }
                let snapshot: ReviewDocument
                let base: Int
                if self.fileURL == url {
                    // Same file still active → snapshot NOW: the previous chained
                    // step has adopted, so the base is fresh — no stale-base merge,
                    // deletions hold, later mutations aren't overwritten.
                    snapshot = self.doc
                    base = self.baseRev
                } else {
                    // User switched away — save what the mutation produced; the
                    // rev-guard merge reconciles any drift.
                    snapshot = enqueuedDoc
                    base = enqueuedBase
                }
                do {
                    let written = try await Self.saveOffMain(snapshot, for: url, baseRev: base)
                    guard self.fileURL == url else { return }
                    // Don't clobber a mutation made while the write was in
                    // flight — the chained follow-up persist reconciles it.
                    if self.doc == snapshot {
                        self.doc = written
                    }
                    self.baseRev = written.rev
                } catch {
                    reviewLog.error("sidecar save failed: \(String(describing: error), privacy: .public)")
                }
            }
        case let .controlMark(url, mark, ticket):
            enqueue { [weak self] in
                guard let self else {
                    ticket.resolve(.failure(.modelUnavailable))
                    return
                }

                let wasActive = self.fileURL == url
                var snapshot: ReviewDocument
                let base: Int
                if wasActive {
                    snapshot = self.doc
                    snapshot.upsert(mark)
                    self.doc = snapshot
                    base = self.baseRev
                } else {
                    snapshot = await Self.loadOffMain(url)
                    base = snapshot.rev
                    snapshot.upsert(mark)
                }

                do {
                    let written = try await Self.saveOffMain(
                        snapshot, for: url, baseRev: base)
                    if wasActive, self.fileURL == url {
                        // A later UI mutation may already include this mark;
                        // never replace that newer document with our snapshot.
                        if self.doc == snapshot {
                            self.doc = written
                        }
                        self.baseRev = written.rev
                    }
                    ticket.resolve(.success(.init(
                        url: url,
                        markID: mark.id,
                        rev: written.rev)))
                } catch {
                    ticket.resolve(.failure(.writeFailed(
                        String(describing: error))))
                }
            }
        case let .controlRead(url, ticket):
            enqueue {
                let doc = await Self.loadOffMain(url)
                ticket.resolve(.success(.init(url: url, doc: doc)))
            }
        }
    }

    private func relocatePaths(_ transform: (URL) -> URL?) {
        if let fileURL {
            if let relocated = transform(fileURL) {
                self.fileURL = relocated.standardizedFileURL
            } else {
                loadToken += 1
                self.fileURL = nil
                currentText = ""
                doc = ReviewDocument()
                baseRev = 0
            }
        }
        deferredPipelineActions = deferredPipelineActions.compactMap { action in
            switch action {
            case let .reload(url, token, expected):
                guard let relocated = transform(url) else { return nil }
                return .reload(url: relocated.standardizedFileURL,
                               token: token,
                               expected: expected)
            case let .persist(url, doc, baseRev):
                guard let relocated = transform(url) else { return nil }
                return .persist(url: relocated.standardizedFileURL,
                                doc: doc, baseRev: baseRev)
            case let .controlMark(url, mark, ticket):
                guard let relocated = transform(url) else {
                    ticket.resolve(.failure(.pathUnavailable(
                        url.standardizedFileURL)))
                    return nil
                }
                return .controlMark(
                    url: relocated.standardizedFileURL,
                    mark: mark,
                    ticket: ticket)
            case let .controlRead(url, ticket):
                guard let relocated = transform(url) else {
                    ticket.resolve(.failure(.pathUnavailable(
                        url.standardizedFileURL)))
                    return nil
                }
                return .controlRead(
                    url: relocated.standardizedFileURL,
                    ticket: ticket)
            }
        }
    }

    private func releasePathMutation(_ token: PathMutationToken) {
        activePathMutationIDs.remove(token.id)
        guard activePathMutationIDs.isEmpty else { return }

        if !pathMutationAcquisitionWaiters.isEmpty {
            let next = pathMutationAcquisitionWaiters.removeFirst()
            next.resume()
            return
        }

        pathMutationGateHeld = false

        let actions = deferredPipelineActions
        deferredPipelineActions.removeAll(keepingCapacity: true)
        for action in actions {
            enqueue(action)
        }

        let waiters = pathMutationWaiters
        pathMutationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForPathMutations() async {
        guard pathMutationGateHeld else { return }
        await withCheckedContinuation { continuation in
            if !pathMutationGateHeld {
                continuation.resume()
            } else {
                pathMutationWaiters.append(continuation)
            }
        }
    }

    private func acquirePathMutationGate() async {
        guard pathMutationGateHeld else {
            pathMutationGateHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            pathMutationAcquisitionWaiters.append(continuation)
        }
    }

    nonisolated private static func relocatedURL(
        _ rawURL: URL,
        from rawOldRoot: URL,
        to rawNewRoot: URL
    ) -> URL? {
        let url = rawURL.standardizedFileURL
        let oldRoot = rawOldRoot.standardizedFileURL
        let newRoot = rawNewRoot.standardizedFileURL
        let path = url.path
        let rootPath = oldRoot.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        let suffix = String(path.dropFirst(rootPath.count))
        return URL(fileURLWithPath: newRoot.path + suffix).standardizedFileURL
    }

    nonisolated private static func isURL(_ rawURL: URL, inside rawRoot: URL) -> Bool {
        let url = rawURL.standardizedFileURL
        let root = rawRoot.standardizedFileURL
        return url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    nonisolated private static func loadOffMain(_ url: URL) async -> ReviewDocument {
        await Task.detached(priority: .userInitiated) {
            ReviewSidecar.loadOrEmpty(for: url)
        }.value
    }

    nonisolated private static func saveOffMain(
        _ doc: ReviewDocument, for url: URL, baseRev: Int
    ) async throws -> ReviewDocument {
        try await Task.detached(priority: .userInitiated) {
            try ReviewSidecar.save(doc, for: url, baseRev: baseRev)
        }.value
    }

    // MARK: Derived

    var visibleMarks: [ReviewMark] {
        doc.worklist.filter { m in
            switch statusFilter {
            case .open: if !m.isOpen { return false }
            case .closed: if m.isOpen { return false }
            case .all: break
            }
            if let t = typeFilter, m.type != t.rawValue { return false }
            return true
        }
    }

    var openCount: Int { doc.openCount }

    func requestCompose() {
        composeRequestID &+= 1
    }

    func consumeComposeRequest() -> Bool {
        guard consumedComposeRequestID != composeRequestID else { return false }
        consumedComposeRequestID = composeRequestID
        return true
    }

    /// An anchor snapshotted from the editor selection at the instant the
    /// compose form opens. Captured once — not re-read while the user types the
    /// note, so moving focus into the text field can't clear it.
    struct CapturedAnchor: Equatable {
        let quote: String
        let prefix: String
        let start: Int
    }

    /// Snapshots the editor selection for a new mark. Uses the live selection
    /// or the bridge's last non-empty snapshot (so clicking Review ▸ + after a
    /// Visual selection still works when AppKit collapses the caret on focus
    /// change). Called on "+", not during rendering.
    func captureSelectionAnchor() -> CapturedAnchor? {
        guard let fileURL,
              let sel = ClaudeIDEBridge.shared.reviewSelectionSource(),
              sel.url.standardizedFileURL == fileURL.standardizedFileURL,
              sel.range.length > 0,
              let r = Range(sel.range, in: sel.markdown) else { return nil }
        let a = ReviewSidecar.captureAnchor(in: sel.markdown, range: r)
        guard !a.quote.isEmpty else { return nil }
        return CapturedAnchor(quote: a.quote, prefix: a.prefix, start: a.start)
    }

    /// Resolved anchor range for `mark` (cache lookup — the shared pass in
    /// `scheduleAnchorRecompute` does the actual text search).
    func anchor(for mark: ReviewMark) -> NSRange? {
        anchors[mark.id]
    }

    /// Open marks whose quote still resolves in the live buffer — used by
    /// Source (UTF-16 ranges into the raw markdown) for temporary-attr wash.
    func openAnchorHighlights() -> [ReviewAnchorHighlight] {
        doc.marks.compactMap { m in
            guard m.isOpen, let range = anchors[m.id] else { return nil }
            return ReviewAnchorHighlight(id: m.id, range: range,
                                         type: m.markType, tooltip: m.washTooltip)
        }
    }

    /// Open marks for Visual's plain-text quote search (display has no markers).
    func openMarksForDisplaySearch() -> [ReviewMark] {
        doc.marks.filter { $0.isOpen && !($0.quote ?? "").isEmpty }
    }

    // MARK: Mutations

    /// Creates a mark from a previously captured anchor (snapshot taken when the
    /// compose form opened). Returns the new mark's id.
    @discardableResult
    func addMark(anchor: CapturedAnchor, type: ReviewMarkType, note: String) -> String {
        let mark = ReviewMark(type: type, quote: anchor.quote, prefix: anchor.prefix,
                              start: anchor.start, note: note)
        doc.upsert(mark)
        persist()
        return mark.id
    }

    func reply(to id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var m = doc[id] else { return }
        m.appendReply(role: "author", text: trimmed)
        doc[id] = m
        persist()
    }

    func setStatus(_ id: String, _ status: ReviewMarkStatus) {
        guard var m = doc[id] else { return }
        m.setStatus(status)
        doc[id] = m
        persist()
    }

    func deleteMark(_ id: String) {
        doc[id] = nil
        persist()
    }

    // MARK: Suggestions (Claude's track-changes edits)

    /// Applies a `suggest` mark — the async twin of `openDiff` Accept. The file
    /// is rewritten through `DocumentRegistry.applyAgentEdit` (the ONLY write
    /// path that keeps the v34 external-change invariant); the anchor is
    /// re-resolved against the live buffer, an honest `needs-rebase` when gone.
    func acceptSuggestion(_ id: String) {
        guard let url = fileURL, var m = doc[id], m.isSuggestion else { return }
        guard let newContent = ReviewSidecar.applySuggest(m, to: currentText) else {
            m.setStatus(.needsRebase)
            m.appendReply(role: "author", text: String(localized: "⚠ fragment not found in the current file"))
            doc[id] = m
            persist()
            return
        }
        do {
            try DocumentRegistry.shared.applyAgentEdit(url, content: newContent)
            m.setStatus(.resolved)
            m.applied = ReviewClock.nowMillis()
            m.appendReply(role: "author", text: String(localized: "✓ accepted and applied"))
            // A suggestion answering an author mark closes it too (smotr `for`).
            if let src = m.forMark, var origin = doc[src], origin.isOpen {
                origin.setStatus(.resolved)
                doc[src] = origin
            }
            doc[id] = m
            persist()
        } catch {
            reviewLog.error("acceptSuggestion write failed: \(String(describing: error), privacy: .public)")
        }
    }

    func rejectSuggestion(_ id: String) {
        guard var m = doc[id] else { return }
        m.setStatus(.wontfix)
        m.appendReply(role: "author", text: String(localized: "✕ declined"))
        doc[id] = m
        persist()
    }

    // MARK: Persistence (serialized off-main rev-guard)

    private func persist() {
        guard let url = fileURL else { return }
        // Fallback snapshot for the file-switched case; the live path
        // re-reads state at execution time (see below).
        let enqueuedDoc = doc
        let enqueuedBase = baseRev
        submit(.persist(url: url, doc: enqueuedDoc, baseRev: enqueuedBase))
    }

    // MARK: Queue ➤ (step E)

    /// Workspace root that should own `.smotr-queue.json` for the active file:
    /// the longest-prefix workspace folder, else the file's parent directory.
    func queueRoot(workspace: WorkspaceModel) -> URL? {
        if let url = fileURL, let ws = workspace.workspaceOwning(url) {
            return URL(fileURLWithPath: ws.folderPath, isDirectory: true)
        }
        // A file outside every workspace queues in its own folder — an open
        // but unrelated workspace must not swallow its marks.
        if let url = fileURL {
            return url.deletingLastPathComponent()
        }
        if let first = workspace.workspaces.first {
            return URL(fileURLWithPath: first.folderPath, isDirectory: true)
        }
        return nil
    }

    /// Builds `.smotr-queue.json` under the workspace root. With the opt-in
    /// auto-spawn setting, starts headless Claude; otherwise copies the
    /// terminal command to the pasteboard and surfaces it in `queueStatus`.
    func sendQueue(workspace: WorkspaceModel) {
        guard let root = queueRoot(workspace: workspace) else {
            queueStatus = String(localized: "No workspace — open a folder (File ▸ Open Folder)")
            return
        }
        let autoSpawn = EditorSettings.shared.general.claudeReviewAutoSpawn
        queueStatus = String(localized: "Building the queue…")
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ReviewQueue.writeQueue(in: root)
                await MainActor.run {
                    if result.count == 0 {
                        self.queueStatus = String(localized: "No open marks — the queue is empty")
                        return
                    }
                    if autoSpawn {
                        if ReviewAgentRunner.shared.isRunning {
                            self.queueStatus = String(localized: "Queue \(result.count) · the agent is already running")
                        } else {
                            self.queueStatus = String(localized: "Queue \(result.count) · launching Claude…")
                            ReviewAgentRunner.shared.start(in: root)
                        }
                    } else {
                        let g = EditorSettings.shared.general
                        let cmd = ReviewQueue.manualCommand(
                            for: root,
                            preset: g.agentCommandPreset,
                            custom: g.agentCustomCommand)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        self.queueStatus =
                            String(localized: "Queue \(result.count) → \(ReviewQueue.fileName). Command copied to clipboard:\n\(cmd)")
                    }
                }
            } catch {
                await MainActor.run {
                    self.queueStatus = String(localized: "Queue error: \(error.localizedDescription)")
                    reviewLog.error("queue write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
