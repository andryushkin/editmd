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
    var previewScrollOffset: Int = 0

    /// D5: editor→preview scroll sync only (Preview listens; Source/Visual
    /// must not re-select / fight the user scroll).
    func requestPreviewScroll(toMarkdownOffset offset: Int) {
        previewScrollOffset = offset
        NotificationCenter.default.post(name: .editMDPreviewScrollSync, object: self)
    }
}

extension Notification.Name {
    /// Posted by `EditorPositionStore.requestJump`; object = the store whose
    /// `markdownOffset` holds the target. Observed by the Source/Visual/
    /// Preview coordinators of the same window.
    static let editMDJumpToOffset = Notification.Name("editmd.jumpToOffset")
    /// Split-mode scroll follow: Preview only (no Source/Visual selection).
    static let editMDPreviewScrollSync = Notification.Name("editmd.previewScrollSync")
}
