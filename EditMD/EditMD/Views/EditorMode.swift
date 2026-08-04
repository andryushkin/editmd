import SwiftUI

/// The editor modes: raw markdown, hybrid WYSIWYG, rendered preview, the fixed
/// Source + Preview workspace, and paginated print output. `.split` is not a
/// render path of its own — it mounts Source beside Preview.
enum EditorMode: String, CaseIterable, Identifiable, Sendable {
    case source
    case visual
    case preview
    case split
    case print

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source:  return String(localized: "Source")
        case .visual:  return String(localized: "Visual")
        case .preview: return String(localized: "Preview")
        case .split:   return String(localized: "Split")
        case .print:   return String(localized: "Print")
        }
    }

    var systemImage: String {
        switch self {
        case .source:  return "chevron.left.forwardslash.chevron.right"
        case .visual:  return "doc.richtext"
        case .preview: return "eye"
        case .split:   return "rectangle.split.2x1"
        case .print:   return "doc.plaintext"
        }
    }

    /// ⌘1 … ⌘5 in the View menu.
    var keyboardShortcutKey: KeyEquivalent {
        switch self {
        case .source:  return "1"
        case .visual:  return "2"
        case .preview: return "3"
        case .split:   return "4"
        case .print:   return "5"
        }
    }

    /// Shortcut shown in toolbar tooltips, e.g. "Source (⌘1)".
    var shortcutHint: String {
        switch self {
        case .source:  return "⌘1"
        case .visual:  return "⌘2"
        case .preview: return "⌘3"
        case .split:   return "⌘4"
        case .print:   return "⌘5"
        }
    }

    /// Modes the UI may offer. Gated cases are filtered here rather than at
    /// each call site so the View menu, the mode pill and the control socket
    /// cannot disagree about what exists.
    static func available(printEnabled: Bool = FeatureFlags.printMode) -> [EditorMode] {
        allCases.filter { $0 != .print || printEnabled }
    }

    /// Resolves a stored or externally supplied mode name. Returns nil for a
    /// gated case, so a `feature.printMode` install that later drops the flag
    /// falls back instead of activating a mode nothing else in the UI shows.
    static func resolve(rawValue: String,
                        printEnabled: Bool = FeatureFlags.printMode) -> EditorMode? {
        guard let mode = EditorMode(rawValue: rawValue) else { return nil }
        return available(printEnabled: printEnabled).contains(mode) ? mode : nil
    }
}
