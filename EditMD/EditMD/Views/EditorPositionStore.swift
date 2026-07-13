import Foundation

/// Cursor/scroll continuity across mode switches. The canonical coordinate is
/// a UTF-16 offset into the *markdown* text (document.content): Source uses it
/// directly, Visual maps through the serializer's paragraph map, Preview
/// scrolls to the proportional position. A class so cursor moves don't
/// trigger SwiftUI invalidation.
@MainActor
final class EditorPositionStore {
    var markdownOffset: Int = 0

    /// Outline-sidebar navigation: store the target offset, then poke the
    /// live editor(s). Mutating this class doesn't invalidate SwiftUI (by
    /// design), so the poke is a notification the editor coordinators
    /// observe OBJECT-SCOPED to this store — one store per window, so a
    /// jump never crosses windows (the agterm object-scoping pattern).
    func requestJump(toMarkdownOffset offset: Int) {
        markdownOffset = offset
        NotificationCenter.default.post(name: .editMDJumpToOffset, object: self)
    }

    /// D5: transport for the split-mode scroll follow. Deliberately NOT
    /// `markdownOffset` — that field is the caret restored on mode switches,
    /// and a passive scroll must never move the caret.
    ///
    /// A FRACTIONAL markdown offset: whole part = character, fraction = how far
    /// between it and the next. Syncing whole characters (or whole lines) can
    /// only ever step, since a position only changes once the viewport edge has
    /// crossed one — the follow visibly waited, then jumped.
    var previewScrollPosition: Double = 0

    /// Editor→Preview transport. The publishers coalesce bounds notifications
    /// once per main-loop turn, so this can stay un-debounced.
    func requestPreviewScroll(toMarkdownPosition position: Double) {
        previewScrollPosition = position
        NotificationCenter.default.post(name: .editMDPreviewScrollSync, object: self)
    }

    /// Preview→editor transport. Kept separate from `markdownOffset` so a
    /// passive Preview scroll never moves the caret or changes mode continuity.
    var editorScrollPosition: Double = 0

    func requestEditorScroll(toMarkdownPosition position: Double) {
        editorScrollPosition = position
        NotificationCenter.default.post(name: .editMDEditorScrollSync, object: self)
    }
}

extension Notification.Name {
    /// Posted by `EditorPositionStore.requestJump`; object = the store whose
    /// `markdownOffset` holds the target. Observed by the Source/Visual/
    /// Preview coordinators of the same window.
    static let editMDJumpToOffset = Notification.Name("editmd.jumpToOffset")
    /// Split-mode scroll follow: Preview only (no Source/Visual selection).
    static let editMDPreviewScrollSync = Notification.Name("editmd.previewScrollSync")
    /// Reverse split follow: Source/Visual scroll their viewport without
    /// changing selection. Object = the window's EditorPositionStore.
    static let editMDEditorScrollSync = Notification.Name("editmd.editorScrollSync")
}
