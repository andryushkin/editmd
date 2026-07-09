import Foundation
import AppKit

// MARK: - Git CLI

/// User-visible failure from a git write op (stage / commit / push).
struct GitError: Error, Equatable, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Thin wrapper around `/usr/bin/git` for path-scoped queries and write ops
/// (stage / commit this file / push). Network only on explicit `push`.
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

    // MARK: Read

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

    /// 1-based **new-side** line numbers touched in the worktree/index vs HEAD
    /// for this path (`git diff -U0 HEAD -- path`). Empty if clean / untracked /
    /// binary / unavailable. Used only for suggested commit messages.
    static func changedLineNumbers(of file: URL) -> Set<Int> {
        guard let root = repositoryRoot(containing: file) else { return [] }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return [] }
        // Include staged + unstaged against HEAD. `-U0` → hunk headers only.
        guard let out = run(in: root, arguments: ["diff", "-U0", "HEAD", "--", rel]) else {
            return []
        }
        return parseUnifiedDiffNewLines(out)
    }

    /// Parses `@@ -old[,n] +new[,n] @@` headers → set of new-file line numbers.
    static func parseUnifiedDiffNewLines(_ diff: String) -> Set<Int> {
        var result = Set<Int>()
        // +start or +start,count  (count 0 = pure deletion — no new lines)
        let pattern = #"@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = diff as NSString
        let full = NSRange(location: 0, length: ns.length)
        re.enumerateMatches(in: diff, options: [], range: full) { match, _, _ in
            guard let match, match.numberOfRanges >= 2 else { return }
            let startStr = ns.substring(with: match.range(at: 1))
            guard let start = Int(startStr), start > 0 else { return }
            var count = 1
            if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound {
                let cStr = ns.substring(with: match.range(at: 2))
                count = Int(cStr) ?? 1
            }
            guard count > 0 else { return }
            for i in 0..<count {
                result.insert(start + i)
            }
        }
        return result
    }

    /// Working-tree / index status for a single path (`git status --porcelain`).
    enum PathStatus: Equatable, Sendable {
        case notInRepo
        /// Tracked and matches HEAD (index + worktree clean for this path).
        case clean
        /// Tracked; worktree and/or index differ from HEAD.
        case modified
        /// Not in the index (new file).
        case untracked
        /// Tracked but missing on disk.
        case deleted
    }

    static func pathStatus(of file: URL) -> PathStatus {
        guard let root = repositoryRoot(containing: file) else { return .notInRepo }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return .notInRepo }
        // `-uall` so untracked files appear; pathspec limits to this file.
        guard let out = run(in: root, arguments: ["status", "--porcelain=v1", "-uall", "--", rel]) else {
            return .notInRepo
        }
        let line = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .clean }
        // Porcelain: XY PATH  or  ?? PATH  or  R  old -> new
        let code: String
        if line.hasPrefix("??") {
            return .untracked
        }
        if line.count >= 2 {
            code = String(line.prefix(2))
        } else {
            return .modified
        }
        if code.contains("D") { return .deleted }
        return .modified
    }

    /// Current branch short name, or nil (detached / no repo).
    static func currentBranch(containing file: URL) -> String? {
        guard let root = repositoryRoot(containing: file) else { return nil }
        let name = run(in: root, arguments: ["branch", "--show-current"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }

    /// Commits on this branch not yet pushed (`ahead`), and remote not yet pulled (`behind`).
    /// Nil if no upstream is configured.
    static func aheadBehind(containing file: URL) -> (ahead: Int, behind: Int)? {
        guard let root = repositoryRoot(containing: file) else { return nil }
        // Fails when upstream is missing.
        guard let out = run(in: root, arguments: [
            "rev-list", "--left-right", "--count", "@{upstream}...HEAD"
        ]) else { return nil }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        guard parts.count >= 2,
              let behind = Int(parts[0]),
              let ahead = Int(parts[1]) else { return nil }
        return (ahead, behind)
    }

    // MARK: Write (stage 4 / 5)

    /// `git add -- <path>` for this file only.
    static func stage(file: URL) -> Result<Void, GitError> {
        guard let root = repositoryRoot(containing: file) else {
            return .failure(GitError("Not inside a git repository."))
        }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return .failure(GitError("Invalid path.")) }
        let result = runDetailed(in: root, arguments: ["add", "--", rel])
        guard let result else { return .failure(GitError("git is not installed.")) }
        guard result.succeeded else {
            return .failure(GitError(result.combinedMessage.isEmpty ? "git add failed." : result.combinedMessage))
        }
        return .success(())
    }

    /// Stage this file and create a commit that includes only it.
    /// Caller must save the buffer to disk first.
    /// - Returns: new commit hash (full SHA) on success.
    static func commit(file: URL, message: String) -> Result<String, GitError> {
        let msg = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !msg.isEmpty else { return .failure(GitError("Commit message is empty.")) }
        guard let root = repositoryRoot(containing: file) else {
            return .failure(GitError("Not inside a git repository."))
        }
        let rel = relativePath(of: file, to: root)
        guard !rel.isEmpty else { return .failure(GitError("Invalid path.")) }

        switch stage(file: file) {
        case .failure(let err): return .failure(err)
        case .success: break
        }

        // Only commit if something is staged for this path.
        let staged = run(in: root, arguments: ["diff", "--cached", "--name-only", "--", rel])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if staged.isEmpty {
            // Maybe already committed / no changes vs HEAD.
            let status = pathStatus(of: file)
            if status == .clean {
                return .failure(GitError("Nothing to commit for this file."))
            }
            return .failure(GitError("Nothing staged for this file."))
        }

        // `-m` + pathspec: commits only the given paths (requires them staged).
        let result = runDetailed(in: root, arguments: ["commit", "-m", msg, "--", rel])
        guard let result else { return .failure(GitError("git is not installed.")) }
        guard result.succeeded else {
            return .failure(GitError(result.combinedMessage.isEmpty ? "git commit failed." : result.combinedMessage))
        }
        if let hash = lastCommitHash(touching: file) {
            return .success(hash)
        }
        // Commit succeeded but log is empty (unlikely) — still OK.
        return .success(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `git push` for the remote tracking branch of the repo containing `file`.
    /// Uses the system credential helper (Keychain / ssh-agent); no passwords in-app.
    static func push(containing file: URL) -> Result<String, GitError> {
        guard let root = repositoryRoot(containing: file) else {
            return .failure(GitError("Not inside a git repository."))
        }
        let result = runDetailed(in: root, arguments: ["push"])
        guard let result else { return .failure(GitError("git is not installed.")) }
        guard result.succeeded else {
            return .failure(GitError(result.combinedMessage.isEmpty ? "git push failed." : result.combinedMessage))
        }
        let msg = result.combinedMessage
        return .success(msg.isEmpty ? "Push completed." : msg)
    }

    // MARK: Process

    struct RunResult: Equatable, Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { exitCode == 0 }
        var combinedMessage: String {
            let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !err.isEmpty { return err }
            return out
        }
    }

    /// Run git in `directory`; returns stdout on exit 0, else nil.
    static func run(in directory: URL, arguments: [String]) -> String? {
        guard let result = runDetailed(in: directory, arguments: arguments), result.succeeded else {
            return nil
        }
        return result.stdout
    }

    /// Run git; always returns stdout/stderr/exit when the process starts.
    static func runDetailed(in directory: URL, arguments: [String]) -> RunResult? {
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
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        return RunResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - Commit watcher → clear dirty marks

extension Notification.Name {
    /// Posted when session dirty-line marks may have changed (gutter redraw).
    static let lineChangeMarksDidChange = Notification.Name("editMD.lineChangeMarksDidChange")
    /// Posted after an in-app git commit or push so status-bar can refresh.
    static let gitRepositoryDidChange = Notification.Name("editMD.gitRepositoryDidChange")
}

/// Polls git for open files: if the last commit that touched a path changed,
/// re-anchors session dirty marks (any commit — Terminal or app).
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

    /// Force-set the known hash after an in-app commit (avoids a race before log updates).
    func noteCommitted(url: URL?, hash: String?) {
        guard let url else { return }
        let key = url.standardizedFileURL
        if let hash, !hash.isEmpty {
            lastHash[key] = hash
        } else {
            noteOpened(url: key)
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
            // Clear / re-anchor only when we already had a hash and it changed
            // (a new commit landed). First sight only seeds.
            if let previous, previous != hash {
                reanchorSessionMarks(for: key)
                NotificationCenter.default.post(name: .lineChangeMarksDidChange, object: key)
                NotificationCenter.default.post(name: .gitRepositoryDidChange, object: key)
            }
        }
        // Untracked / no repo: leave lastHash as-is or remove if vanished.
        if hash == nil, previous != nil {
            lastHash.removeValue(forKey: key)
        }
    }

    /// After a commit that touched `key`, session dirty marks should not return
    /// on the next keystroke — re-baseline open buffer to current content.
    private func reanchorSessionMarks(for key: URL) {
        if let content = DocumentRegistry.shared.contentIfOpen(key) {
            LineChangeTracker.shared.noteBaseline(url: key, content: content)
        } else {
            LineChangeTracker.shared.clearMarks(url: key)
        }
    }
}
