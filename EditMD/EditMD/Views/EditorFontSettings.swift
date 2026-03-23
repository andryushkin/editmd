import AppKit

extension Notification.Name {
    static let editorFontSizeDidChange = Notification.Name("editorFontSizeDidChange")
}

@MainActor
final class EditorFontSettings {
    static let shared = EditorFontSettings()
    private init() {}

    private let sizeKey = "editorFontSize"
    private let minSize: CGFloat = 10
    private let maxSize: CGFloat = 32

    var fontSize: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: sizeKey)
            return stored > 0 ? CGFloat(stored) : 14
        }
        set {
            let clamped = min(maxSize, max(minSize, newValue))
            UserDefaults.standard.set(Double(clamped), forKey: sizeKey)
            NotificationCenter.default.post(name: .editorFontSizeDidChange, object: nil)
        }
    }

    var canIncrease: Bool { fontSize < maxSize }
    var canDecrease: Bool { fontSize > minSize }
}
