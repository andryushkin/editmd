import Foundation

/// Cursor/scroll continuity across mode switches. The canonical coordinate is
/// a UTF-16 offset into the *markdown* text (document.content): Source uses it
/// directly, Visual maps through the serializer's paragraph map, Preview
/// scrolls to the proportional position. A class so cursor moves don't
/// trigger SwiftUI invalidation.
@MainActor
final class EditorPositionStore {
    var markdownOffset: Int = 0
}
