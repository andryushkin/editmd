import Foundation

/// Gates for work that ships in the binary but is not offered yet.
///
/// A flag is read once per launch — `defaults write andryushkin.EditMD
/// feature.<name> -bool YES`, then restart. With a flag off the app must be
/// indistinguishable from one built without the feature: no menu item, no
/// mode, no settings tab. Flipping one mid-session is deliberately impossible;
/// half the UI would answer from the old value, and the persisted editor mode
/// could name a case the rest of the app no longer offers.
enum FeatureFlags {

    /// Print mode (⌘5) and its settings tab.
    static let printMode = read("printMode")

    private static func read(_ name: String) -> Bool {
        UserDefaults.standard.bool(forKey: "feature.\(name)")
    }
}
