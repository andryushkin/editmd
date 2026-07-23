import Foundation

// MARK: - Meta / hits

/// Cheap file facts used before content is read.
struct SearchFileMeta: Equatable, Sendable {
    let url: URL
    /// Path relative to the owning workspace root (`notes/a.md`), no leading slash.
    let relativePath: String
    let fileName: String
    /// Lowercased extension without dot (`md`).
    let pathExtension: String
    let modificationDate: Date
    let fileSize: Int64
    /// Frontmatter tags (original casing); matching is case-insensitive.
    let tags: [String]
    /// True when git porcelain lists the file as not clean.
    let isGitModified: Bool
}

/// One matching line inside a file (for the results list).
struct SearchLineHit: Equatable, Sendable, Identifiable {
    /// 1-based line number.
    let lineNumber: Int
    /// Full line text (trimmed trailing newline; may be truncated for display).
    let lineText: String
    /// UTF-16 offset of the line start in the file text (for jump).
    let utf16Offset: Int

    var id: Int { lineNumber }
}

/// Result of content + file-name matching for one file.
struct SearchContentMatch: Equatable, Sendable {
    /// All tokens/phrases satisfied (name and/or body).
    let matched: Bool
    /// Up to `maxLineHits` first body lines that contain any needle.
    let lineHits: [SearchLineHit]
    /// Total needle occurrences across body lines (for sort-by-relevance).
    let matchCount: Int
    /// True when every token/phrase also appears in the file name (or only name).
    let nameMatched: Bool
}

/// Options that affect structural filters without reading content.
struct SearchMetaOptions: Equatable, Sendable {
    /// Whether any workspace root sits in a git repo (for `is:modified`).
    var gitAvailable: Bool
    /// When `type` is nil, only these extensions pass (default markdown).
    var defaultExtensions: Set<String>

    static let markdownDefault = SearchMetaOptions(
        gitAvailable: true,
        defaultExtensions: ["md", "markdown"]
    )
}

/// Tunables for a full multi-file run.
struct SearchRunOptions: Equatable, Sendable {
    var meta: SearchMetaOptions
    var maxFileBytes: Int64
    var maxResultFiles: Int
    var maxLineHitsPerFile: Int
    /// When true and query has only structural filters, skip content read.
    var skipContentWhenNoText: Bool

    static let `default` = SearchRunOptions(
        meta: .markdownDefault,
        maxFileBytes: 4 * 1024 * 1024,
        maxResultFiles: 200,
        maxLineHitsPerFile: 5,
        skipContentWhenNoText: true
    )
}

/// One file in the search result list.
struct SearchFileResult: Equatable, Sendable, Identifiable {
    let url: URL
    let relativePath: String
    let fileName: String
    let modificationDate: Date
    let lineHits: [SearchLineHit]
    let matchCount: Int
    let nameMatched: Bool
    let skippedContent: Bool

    var id: URL { url }
}

/// Aggregate of a pure multi-file search pass.
struct SearchRunResult: Equatable, Sendable {
    var files: [SearchFileResult]
    var skippedOversized: Int
    var truncated: Bool
    /// Set when `is:modified` was requested but git is unavailable.
    var emptyReason: String?
    var cancelled: Bool

    static let empty = SearchRunResult(
        files: [], skippedOversized: 0, truncated: false,
        emptyReason: nil, cancelled: false
    )
}

// MARK: - Case-insensitive contains (Cyrillic-safe, scalar fold)

/// Simple lowercase case-fold for one Unicode scalar, covering the alphabets
/// EditMD users actually search: ASCII, Latin-1 letters, and Russian Cyrillic
/// (incl. Ё). Every other scalar passes through unchanged — i.e. it is compared
/// case-sensitively.
///
/// Why not Foundation `range(of:options:.caseInsensitive)` (the v1 choice):
/// it folds every script but iterates grapheme clusters, which measured
/// 3–7 s for a whole-body scan of a 7k-file vault (50 MB). Folding scalar
/// values directly is ~200× faster and produced identical match counts against
/// Foundation across ASCII + Russian on that vault, including mixed case
/// (`Витамин` == `витамин`). The narrowed coverage is deliberate; if a broader
/// script ever needs folding, extend this table rather than reverting to the
/// grapheme path.
@inline(__always)
func searchFoldScalar(_ s: UInt32) -> UInt32 {
    if s >= 0x41 && s <= 0x5A { return s + 0x20 }              // A–Z
    if s >= 0xC0 && s <= 0xDE && s != 0xD7 { return s + 0x20 } // À–Þ (skip ×)
    if s >= 0x410 && s <= 0x42F { return s + 0x20 }            // А–Я
    if s >= 0x400 && s <= 0x40F { return s + 0x50 }            // Ѐ–Џ (incl. Ё)
    return s
}

/// Fold a whole string to lowercase scalar values, once. Callers that reuse a
/// haystack against several needles fold it a single time and pass the buffer
/// to the `Folded` primitives below.
func searchFolded(_ s: String) -> [UInt32] {
    var out = [UInt32]()
    out.reserveCapacity(s.unicodeScalars.count)
    for u in s.unicodeScalars { out.append(searchFoldScalar(u.value)) }
    return out
}

/// Case-insensitive contains over pre-folded scalar buffers.
func searchFoldedContains(_ hay: [UInt32], _ needle: [UInt32]) -> Bool {
    if needle.isEmpty { return true }
    guard needle.count <= hay.count else { return false }
    let n0 = needle[0]
    let last = hay.count - needle.count
    var i = 0
    while i <= last {
        if hay[i] == n0 {
            var j = 1
            while j < needle.count, hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

/// Count non-overlapping occurrences over pre-folded scalar buffers.
func searchFoldedOccurrenceCount(_ hay: [UInt32], _ needle: [UInt32]) -> Int {
    if needle.isEmpty || needle.count > hay.count { return 0 }
    var count = 0
    let n0 = needle[0]
    let last = hay.count - needle.count
    var i = 0
    while i <= last {
        if hay[i] == n0 {
            var j = 1
            while j < needle.count, hay[i + j] == needle[j] { j += 1 }
            if j == needle.count {
                count += 1
                i += needle.count      // non-overlapping
                continue
            }
        }
        i += 1
    }
    return count
}

/// Convenience wrappers folding both sides per call. Fine for one-shot checks
/// (short strings, tests); the hot multi-needle path in `searchContentMatches`
/// folds the haystack once and calls the `Folded` primitives directly.
func searchTextContains(_ haystack: String, _ needle: String) -> Bool {
    guard !needle.isEmpty else { return true }
    return searchFoldedContains(searchFolded(haystack), searchFolded(needle))
}

func searchTextOccurrenceCount(_ haystack: String, _ needle: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    return searchFoldedOccurrenceCount(searchFolded(haystack), searchFolded(needle))
}

// MARK: - Meta filter

/// Cheap pre-filter: path / type / tag / dates / git. No content I/O.
func searchFileMatchesMeta(
    _ query: SearchQuery,
    meta: SearchFileMeta,
    options: SearchMetaOptions = .markdownDefault
) -> Bool {
    // type
    let allowed: Set<String>
    if let ft = query.fileType {
        switch ft {
        case .allText:
            allowed = searchAllTextExtensions
        case .fileExtension(let ext):
            allowed = [ext.lowercased()]
        }
    } else {
        allowed = options.defaultExtensions
    }
    guard allowed.contains(meta.pathExtension.lowercased()) else { return false }

    // path: relative path equals prefix or starts with `prefix/`
    if let prefix = query.pathPrefix {
        if !relativePath(meta.relativePath, hasPrefix: prefix) {
            return false
        }
    }

    // tag: AND
    if !query.tags.isEmpty {
        let fileTags = Set(meta.tags.map { $0.lowercased() })
        for t in query.tags {
            if !fileTags.contains(t.lowercased()) { return false }
        }
    }

    // is:modified
    if query.isModified {
        if !options.gitAvailable { return false }
        if !meta.isGitModified { return false }
    }

    // dates (inclusive day bounds — see parseSearchDate / searchDateEndExclusive)
    if let after = query.afterDate {
        if meta.modificationDate < after { return false }
    }
    if let before = query.beforeDate {
        let end = searchDateEndExclusive(before)
        if meta.modificationDate >= end { return false }
    }

    return true
}

/// `path:` match: relative path equals prefix or starts with `prefix/`.
func relativePath(_ relative: String, hasPrefix prefix: String) -> Bool {
    var rel = relative
    var pref = prefix
    while rel.hasPrefix("./") { rel = String(rel.dropFirst(2)) }
    while rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
    while pref.hasPrefix("./") { pref = String(pref.dropFirst(2)) }
    while pref.hasPrefix("/") { pref = String(pref.dropFirst()) }
    let r = rel.lowercased()
    let p = pref.lowercased()
    return r == p || r.hasPrefix(p + "/")
}

/// Extensions admitted by `type:*` (text-ish; not binaries).
let searchAllTextExtensions: Set<String> = [
    "md", "markdown", "mdown", "mkd", "txt", "text", "csv", "tsv",
    "json", "yaml", "yml", "toml", "xml", "html", "htm", "css", "scss",
    "js", "ts", "jsx", "tsx", "swift", "m", "mm", "h", "c", "cpp", "hpp",
    "py", "rb", "go", "rs", "sh", "zsh", "bash", "fish", "plist",
    "log", "ini", "conf", "cfg", "env", "rtf", "tex", "bib"
]

// MARK: - Content match

/// AND-match tokens/phrases in body and/or file name; collect line hits.
func searchContentMatches(
    _ query: SearchQuery,
    text: String,
    fileName: String,
    maxLineHits: Int = 5
) -> SearchContentMatch {
    let needles = query.tokens + query.phrases
    if needles.isEmpty {
        // Structural-only query: content always "matches".
        return SearchContentMatch(
            matched: true, lineHits: [], matchCount: 0, nameMatched: false
        )
    }

    // Fold each side once and reuse across needles: the whole-body fold is the
    // dominant cost, so folding `text` a single time (not once per needle) is
    // what keeps a vault-wide search interactive.
    let foldedNeedles = needles.map(searchFolded)
    let foldedName = searchFolded(fileName)
    let foldedBody = searchFolded(text)
    let nameOK = foldedNeedles.allSatisfy { searchFoldedContains(foldedName, $0) }
    let bodyOK = foldedNeedles.allSatisfy { searchFoldedContains(foldedBody, $0) }
    let matched = nameOK || bodyOK
    guard matched else {
        return SearchContentMatch(
            matched: false, lineHits: [], matchCount: 0, nameMatched: false
        )
    }

    // Line hits: lines that contain at least one needle (body only).
    var hits: [SearchLineHit] = []
    var matchCount = 0
    if bodyOK || !nameOK {
        // Still scan lines for highlight when body has any needle occurrence.
        let ns = text as NSString
        let full = ns.length
        var lineStart = 0
        var lineNumber = 1
        while lineStart <= full {
            var lineEnd = lineStart
            while lineEnd < full, ns.character(at: lineEnd) != 0x0A {
                lineEnd += 1
            }
            let len = lineEnd - lineStart
            var line = ns.substring(with: NSRange(location: lineStart, length: len))
            if line.hasSuffix("\r") { line = String(line.dropLast()) }

            let foldedLine = searchFolded(line)
            var lineOcc = 0
            for nf in foldedNeedles {
                lineOcc += searchFoldedOccurrenceCount(foldedLine, nf)
            }
            if lineOcc > 0 {
                matchCount += lineOcc
                if hits.count < maxLineHits {
                    hits.append(SearchLineHit(
                        lineNumber: lineNumber,
                        lineText: line,
                        utf16Offset: lineStart
                    ))
                }
            }

            if lineEnd >= full { break }
            lineStart = lineEnd + 1
            lineNumber += 1
        }
    }

    // Name-only match still counts for sorting.
    if nameOK {
        for nf in foldedNeedles {
            matchCount += searchFoldedOccurrenceCount(foldedName, nf)
        }
    }

    return SearchContentMatch(
        matched: true,
        lineHits: hits,
        matchCount: max(matchCount, nameOK && hits.isEmpty ? 1 : matchCount),
        nameMatched: nameOK
    )
}

// MARK: - Multi-file pure runner

/// Pure multi-file search. `contentProvider` returns UTF-8 text or nil on error.
/// Oversized files are counted when `meta.fileSize > options.maxFileBytes`
/// (provider is not called). Cancellation is cooperative via `isCancelled`.
func runWorkspaceSearch(
    query: SearchQuery,
    files: [SearchFileMeta],
    contentProvider: (SearchFileMeta) -> String?,
    options: SearchRunOptions = .default,
    isCancelled: () -> Bool = { false }
) -> SearchRunResult {
    if query.isEmpty {
        return .empty
    }
    if query.isModified && !options.meta.gitAvailable {
        return SearchRunResult(
            files: [],
            skippedOversized: 0,
            truncated: false,
            emptyReason: String(localized: "is:modified — the workspace is not under git or status is unavailable"),
            cancelled: false
        )
    }

    var results: [SearchFileResult] = []
    var skipped = 0
    var truncated = false

    for meta in files {
        if isCancelled() {
            return SearchRunResult(
                files: results, skippedOversized: skipped, truncated: truncated,
                emptyReason: nil, cancelled: true
            )
        }
        guard searchFileMatchesMeta(query, meta: meta, options: options.meta) else {
            continue
        }

        if meta.fileSize > options.maxFileBytes {
            skipped += 1
            continue
        }

        let contentMatch: SearchContentMatch
        let skippedContent: Bool
        if !query.hasTextConstraints, options.skipContentWhenNoText {
            contentMatch = SearchContentMatch(
                matched: true, lineHits: [], matchCount: 0, nameMatched: false
            )
            skippedContent = true
        } else {
            guard let text = contentProvider(meta) else { continue }
            contentMatch = searchContentMatches(
                query, text: text, fileName: meta.fileName,
                maxLineHits: options.maxLineHitsPerFile
            )
            skippedContent = false
            guard contentMatch.matched else { continue }
        }

        results.append(SearchFileResult(
            url: meta.url,
            relativePath: meta.relativePath,
            fileName: meta.fileName,
            modificationDate: meta.modificationDate,
            lineHits: contentMatch.lineHits,
            matchCount: contentMatch.matchCount,
            nameMatched: contentMatch.nameMatched,
            skippedContent: skippedContent
        ))

        if results.count >= options.maxResultFiles {
            truncated = true
            break
        }
    }

    return SearchRunResult(
        files: results,
        skippedOversized: skipped,
        truncated: truncated,
        emptyReason: nil,
        cancelled: false
    )
}

/// Sort results: by match count desc then mtime desc; or by mtime only.
func sortSearchResults(_ files: [SearchFileResult], byDate: Bool) -> [SearchFileResult] {
    if byDate {
        return files.sorted {
            if $0.modificationDate != $1.modificationDate {
                return $0.modificationDate > $1.modificationDate
            }
            return $0.relativePath.localizedStandardCompare($1.relativePath)
                == .orderedAscending
        }
    }
    return files.sorted {
        if $0.matchCount != $1.matchCount {
            return $0.matchCount > $1.matchCount
        }
        if $0.modificationDate != $1.modificationDate {
            return $0.modificationDate > $1.modificationDate
        }
        return $0.relativePath.localizedStandardCompare($1.relativePath)
            == .orderedAscending
    }
}

// MARK: - Content cache (in-memory LRU by total bytes)

/// Cache of file contents keyed by path + mtime + size. Cap ~64 MiB.
final class SearchContentCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let path: String
        let mtime: TimeInterval
        let size: Int64
    }

    private let lock = NSLock()
    private var map: [Key: String] = [:]
    private var order: [Key] = []
    private var totalBytes = 0
    let maxBytes: Int

    init(maxBytes: Int = 64 * 1024 * 1024) {
        self.maxBytes = maxBytes
    }

    func value(for key: Key) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let v = map[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return v
    }

    func insert(_ text: String, for key: Key) {
        let bytes = text.utf8.count
        lock.lock()
        defer { lock.unlock() }
        if let old = map[key] {
            totalBytes -= old.utf8.count
            map[key] = text
            totalBytes += bytes
            if let idx = order.firstIndex(of: key) {
                order.remove(at: idx)
            }
            order.append(key)
        } else {
            map[key] = text
            order.append(key)
            totalBytes += bytes
        }
        while totalBytes > maxBytes, let victim = order.first {
            order.removeFirst()
            if let old = map.removeValue(forKey: victim) {
                totalBytes -= old.utf8.count
            }
        }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return map.count
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll()
        order.removeAll()
        totalBytes = 0
    }
}

// MARK: - Disk helpers (off-main)

/// Enumerate candidate files under workspace roots (skips hidden / packages).
func collectSearchFileMetas(
    roots: [URL],
    tagIndex: [String: [URL]] = [:],
    modifiedPaths: Set<String> = [],
    isCancelled: () -> Bool = { false }
) -> [SearchFileMeta] {
    // Invert tag index: path → tags
    var tagsByPath: [String: [String]] = [:]
    for (tag, urls) in tagIndex {
        for u in urls {
            tagsByPath[u.standardizedFileURL.path, default: []].append(tag)
        }
    }

    var result: [SearchFileMeta] = []
    let fm = FileManager.default
    let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
    ]

    func walk(_ dir: URL, root: URL) {
        if isCancelled() { return }
        let items = (try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        for url in items {
            if isCancelled() { return }
            let vals = try? url.resourceValues(forKeys: keys)
            let isDir = vals?.isDirectory ?? false
            let isPackage = vals?.isPackage ?? false
            if isDir && !isPackage {
                walk(url, root: root)
                continue
            }
            let std = url.standardizedFileURL
            let rootPath = root.standardizedFileURL.path
            var rel = std.path
            if rel.hasPrefix(rootPath) {
                rel = String(rel.dropFirst(rootPath.count))
                if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
            } else {
                rel = std.lastPathComponent
            }
            let size = Int64(vals?.fileSize ?? 0)
            let mtime = vals?.contentModificationDate ?? .distantPast
            let ext = std.pathExtension.lowercased()
            result.append(SearchFileMeta(
                url: std,
                relativePath: rel,
                fileName: std.lastPathComponent,
                pathExtension: ext,
                modificationDate: mtime,
                fileSize: size,
                tags: tagsByPath[std.path] ?? [],
                isGitModified: modifiedPaths.contains(std.path)
            ))
        }
    }

    for root in roots {
        walk(root.standardizedFileURL, root: root.standardizedFileURL)
    }
    return result
}

/// Read UTF-8 (lossy fallback) file contents, optionally via cache.
func loadSearchFileContent(
    meta: SearchFileMeta,
    cache: SearchContentCache?,
    maxBytes: Int64
) -> String? {
    if meta.fileSize > maxBytes { return nil }
    let key = SearchContentCache.Key(
        path: meta.url.path,
        mtime: meta.modificationDate.timeIntervalSince1970,
        size: meta.fileSize
    )
    if let cache, let hit = cache.value(for: key) {
        return hit
    }
    guard let data = try? Data(contentsOf: meta.url, options: [.mappedIfSafe]) else {
        return nil
    }
    // Lossy decode so a truncated multi-byte sequence still yields text.
    let text = String(decoding: data, as: UTF8.self)
    cache?.insert(text, for: key)
    return text
}
