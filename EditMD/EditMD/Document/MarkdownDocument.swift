import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdown = UTType("net.daringfireball.markdown")!
    static let textBundle = UTType("org.textbundle.package")!
}

/// True when a document is large or table-heavy enough that the Visual mode's
/// NSTextTable layout would peg the CPU (a 9000-cell table hangs indefinitely),
/// or the per-keystroke work would lag. Such documents open in plain Source
/// (no syntax highlighting, no lint) instead. Cheap single pass with early-out.
///
/// The trigger is deliberately table-aware, not size-only: a large prose note
/// lays out fine in Visual, whereas even a modest document that is mostly one
/// GFM table does not (the layout cost is super-linear in cell count).
func markdownIsHeavy(_ content: String) -> Bool {
    let length = content.utf16.count
    if length > 200_000 { return true }   // extreme size — plain regardless
    if length < 40_000 { return false }   // comfortably small
    // In between: heavy only when table-dominated (the NSTextTable trap).
    var rows = 0
    var atLineStart = true
    for ch in content {
        if ch == "\n" { atLineStart = true; continue }
        guard atLineStart else { continue }
        if ch == " " || ch == "\t" { continue }   // skip leading indent
        atLineStart = false
        if ch == "|" {
            rows += 1
            if rows > 300 { return true }
        }
    }
    return false
}

final class MarkdownDocument: ReferenceFileDocument {

    // nonisolated(unsafe) because ReferenceFileDocument protocol methods are nonisolated.
    // didSet publishes the change so SwiftUI-only readers (the outline sidebar,
    // the split's live preview, the Preview status bar) refresh on every edit —
    // editors write from the main thread, and init assignments skip didSet.
    nonisolated(unsafe) var content: String {
        didSet {
            guard content != oldValue else { return }
            isHeavy = markdownIsHeavy(content)
            objectWillChange.send()
        }
    }
    nonisolated(unsafe) var assetsFileWrapper: FileWrapper?

    /// Large/table-heavy documents skip the per-keystroke syntax highlighting
    /// and lint in Source (they would freeze on a 300K single-table file). See
    /// `markdownIsHeavy`. Recomputed cheaply whenever `content` changes.
    nonisolated(unsafe) private(set) var isHeavy = false

    /// Document-scoped undo stack. Targets `content` string swaps, not an
    /// NSTextView — so ⌘Z survives Source ↔ Visual ↔ Preview mode switches
    /// (view-local text undos die with the text view).
    /// `nonisolated(unsafe)`: UndoManager is MainActor in recent SDKs, but this
    /// document is mutated from AppKit callbacks that already run on main.
    nonisolated(unsafe) let contentUndoManager: UndoManager

    /// Content at the start of a coalesced typing session (`beginContentEdit`).
    private var editBaseline: String?
    private var endEditTask: Task<Void, Never>?

    struct Snapshot: @unchecked Sendable {
        let content: String
        let assetsFileWrapper: FileWrapper?
    }

    static var readableContentTypes: [UTType] { [.markdown, .textBundle] }
    static var writableContentTypes: [UTType] { [.markdown, .textBundle] }

    // MARK: - Init

    init() {
        content = ""
        assetsFileWrapper = nil
        let um = UndoManager()
        um.levelsOfUndo = 50
        contentUndoManager = um
    }

    init(configuration: ReadConfiguration) throws {
        let (text, assets) = try parseMarkdownWrapper(
            configuration.file,
            isTextBundle: configuration.contentType == .textBundle)
        content = text
        assetsFileWrapper = assets
        isHeavy = markdownIsHeavy(text)
        let um = UndoManager()
        um.levelsOfUndo = 50
        contentUndoManager = um
    }

    // MARK: - Snapshot & Write

    func snapshot(contentType: UTType) throws -> Snapshot {
        Snapshot(content: content, assetsFileWrapper: assetsFileWrapper)
    }

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        makeMarkdownWrapper(content: snapshot.content,
                            assets: snapshot.assetsFileWrapper,
                            isTextBundle: configuration.contentType == .textBundle)
    }

    // MARK: - Document undo (cross-mode)

    var isPerformingUndoRedo: Bool {
        contentUndoManager.isUndoing || contentUndoManager.isRedoing
    }

    /// Call from `shouldChangeTextIn` before the buffer mutates. Captures a
    /// baseline once per typing burst; commits after idle (see `noteContentEdited`).
    func beginContentEdit() {
        guard !isPerformingUndoRedo else { return }
        if editBaseline == nil {
            editBaseline = content
        }
        scheduleEndContentEdit()
    }

    /// Call after `content` was updated by typing. Resets the idle commit timer.
    /// Does not capture a baseline (that must happen in `beginContentEdit` before
    /// the mutation — otherwise the "old" value is already lost).
    func noteContentEdited() {
        guard !isPerformingUndoRedo else { return }
        guard editBaseline != nil else { return }
        scheduleEndContentEdit()
    }

    /// Flush a pending typing burst into the undo stack (mode switch, save,
    /// toolbar action, coordinator teardown).
    func commitContentEdit(actionName: String = "Typing") {
        endEditTask?.cancel()
        endEditTask = nil
        guard let baseline = editBaseline else { return }
        editBaseline = nil
        guard baseline != content else { return }
        // Content is already at the new value — register restore only.
        let um = contentUndoManager
        um.registerUndo(withTarget: self) { document in
            document.applyUndoableContent(baseline, actionName: actionName)
        }
        um.setActionName(actionName)
    }

    /// Edit ▸ Undo — flush coalesced typing first so the last keystrokes aren't lost.
    func performUndo() {
        commitContentEdit()
        guard contentUndoManager.canUndo else { return }
        contentUndoManager.undo()
    }

    /// Edit ▸ Redo.
    func performRedo() {
        guard contentUndoManager.canRedo else { return }
        contentUndoManager.redo()
    }

    /// Sets `content` and registers the inverse so ⌘Z / ⌘⇧Z restore the previous
    /// string. Used by Preview toolbar / checkboxes and by undo handlers themselves
    /// (re-entry registers Redo).
    func applyUndoableContent(_ newContent: String, actionName: String = "") {
        endEditTask?.cancel()
        endEditTask = nil
        editBaseline = nil

        let previous = content
        guard previous != newContent else { return }
        content = newContent
        let um = contentUndoManager
        um.registerUndo(withTarget: self) { document in
            document.applyUndoableContent(previous, actionName: actionName)
        }
        if !actionName.isEmpty {
            um.setActionName(actionName)
        }
    }

    private func scheduleEndContentEdit() {
        endEditTask?.cancel()
        endEditTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self.commitContentEdit(actionName: "Typing")
        }
    }
}
