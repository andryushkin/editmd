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
    // Large prose (Claude.md ~108K) still pegs Source lint (~0.8s) and
    // per-keystroke highlight; treat as heavy so Source stays plain+fast.
    if length > 100_000 { return true }
    if length < 40_000 { return false }   // comfortably small
    // In between: heavy when table-dominated (the NSTextTable trap) or when
    // line count is high enough that lint/gutter work hitches open.
    var rows = 0
    var lines = 1
    var atLineStart = true
    for ch in content {
        if ch == "\n" {
            lines += 1
            if lines > 2_000 { return true }
            atLineStart = true
            continue
        }
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

/// Main-actor undo stack + typing-coalesce state for one document.
/// Held behind `@unchecked Sendable` so `MarkdownDocument` (nonisolated
/// `ReferenceFileDocument` inits) can own it without storing a MainActor
/// `UndoManager` as a stored property of a nonisolated class.
@MainActor
final class DocumentUndoController {
    let manager: UndoManager
    /// Content at the start of a coalesced typing session.
    var editBaseline: String?
    private var endEditTask: Task<Void, Never>?

    init() {
        let um = UndoManager()
        um.levelsOfUndo = 50
        manager = um
    }

    var isPerformingUndoRedo: Bool {
        manager.isUndoing || manager.isRedoing
    }

    func cancelTypingSession() {
        endEditTask?.cancel()
        endEditTask = nil
        editBaseline = nil
    }

    func scheduleCommit(on document: MarkdownDocument) {
        endEditTask?.cancel()
        endEditTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            document.commitContentEdit(actionName: "Typing")
        }
    }

    func cancelScheduledCommit() {
        endEditTask?.cancel()
        endEditTask = nil
    }
}

/// Box so the document can hold MainActor undo state from a nonisolated init.
private final class DocumentUndoBox: @unchecked Sendable {
    /// Lazily created on first MainActor use.
    @MainActor var controller: DocumentUndoController?
}

final class MarkdownDocument: ReferenceFileDocument {

    // nonisolated(unsafe) because ReferenceFileDocument protocol methods are nonisolated.
    // didSet publishes every distinct assignment immediately. AppKit editor
    // delegates must assign only after their NSTextView mutation has landed; an
    // earlier publish can look like an external edit and reload the text view.
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

    private let undoBox = DocumentUndoBox()

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
    }

    init(configuration: ReadConfiguration) throws {
        let (text, assets) = try parseMarkdownWrapper(
            configuration.file,
            isTextBundle: configuration.contentType == .textBundle)
        content = text
        assetsFileWrapper = assets
        isHeavy = markdownIsHeavy(text)
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

    // MARK: - Document undo (cross-mode, MainActor)

    /// Document-scoped undo stack. Targets `content` string swaps, not an
    /// NSTextView — so ⌘Z survives Source ↔ Visual ↔ Preview and file switches.
    @MainActor
    var contentUndoManager: UndoManager {
        undoController.manager
    }

    @MainActor
    private var undoController: DocumentUndoController {
        if let existing = undoBox.controller { return existing }
        let created = DocumentUndoController()
        undoBox.controller = created
        return created
    }

    @MainActor
    var isPerformingUndoRedo: Bool {
        undoController.isPerformingUndoRedo
    }

    /// Call from `shouldChangeTextIn` before the buffer mutates. Captures a
    /// baseline once per typing burst; commits after idle (see `noteContentEdited`).
    @MainActor
    func beginContentEdit() {
        let undo = undoController
        guard !undo.isPerformingUndoRedo else { return }
        if undo.editBaseline == nil {
            undo.editBaseline = content
        }
        undo.scheduleCommit(on: self)
    }

    /// Call after `content` was updated by typing. Resets the idle commit timer.
    /// Does not capture a baseline (that must happen in `beginContentEdit` before
    /// the mutation — otherwise the "old" value is already lost).
    @MainActor
    func noteContentEdited() {
        let undo = undoController
        guard !undo.isPerformingUndoRedo else { return }
        guard undo.editBaseline != nil else { return }
        undo.scheduleCommit(on: self)
    }

    /// Flush a pending typing burst into the undo stack (mode switch, save,
    /// toolbar action, coordinator teardown).
    @MainActor
    func commitContentEdit(actionName: String = "Typing") {
        let undo = undoController
        undo.cancelScheduledCommit()
        guard let baseline = undo.editBaseline else { return }
        undo.editBaseline = nil
        guard baseline != content else { return }
        // Content is already at the new value — register restore only.
        let um = undo.manager
        // When `groupsByEvent` is false (tests / programmatic stacks), registerUndo
        // requires an open group — otherwise NSUndoManager traps (same guard as
        // `applyUndoableContent`).
        let needsGroup = !um.groupsByEvent && !um.isUndoing && !um.isRedoing
        if needsGroup { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.applyUndoableContent(baseline, actionName: actionName)
            }
        }
        um.setActionName(actionName)
        if needsGroup { um.endUndoGrouping() }
    }

    /// Edit ▸ Undo — flush coalesced typing first so the last keystrokes aren't lost.
    @MainActor
    func performUndo() {
        commitContentEdit()
        let um = contentUndoManager
        guard um.canUndo else { return }
        um.undo()
    }

    /// Edit ▸ Redo.
    @MainActor
    func performRedo() {
        let um = contentUndoManager
        guard um.canRedo else { return }
        um.redo()
    }

    /// Sets `content` and registers the inverse so ⌘Z / ⌘⇧Z restore the previous
    /// string. Used by Preview toolbar / checkboxes and by undo handlers themselves
    /// (re-entry registers Redo).
    @MainActor
    func applyUndoableContent(_ newContent: String, actionName: String = "") {
        let undo = undoController
        undo.cancelTypingSession()

        let previous = content
        guard previous != newContent else { return }
        content = newContent
        let um = undo.manager
        // When `groupsByEvent` is false (tests / programmatic stacks), registerUndo
        // requires an open group — otherwise NSUndoManager traps.
        let needsGroup = !um.groupsByEvent && !um.isUndoing && !um.isRedoing
        if needsGroup { um.beginUndoGrouping() }
        um.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.applyUndoableContent(previous, actionName: actionName)
            }
        }
        if !actionName.isEmpty {
            um.setActionName(actionName)
        }
        if needsGroup { um.endUndoGrouping() }
    }
}
