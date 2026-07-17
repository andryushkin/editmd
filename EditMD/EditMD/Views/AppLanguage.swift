import Foundation

/// The in-app UI-language override (Settings ▸ General ▸ Language).
/// Canonical macOS mechanism: an app-domain `AppleLanguages` default. The
/// bundle resolves its localization at launch, so a manual choice applies on
/// the next start; `.system` removes the override entirely.
enum AppLanguageChoice: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case russian = "ru"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return String(localized: "Automatic")
        // Language names are shown in their own language on purpose — the
        // option must stay readable from the other language.
        case .english: return "English"
        case .russian: return "Русский"
        }
    }

    /// What Settings should preselect. Reads our mirror key, not the raw
    /// `AppleLanguages`: the global domain always carries the system list, so
    /// its mere presence does not mean the user chose an override.
    static var current: AppLanguageChoice {
        guard let raw = UserDefaults.standard.string(forKey: overrideKey),
              let choice = AppLanguageChoice(rawValue: raw) else { return .system }
        return choice
    }

    func apply() {
        let defaults = UserDefaults.standard
        switch self {
        case .system:
            defaults.removeObject(forKey: Self.overrideKey)
            defaults.removeObject(forKey: "AppleLanguages")
        case .english, .russian:
            defaults.set(rawValue, forKey: Self.overrideKey)
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }

    private static let overrideKey = "editMD.languageOverride"
}
