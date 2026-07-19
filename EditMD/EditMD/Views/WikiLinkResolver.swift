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

    /// File URLs whose basename matches `target`, notes before read-only media,
    /// then by path for stable ordering. A `folder/Note` target resolves by its
    /// last path component; an explicit extension narrows matches to that type.
    func resolve(_ target: String) -> [URL] {
        buildIfNeeded()
        return Self.matches(for: target, in: index)
    }

    /// Whole basename index (standardized URLs) — one actor hop for batch
    /// consumers (the workspace link scan resolves tens of thousands of links;
    /// a hop per link starved the cooperative pool for minutes on big vaults).
    func indexedMatches() -> [String: [URL]] {
        buildIfNeeded()
        return index
    }

    /// Same lookup rules as `resolve`, over a captured index snapshot.
    /// (Delegates to `WikiLinkCore` — the pure engine shared with editmdctl.)
    nonisolated static func matches(for target: String,
                                    in index: [String: [URL]]) -> [URL] {
        WikiLinkCore.matches(for: target, in: index)
    }

    private func buildIfNeeded() {
        guard !built else { return }
        index = WikiLinkCore.buildIndex(roots: roots)
        built = true
    }
}

/// Opens the file a wiki-link `target` points at, in the main window.
/// Resolution runs off the main actor; when several files share the basename,
/// one in the current file's own folder wins (Obsidian's shortest-path bias);
/// an unresolved link beeps. When `heading` is set, scrolls to that heading
/// via `requestControlJump` after the file is mounted (or immediately if already open).
@MainActor
func navigateToWikiLink(target: String, heading: String? = nil, from currentURL: URL?) {
    // Index the stable workspace roots; if none are adopted, fall back to the
    // current file's own folder so loose files can still link to siblings.
    var roots = WorkspaceModel.shared.workspaces.map { $0.url }
    if roots.isEmpty, let dir = currentURL?.deletingLastPathComponent() {
        roots = [dir]
    }
    let currentDir = currentURL?.deletingLastPathComponent().standardizedFileURL
    let headingQuery = heading?.trimmingCharacters(in: .whitespacesAndNewlines)
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

        var jumpOffset: Int?
        if let headingQuery, !headingQuery.isEmpty {
            // Prefer open buffer (live edits) then disk.
            let text = DocumentRegistry.shared.contentIfOpen(chosen)
                ?? (try? String(contentsOf: chosen, encoding: .utf8))
            if let text {
                jumpOffset = findHeadingOffset(matching: headingQuery, in: text)
            }
        }

        if let jumpOffset {
            AppState.shared.requestControlJump(url: chosen, offset: jumpOffset)
        }
        AppState.shared.openInMainWindow(chosen)
    }
}

// MARK: - Plain markdown links to local files

/// Opens a regular markdown link destination (`[pdf](/research_pdf/x.pdf)`).
/// Scheme links (`https:`, `mailto:` …) go to the system as before. Schemeless
/// paths resolve Obsidian-style: leading `/` is vault-absolute — against the
/// workspace root that owns `currentURL` (fallback: the nearest ancestor with
/// an `.obsidian` folder, so un-adopted vaults still work) — otherwise relative
/// to the file's folder. Files EditMD displays (markdown / PDF) open in the
/// main window; any other existing file opens with its system app.
@MainActor
func openMarkdownLink(destination: String, from currentURL: URL?) {
    let trimmed = destination.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { NSSound.beep(); return }
    if let url = URL(string: trimmed), url.scheme != nil {
        NSWorkspace.shared.open(url)
        return
    }
    let fileDir = currentURL?.deletingLastPathComponent()
    var root = currentURL.flatMap { WorkspaceModel.shared.workspaceOwning($0)?.url }
    if root == nil, let fileDir { root = nearestVaultRoot(startingAt: fileDir) }
    guard let resolved = resolveLocalLinkDestination(trimmed, fileDir: fileDir, vaultRoot: root)
    else { NSSound.beep(); return }
    let ext = resolved.pathExtension.lowercased()
    if ["md", "markdown", "textbundle", "pdf"].contains(ext) || isImageFile(resolved) {
        AppState.shared.openInMainWindow(resolved)
    } else {
        NSWorkspace.shared.open(resolved)
    }
}

// `localLinkDestinationCandidates` / `resolveLocalLinkDestination` /
// `nearestVaultRoot` live in Editor/WikiLinkCore.swift (pure Foundation —
// shared with the offline editmdctl engine).
