import AppKit
import Foundation
import SwiftUI
import os

let reviewLog = Logger(subsystem: "com.editmd.app", category: "review")

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
            case .open: return "Открытые"
            case .all: return "Все"
            case .closed: return "Закрытые"
            }
        }
    }

    @Published private(set) var fileURL: URL?
    @Published private(set) var doc = ReviewDocument() {
        didSet {
            // AppKit coordinators (Source/Visual) repaint anchors from this.
            NotificationCenter.default.post(name: .reviewMarksDidChange, object: self)
        }
    }
    /// Raw markdown of the active buffer — anchors resolve against it.
    @Published private(set) var currentText = "" {
        didSet {
            // Text moved under existing marks — re-resolve wash ranges.
            if oldValue != currentText {
                NotificationCenter.default.post(name: .reviewMarksDidChange, object: self)
            }
        }
    }
    @Published var statusFilter: StatusFilter = .open
    /// nil = every type.
    @Published var typeFilter: ReviewMarkType?
    /// Last queue/agent status line shown under the Review header (cleared by UI).
    @Published var queueStatus: String?

    private var baseRev = 0
    /// Guards against a stale async load landing after a newer file switch.
    private var loadToken = 0

    // MARK: Active file

    /// Fed by the main window on file switch and on buffer edits. A same-file
    /// text change keeps the marks (anchors recompute in the views); a new file
    /// reloads the sidecar off-main.
    func setActiveFile(_ url: URL?, text: String) {
        currentText = text
        let std = url?.standardizedFileURL
        guard std != fileURL else { return }
        fileURL = std
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
        Task.detached(priority: .userInitiated) {
            let loaded = ReviewSidecar.loadOrEmpty(for: url)
            await MainActor.run {
                guard token == self.loadToken else { return }   // superseded
                self.doc = loaded
                self.baseRev = loaded.rev
            }
        }
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

    /// Resolved anchor ranges for the active buffer (for highlighting / jump).
    /// Only marks whose fragment still exists appear.
    func anchor(for mark: ReviewMark) -> NSRange? {
        ReviewSidecar.anchorNSRange(for: mark, in: currentText)
    }

    /// Open marks whose quote still resolves in the live buffer — used by
    /// Source (UTF-16 ranges into the raw markdown) for temporary-attr wash.
    func openAnchorHighlights() -> [ReviewAnchorHighlight] {
        doc.marks.compactMap { m in
            guard m.isOpen, let range = ReviewSidecar.anchorNSRange(for: m, in: currentText)
            else { return nil }
            let tip: String
            if m.isSuggestion, let repl = m.replacement {
                tip = "suggest: \(repl)"
            } else if let note = m.note, !note.isEmpty {
                tip = "\(m.markType?.label ?? m.type): \(note)"
            } else {
                tip = m.markType?.label ?? m.type
            }
            return ReviewAnchorHighlight(id: m.id, range: range, type: m.markType, tooltip: tip)
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
            m.appendReply(role: "author", text: "⚠ фрагмент не найден в актуальном файле")
            doc[id] = m
            persist()
            return
        }
        do {
            try DocumentRegistry.shared.applyAgentEdit(url, content: newContent)
            m.setStatus(.resolved)
            m.applied = ReviewClock.nowMillis()
            m.appendReply(role: "author", text: "✓ принято и применено")
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
        m.appendReply(role: "author", text: "✕ отклонено")
        doc[id] = m
        persist()
    }

    // MARK: Persistence (off-main rev-guard)

    private func persist() {
        guard let url = fileURL else { return }
        let snapshot = doc
        let base = baseRev
        Task.detached(priority: .userInitiated) {
            do {
                let written = try ReviewSidecar.save(snapshot, for: url, baseRev: base)
                await MainActor.run {
                    // Adopt the reconciled result unless the user switched files.
                    guard self.fileURL == url else { return }
                    self.doc = written
                    self.baseRev = written.rev
                }
            } catch {
                reviewLog.error("sidecar save failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Queue ➤ (step E)

    /// Workspace root that should own `.smotr-queue.json` for the active file:
    /// the longest-prefix workspace folder, else the file's parent directory.
    func queueRoot(workspace: WorkspaceModel) -> URL? {
        if let url = fileURL, let ws = workspace.workspaceOwning(url) {
            return URL(fileURLWithPath: ws.folderPath, isDirectory: true)
        }
        if let first = workspace.workspaces.first {
            return URL(fileURLWithPath: first.folderPath, isDirectory: true)
        }
        if let url = fileURL {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// Builds `.smotr-queue.json` under the workspace root. With the opt-in
    /// auto-spawn setting, starts headless Claude; otherwise copies the
    /// terminal command to the pasteboard and surfaces it in `queueStatus`.
    func sendQueue(workspace: WorkspaceModel) {
        guard let root = queueRoot(workspace: workspace) else {
            queueStatus = "Нет workspace — открой папку (File ▸ Open Folder)"
            return
        }
        let autoSpawn = EditorSettings.shared.general.claudeReviewAutoSpawn
        queueStatus = "Собираю очередь…"
        Task.detached(priority: .userInitiated) {
            do {
                let result = try ReviewQueue.writeQueue(in: root)
                await MainActor.run {
                    if result.count == 0 {
                        self.queueStatus = "Открытых меток нет — очередь пуста"
                        return
                    }
                    if autoSpawn {
                        if ReviewAgentRunner.shared.isRunning {
                            self.queueStatus = "Очередь \(result.count) · агент уже работает"
                        } else {
                            self.queueStatus = "Очередь \(result.count) · запускаю Claude…"
                            ReviewAgentRunner.shared.start(in: root)
                        }
                    } else {
                        let cmd = ReviewQueue.manualCommand(for: root)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(cmd, forType: .string)
                        self.queueStatus =
                            "Очередь \(result.count) → \(ReviewQueue.fileName). Команда в буфере:\n\(cmd)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.queueStatus = "Ошибка очереди: \(error.localizedDescription)"
                    reviewLog.error("queue write failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}
