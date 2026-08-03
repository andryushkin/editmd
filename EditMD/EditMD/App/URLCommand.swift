import Foundation
import os

let urlSchemeLog = Logger(subsystem: "andryushkin.EditMD", category: "url-scheme")

/// `editmd://` command (web-clipper handoff). Contract v1
/// `editmd://new?file=<name>&clipboard` is FIXED by the shipped webtodotmd
/// extension — do not change unilaterally; full contract in
/// docs/integration.md § URL scheme. Unknown commands/parameters (incl.
/// reserved `content`, `append`, `silent`) are ignored, never errors — any web
/// page can open this URL. Pure Foundation, no AppKit: unit-testable without
/// launching the app.
enum EditMDURLCommand: Equatable, Sendable {
    /// `new` — create a file and open it.
    case newClip(NewClip)

    struct NewClip: Equatable, Sendable {
        /// Sanitized base name, no extension (`ClipFileNaming.sanitizedBaseName`).
        var name: String
        /// `clipboard` flag: body travels via the general pasteboard. Without
        /// it v1 creates an empty file (`content=` not honoured yet).
        var usesClipboard: Bool
        /// `workspace=` — NAME of an adopted workspace (Obsidian's `vault=`).
        /// Never a path: an untrusted sender may only pick among folders the
        /// user already adopted. Unknown name → configured destination.
        var requestedWorkspace: String?

        init(name: String, usesClipboard: Bool, requestedWorkspace: String? = nil) {
            self.name = name
            self.usesClipboard = usesClipboard
            self.requestedWorkspace = requestedWorkspace
        }
    }

    static let scheme = "editmd"

    /// `nil` for anything this build does not implement; caller logs and drops.
    static func parse(_ url: URL) -> EditMDURLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // Command lives in the host (`editmd://new?…`); tolerate authority-less
        // spellings (`editmd:new?…`, `editmd:///new?…`) where it lands in the path.
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
    /// First occurrence's value (already percent-decoded by URLComponents).
    func firstValue(of name: String) -> String? {
        first { $0.name.lowercased() == name }?.value
    }

    /// Valueless flag (`&clipboard`) = true; explicit value honoured so
    /// `&clipboard=false` opts out.
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
    /// One fixed folder, whatever is open. Default: a clipper is a capture
    /// inbox; "wherever I last looked" cannot be found again.
    case folder
    /// Root of the currently active workspace.
    case activeWorkspace

    var id: String { rawValue }
}

/// All inputs of the destination decision. Assembled on the main actor,
/// resolved off it — rules stay a pure function over data; the validating stat
/// never runs on main.
struct ClipDestination: Equatable, Sendable {
    struct AdoptedWorkspace: Equatable, Sendable {
        var name: String
        var root: URL
    }

    /// The decision, before anything touches the filesystem.
    enum Resolved: Equatable, Sendable {
        case folder(URL)
        /// EditMD's own folder, which may still have to be created
        /// (`StarterFolderOwner`).
        case starterFolder
    }

    /// `workspace=` from the URL (a name, see `NewClip.requestedWorkspace`).
    var requestedWorkspace: String?
    var mode: ClipDestinationMode
    /// Settings ▸ Web clips ▸ Folder; `nil` = not chosen = EditMD's own folder.
    var configuredFolder: URL?
    /// Adopted sidebar roots with display names.
    var workspaces: [AdoptedWorkspace] = []
    var activeWorkspaceRoot: URL?

    /// Order: really-adopted named workspace → configured mode → clips folder.
    /// Unknown or gone-from-disk falls through instead of failing: a note in a
    /// wrong-but-known place beats a lost note.
    func resolved(isExistingFolder: (URL) -> Bool) -> Resolved {
        if let named = matchedWorkspaceRoot(isExistingFolder: isExistingFolder) {
            return .folder(named)
        }
        if mode == .activeWorkspace,
           let activeWorkspaceRoot, isExistingFolder(activeWorkspaceRoot) {
            return .folder(activeWorkspaceRoot)
        }
        return configuredFolder.map { .folder($0) } ?? .starterFolder
    }

    /// The requested workspace — only when unambiguous. Two adopted roots can
    /// share a name; guessing which one a web page meant is worse than the
    /// configured fallback. Roots missing from disk are ruled out first so a
    /// stale duplicate cannot shadow the live one.
    private func matchedWorkspaceRoot(isExistingFolder: (URL) -> Bool) -> URL? {
        guard let requested = requestedWorkspace?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty
        else { return nil }
        let live = workspaces
            .filter { $0.name.compare(requested, options: .caseInsensitive) == .orderedSame }
            .map(\.root)
            .filter(isExistingFolder)
        return live.count == 1 ? live[0] : nil
    }

    /// Settings path → folder URL; `nil` = unset (clips go to EditMD's own
    /// folder). Hand-edited `~` is expanded.
    static func configuredFolder(forSettingsPath path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return StarterFolder.normalized(
            URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath))
    }
}

/// Naming for files created from a URL command. The app re-sanitizes even
/// though the sender does — any web page can craft the URL; the result must
/// stay a single, visible file name inside the destination folder.
enum ClipFileNaming {
    /// Used when the sanitized name comes out empty.
    static let fallbackBaseName = "Clip"
    /// Cap: characters first, then bytes — a name component is limited to
    /// 255 UTF-8 bytes, and 100 characters can exceed that in non-Latin scripts.
    static let maxBaseNameCharacters = 100
    static let maxBaseNameBytes = 200

    /// URL `file` parameter → base name without extension. Drops path
    /// separators, folds control/line separators to spaces (cannot escape the
    /// folder or hide a line break), drops leading dots (dot-prefixed files
    /// vanish from listings) and trailing `.md`/`.markdown` (else a sloppy
    /// sender yields `Note.md.md`).
    static func sanitizedBaseName(_ raw: String?) -> String {
        guard let raw else { return fallbackBaseName }
        // Character rules shared with the name prompts
        // (`Editor/SingleLineText.swift`): control + line separators fold to
        // spaces; format characters (ZWJ holding an emoji) survive. Path
        // separators dropped only here — only a URL-supplied name can have them.
        var name = singleLineFieldText(String(raw.unicodeScalars.filter {
            $0 != "/" && $0 != "\\" && $0 != ":"
        }))
        // Space runs collapse here but NOT in the prompts: a web page's name is
        // a title to tidy; a user-typed name is theirs.
        name = name.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
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

    /// Trailing spaces/dots: legal on APFS, broken-looking in Finder, and
    /// truncation can leave either behind.
    private static func trimmedTail(_ name: String) -> String {
        var trimmed = name
        while let last = trimmed.last, last == "." || last == " " {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Try order: `Name.md`, `Name 2.md`, `Name 3.md`… A clip never
    /// overwrites; an occupied name moves to the next attempt.
    static func candidateFileName(base: String, attempt: Int) -> String {
        attempt <= 1 ? "\(base).md" : "\(base) \(attempt).md"
    }
}

/// Clip disk writes. Separate from `AppState` so create/uniquify is testable
/// against a temp directory without app state.
enum ClipFile {
    /// `Name N.md` candidates tried before giving up.
    static let maxAttempts = 999
    /// Sanity cap on an externally supplied body.
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

    /// New file in `folder` (created on demand) → its URL. Never overwrites:
    /// each candidate uses `.withoutOverwriting`, so a name taken between check
    /// and write loses the race and the next candidate is tried.
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

    /// Truncates an oversized body on a character boundary. The body is only
    /// written, never interpreted — size is the only thing to enforce.
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

extension NSError {
    /// Destination exists — Cocoa or POSIX flavour depending on the failing
    /// layer. Shared with `StarterFolder`'s folder creation.
    var isFileExists: Bool {
        (domain == NSCocoaErrorDomain && code == NSFileWriteFileExistsError)
            || (domain == NSPOSIXErrorDomain && code == Int(EEXIST))
    }

    /// Access refused, either flavour. Deliberately broad: "Don't Allow",
    /// POSIX perms, ACL, SIP, data protection are indistinguishable — read
    /// "refused", never "refused by the user". `StarterFolder` treats the
    /// whole class as possibly reversible.
    var isPermissionDenied: Bool {
        (domain == NSCocoaErrorDomain
            && (code == NSFileWriteNoPermissionError
                || code == NSFileReadNoPermissionError))
            || (domain == NSPOSIXErrorDomain
                && (code == Int(EACCES) || code == Int(EPERM)))
    }
}
