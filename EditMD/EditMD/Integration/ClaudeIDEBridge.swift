import AppKit
import Foundation
import SwiftUI

// The main-actor side of the IDE channel (v36).
//
// `ClaudeIDEBridge` is the only place the editor talks to the integration:
// coordinators push selections in, `openFile` pushes a reveal request out.
// `LiveEditorContext` is the nonisolated adapter the tools call — it hops to
// the main actor for state and stays off it for disk work (v35.3 invariant).

extension Notification.Name {
    /// Posted when Claude's `openFile` wants a range revealed. Observed by the
    /// Source / Visual coordinators, which claim it via `takeReveal(for:)`.
    static let claudeIDERevealRequested = Notification.Name("editmd.claudeIDE.reveal")
}

/// A non-empty selection in markdown-source coordinates, used to anchor a new
/// review mark (phase 2). Value type so it crosses actor hops freely.
struct ReviewSelectionSource: Sendable {
    let url: URL
    /// Range in **markdown source** coordinates (Visual maps via the v22 map).
    let range: NSRange
    let markdown: String
}

@MainActor
final class ClaudeIDEBridge: ObservableObject {

    static let shared = ClaudeIDEBridge()

    /// A selection captured verbatim from an editor. Positions are derived on
    /// demand: `textViewDidChangeSelection` fires on every caret move, and
    /// mapping an offset to (line, character) is O(offset).
    private struct RawSelection: Equatable, Sendable {
        let url: URL
        /// Range in **markdown source** coordinates.
        let range: NSRange
        let markdown: String
    }

    /// Empty selections are dropped from notifications but still answer
    /// `getCurrentSelection` (the caret is where Claude is being asked about).
    @Published private(set) var hasSelection = false

    /// File shown in the main window — the "active editor" for phase 1.
    private(set) var activeURL: URL?

    private var raw: RawSelection?
    private var latestRaw: RawSelection?
    /// Once the debounce settles, the latest selection is kept materialized
    /// (positions + selected text) and `latestRaw` is dropped — its document
    /// string would otherwise pin a stale full-document copy after edits
    /// diverge the COW storage. Still used by `getLatestSelection`.
    private var latestMaterialized: IDESelection?
    /// Last non-empty selection kept for review-mark capture (v37). Clicking
    /// Review ▸ + moves first-responder out of the NSTextView; AppKit often
    /// collapses the selection to a caret *before* the button action runs, so
    /// `raw` is already empty. This snapshot survives that focus hop until the
    /// active file changes or a new non-empty selection replaces it.
    private var latestNonEmpty: RawSelection?
    private var selectionNotifyTask: Task<Void, Never>?

    private var pendingReveal: (url: URL, range: NSRange, requestedAt: Date)?

    /// A reveal that no editor claims (Preview mode, window closing) must not
    /// fire at some random later moment.
    private static let revealTTL: TimeInterval = 5

    /// Selections arrive per keystroke; the CLI wants an occasional update.
    private static let selectionDebounceNanos: UInt64 = 220_000_000

    // MARK: Active editor

    func setActiveURL(_ url: URL?) {
        activeURL = url?.standardizedFileURL
        if raw?.url != activeURL {
            raw = nil
            if hasSelection { hasSelection = false }
        }
        // Drop review/Claude caches that belong to another file.
        if latestNonEmpty?.url != activeURL {
            latestNonEmpty = nil
            latestRaw = nil
            latestMaterialized = nil
        }
    }

    // MARK: Selection

    /// Called from both editor coordinators. `markdownRange` is already in
    /// source coordinates (Visual maps through the v22 paragraph map).
    func noteSelection(url: URL?, markdownRange: NSRange, markdown: String) {
        guard let url else {
            raw = nil
            if hasSelection { hasSelection = false }
            return
        }
        let selection = RawSelection(url: url.standardizedFileURL,
                                     range: markdownRange,
                                     markdown: markdown)
        raw = selection
        let nonEmpty = markdownRange.length > 0
        if nonEmpty {
            latestRaw = selection
            latestNonEmpty = selection
        }
        if hasSelection != nonEmpty { hasSelection = nonEmpty }
        guard nonEmpty else { return }

        selectionNotifyTask?.cancel()
        selectionNotifyTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.selectionDebounceNanos)
            guard !Task.isCancelled else { return }
            // Off the main actor: materializing walks the document prefix.
            let materialized = await Task.detached { Self.materialize(selection) }.value
            guard !Task.isCancelled, let self else { return }
            if self.latestRaw == selection {
                self.latestMaterialized = materialized
                self.latestRaw = nil
            }
            ClaudeIDEService.shared.notifySelectionChanged(materialized)
        }
    }

    var currentSelection: IDESelection? { raw.map(Self.materialize) }
    var latestSelection: IDESelection? {
        latestRaw.map(Self.materialize) ?? latestMaterialized
    }

    /// Non-empty selection in source coordinates for creating a review mark
    /// (v37). Prefers the live selection; if the caret already collapsed
    /// (typical when the user clicked Review ▸ +), falls back to the last
    /// non-empty snapshot for the active file.
    func reviewSelectionSource() -> ReviewSelectionSource? {
        if let raw, raw.range.length > 0 {
            return ReviewSelectionSource(url: raw.url, range: raw.range,
                                         markdown: raw.markdown)
        }
        guard let snap = latestNonEmpty, snap.range.length > 0 else { return nil }
        // Don't attach a mark to file A using a leftover selection from file B.
        if let activeURL, snap.url != activeURL { return nil }
        return ReviewSelectionSource(url: snap.url, range: snap.range,
                                     markdown: snap.markdown)
    }

    private nonisolated static func materialize(_ selection: RawSelection) -> IDESelection {
        let nsText = selection.markdown as NSString
        let location = max(0, min(selection.range.location, nsText.length))
        let length = max(0, min(selection.range.length, nsText.length - location))
        let clamped = NSRange(location: location, length: length)
        return IDESelection(text: nsText.substring(with: clamped),
                            filePath: selection.url.path,
                            range: ideSelectionRange(for: clamped, in: selection.markdown))
    }

    // MARK: Reveal (openFile with startText / endText)

    func requestReveal(url: URL, range: NSRange) {
        pendingReveal = (url.standardizedFileURL, range, Date())
        NotificationCenter.default.post(name: .claudeIDERevealRequested, object: nil)
    }

    /// Consumes a pending reveal for `url`, if it is fresh and belongs to it.
    func takeReveal(for url: URL?) -> NSRange? {
        guard let url, let pending = pendingReveal else { return nil }
        guard pending.url == url.standardizedFileURL else { return nil }
        guard Date().timeIntervalSince(pending.requestedAt) < Self.revealTTL else {
            pendingReveal = nil
            return nil
        }
        pendingReveal = nil
        return pending.range
    }

    // MARK: openFile

    /// Routes the open through `AppState`, exactly like a sidebar click.
    func openFile(url: URL, revealRange: NSRange?, makeFrontmost: Bool) -> OpenFileOutcome {
        guard !AppState.isFolder(url) else {
            return OpenFileOutcome(success: false, message: "Not a file: \(url.path)")
        }
        AppState.shared.openInMainWindow(url)
        if let revealRange { requestReveal(url: url, range: revealRange) }
        if makeFrontmost { NSApp.activate(ignoringOtherApps: true) }
        return OpenFileOutcome(success: true, message: "Opened \(url.lastPathComponent) in EditMD")
    }

    // MARK: at_mentioned

    /// Edit ▸ Send to Claude. Uses the live selection, so it is only offered
    /// when there is one and a client is attached.
    func sendSelectionToClaude() {
        guard let selection = currentSelection else { return }
        ClaudeIDEService.shared.notifyAtMentioned(
            filePath: selection.filePath,
            lineStart: selection.range.start.line,
            lineEnd: selection.range.end.line)
    }
}

// MARK: - Reveal target resolution (pure, unit-tested)

/// Resolves `startText` / `endText` into a markdown range. `nil` when neither
/// is given or the anchor text is not in the file — Claude sometimes quotes a
/// fragment that has already been edited away, and guessing is worse than
/// leaving the caret alone.
func ideRevealRange(for request: OpenFileRequest, in content: String) -> NSRange? {
    guard let startText = request.startText, !startText.isEmpty else { return nil }
    let nsText = content as NSString
    let startRange = nsText.range(of: startText)
    guard startRange.location != NSNotFound else { return nil }

    var range = startRange
    if let endText = request.endText, !endText.isEmpty {
        let tail = NSRange(location: startRange.location,
                           length: nsText.length - startRange.location)
        let endRange = nsText.range(of: endText, options: [], range: tail)
        if endRange.location != NSNotFound {
            range = NSRange(location: startRange.location,
                            length: NSMaxRange(endRange) - startRange.location)
        }
    }
    if request.selectToEndOfLine {
        // `contentsEnd` is the line end without its terminator.
        var contentsEnd = 0
        nsText.getLineStart(nil, end: nil, contentsEnd: &contentsEnd,
                            for: NSRange(location: NSMaxRange(range), length: 0))
        range = NSRange(location: range.location,
                        length: max(0, contentsEnd - range.location))
    }
    return range
}

// MARK: - Live context (what the tools actually call)

/// Nonisolated adapter: main-actor hops for editor state, `Task.detached` for
/// disk. Kept as a struct so it is trivially `Sendable`.
struct LiveEditorContext: IDEEditorContext {

    func currentSelection() async -> IDESelection? {
        await ClaudeIDEBridge.shared.currentSelection
    }

    func latestSelection() async -> IDESelection? {
        await ClaudeIDEBridge.shared.latestSelection
    }

    func openEditors() async -> [IDEEditorTab] {
        await MainActor.run {
            let active = ClaudeIDEBridge.shared.activeURL
            return DocumentRegistry.shared.openURLs
                .map { url in
                    IDEEditorTab(path: url.path,
                                 isActive: url.standardizedFileURL == active,
                                 isDirty: DocumentRegistry.shared.isDirty(url))
                }
                .sorted { $0.path < $1.path }
        }
    }

    func workspaceFolders() async -> [IDEWorkspaceFolder] {
        await MainActor.run { claudeIDEWorkspaceFolders() }
    }

    func openFile(_ request: OpenFileRequest) async -> OpenFileOutcome {
        let url = URL(fileURLWithPath: request.filePath).standardizedFileURL
        var range: NSRange?
        if request.startText?.isEmpty == false {
            // Anchor text to resolve — we need the content anyway.
            guard let content = await documentContent(of: url) else {
                return OpenFileOutcome(success: false, message: "Cannot read \(request.filePath)")
            }
            range = ideRevealRange(for: request, in: content)
        } else {
            // No anchor: don't read the file just to prove it exists.
            let exists = await Task.detached {
                FileManager.default.fileExists(atPath: url.path)
            }.value
            guard exists else {
                return OpenFileOutcome(success: false, message: "No such file: \(request.filePath)")
            }
        }
        return await MainActor.run {
            ClaudeIDEBridge.shared.openFile(url: url,
                                            revealRange: range,
                                            makeFrontmost: request.makeFrontmost)
        }
    }

    func documentDirtyState(path: String) async -> IDEDirtyState? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return await MainActor.run {
            guard DocumentRegistry.shared.isOpen(url) else { return nil }
            return IDEDirtyState(isDirty: DocumentRegistry.shared.isDirty(url), isUntitled: false)
        }
    }

    func saveDocument(path: String) async -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return await MainActor.run {
            guard DocumentRegistry.shared.isOpen(url) else { return false }
            do {
                try DocumentRegistry.shared.saveNow(url)
                return true
            } catch {
                claudeIDELog.error("saveDocument failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
    }

    func diagnostics(uri: String?) async -> [IDEDiagnosticFile] {
        let url: URL?
        if let uri, !uri.isEmpty {
            url = URL(string: uri)?.isFileURL == true
                ? URL(string: uri)!.standardizedFileURL
                : URL(fileURLWithPath: uri).standardizedFileURL
        } else {
            url = await MainActor.run { ClaudeIDEBridge.shared.activeURL }
        }
        guard let url, let content = await documentContent(of: url) else { return [] }
        // 14 lint rules; ~1s on a 100K note — never on the main actor.
        let diagnostics = await Task.detached(priority: .userInitiated) {
            // One line-start pass for the whole list — per-finding
            // `ideSelectionRange` would rescan the prefix each time.
            let lineMap = IDELineMap(content)
            return lint(content).map { diagnostic in
                IDEDiagnostic(
                    message: diagnostic.message,
                    severity: diagnostic.severity == .error ? "Error" : "Warning",
                    source: "editmd-lint",
                    code: diagnostic.rule.rawValue,
                    range: lineMap.selectionRange(for: diagnostic.range))
            }
        }.value
        return [IDEDiagnosticFile(uri: url.absoluteString, diagnostics: diagnostics)]
    }

    func openDiff(_ request: OpenDiffRequest) async -> DiffOutcome {
        guard let path = request.targetPath else { return .rejected }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // One hop: the buffer and its dirty flag must come from the same instant.
        let (buffer, bufferIsDirty) = await MainActor.run {
            (DocumentRegistry.shared.contentIfOpen(url), DocumentRegistry.shared.isDirty(url))
        }
        let disk: String? = buffer != nil ? nil : await Task.detached(priority: .userInitiated) {
            (try? loadMarkdownDocument(from: url))?.content
        }.value

        let diff = DiffApprovalController.PendingDiff(
            tabName: request.tabName,
            targetURL: url,
            before: buffer ?? disk ?? "",
            after: request.newFileContents,
            bufferIsDirty: buffer != nil && bufferIsDirty,
            isNewFile: buffer == nil && disk == nil)
        return await DiffApprovalController.shared.present(diff)
    }

    func closeDiffTab(named tabName: String) async -> Bool {
        await DiffApprovalController.shared.closeTab(named: tabName)
    }

    func closeAllDiffTabs() async -> Int {
        await DiffApprovalController.shared.closeAllTabs()
    }

    // MARK: Helpers

    /// Open buffer first (that is what the user sees), disk otherwise.
    /// The disk read is detached: `.textbundle` walks a wrapper.
    private func documentContent(of url: URL) async -> String? {
        if let buffer = await MainActor.run(body: { DocumentRegistry.shared.contentIfOpen(url) }) {
            return buffer
        }
        return await Task.detached(priority: .userInitiated) {
            (try? loadMarkdownDocument(from: url))?.content
        }.value
    }
}

/// Roots advertised in the lock file and by `getWorkspaceFolders`.
///
/// Adopted workspace folders, or — when none are adopted — the directory of the
/// file in the main window. Without the fallback `/ide` cannot match the
/// terminal's cwd on a fresh install and silently finds no IDE.
@MainActor
func claudeIDEWorkspaceFolders() -> [IDEWorkspaceFolder] {
    let roots = WorkspaceModel.shared.workspaces.map { IDEWorkspaceFolder(path: $0.folderPath) }
    guard roots.isEmpty else { return roots }
    guard let active = ClaudeIDEBridge.shared.activeURL else { return [] }
    return [IDEWorkspaceFolder(path: active.deletingLastPathComponent().path)]
}
