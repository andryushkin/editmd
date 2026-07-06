import SwiftUI

/// The three editor modes: raw markdown, hybrid WYSIWYG editing, rendered preview.
enum EditorMode: String, CaseIterable, Identifiable {
    case source
    case visual
    case preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:  return "Source"
        case .visual:  return "Visual"
        case .preview: return "Preview"
        }
    }

    var systemImage: String {
        switch self {
        case .source:  return "chevron.left.forwardslash.chevron.right"
        case .visual:  return "doc.richtext"
        case .preview: return "eye"
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 in the View menu.
    var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .source:  return "1"
        case .visual:  return "2"
        case .preview: return "3"
        }
    }
}
