import SwiftUI

/// The four editor modes: raw markdown, hybrid WYSIWYG, rendered preview,
/// and the fixed Source + Preview workspace.
enum EditorMode: String, CaseIterable, Identifiable, Sendable {
    case source
    case visual
    case preview
    case split

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:  return "Source"
        case .visual:  return "Visual"
        case .preview: return "Preview"
        case .split:   return "Split"
        }
    }

    var systemImage: String {
        switch self {
        case .source:  return "chevron.left.forwardslash.chevron.right"
        case .visual:  return "doc.richtext"
        case .preview: return "eye"
        case .split:   return "rectangle.split.2x1"
        }
    }

    /// Filled glyph variant shown while the mode is active (the agterm-style
    /// multi-state symbol). Source has no fill variant — the accent tint
    /// alone marks it active.
    var activeSystemImage: String {
        switch self {
        case .source:  return "chevron.left.forwardslash.chevron.right"
        case .visual:  return "doc.richtext.fill"
        case .preview: return "eye.fill"
        case .split:   return "rectangle.split.2x1.fill"
        }
    }

    /// ⌘1 / ⌘2 / ⌘3 / ⌘4 in the View menu.
    var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .source:  return "1"
        case .visual:  return "2"
        case .preview: return "3"
        case .split:   return "4"
        }
    }

    /// Shortcut shown in toolbar tooltips, e.g. "Source (⌘1)".
    var shortcutHint: String {
        switch self {
        case .source:  return "⌘1"
        case .visual:  return "⌘2"
        case .preview: return "⌘3"
        case .split:   return "⌘4"
        }
    }
}
