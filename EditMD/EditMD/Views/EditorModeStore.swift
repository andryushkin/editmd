import Foundation

/// Per-document editor mode (FSNotes' `previewState` idea): each file remembers
/// whether it was last left in Source / Visual / Preview / Split, so a
/// "page-like" note reopens in Preview while a draft reopens in the editor.
/// The global `@AppStorage("editorMode")` stays the default for files that have
/// no remembered mode yet (and for untitled buffers).
///
/// Keyed by standardized path in one UserDefaults dictionary — the files on
/// disk stay clean (no per-file dotfiles), matching `WorkspaceModel`.
@MainActor
enum EditorModeStore {
    private static let key = "editorMode.byPath"
    /// Soft cap so the map can't grow without bound. No recency data is kept,
    /// so an overflow drops arbitrary entries — a remembered mode is a nicety,
    /// and the global default covers anything evicted.
    private static let limit = 2000

    /// The mode a file was last left in, or nil if it has none. `defaults` is
    /// injectable so tests don't touch the developer's real preferences.
    static func mode(for url: URL?, defaults: UserDefaults = .standard) -> EditorMode? {
        guard let path = url?.standardizedFileURL.path,
              let raw = dictionary(defaults)[path] else { return nil }
        return EditorMode(rawValue: raw)
    }

    /// Records the mode a file is currently shown in. No-op for untitled
    /// buffers (nil URL) — they fall back to the global default on reopen.
    static func setMode(_ mode: EditorMode, for url: URL?, defaults: UserDefaults = .standard) {
        guard let path = url?.standardizedFileURL.path else { return }
        var dict = dictionary(defaults)
        dict[path] = mode.rawValue
        if dict.count > limit {
            for extra in dict.keys.shuffled().prefix(dict.count - limit) {
                dict.removeValue(forKey: extra)
            }
        }
        defaults.set(dict, forKey: key)
    }

    private static func dictionary(_ defaults: UserDefaults) -> [String: String] {
        defaults.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
