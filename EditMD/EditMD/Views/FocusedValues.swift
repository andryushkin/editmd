import SwiftUI

struct FormatActions {
    var toggleBold: () -> Void
    var toggleItalic: () -> Void
    var makeFontBigger: () -> Void
    var makeFontSmaller: () -> Void
    var canIncreaseFontSize: Bool
    var canDecreaseFontSize: Bool
    /// Toggles task-list on the selected paragraphs / lines.
    var toggleChecklist: (() -> Void)? = nil
    /// Visual mode only: add/edit/remove a link on the selection (⌘K).
    var editLink: (() -> Void)? = nil
    // Format-menu block/inline commands (v25). Optional: a mode publishes
    // only what it implements, the menu item disables on nil.
    var toggleStrikethrough: (() -> Void)? = nil
    var toggleCodeSpan: (() -> Void)? = nil
    /// `==…==` highlight (Obsidian-style).
    var toggleHighlight: (() -> Void)? = nil
    /// Sets heading level 1…6 on the selected paragraphs; the same level
    /// again turns them back into plain paragraphs.
    var setHeading: ((Int) -> Void)? = nil
    /// Plain body paragraph (strip heading / list / quote structure).
    var setBody: (() -> Void)? = nil
    var toggleBulletList: (() -> Void)? = nil
    var toggleNumberedList: (() -> Void)? = nil
    var toggleQuote: (() -> Void)? = nil
    var toggleCodeBlock: (() -> Void)? = nil
    var copySelection: (() -> Void)? = nil
    // Visual table tools (nil in Source / Preview)
    var insertTable: (() -> Void)? = nil
    var tableAddRow: (() -> Void)? = nil
    var tableDeleteRow: (() -> Void)? = nil
    /// Placeholder for future math/formula editing (Visual).
    var formulaStub: (() -> Void)? = nil
}

/// Save/Save As for the focused window's document. Published by ContentView so
/// the manual File menu (which replaced DocumentGroup's built-in one) can act on
/// whichever window is key.
struct DocumentActions {
    var save: () -> Void
    var saveAs: () -> Void
    /// false = untitled (Save falls back to a save panel).
    var hasURL: Bool
}

struct DocumentActionsKey: FocusedValueKey {
    typealias Value = DocumentActions
}

struct FormatActionsKey: FocusedValueKey {
    typealias Value = FormatActions
}

struct EditorModeKey: FocusedValueKey {
    typealias Value = Binding<EditorMode>
}

struct SidebarVisibleKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct SplitPreviewKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

struct DocumentUndoActionsKey: FocusedValueKey {
    typealias Value = DocumentUndoActions
}

/// Edit ▸ Undo / Redo for the focused document (document-scoped stack).
struct DocumentUndoActions {
    var undo: () -> Void
    var redo: () -> Void
}

extension FocusedValues {
    var formatActions: FormatActions? {
        get { self[FormatActionsKey.self] }
        set { self[FormatActionsKey.self] = newValue }
    }

    /// Save/Save As for the key window's document (manual File menu).
    var documentActions: DocumentActions? {
        get { self[DocumentActionsKey.self] }
        set { self[DocumentActionsKey.self] = newValue }
    }

    var editorMode: Binding<EditorMode>? {
        get { self[EditorModeKey.self] }
        set { self[EditorModeKey.self] = newValue }
    }

    /// Outline sidebar show/hide — the View menu (⌃⌘S) and the toolbar
    /// button share this binding.
    var sidebarVisible: Binding<Bool>? {
        get { self[SidebarVisibleKey.self] }
        set { self[SidebarVisibleKey.self] = newValue }
    }

    /// Editor+preview split — the View menu (⌥⌘P) and the toolbar button
    /// share this binding (ContentView hands in `splitBinding`, whose setter
    /// also leaves Preview mode when the split turns on).
    var splitPreview: Binding<Bool>? {
        get { self[SplitPreviewKey.self] }
        set { self[SplitPreviewKey.self] = newValue }
    }

    /// Document-scoped undo (survives mode switches). Edit ▸ Undo/Redo + ⌘Z.
    var documentUndoActions: DocumentUndoActions? {
        get { self[DocumentUndoActionsKey.self] }
        set { self[DocumentUndoActionsKey.self] = newValue }
    }
}
