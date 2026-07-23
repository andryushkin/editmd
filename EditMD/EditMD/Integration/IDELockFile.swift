import Foundation
import Security

// Discovery for the Claude Code IDE channel (v36).
//
// The CLI has no idea we exist until it finds `~/.claude/ide/<port>.lock`.
// On `/ide` it scans that directory, picks the lock whose `workspaceFolders`
// cover the terminal's cwd, and dials 127.0.0.1:<port> with `authToken` in the
// `x-claude-code-ide-authorization` header.
//
// Schema is verbatim from the reverse-engineered Claude Code IDE protocol
// (see `docs/integration.md`) — extra or renamed keys break discovery
// silently.

struct IDELockFileContents: Codable, Equatable, Sendable {
    var pid: Int32
    var workspaceFolders: [String]
    var ideName: String
    var transport: String
    var authToken: String

    init(pid: Int32 = ProcessInfo.processInfo.processIdentifier,
         workspaceFolders: [String],
         ideName: String = "EditMD",
         transport: String = "ws",
         authToken: String) {
        self.pid = pid
        self.workspaceFolders = workspaceFolders
        self.ideName = ideName
        self.transport = transport
        self.authToken = authToken
    }
}

enum IDELockFileError: Error, Equatable {
    case randomGenerationFailed(OSStatus)
}

/// Stateless helpers over the lock directory. The directory is a parameter so
/// tests never touch the real `~/.claude/ide`.
enum IDELockFile {

    /// `~/.claude/ide` — resolved from the real home, not a sandbox container
    /// (EditMD ships unsandboxed; the CLI looks here too).
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("ide", isDirectory: true)
    }

    /// 16 CSPRNG bytes as 32 lowercase hex chars. New on every server start;
    /// lives only in memory and in the 0600 lock file.
    static func generateAuthToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw IDELockFileError.randomGenerationFailed(status)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func url(port: UInt16, in directory: URL) -> URL {
        directory.appendingPathComponent("\(port).lock")
    }

    /// Creates the directory (0700) and writes the lock file (0600).
    /// Overwrites an existing file for the same port — the workspace list is
    /// rewritten in place when the user adopts or drops a folder.
    @discardableResult
    static func write(_ contents: IDELockFileContents,
                      port: UInt16,
                      in directory: URL) throws -> URL {
        try ensureDirectory(directory)
        let target = url(port: port, in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(contents)
        // Write, then tighten: `Data.write` honors an existing file's mode, and
        // a fresh file would land at the process umask (typically 0644).
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                              ofItemAtPath: target.path)
        return target
    }

    static func read(port: UInt16, in directory: URL) throws -> IDELockFileContents {
        let data = try Data(contentsOf: url(port: port, in: directory))
        return try JSONDecoder().decode(IDELockFileContents.self, from: data)
    }

    static func remove(port: UInt16, in directory: URL) {
        try? FileManager.default.removeItem(at: url(port: port, in: directory))
    }

    /// Deletes `*.lock` files whose `pid` is gone. A crashed EditMD (or any
    /// other IDE) otherwise leaves the CLI dialing a dead port forever.
    /// Files that don't parse are left alone — they may belong to a newer
    /// schema from another editor.
    @discardableResult
    static func cleanStale(in directory: URL) -> [URL] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        var removed: [URL] = []
        for entry in entries where entry.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: entry),
                  let contents = try? JSONDecoder().decode(IDELockFileContents.self, from: data)
            else { continue }
            guard !processIsAlive(contents.pid) else { continue }
            try? manager.removeItem(at: entry)
            removed.append(entry)
        }
        return removed
    }

    /// `kill(pid, 0)` probes existence without signalling. `EPERM` means the
    /// process exists but belongs to another user — still alive.
    static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            return
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
}
