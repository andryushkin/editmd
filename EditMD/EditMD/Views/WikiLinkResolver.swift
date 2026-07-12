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

    /// Markdown documents + PDF — everything a `[[target]]` may point at.
    private static let indexedExtensions: Set<String> = ["md", "markdown", "textbundle", "pdf"]

    /// Extensions the user may type explicitly in a target (`[[doc.pdf]]`).
    /// An explicit extension filters matches to that file type.
    private static let explicitExtensions = ["md", "pdf"]

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

    /// File URLs whose basename matches `target`, notes before PDFs, then by
    /// path for stable ordering. A `folder/Note` target resolves by its last
    /// path component; an explicit `.md` / `.pdf` the user typed narrows the
    /// matches to that file type.
    func resolve(_ target: String) -> [URL] {
        buildIfNeeded()
        let (key, ext) = Self.normalizeTarget(target)
        var matches = index[key] ?? []
        if let ext {
            matches = matches.filter { $0.pathExtension.lowercased() == ext }
        }
        return matches
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
            where Self.indexedExtensions.contains(url.pathExtension.lowercased()) {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                newIndex[key, default: []].append(url)
            }
        }
        for key in newIndex.keys {
            newIndex[key]?.sort {
                // A bare [[Name]] shared by note.md and note.pdf opens the note.
                let aPDF = $0.pathExtension.lowercased() == "pdf"
                let bPDF = $1.pathExtension.lowercased() == "pdf"
                if aPDF != bPDF { return bPDF }
                return $0.path < $1.path
            }
        }
        index = newIndex
        built = true
    }

    private static func normalizeTarget(_ target: String) -> (key: String, ext: String?) {
        var t = target
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        t = t.trimmingCharacters(in: .whitespaces)
        var ext: String?
        for candidate in explicitExtensions where t.lowercased().hasSuffix("." + candidate) {
            ext = candidate
            t = String(t.dropLast(candidate.count + 1))
            break
        }
        return (t.trimmingCharacters(in: .whitespaces).lowercased(), ext)
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
