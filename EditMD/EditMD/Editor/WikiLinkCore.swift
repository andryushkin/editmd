import Foundation

/// Pure wiki-link machinery shared by the app's `WikiLinkResolver` actor and
/// the offline `editmdctl` engine: basename index over workspace roots +
/// lookups in a captured snapshot. No AppKit, no app state.
enum WikiLinkCore {

    /// Every file EditMD can display directly may be a `[[target]]`.
    static let indexedExtensions: Set<String> =
        Set(["md", "markdown", "textbundle", "pdf"]).union(supportedImageFileExtensions)

    /// Extensions the user may type explicitly in a target (`[[doc.pdf]]`).
    /// An explicit extension filters matches to that file type.
    static let explicitExtensions = ["md", "markdown", "textbundle", "pdf"]
        + supportedImageFileExtensions.sorted()

    /// Walks `roots` and builds basename (lowercased, no extension) → URLs,
    /// notes before read-only media, then by path for stable ordering.
    static func buildIndex(roots: [URL]) -> [String: [URL]] {
        var newIndex: [String: [URL]] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator
            where indexedExtensions.contains(url.pathExtension.lowercased()) {
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                // Standardized once here — per-match standardization during
                // link resolution was the hot spot of the workspace scan.
                newIndex[key, default: []].append(url.standardizedFileURL)
            }
        }
        for key in newIndex.keys {
            newIndex[key]?.sort {
                // A bare [[Name]] shared by a note and media opens the editable note.
                let aRank = targetRank($0)
                let bRank = targetRank($1)
                if aRank != bRank { return aRank < bRank }
                return $0.path < $1.path
            }
        }
        return newIndex
    }

    /// File URLs whose basename matches `target` in a captured index.
    /// A `folder/Note` target resolves by its last path component; an
    /// explicit extension narrows matches to that file type.
    static func matches(for target: String, in index: [String: [URL]]) -> [URL] {
        let (key, ext) = normalizeTarget(target)
        var matches = index[key] ?? []
        if let ext {
            matches = matches.filter { $0.pathExtension.lowercased() == ext }
        }
        return matches
    }

    static func targetRank(_ url: URL) -> Int {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "textbundle"].contains(ext) { return 0 }
        if ext == "pdf" { return 1 }
        return 2
    }

    static func normalizeTarget(_ target: String) -> (key: String, ext: String?) {
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

// MARK: - Plain local link destinations (pure filesystem probing)

/// Candidate URLs `resolveLocalLinkDestination` probes, in probe order.
/// Drops a `#…` fragment and undoes percent-encoding (`%20`); leading `/` →
/// vault root + path, then the literal absolute path; otherwise file's
/// folder + path, then vault root + path (Obsidian resolves both).
/// Split out so the link-graph resolve cache can reason about which paths a
/// destination's resolution depends on (`LinkGraphEngine.localResolutionCovered`).
func localLinkDestinationCandidates(_ destination: String,
                                    fileDir: URL?,
                                    vaultRoot: URL?) -> [URL] {
    var path = destination
    if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
    path = (path.removingPercentEncoding ?? path).trimmingCharacters(in: .whitespaces)
    guard !path.isEmpty else { return [] }

    var candidates: [URL] = []
    if path.hasPrefix("/") {
        let rel = String(path.dropFirst())
        if let vaultRoot { candidates.append(vaultRoot.appendingPathComponent(rel)) }
        candidates.append(URL(fileURLWithPath: path))
    } else {
        if let fileDir { candidates.append(fileDir.appendingPathComponent(path)) }
        if let vaultRoot { candidates.append(vaultRoot.appendingPathComponent(path)) }
    }
    return candidates
}

/// Filesystem resolution for a schemeless link destination: probes
/// `localLinkDestinationCandidates` in order and returns the first existing
/// file, nil when nothing matches.
func resolveLocalLinkDestination(_ destination: String,
                                 fileDir: URL?,
                                 vaultRoot: URL?) -> URL? {
    for candidate in localLinkDestinationCandidates(
        destination, fileDir: fileDir, vaultRoot: vaultRoot) {
        let std = candidate.standardizedFileURL
        if FileManager.default.fileExists(atPath: std.path) { return std }
    }
    return nil
}

/// Nearest ancestor of `dir` (inclusive) containing an `.obsidian` folder —
/// the vault marker, so `/vault/absolute` links work for files opened outside
/// any adopted workspace. Bounded walk to filesystem root.
func nearestVaultRoot(startingAt dir: URL) -> URL? {
    var probe = dir.standardizedFileURL
    for _ in 0..<64 {
        if FileManager.default.fileExists(
            atPath: probe.appendingPathComponent(".obsidian").path) {
            return probe
        }
        let parent = probe.deletingLastPathComponent()
        if parent.path == probe.path { return nil }
        probe = parent
    }
    return nil
}
