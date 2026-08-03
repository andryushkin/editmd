import Foundation
import CryptoKit
import os.log

// MARK: - Types

/// One local snapshot of a saved document (content-addressed).
struct FileRevisionEntry: Codable, Equatable, Sendable, Identifiable {
    /// SHA-256 hex of UTF-8 content bytes.
    let contentSHA: String
    let savedAt: Date
    let byteSize: Int
    var label: String?

    var id: String { "\(contentSHA)-\(savedAt.timeIntervalSince1970)" }
}

/// On-disk manifest for one file's revision directory.
struct FileRevisionManifest: Codable, Equatable, Sendable {
    /// Append-only; newest entries are at the end.
    var entries: [FileRevisionEntry]
}

// MARK: - Path key

/// Content-addressed directory name for a document path.
/// v1: rename/move does NOT migrate history (path is the key).
func fileRevisionPathKey(for url: URL) -> String {
    let path = url.standardizedFileURL.path
    let digest = SHA256.hash(data: Data(path.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

func fileRevisionContentSHA(_ content: String) -> String {
    let digest = SHA256.hash(data: Data(content.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Store

/// Content-addressed local revision store under Application Support.
///
/// Layout:
/// ```
/// revisions/<sha256(canonical-path)>/
///   manifest.json
///   objects/<contentSHA>
/// ```
///
/// Thread-safe. Disk I/O must run off the main actor in production paths
/// (flush / close); tests may call synchronously with a temporary root.
final class FileRevisionStore: @unchecked Sendable {
    static let shared = FileRevisionStore()

    /// Max kept snapshots per file (oldest pruned first).
    static let maxRevisionsPerFile = 100
    /// Skip storing bodies larger than this (UTF-8 byte count).
    static let maxContentBytes = 4 * 1024 * 1024
    /// Debounce window: at most one revision per file in this interval unless `force`.
    static let debounceInterval: TimeInterval = 5 * 60

    private let rootURL: URL
    private let fm = FileManager.default
    private let lock = NSLock()
    /// pathKey → last successful record time (for debounce).
    private var lastRecordAt: [String: Date] = [:]
    private let log = Logger(subsystem: "andryushkin.EditMD", category: "FileRevisionStore")

    /// - Parameter rootURL: Override store root (tests). Nil → Application Support.
    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = fm.urls(for: .applicationSupportDirectory,
                               in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.rootURL = base
                .appendingPathComponent("EditMD", isDirectory: true)
                .appendingPathComponent("revisions", isDirectory: true)
        }
    }

    var storeRoot: URL { rootURL }

    // MARK: Public API

    /// Records a revision if allowed by size, debounce, and content dedup.
    /// - Parameters:
    ///   - force: Bypass debounce (document close / explicit save-as snapshot).
    ///   - now: Injectable clock for tests.
    /// - Returns: The entry written, or nil if skipped / failed.
    @discardableResult
    func record(url: URL, content: String, force: Bool = false,
                now: Date = Date()) -> FileRevisionEntry? {
        // Untitled / no real path — never store (privacy).
        guard url.isFileURL, !url.path.isEmpty else { return nil }
        let data = Data(content.utf8)
        guard data.count <= Self.maxContentBytes else { return nil }

        let pathKey = fileRevisionPathKey(for: url)
        let contentSHA = fileRevisionContentSHA(content)

        lock.lock()
        defer { lock.unlock() }

        if !force, let last = lastRecordAt[pathKey],
           now.timeIntervalSince(last) < Self.debounceInterval {
            return nil
        }

        let dir = fileDir(pathKey: pathKey)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(at: objectsDir(pathKey: pathKey),
                                   withIntermediateDirectories: true)
        } catch {
            log.error("create revision dir failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        var manifest = loadManifestLocked(pathKey: pathKey)
        // Dedup: identical content as the newest entry → no new row.
        if let last = manifest.entries.last, last.contentSHA == contentSHA {
            lastRecordAt[pathKey] = now
            return nil
        }

        let objectURL = objectsDir(pathKey: pathKey)
            .appendingPathComponent(contentSHA, isDirectory: false)
        if !fm.fileExists(atPath: objectURL.path) {
            do {
                try data.write(to: objectURL, options: .atomic)
            } catch {
                log.error("write revision object failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        let entry = FileRevisionEntry(contentSHA: contentSHA, savedAt: now,
                                      byteSize: data.count, label: nil)
        manifest.entries.append(entry)
        pruneLocked(pathKey: pathKey, manifest: &manifest)
        do {
            try writeManifestLocked(pathKey: pathKey, manifest: manifest)
        } catch {
            log.error("write manifest failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        lastRecordAt[pathKey] = now
        return entry
    }

    /// Newest-first list of revisions for `url`.
    func revisions(for url: URL) -> [FileRevisionEntry] {
        let pathKey = fileRevisionPathKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        return loadManifestLocked(pathKey: pathKey).entries.reversed()
    }

    /// UTF-8 content of a stored object, or nil if missing/unreadable.
    func content(for url: URL, contentSHA: String) -> String? {
        let pathKey = fileRevisionPathKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        let objectURL = objectsDir(pathKey: pathKey)
            .appendingPathComponent(contentSHA, isDirectory: false)
        guard let data = try? Data(contentsOf: objectURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Test helper: reset in-memory debounce clock for a path.
    func resetDebounce(for url: URL) {
        let pathKey = fileRevisionPathKey(for: url)
        lock.lock()
        lastRecordAt[pathKey] = nil
        lock.unlock()
    }

    // MARK: Internals

    private func fileDir(pathKey: String) -> URL {
        rootURL.appendingPathComponent(pathKey, isDirectory: true)
    }

    private func objectsDir(pathKey: String) -> URL {
        fileDir(pathKey: pathKey).appendingPathComponent("objects", isDirectory: true)
    }

    private func manifestURL(pathKey: String) -> URL {
        fileDir(pathKey: pathKey).appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func loadManifestLocked(pathKey: String) -> FileRevisionManifest {
        let url = manifestURL(pathKey: pathKey)
        guard fm.fileExists(atPath: url.path) else {
            return FileRevisionManifest(entries: [])
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(FileRevisionManifest.self, from: data)
        } catch {
            log.error("corrupt revision manifest, recreating: \(error.localizedDescription, privacy: .public)")
            // Reset only the index; never delete objects on corruption.
            return FileRevisionManifest(entries: [])
        }
    }

    private func writeManifestLocked(pathKey: String,
                                     manifest: FileRevisionManifest) throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: manifestURL(pathKey: pathKey), options: .atomic)
    }

    /// Keep at most `maxRevisionsPerFile`; drop oldest entries and orphan objects.
    private func pruneLocked(pathKey: String, manifest: inout FileRevisionManifest) {
        if manifest.entries.count > Self.maxRevisionsPerFile {
            let drop = manifest.entries.count - Self.maxRevisionsPerFile
            manifest.entries.removeFirst(drop)
        }
        let live = Set(manifest.entries.map(\.contentSHA))
        let objects = objectsDir(pathKey: pathKey)
        guard let names = try? fm.contentsOfDirectory(atPath: objects.path) else { return }
        for name in names where !live.contains(name) {
            try? fm.removeItem(at: objects.appendingPathComponent(name))
        }
    }
}

// MARK: - Main-actor façade (flush / close)

extension FileRevisionStore {
    /// Fire-and-forget record from DocumentRegistry flush (off-main).
    func notePersistedAsync(url: URL, content: String, force: Bool = false) {
        let store = self
        let u = url.standardizedFileURL
        let c = content
        Task.detached(priority: .utility) {
            _ = store.record(url: u, content: c, force: force)
        }
    }
}
