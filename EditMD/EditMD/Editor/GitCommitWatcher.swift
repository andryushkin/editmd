import Foundation
import AppKit

// MARK: - Git CLI (read-only)

/// Thin wrapper around `/usr/bin/git` for path-scoped read queries.
/// No network, no write — stage 3 only needs “last commit that touched this file”.
enum GitCLI {
    /// Absolute path to git, or nil if missing.
    static var gitExecutable: URL? {
        let candidates = [
            "/usr/bin/git",
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Nearest git work-tree root containing `file`, or nil.
    static func repositoryRoot(containing file: URL) -> URL? {
        let dir = file.hasDirectoryPath ? file : file.deletingLastPathComponent()
        return run(in: dir, arguments: ["rev-parse", "--show-toplevel"])
            .flatMap { path -> URL? in
                let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL
            }
    }

    /// `git log -1 --format=%H -- <relative path>` — empty/nil if untracked or no history.
    static func lastCommitHash(touching file: URL) -> String? {
        guard let root = repositoryRoot(containing: file) else { return nil }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return nil }
        let hash = run(in: root, arguments: ["log", "-1", "--format=%H", "--", rel])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let hash, !hash.isEmpty, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash
    }

    /// Path of `file` relative to `root` (POSIX, no leading slash).
    static func relativePath(of file: URL, to root: URL) -> String {
        let filePath = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath) else { return file.lastPathComponent }
        var rel = String(filePath.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    /// Run git in `directory`; returns stdout on exit 0, else nil.
    static func run(in directory: URL, arguments: [String]) -> String? {
        guard let git = gitExecutable else { return nil }
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Commit watcher → clear session dirty marks

extension Notification.Name {
    /// Posted when session dirty-line marks may have changed (gutter redraw).
    static let lineChangeMarksDidChange = Notification.Name("editMD.lineChangeMarksDidChange")
}

/// Polls git for open files: if the last commit that touched a path changed,
/// clears `LineChangeTracker` marks for that file (any commit — Terminal or app).
@MainActor
final class GitCommitWatcher {
    static let shared = GitCommitWatcher()

    /// Last seen `git log -1 --format=%H -- path` per file.
    private var lastHash: [URL: String] = [:]
    private var checkTask: Task<Void, Never>?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleCheck(reason: "becomeActive") }
        }
    }

    /// Seed / refresh hash when a file is opened or baseline resets.
    func noteOpened(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        Task.detached(priority: .utility) {
            let hash = GitCLI.lastCommitHash(touching: key)
            await MainActor.run {
                if let hash {
                    self.lastHash[key] = hash
                } else {
                    self.lastHash.removeValue(forKey: key)
                }
            }
        }
    }

    func forget(url: URL?) {
        guard let url else { return }
        lastHash.removeValue(forKey: url.standardizedFileURL)
    }

    /// Coalesced re-check of all tracked files (open baselines + known hashes).
    func scheduleCheck(reason: String = "") {
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self.checkAll()
        }
    }

    /// Immediate check for one path (e.g. after save).
    func check(url: URL?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        Task.detached(priority: .utility) {
            let hash = GitCLI.lastCommitHash(touching: key)
            await MainActor.run {
                self.applyHash(hash, for: key)
            }
        }
    }

    private func checkAll() async {
        let urls = Set(LineChangeTracker.shared.trackedURLs() + Array(lastHash.keys))
        guard !urls.isEmpty else { return }
        // Snapshot off main actor.
        let pairs: [(URL, String?)] = await Task.detached(priority: .utility) {
            urls.map { ($0, GitCLI.lastCommitHash(touching: $0)) }
        }.value
        for (url, hash) in pairs {
            applyHash(hash, for: url)
        }
    }

    private func applyHash(_ hash: String?, for key: URL) {
        let previous = lastHash[key]
        if let hash {
            lastHash[key] = hash
            // Clear marks only when we already had a hash and it changed
            // (a new commit landed). First sight only seeds.
            if let previous, previous != hash {
                LineChangeTracker.shared.clearMarks(url: key)
                // Re-baseline so dirty is empty against current buffer too.
                // Keep content baseline — only marks clear per product decision.
                NotificationCenter.default.post(name: .lineChangeMarksDidChange, object: key)
            }
        }
        // Untracked / no repo: leave lastHash as-is or remove if vanished.
        if hash == nil, previous != nil {
            // Repo gone or file untracked after commit-delete — just drop seed.
            lastHash.removeValue(forKey: key)
        }
    }
}
