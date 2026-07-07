import SwiftUI

struct FormatActions {
    var toggleBold: () -> Void
    var toggleItalic: () -> Void
    var makeFontBigger: () -> Void
    var makeFontSmaller: () -> Void
    var canIncreaseFontSize: Bool
    var canDecreaseFontSize: Bool
    /// Visual mode only: toggles task-list state of the selected paragraphs.
    var toggleChecklist: (() -> Void)? = nil
    /// Visual mode only: add/edit/remove a link on the selection (⌘K).
    var editLink: (() -> Void)? = nil
    // Format-menu block/inline commands (v25). Optional: a mode publishes
    // only what it implements, the menu item disables on nil.
    var toggleStrikethrough: (() -> Void)? = nil
    var toggleCodeSpan: (() -> Void)? = nil
    /// Sets heading level 1…6 on the selected paragraphs; the same level
    /// again turns them back into plain paragraphs.
    var setHeading: ((Int) -> Void)? = nil
    var toggleBulletList: (() -> Void)? = nil
    var toggleNumberedList: (() -> Void)? = nil
    var toggleQuote: (() -> Void)? = nil
    var toggleCodeBlock: (() -> Void)? = nil
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

extension FocusedValues {
    var formatActions: FormatActions? {
        get { self[FormatActionsKey.self] }
        set { self[FormatActionsKey.self] = newValue }
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
}
