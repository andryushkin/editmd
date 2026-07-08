import Foundation
import AppKit

/// Resolves wiki-link targets (`[[Note]]`) to file URLs by basename across the
/// adopted workspace folders.
///
/// The index is built LAZILY on first `resolve` and cached — a vault can hold
/// thousands of files (the reference `wol` folder has ~7000), so we never walk
/// eagerly at launch. `setRoots` rebuilds only when the root set actually
/// changes; `invalidate()` forces a rebuild after files are added/renamed.
actor WikiLinkResolver {
    static let shared = WikiLinkResolver()

    /// note basename (lowercased, no extension) → matching file URLs.
    private var index: [String: [URL]] = [:]
    private var built = false
    private var roots: [URL] = []

    private static let markdownExtensions: Set<String> = ["md", "markdown", "textbundle"]

    init() {}

    /// Sets the folders to index. A no-op (keeps the cache) when the set is
    /// unchanged, so repeated clicks don't rebuild.
    func setRoots(_ newRoots: [URL]) {
        let normalized = newRoots.map { $0.standardizedFileURL }
        if normalized.map(\.path) != roots.map(\.path) {
            roots = normalized
            built = false
            index = [:]
        }
    }

    func invalidate() {
        built = false
        index = [:]
    }

    /// File URLs whose basename matches `target`, sorted by path for stable
    /// ordering. A `folder/Note` target resolves by its last path component; a
    /// trailing `.md` the user typed is ignored.
    func resolve(_ target: String) -> [URL] {
        buildIfNeeded()
        return index[normalizeKey(target)] ?? []
    }

    private func buildIfNeeded() {
        guard !built else { return }
        var newIndex: [String: [URL]] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator
            where Self.markdownExtensions.contains(url.pathExtension.lowercased()) {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                newIndex[key, default: []].append(url)
            }
        }
        for key in newIndex.keys {
            newIndex[key]?.sort { $0.path < $1.path }
        }
        index = newIndex
        built = true
    }

    private func normalizeKey(_ target: String) -> String {
        var t = target
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }
        return t.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// Opens the file a wiki-link `target` points at, in the main window.
/// Resolution runs off the main actor; when several files share the basename,
/// one in the current file's own folder wins (Obsidian's shortest-path bias);
/// an unresolved link beeps. Heading/block scrolling is not wired yet.
@MainActor
func navigateToWikiLink(target: String, from currentURL: URL?) {
    // Index the stable workspace roots; if none are adopted, fall back to the
    // current file's own folder so loose files can still link to siblings.
    var roots = WorkspaceModel.shared.workspaces.map { $0.url }
    if roots.isEmpty, let dir = currentURL?.deletingLastPathComponent() {
        roots = [dir]
    }
    let currentDir = currentURL?.deletingLastPathComponent().standardizedFileURL
    Task {
        await WikiLinkResolver.shared.setRoots(roots)
        var matches = await WikiLinkResolver.shared.resolve(target)
        if matches.isEmpty {
            // The target may have been created since the index was built (no
            // FSEvents watcher yet); rebuild once before giving up.
            await WikiLinkResolver.shared.invalidate()
            matches = await WikiLinkResolver.shared.resolve(target)
        }
        guard !matches.isEmpty else { NSSound.beep(); return }
        let chosen = matches.first {
            $0.deletingLastPathComponent().standardizedFileURL == currentDir
        } ?? matches[0]
        AppState.shared.openInMainWindow(chosen)
    }
}
