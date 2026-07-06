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
}

struct FormatActionsKey: FocusedValueKey {
    typealias Value = FormatActions
}

struct EditorModeKey: FocusedValueKey {
    typealias Value = Binding<EditorMode>
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
}
