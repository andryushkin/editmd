import Foundation
import os

let starterFolderLog = Logger(subsystem: "andryushkin.EditMD", category: "starter")

/// New-user folder: `~/Documents/EditMD` (or next free name) with README,
/// `Guide/`, and — until Settings ▸ Web clips says otherwise — browser clips.
///
/// Seeded once per installation from `Resources/starter/`, only into a
/// directory EditMD created itself; an ordinary folder afterwards — never
/// re-checked, repaired, or restored after user deletion (the clips folder is
/// recreated on demand, empty). Pure Foundation → copy runs off-main.
enum StarterFolder {

    /// UserDefaults flag: seed exactly once per installation.
    static let seededKey = "starter.seeded"
    /// Path of the owned folder. Written the moment the directory exists —
    /// before the guide copies — so a failed copy still leaves clips a home.
    static let folderKey = "starter.folder"
    /// Document identifier where the volume provides one: a path is not an
    /// identity; the thing at it can be replaced.
    static let folderIDKey = "starter.folderID"

    /// Also the default destination for web clips (`ClipDestination`).
    static var defaultURL: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        return normalized(documents.appendingPathComponent("EditMD"))
    }

    /// URL equality is by string, and `URL(fileURLWithPath:)` appends a
    /// trailing slash for an existing directory while `appendingPathComponent`
    /// does not — normalize so builds compare equal.
    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
            .standardizedFileURL
    }

    /// Never surfaced to the user (the folder is a courtesy, not something a
    /// launch may fail on) — unlocalized log strings.
    enum SeedError: Error, CustomStringConvertible, Equatable {
        case missingResources
        case noFreeFolderName

        var description: String {
            switch self {
            case .missingResources: return "bundled starter documents are missing"
            case .noFreeFolderName: return "no free name for the starter folder"
            }
        }
    }

    /// How many `EditMD N` names are tried before giving up on a location.
    static let maxNameAttempts = 20

    /// Owned folder without creating anything: resolved one, else where it
    /// would go. Display / "empty means here" only — never for writing.
    static func ownedFolder(defaults: UserDefaults = .standard) -> URL {
        guard let stored = defaults.string(forKey: folderKey), !stored.isEmpty else {
            return defaultURL
        }
        return normalized(URL(fileURLWithPath: stored))
    }

    /// Claims the installation's ONE seed attempt, *before* the work — so any
    /// failure spends the attempt by default. Only a refused access hands it
    /// back (`returnSeedAttempt`), and that case retries while the refusal lasts.
    static func claimSeedAttempt(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: seededKey) else { return false }
        defaults.set(true, forKey: seededKey)
        return true
    }

    /// Hands the attempt back for refused access — the one failure that may
    /// not be final: "Don't Allow" on the `~/Documents` prompt must not burn
    /// the only attempt (the user can grant access later).
    /// Cannot be narrowed: consent, POSIX perms, ACL, SIP, data protection all
    /// arrive as the same error (`NSError.isPermissionDenied`), so every
    /// refusal retries — a permanently unwritable location re-attempts each
    /// launch forever. Cost: one immediately-failing `createDirectory`,
    /// off-main — cheaper than putting an expiry date on the folder.
    static func returnSeedAttempt(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: seededKey)
    }

    /// Launch task: claim attempt → owner resolves/creates the folder → copy
    /// the guide. Returns the folder only when the guide landed now; `nil` if
    /// already seeded or the copy failed (logged and swallowed — never worth
    /// blocking a launch; the folder itself survives, recorded by the owner).
    /// Refused access alone returns the attempt (`returnSeedAttempt`).
    /// `defaultsSuite` is a name, not `UserDefaults` — the work crosses actors;
    /// `nil` = `.standard`.
    static func seedIfNeeded(
        owner: StarterFolderOwner = .shared,
        defaultsSuite: String? = nil,
        bundle: Bundle = .main
    ) async -> URL? {
        let defaults = defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        guard claimSeedAttempt(defaults: defaults) else { return nil }
        do {
            let root = try await owner.folder()
            let created = try seedContents(at: root, bundle: bundle)
            starterFolderLog.info(
                "seeded starter folder with \(created.count, privacy: .public) files")
            return root
        } catch {
            if (error as NSError).isPermissionDenied {
                returnSeedAttempt(defaults: defaults)
            }
            starterFolderLog.error(
                "starter folder not seeded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Creates a folder EditMD owns: `preferred` when free, an empty same-name
    /// folder (nothing of the user's at stake), else `EditMD 2`, `EditMD 3`…
    /// Creation IS the ownership test — `withIntermediateDirectories: false`
    /// fails rather than merging into someone else's directory.
    static func makeOwnFolder(preferring preferred: URL) throws -> URL {
        let manager = FileManager.default
        let parent = preferred.deletingLastPathComponent()
        let base = preferred.lastPathComponent
        // Only the leaf must be ours; the parent (`~/Documents`) is not in question.
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        for attempt in 1...maxNameAttempts {
            let candidate = attempt == 1
                ? preferred
                : parent.appendingPathComponent("\(base) \(attempt)")
            do {
                try manager.createDirectory(
                    at: candidate, withIntermediateDirectories: false)
                return normalized(candidate)
            } catch let error as NSError where error.isFileExists {
                if isAdoptableEmptyDirectory(candidate) { return normalized(candidate) }
                continue
            }
        }
        throw SeedError.noFreeFolderName
    }

    /// Filesystem identity: survives rename/move, changes when the item at a
    /// path is replaced. `nil` where the volume does not provide it.
    static func identity(of url: URL) -> Int? {
        probe(url).flatMap {
            (try? $0.resourceValues(forKeys: [.documentIdentifierKey]))?.documentIdentifier
        }
    }

    /// URL with no cached resource values: `URL` memoizes them, so a URL kept
    /// across a deletion happily reports the directory it used to point at —
    /// exactly the case these checks exist for.
    private static func probe(_ url: URL) -> URL? {
        var probe = URL(fileURLWithPath: url.path, isDirectory: false)
        probe.removeAllCachedResourceValues()
        return probe
    }

    /// Is the recorded folder still the one EditMD made? Checked on EVERY ask:
    /// a deleted folder replaced by a symlink would otherwise be walked into.
    /// Identity is checked whenever it was recorded; no record = volume never
    /// offered one, structural check stands alone. A record that cannot be
    /// confirmed now is NOT a pass — that is what a swapped directory looks
    /// like. Fail closed: costs at most a fresh `EditMD 2`; failing open hands
    /// a stranger's folder our clips.
    static func isRecordedFolderOurs(_ url: URL, recordedIdentity: Int?) -> Bool {
        guard let probe = probe(url),
              let values = try? probe.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .documentIdentifierKey]),
              values.isSymbolicLink != true, values.isDirectory == true
        else { return false }
        guard let recordedIdentity else { return true }
        guard let current = values.documentIdentifier else { return false }
        return current == recordedIdentity
    }

    /// Adoptable only when it holds NOTHING at all — hidden entries count
    /// (`.git`/`.obsidian` means somebody's vault; skipping hidden files would
    /// seed straight into it). Symlinks never adopted — the target is not ours.
    static func isAdoptableEmptyDirectory(_ url: URL) -> Bool {
        let values = probe(url).flatMap {
            try? $0.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        }
        guard values?.isSymbolicLink != true, values?.isDirectory == true,
              let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        else { return false }
        return entries.isEmpty
    }

    /// What a launch does with a folder it has just seeded.
    enum Presentation: Equatable, Sendable {
        /// Someone else's setup or window — create the folder, change nothing.
        case none
        /// Empty sidebar, but the window is already showing something.
        case adopt
        /// Fresh start: adopt the folder and open its README.
        case adoptAndOpenReadme
    }

    /// Introduces itself only on a genuinely fresh start; an existing sidebar
    /// means an existing user — nothing is added to their tree.
    /// Empty sidebar always adopts, including when an `editmd://` clip beat
    /// `applicationDidFinishLaunching`: the clip landed in this very folder, so
    /// showing it is the point. The clip keeps the DOCUMENT — the README never
    /// replaces what the user is looking at.
    static func presentation(
        sidebarIsEmpty: Bool,
        mainPaneIsWelcome: Bool,
        hasEditorModeClaim: Bool
    ) -> Presentation {
        guard sidebarIsEmpty else { return .none }
        return mainPaneIsWelcome && !hasEditorModeClaim ? .adoptAndOpenReadme : .adopt
    }

    /// Bundled documents (`Resources/starter/`) → destination paths. The build
    /// flattens `Resources/` into the bundle root, so the delivered tree is
    /// described here, not mirrored from bundle layout.
    static let bundledDocuments: [(resource: String, relativePath: String)] = [
        ("README", "README.md"),
        ("Editing modes", "Guide/Editing modes.md"),
        ("Web clipper", "Guide/Web clipper.md"),
        ("Markdown showcase", "Guide/Markdown showcase.md"),
    ]

    /// Writes the bundled documents into `root` (creating it and `Guide/`);
    /// returns the created files. Never overwrites, never aborts the rest over
    /// one file: an edited document or a racing clip wins over the bundled
    /// version, remaining documents still land.
    @discardableResult
    static func seedContents(at root: URL, bundle: Bundle = .main) throws -> [URL] {
        let manager = FileManager.default
        var created: [URL] = []
        for document in bundledDocuments {
            guard let source = bundle.url(
                forResource: document.resource, withExtension: "md")
            else { throw SeedError.missingResources }
            let target = root.appendingPathComponent(document.relativePath)
            try manager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            do {
                try manager.copyItem(at: source, to: target)
                created.append(target.standardizedFileURL)
            } catch let error as NSError where error.isFileExists {
                // Existing file wins — including a clip created between check
                // and copy. Test-then-copy would let that race abort the whole
                // seed and lose the documents after it.
                continue
            }
        }
        return created
    }
}

/// Single owner of "where is our folder". Two paths need it on first launch,
/// and an `editmd://` clip arrives FIRST (Apple Event beats
/// `applicationDidFinishLaunching`); answering independently could write the
/// clip into a user's own `~/Documents/EditMD` while the guide stepped aside
/// to `EditMD 2`. Both callers await this actor: directory created once,
/// everyone told the same path. Off-main by construction.
actor StarterFolderOwner {
    static let shared = StarterFolderOwner()

    private let preferred: URL
    private let defaultsSuite: String?
    private var resolved: URL?
    private var resolvedIdentity: Int?

    /// `defaultsSuite` is a name, not `UserDefaults` — no shared mutable state
    /// the actor does not own; `nil` = `.standard`.
    init(preferring preferred: URL = StarterFolder.defaultURL,
         defaultsSuite: String? = nil) {
        self.preferred = preferred
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// Recorded folder, or a freshly created one. Recorded as soon as the
    /// directory exists, before anything is written — a failed guide copy must
    /// not cost the clips their home.
    func folder() throws -> URL {
        let store = defaults
        // Re-checked every time, cache included: the path's target can be
        // deleted, replaced, or symlinked between two clips.
        if let resolved,
           StarterFolder.isRecordedFolderOurs(resolved, recordedIdentity: resolvedIdentity) {
            return resolved
        }
        if let stored = store.string(forKey: StarterFolder.folderKey), !stored.isEmpty {
            let url = StarterFolder.normalized(URL(fileURLWithPath: stored))
            let identity = store.object(forKey: StarterFolder.folderIDKey) as? Int
            if StarterFolder.isRecordedFolderOurs(url, recordedIdentity: identity) {
                resolved = url
                resolvedIdentity = identity
                return url
            }
            starterFolderLog.notice(
                "recorded starter folder is not ours anymore — choosing again")
        }
        let created = try StarterFolder.makeOwnFolder(preferring: preferred)
        let identity = StarterFolder.identity(of: created)
        store.set(created.path, forKey: StarterFolder.folderKey)
        if let identity {
            store.set(identity, forKey: StarterFolder.folderIDKey)
        } else {
            store.removeObject(forKey: StarterFolder.folderIDKey)
        }
        resolved = created
        resolvedIdentity = identity
        starterFolderLog.info("starter folder is \(created.lastPathComponent, privacy: .public)")
        return created
    }
}
