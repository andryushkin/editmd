import Foundation

/// One reverse edge: `source` file contains `link` pointing at the key URL.
struct BacklinkEdge: Equatable, Sendable {
    let source: URL
    let link: OutgoingLink
}

/// The pure link-graph engine (plan 10): scan, resolution, environment
/// fingerprint and backlink projection, extracted from `LinkIndex` so the
/// offline `editmdctl` target compiles the same code without AppKit or the
/// app's models. `LinkIndex` (the app-side @MainActor owner) and the CLI are
/// both thin drivers over these functions.
enum LinkGraphEngine {

    /// Max file size fully read during a workspace scan (4 MiB).
    static let maxFileBytes: Int64 = 4 * 1024 * 1024

    // MARK: - Resolution (testable pure)

    static func resolveLink(
        _ link: OutgoingLink,
        from sourceURL: URL,
        vaultRoot: URL?,
        wikiMatches: [URL]
    ) -> OutgoingLink {
        var out = link
        let fileDir = sourceURL.deletingLastPathComponent()
        let target = link.rawTarget

        // Markdown / path-like image: try filesystem resolution first.
        let looksLikePath = target.contains("/")
            || target.hasPrefix(".")
            || target.contains(".")
        if link.kind == .markdown || (link.kind == .image && looksLikePath) {
            if let hit = resolveLocalLinkDestination(target, fileDir: fileDir, vaultRoot: vaultRoot) {
                out.resolved = hit.standardizedFileURL
                out.candidates = [hit.standardizedFileURL]
                return out
            }
            // Fall through to wiki basename for bare `Note` style destinations.
        }

        // Wiki (and pathless image embeds `![[img.png]]` already handled as
        // path-like when they have an extension; still try wiki index).
        // `wikiMatches` come standardized from WikiLinkResolver — do not
        // re-standardize: it stats the disk per URL, and the full scan calls
        // this for every link in the vault.
        let matches = wikiMatches
        if matches.isEmpty {
            out.resolved = nil
            out.candidates = []
            return out
        }
        if matches.count == 1 {
            out.resolved = matches[0]
            out.candidates = matches
            return out
        }
        // Prefer sibling of the source (same as navigateToWikiLink).
        let sourceDir = fileDir.standardizedFileURL
        if let sibling = matches.first(where: {
            $0.deletingLastPathComponent().standardizedFileURL == sourceDir
        }) {
            out.resolved = sibling
            out.candidates = matches
            return out
        }
        // Ambiguous — no unique pick.
        out.resolved = nil
        out.candidates = matches
        return out
    }

    static func projectBacklinks(
        from outgoing: [URL: [OutgoingLink]]
    ) -> [URL: [BacklinkEdge]] {
        var result: [URL: [BacklinkEdge]] = [:]
        for (source, links) in outgoing {
            let src = source.standardizedFileURL
            for link in links {
                guard let target = link.resolved?.standardizedFileURL else { continue }
                result[target, default: []].append(BacklinkEdge(source: src, link: link))
            }
        }
        for key in result.keys {
            result[key]?.sort {
                if $0.source.path != $1.source.path {
                    return $0.source.path < $1.source.path
                }
                return $0.link.utf16Offset < $1.link.utf16Offset
            }
        }
        return result
    }

    /// One file's parsed scan result keyed by (mtime, size). Full scans reuse
    /// entries for unchanged files, so an epoch bump re-parses only what
    /// actually changed instead of the whole workspace.
    struct FileScanEntry: Sendable {
        let mtime: Date
        let size: Int64
        let links: [OutgoingLink]
        let headings: [String]
        /// Resolve cache: links with `resolved`/`candidates` filled, valid
        /// only while `resolveFingerprint` matches the vault's current
        /// file-set fingerprint. Resolution depends on which files exist,
        /// not on their contents — so an unchanged file in an unchanged
        /// file set skips the (expensive) resolve pass entirely.
        var resolvedLinks: [OutgoingLink]? = nil
        var resolveFingerprint: UInt64? = nil
    }

    /// Filesystem facts the resolve pass depends on, captured during the walk:
    /// every visible item under the roots (files of any type AND directories —
    /// `resolveLocalLinkDestination` accepts any existing path), which
    /// directories the walk actually enumerated, and which items are symlinks
    /// (a listed symlink does not prove its destination exists).
    struct ResolveEnvironment: Sendable {
        let paths: Set<String>
        let walkedDirs: Set<String>
        let symlinks: Set<String>
        static let empty = ResolveEnvironment(paths: [], walkedDirs: [], symlinks: [])
    }

    /// Stable FNV-1a over a string. The resolve fingerprint persists to disk
    /// with the workspace index (plan 10), so it must NOT use `Hasher` (its
    /// seed is random per process).
    static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    /// `path` relative to the first root containing it; unchanged otherwise.
    /// Keeps the fingerprint (and the persisted index) portable: moving or
    /// renaming the vault folder must not invalidate per-file entries.
    static func relativePath(_ path: String, roots: [URL]) -> String {
        for root in roots {
            let r = root.path
            if path == r { return "." }
            if path.hasPrefix(r + "/") { return String(path.dropFirst(r.count + 1)) }
        }
        return path
    }

    /// Order-independent fingerprint of the resolve environment: the wiki
    /// index (every indexable file's basename → paths) + the full visible
    /// item set under the roots (plain relative links resolve to ANY existing
    /// path, including directories and non-indexable files). Any item
    /// added/removed/renamed changes it; content edits do not. Paths enter
    /// relativized so the value survives a vault move; stable across
    /// processes (FNV-1a) so it can persist with the workspace index.
    static func resolveEnvironmentFingerprint(
        roots: [URL], wikiIndex: [String: [URL]], paths: Set<String>
    ) -> UInt64 {
        var result: UInt64 = 0
        for (key, urls) in wikiIndex {
            var entry = stableHash(key)
            for url in urls {
                entry ^= stableHash(relativePath(url.path, roots: roots)) &* 31
            }
            result ^= entry
        }
        for path in paths {
            result ^= stableHash(relativePath(path, roots: roots))
        }
        return result
    }

    /// True when `destination`'s local-path resolution is fully determined by
    /// `environment`: every candidate the probe would try, up to and including
    /// its first hit, lies in a walked directory under a visible (non-hidden,
    /// non-symlink) name — so the environment fingerprint is guaranteed to
    /// change whenever the resolution outcome could change. Destinations that
    /// fail this (targets outside the roots, hidden names, package contents)
    /// must not be resolve-cached: their existence is invisible to the walk.
    static func localResolutionCovered(
        _ destination: String,
        fileDir: URL,
        vaultRoot: URL?,
        environment: ResolveEnvironment
    ) -> Bool {
        for candidate in localLinkDestinationCandidates(
            destination, fileDir: fileDir, vaultRoot: vaultRoot) {
            let std = candidate.standardizedFileURL
            guard environment.walkedDirs.contains(std.deletingLastPathComponent().path),
                  !std.lastPathComponent.hasPrefix("."),
                  !environment.symlinks.contains(std.path)
            else { return false }
            // Probe stops at the first existing candidate — later ones
            // cannot influence the outcome.
            if environment.paths.contains(std.path) { return true }
        }
        return true
    }

    /// Scan all markdown files under `roots` (no resolution). Off-main only.
    /// `onProgress(done, total)` reports the parse phase (directory walk is
    /// fast; parsing dominates) and is called at most ~100 times per scan.
    static func scanWorkspaceOutgoing(
        roots: [URL],
        maxBytes: Int64 = LinkGraphEngine.maxFileBytes,
        cache: [URL: FileScanEntry] = [:],
        onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> (outgoing: [URL: [OutgoingLink]], headings: [URL: [String]],
          skipped: Int, filesScanned: Int, newCache: [URL: FileScanEntry],
          environment: ResolveEnvironment) {
        var outgoing: [URL: [OutgoingLink]] = [:]
        var headings: [URL: [String]] = [:]
        var skipped = 0
        var filesScanned = 0
        var newCache: [URL: FileScanEntry] = [:]
        let mdExt: Set<String> = ["md", "markdown"]
        let fm = FileManager.default

        // Phase 1: enumerate candidates (cheap — attributes only) so the
        // parse phase below has a denominator for progress reporting, and
        // capture the resolve environment (which paths exist) along the way.
        // Environment paths are STANDARDIZED: `contentsOfDirectory(at:)` can
        // return children with a resolved symlink prefix (`/private/var/…`
        // under a `/var/…` root) while link candidates and outgoing keys go
        // through `standardizedFileURL` — a raw-path environment silently
        // marked every sub-directory link uncovered and defeated the resolve
        // cache for them.
        var candidates: [(url: URL, size: Int64, mtime: Date?)] = []
        var envPaths: Set<String> = []
        var envWalkedDirs: Set<String> = []
        var envSymlinks: Set<String> = []
        func walk(_ dir: URL) {
            if Task.isCancelled { return }
            envWalkedDirs.insert(dir.standardizedFileURL.path)
            let items = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey
                ],
                options: [.skipsHiddenFiles])) ?? []
            for url in items {
                if Task.isCancelled { return }
                let vals = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey,
                    .contentModificationDateKey, .isSymbolicLinkKey
                ])
                let stdPath = url.standardizedFileURL.path
                envPaths.insert(stdPath)
                if vals?.isSymbolicLink == true { envSymlinks.insert(stdPath) }
                let isDir = vals?.isDirectory ?? false
                let isPackage = vals?.isPackage ?? false
                if isDir && !isPackage {
                    walk(url)
                    continue
                }
                guard mdExt.contains(url.pathExtension.lowercased()) else { continue }
                let size = Int64(vals?.fileSize ?? 0)
                if size > maxBytes {
                    skipped += 1
                    continue
                }
                candidates.append((url, size, vals?.contentModificationDate))
            }
        }
        for root in roots {
            walk(root.standardizedFileURL)
        }
        let environment = ResolveEnvironment(
            paths: envPaths, walkedDirs: envWalkedDirs, symlinks: envSymlinks)

        // Phase 2: parse (or reuse cache) with progress.
        let total = candidates.count
        let step = max(1, total / 100)
        for (done, candidate) in candidates.enumerated() {
            if Task.isCancelled { break }
            if done % step == 0 { onProgress?(done, total) }
            let key = candidate.url.standardizedFileURL
            if let mtime = candidate.mtime, let hit = cache[key],
               hit.mtime == mtime, hit.size == candidate.size {
                outgoing[key] = hit.links
                headings[key] = hit.headings
                newCache[key] = hit
                continue
            }
            guard let data = try? Data(contentsOf: candidate.url),
                  let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            else { continue }
            filesScanned += 1
            let links = scanOutgoingLinks(text: text)
            let titles = markdownOutline(text).map(\.title)
            outgoing[key] = links
            headings[key] = titles
            if let mtime = candidate.mtime {
                newCache[key] = FileScanEntry(
                    mtime: mtime, size: candidate.size, links: links, headings: titles)
            }
        }
        onProgress?(total, total)
        return (outgoing, headings, skipped, filesScanned, newCache, environment)
    }


    /// Resolve one file's scanned links (wiki index + local path rules).
    /// Pure over inputs; hits the disk — call off the main actor. `wikiIndex`
    /// is a captured WikiLinkResolver snapshot: batch resolution must not hop
    /// to the actor per link (the full scan resolves tens of thousands).
    /// `cacheable` is true only when `environment` was given AND every
    /// path-like link's resolution is covered by it (see
    /// `localResolutionCovered`) — the single-file path passes nil.
    static func resolveScannedLinks(
        _ links: [OutgoingLink],
        source: URL,
        roots: [URL],
        vaultFallback: URL?,
        wikiIndex: [String: [URL]],
        environment: ResolveEnvironment? = nil
    ) -> (links: [OutgoingLink], cacheable: Bool) {
        let vault = roots.first { root in
            let p = source.path
            let r = root.standardizedFileURL.path
            return p == r || p.hasPrefix(r + "/")
        } ?? vaultFallback
        var resolvedLinks: [OutgoingLink] = []
        resolvedLinks.reserveCapacity(links.count)
        var cacheable = environment != nil
        for link in links {
            if Task.isCancelled { return ([], false) }
            if cacheable, let environment,
               link.kind == .markdown || link.kind == .image,
               !localResolutionCovered(
                   link.rawTarget,
                   fileDir: source.deletingLastPathComponent(),
                   vaultRoot: vault,
                   environment: environment) {
                cacheable = false
            }
            let wikiHits: [URL]
            if link.kind == .wiki
                || (link.kind == .image && !link.rawTarget.contains("/")) {
                wikiHits = WikiLinkCore.matches(for: link.rawTarget, in: wikiIndex)
            } else if link.kind == .markdown
                        || link.kind == .image {
                // Path resolve first; wiki fallback for bare names.
                let local = resolveLocalLinkDestination(
                    link.rawTarget,
                    fileDir: source.deletingLastPathComponent(),
                    vaultRoot: vault
                )
                if local != nil {
                    wikiHits = []
                } else {
                    wikiHits = WikiLinkCore.matches(for: link.rawTarget, in: wikiIndex)
                }
            } else {
                wikiHits = []
            }
            resolvedLinks.append(resolveLink(
                link, from: source, vaultRoot: vault, wikiMatches: wikiHits
            ))
        }
        return (resolvedLinks, cacheable)
    }
}
