import Foundation

// MARK: - Git file history (plan 05)

/// One commit that touched a file (`git log --follow`).
struct GitFileHistoryEntry: Equatable, Sendable, Identifiable {
    /// Full SHA.
    let hash: String
    let shortHash: String
    /// Author name only (no email).
    let author: String
    let date: Date
    /// First line of the commit message.
    let subject: String

    var id: String { hash }
}

/// Pure parser for `git log` fixture output. Format fields are NUL-separated:
/// `%H %h %an %aI %s` then a final NUL; records follow each other.
func parseGitFileHistoryLog(_ output: String, maxCount: Int = 50) -> [GitFileHistoryEntry] {
    guard !output.isEmpty else { return [] }
    // Split on NUL; trailing empty from final %x00 is fine.
    let parts = output.split(separator: "\0", omittingEmptySubsequences: false)
        .map { String($0).trimmingCharacters(in: .newlines) }
    var result: [GitFileHistoryEntry] = []
    result.reserveCapacity(min(maxCount, parts.count / 5 + 1))
    var i = 0
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let isoBasic = ISO8601DateFormatter()
    isoBasic.formatOptions = [.withInternetDateTime]

    while i + 4 < parts.count, result.count < maxCount {
        let hash = parts[i].trimmingCharacters(in: .whitespacesAndNewlines)
        let shortHash = parts[i + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        let author = parts[i + 2].trimmingCharacters(in: .whitespacesAndNewlines)
        let dateRaw = parts[i + 3].trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = parts[i + 4]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            // Subject must stay single-line for the list row.
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        i += 5
        // Skip blank padding between records.
        while i < parts.count, parts[i].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            i += 1
        }
        guard !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else { continue }
        let date = iso.date(from: dateRaw) ?? isoBasic.date(from: dateRaw) ?? Date.distantPast
        result.append(GitFileHistoryEntry(
            hash: hash,
            shortHash: shortHash.isEmpty ? String(hash.prefix(7)) : shortHash,
            author: author,
            date: date,
            subject: subject
        ))
    }
    return result
}

extension GitCLI {
    /// Bounded `git log --follow` for a single file. Returns empty when not in a repo.
    /// Must be called off the main actor (Process).
    static func fileHistory(of file: URL, maxCount: Int = 50) -> [GitFileHistoryEntry] {
        guard let root = repositoryRoot(containing: file) else { return [] }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return [] }
        // %x00 field separators; subject may contain | or newlines in rare cases —
        // we take only the first line of %s.
        let format = "%H%x00%h%x00%an%x00%aI%x00%s%x00"
        guard let out = run(in: root, arguments: [
            "log", "--follow", "--max-count=\(maxCount)",
            "--format=\(format)", "--", rel
        ]) else { return [] }
        return parseGitFileHistoryLog(out, maxCount: maxCount)
    }

    /// Blob text at `rev:relpath` (`git show`). Empty when missing/binary fail.
    static func fileContents(of file: URL, at revision: String) -> String? {
        guard let root = repositoryRoot(containing: file) else { return nil }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty, !revision.isEmpty else { return nil }
        // `git show` may fail if --follow renamed the path; try current rel first.
        if let out = run(in: root, arguments: ["show", "\(revision):\(rel)"]) {
            return out
        }
        return nil
    }

    /// Current HEAD full SHA for a repo containing `file`, or nil.
    static func headHash(containing file: URL) -> String? {
        guard let root = repositoryRoot(containing: file) else { return nil }
        let hash = run(in: root, arguments: ["rev-parse", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash, !hash.isEmpty, hash.allSatisfy(\.isHexDigit) else { return nil }
        return hash
    }
}

// MARK: - Cache

/// Caches git file history by (file path, HEAD). Invalidated when HEAD changes
/// or when `GitCommitWatcher` posts repository change.
@MainActor
final class FileHistoryGitCache: ObservableObject {
    static let shared = FileHistoryGitCache()

    private struct Key: Hashable {
        let path: String
        let head: String
    }

    private var cache: [Key: [GitFileHistoryEntry]] = [:]
    private var loading: Set<String> = []

    private init() {
        NotificationCenter.default.addObserver(
            forName: .gitRepositoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.invalidateAll() }
        }
        NotificationCenter.default.addObserver(
            forName: .lineChangeMarksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Commit watcher posts this with file URL as object when hash changes.
            guard let url = note.object as? URL else { return }
            Task { @MainActor in self?.invalidate(url: url) }
        }
    }

    func invalidateAll() {
        cache.removeAll()
        objectWillChange.send()
    }

    func invalidate(url: URL) {
        let path = url.standardizedFileURL.path
        cache = cache.filter { $0.key.path != path }
        objectWillChange.send()
    }

    /// Cached list if present; otherwise kicks off a background load.
    func history(for url: URL?) -> [GitFileHistoryEntry]? {
        guard let url else { return nil }
        let path = url.standardizedFileURL.path
        // If we have any entry for this path, return it (head may be stale until
        // refresh completes). Prefer exact HEAD match when known.
        if let head = cachedHeadHint(for: path),
           let hit = cache[Key(path: path, head: head)] {
            return hit
        }
        // Any cached list for path.
        if let any = cache.first(where: { $0.key.path == path }) {
            return any.value
        }
        return nil
    }

    private func cachedHeadHint(for path: String) -> String? {
        cache.keys.first(where: { $0.path == path })?.head
    }

    func ensureLoaded(url: URL?) {
        guard let url else { return }
        let path = url.standardizedFileURL.path
        guard !loading.contains(path) else { return }
        loading.insert(path)
        let file = url.standardizedFileURL
        Task.detached(priority: .userInitiated) {
            let head = GitCLI.headHash(containing: file) ?? ""
            let entries = GitCLI.fileHistory(of: file)
            await MainActor.run {
                self.loading.remove(path)
                if !head.isEmpty {
                    self.cache[Key(path: path, head: head)] = entries
                } else {
                    // Not in repo — cache empty under sentinel.
                    self.cache[Key(path: path, head: "none")] = []
                }
                self.objectWillChange.send()
            }
        }
    }

    var isLoading: Bool { !loading.isEmpty }

    func isLoading(url: URL?) -> Bool {
        guard let url else { return false }
        return loading.contains(url.standardizedFileURL.path)
    }
}
