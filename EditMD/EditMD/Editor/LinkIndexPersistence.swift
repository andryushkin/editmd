import Foundation

/// On-disk link index: `<workspace>/.editmd/link-index.json`. Written after a
/// successful full scan; read once per cold start to seed `LinkIndex.scanCache`
/// (unchanged vault = walk + stats, no re-parse). External tools (wikillm
/// agents) read the same file. Contract — workspace-only, root-relative paths,
/// self-ignoring `.gitignore`, deterministic output, corrupt/foreign versions
/// silently ignored, disk I/O off-main: docs/vault.md § Link index.
enum LinkIndexPersistence {

    static let directoryName = ".editmd"
    static let fileName = "link-index.json"
    static let formatVersion = 1

    struct FilePayload: Codable {
        var version: Int
        var scannedAt: Date
        var files: [Entry]
    }

    struct Entry: Codable {
        var path: String
        /// Exact bit pattern of `timeIntervalSinceReferenceDate`: the seeded
        /// value must compare `==` to a future stat, and a decimal JSON
        /// round-trip is not guaranteed bit-exact.
        var mtimeBits: UInt64
        var size: Int64
        var headings: [String]
        var links: [Link]
        /// Present only when the resolution was environment-covered (see
        /// `LinkGraphEngine.localResolutionCovered`); its links carry
        /// `resolvedPath`/`candidatePaths`.
        var resolveFingerprint: UInt64?
    }

    struct Link: Codable {
        var kind: String
        var rawTarget: String
        var heading: String?
        var label: String
        var line: Int
        var utf16Offset: Int
        var context: String
        var resolvedPath: String?
        var candidatePaths: [String]?
    }

    static func indexFileURL(root: URL) -> URL {
        root.appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)
    }

    // MARK: - Encode

    /// Serializes the cache entries that live under `root`. Entries whose
    /// resolve info references paths outside the root are persisted without
    /// it (defensively — covered resolutions always stay inside the root).
    static func encode(cache: [URL: LinkGraphEngine.FileScanEntry], root: URL) -> Data? {
        let rootPath = root.standardizedFileURL.path
        var entries: [Entry] = []
        for (url, entry) in cache {
            guard url.path.hasPrefix(rootPath + "/") else { continue }
            let rel = String(url.path.dropFirst(rootPath.count + 1))
            var links: [Link] = []
            var fingerprint = entry.resolveFingerprint
            let source = entry.resolvedLinks ?? entry.links
            var resolveInsideRoot = entry.resolvedLinks != nil && fingerprint != nil
            for link in source {
                var resolvedPath: String?
                var candidatePaths: [String]?
                if resolveInsideRoot, let resolved = link.resolved {
                    if resolved.path.hasPrefix(rootPath + "/") {
                        resolvedPath = String(resolved.path.dropFirst(rootPath.count + 1))
                    } else {
                        resolveInsideRoot = false
                    }
                }
                if resolveInsideRoot, !link.candidates.isEmpty {
                    var rels: [String] = []
                    for candidate in link.candidates {
                        guard candidate.path.hasPrefix(rootPath + "/") else {
                            resolveInsideRoot = false
                            break
                        }
                        rels.append(String(candidate.path.dropFirst(rootPath.count + 1)))
                    }
                    if resolveInsideRoot { candidatePaths = rels }
                }
                links.append(Link(
                    kind: link.kind.rawValue,
                    rawTarget: link.rawTarget,
                    heading: link.heading,
                    label: link.label,
                    line: link.line,
                    utf16Offset: link.utf16Offset,
                    context: link.context,
                    resolvedPath: resolvedPath,
                    candidatePaths: candidatePaths))
            }
            if !resolveInsideRoot {
                fingerprint = nil
                for i in links.indices {
                    links[i].resolvedPath = nil
                    links[i].candidatePaths = nil
                }
            }
            entries.append(Entry(
                path: rel,
                mtimeBits: entry.mtime.timeIntervalSinceReferenceDate.bitPattern,
                size: entry.size,
                headings: entry.headings,
                links: links,
                resolveFingerprint: fingerprint))
        }
        entries.sort { $0.path < $1.path }
        // scannedAt rounds to whole seconds and may change per save;
        // determinism is asserted over `files` in tests.
        let payload = FilePayload(
            version: formatVersion,
            scannedAt: Date(timeIntervalSince1970:
                Date().timeIntervalSince1970.rounded(.down)),
            files: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(payload)
    }

    // MARK: - Decode

    /// Rebuilds cache entries keyed by absolute standardized URL. Returns [:]
    /// for corrupt data or a version mismatch — the caller scans without a
    /// seed. Validity against the live filesystem is NOT checked here: the
    /// scan itself compares (mtime, size) per file.
    static func decode(_ data: Data, root: URL) -> [URL: LinkGraphEngine.FileScanEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(FilePayload.self, from: data),
              payload.version == formatVersion else { return [:] }
        let std = root.standardizedFileURL
        var cache: [URL: LinkGraphEngine.FileScanEntry] = [:]
        for entry in payload.files {
            // Reject entries that escape the root — the file is a cache, but
            // it is also untrusted input from disk.
            guard isSafeRelative(entry.path) else { continue }
            let url = std.appendingPathComponent(entry.path).standardizedFileURL
            var raw: [OutgoingLink] = []
            var resolved: [OutgoingLink] = []
            var links: [(Link, OutgoingLink.Kind)] = []
            for link in entry.links {
                guard let kind = OutgoingLink.Kind(rawValue: link.kind) else {
                    links.removeAll()
                    break
                }
                links.append((link, kind))
            }
            guard links.count == entry.links.count else { continue }
            // One unsafe resolved/candidate path taints ALL resolve-info for
            // this entry: keep raw links, drop cached resolution so the scan
            // re-resolves inside the root.
            var resolveTainted = false
            for (link, kind) in links {
                raw.append(OutgoingLink(
                    kind: kind, rawTarget: link.rawTarget, heading: link.heading,
                    label: link.label, line: link.line,
                    utf16Offset: link.utf16Offset, context: link.context))
                if let rp = link.resolvedPath, !isSafeRelative(rp) { resolveTainted = true }
                if (link.candidatePaths ?? []).contains(where: { !isSafeRelative($0) }) {
                    resolveTainted = true
                }
                resolved.append(OutgoingLink(
                    kind: kind, rawTarget: link.rawTarget, heading: link.heading,
                    label: link.label, line: link.line,
                    utf16Offset: link.utf16Offset, context: link.context,
                    resolved: link.resolvedPath.map {
                        std.appendingPathComponent($0).standardizedFileURL
                    },
                    candidates: (link.candidatePaths ?? []).map {
                        std.appendingPathComponent($0).standardizedFileURL
                    }))
            }
            var scanEntry = LinkGraphEngine.FileScanEntry(
                mtime: Date(timeIntervalSinceReferenceDate:
                    Double(bitPattern: entry.mtimeBits)),
                size: entry.size,
                links: raw,
                headings: entry.headings)
            if let fingerprint = entry.resolveFingerprint, !resolveTainted {
                scanEntry.resolvedLinks = resolved
                scanEntry.resolveFingerprint = fingerprint
            }
            cache[url] = scanEntry
        }
        return cache
    }

    /// A workspace-relative path that cannot escape the root: non-empty, not
    /// absolute, no `..` component. Guards every path read out of the
    /// untrusted index file — entry paths AND resolved/candidate paths.
    static func isSafeRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/")
            && !path.split(separator: "/").contains("..")
    }

    // MARK: - Disk

    /// Atomic save (`tmp` + rename) plus the self-ignoring `.gitignore`.
    /// Call off the main actor only.
    static func save(cache: [URL: LinkGraphEngine.FileScanEntry], root: URL) {
        guard let data = encode(cache: cache, root: root) else { return }
        let fm = FileManager.default
        let dir = root.appendingPathComponent(directoryName)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let gitignore = dir.appendingPathComponent(".gitignore")
            if !fm.fileExists(atPath: gitignore.path) {
                try? Data("*\n".utf8).write(to: gitignore)
            }
            let target = dir.appendingPathComponent(fileName)
            let tmp = dir.appendingPathComponent(fileName + ".tmp")
            try data.write(to: tmp)
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: dir.appendingPathComponent(fileName + ".tmp"))
        }
    }

    /// Loads the persisted seed for `root`; [:] when absent or unusable.
    /// Call off the main actor only.
    static func load(root: URL) -> [URL: LinkGraphEngine.FileScanEntry] {
        guard let data = try? Data(contentsOf: indexFileURL(root: root)) else {
            return [:]
        }
        return decode(data, root: root)
    }
}
