import Foundation
import os

let urlSchemeLog = Logger(subsystem: "andryushkin.EditMD", category: "url-scheme")

/// A command delivered through the `editmd://` URL scheme — the web-clipper
/// handoff (see `docs/integration.md`). Registered in `Info.plist`, so macOS
/// launches EditMD for it even when the app is not running, which is why the
/// clipper uses it instead of the control socket.
///
/// Contract v1 (fixed by the shipped webtodotmd extension, do not change):
///
/// ```
/// editmd://new?file=<name-without-extension>&clipboard
/// ```
///
/// Anything else is ignored: unknown commands, and the parameters reserved for
/// later (`content`, `append`, `silent`, `workspace`) which a sender may
/// already include. Parsing is deliberately tolerant — any web page can open
/// this URL, so the app must not act on anything it does not understand.
///
/// Pure Foundation, no AppKit: the parsing and naming rules are unit-tested
/// without launching the app.
enum EditMDURLCommand: Equatable, Sendable {
    /// `new` — create a file and open it.
    case newClip(NewClip)

    struct NewClip: Equatable, Sendable {
        /// Sanitized base name, no extension (`ClipFileNaming.sanitizedBaseName`).
        var name: String
        /// `clipboard` flag: the body travels through the general pasteboard.
        /// Without it v1 creates an empty file (`content=` is not honoured yet).
        var usesClipboard: Bool
        /// `workspace=` — the **name** of an adopted workspace, the analog of
        /// Obsidian's `vault=`. Never a path: an untrusted sender may pick
        /// among folders the user has already adopted, and nothing else. An
        /// unknown name falls back to the configured destination.
        var requestedWorkspace: String?

        init(name: String, usesClipboard: Bool, requestedWorkspace: String? = nil) {
            self.name = name
            self.usesClipboard = usesClipboard
            self.requestedWorkspace = requestedWorkspace
        }
    }

    static let scheme = "editmd"

    /// Returns `nil` for anything this build does not implement; the caller
    /// logs and drops it.
    static func parse(_ url: URL) -> EditMDURLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // `editmd://new?…` puts the command in the host. Tolerate the
        // authority-less spellings (`editmd:new?…`, `editmd:///new?…`) that
        // some senders produce — there the command lands in the path.
        let command = components.host.flatMap { $0.isEmpty ? nil : $0 }
            ?? components.path.split(separator: "/").first.map(String.init)
        let query = components.queryItems ?? []
        switch command?.lowercased() {
        case "new":
            return .newClip(NewClip(
                name: ClipFileNaming.sanitizedBaseName(query.firstValue(of: "file")),
                usesClipboard: query.hasFlag("clipboard"),
                requestedWorkspace: query.firstValue(of: "workspace")))
        default:
            return nil
        }
    }
}

private extension Array where Element == URLQueryItem {
    /// Value of the first occurrence (`URLComponents` has already
    /// percent-decoded it).
    func firstValue(of name: String) -> String? {
        first { $0.name.lowercased() == name }?.value
    }

    /// A valueless flag (`&clipboard`) is true; an explicit value is honoured
    /// so `&clipboard=false` opts out.
    func hasFlag(_ name: String) -> Bool {
        guard let item = first(where: { $0.name.lowercased() == name }) else { return false }
        guard let value = item.value?.trimmingCharacters(in: .whitespaces).lowercased(),
              !value.isEmpty else { return true }
        return ["true", "1", "yes"].contains(value)
    }
}

/// Where clips land when the URL does not name a workspace
/// (Settings ▸ General ▸ Web clips).
enum ClipDestinationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// One fixed folder, whatever is open. The default: a clipper is a capture
    /// inbox, and "wherever I last looked" is not a place you can find again.
    case folder
    /// The root of the workspace the app is currently working in.
    case activeWorkspace

    var id: String { rawValue }
}

/// Everything the destination decision depends on. Assembled on the main actor
/// from settings and the sidebar, then resolved off it — the rules stay a pure
/// function over data, and the stat that validates a folder never runs on main.
struct ClipDestination: Equatable, Sendable {
    struct AdoptedWorkspace: Equatable, Sendable {
        var name: String
        var root: URL
    }

    /// `workspace=` from the URL (a name, see `NewClip.requestedWorkspace`).
    var requestedWorkspace: String?
    var mode: ClipDestinationMode
    /// Settings ▸ Web clips ▸ Folder, already resolved to a URL.
    var configuredFolder: URL
    /// The roots currently adopted in the sidebar, with their display names.
    var workspaces: [AdoptedWorkspace] = []
    var activeWorkspaceRoot: URL?

    /// Resolution order: a named workspace that is really adopted → the
    /// configured mode → the clips folder. Anything unknown or gone from disk
    /// falls through to the clips folder instead of failing: a note that
    /// arrives in the wrong-but-known place beats a note that is lost.
    func resolvedFolder(isExistingFolder: (URL) -> Bool) -> URL {
        if let named = matchedWorkspaceRoot(), isExistingFolder(named) { return named }
        if mode == .activeWorkspace,
           let activeWorkspaceRoot, isExistingFolder(activeWorkspaceRoot) {
            return activeWorkspaceRoot
        }
        return configuredFolder
    }

    private func matchedWorkspaceRoot() -> URL? {
        guard let requested = requestedWorkspace?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty
        else { return nil }
        return workspaces.first {
            $0.name.compare(requested, options: .caseInsensitive) == .orderedSame
        }?.root
    }

    /// Settings path → folder URL. Empty (the default) means the folder EditMD
    /// made on first launch; a `~` in a hand-edited path is expanded.
    static func configuredFolder(forSettingsPath path: String) -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultFolder }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    /// `~/Documents/EditMD` — the same folder that holds the README and the
    /// guide, so a new user finds their first clip next to the instructions.
    static var defaultFolder: URL { StarterFolder.defaultURL }
}

/// Naming rules for files created from a URL command. The sender already
/// sanitizes the name; the app re-sanitizes because any web page can craft the
/// URL (defense in depth — the result must stay a single, visible file name
/// inside the destination folder).
enum ClipFileNaming {
    /// Used when the sanitized name comes out empty.
    static let fallbackBaseName = "Clip"
    /// Cap on the base name. Characters first, then bytes: a file name
    /// component is limited to 255 UTF-8 bytes, and a 100-character name can
    /// be far longer than that in non-Latin scripts.
    static let maxBaseNameCharacters = 100
    static let maxBaseNameBytes = 200

    /// URL `file` parameter → base name without extension.
    ///
    /// Drops path separators and control characters (so the result cannot
    /// escape the destination folder or hide a newline), leading dots (a
    /// dot-prefixed file would vanish from every listing), and a trailing
    /// `.md`/`.markdown` (senders are supposed to omit the extension; without
    /// this a sloppy one would produce `Note.md.md`).
    static func sanitizedBaseName(_ raw: String?) -> String {
        guard let raw else { return fallbackBaseName }
        var name = String(raw.unicodeScalars.compactMap { scalar -> Character? in
            switch scalar {
            case "/", "\\", ":": return nil
            default:
                // Newlines, tabs and NUL become spaces — collapsed below.
                return CharacterSet.controlCharacters.contains(scalar)
                    ? " " : Character(scalar)
            }
        })
        name = name.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        while let first = name.first, first == "." || first == " " {
            name.removeFirst()
        }
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "md" || ext == "markdown" {
            name = (name as NSString).deletingPathExtension
        }
        name = trimmedTail(name)
        if name.count > maxBaseNameCharacters {
            name = String(name.prefix(maxBaseNameCharacters))
        }
        while name.utf8.count > maxBaseNameBytes { name.removeLast() }
        name = trimmedTail(name)
        return name.isEmpty ? fallbackBaseName : name
    }

    /// Trailing spaces and dots are legal on APFS but read as a broken name in
    /// Finder, and a truncation can leave either behind.
    private static func trimmedTail(_ name: String) -> String {
        var trimmed = name
        while let last = trimmed.last, last == "." || last == " " {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Candidate file names for one base name, in the order they are tried:
    /// `Name.md`, `Name 2.md`, `Name 3.md`… A clip never overwrites, so an
    /// occupied name simply moves on to the next attempt.
    static func candidateFileName(base: String, attempt: Int) -> String {
        attempt <= 1 ? "\(base).md" : "\(base) \(attempt).md"
    }
}

/// Writes a clip to disk. Separate from `AppState` so the create/uniquify
/// behaviour is testable against a temporary directory without any app state.
enum ClipFile {
    /// How many `Name N.md` candidates are tried before giving up.
    static let maxAttempts = 999
    /// Sanity cap on a body handed over by an external sender.
    static let maxBodyBytes = 4 << 20

    enum WriteError: LocalizedError, Equatable {
        case noFreeName(String)

        var errorDescription: String? {
            switch self {
            case .noFreeName(let base):
                return String(localized: "Too many files are already named “\(base)”.")
            }
        }
    }

    /// Creates a new file in `folder` (created on demand) and returns its URL.
    ///
    /// Never overwrites: every candidate is written with `.withoutOverwriting`,
    /// so a name taken between the check and the write loses the race and the
    /// next candidate is tried instead of clobbering someone's file.
    @discardableResult
    static func write(_ body: String, baseName: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true)
        let data = Data(cappedBody(body).utf8)
        for attempt in 1...maxAttempts {
            let name = ClipFileNaming.candidateFileName(base: baseName, attempt: attempt)
            let dest = folder.appendingPathComponent(name)
            do {
                try data.write(to: dest, options: [.withoutOverwriting])
                return dest.standardizedFileURL
            } catch let error as NSError where error.isFileExists {
                continue
            }
        }
        throw WriteError.noFreeName(baseName)
    }

    /// Truncates an oversized body on a character boundary. The body is never
    /// interpreted, only written, so the only thing to enforce here is size.
    static func cappedBody(_ body: String, maxBytes: Int = ClipFile.maxBodyBytes) -> String {
        guard body.utf8.count > maxBytes else { return body }
        var capped = ""
        var bytes = 0
        for character in body {
            let size = String(character).utf8.count
            if bytes + size > maxBytes { break }
            capped.append(character)
            bytes += size
        }
        urlSchemeLog.warning("clip body truncated to \(bytes, privacy: .public) bytes")
        return capped
    }
}

private extension NSError {
    /// The destination already exists — Foundation reports it as either the
    /// Cocoa or the POSIX flavour depending on the failing layer.
    var isFileExists: Bool {
        (domain == NSCocoaErrorDomain && code == NSFileWriteFileExistsError)
            || (domain == NSPOSIXErrorDomain && code == Int(EEXIST))
    }
}
