import Foundation
import os

let starterFolderLog = Logger(subsystem: "andryushkin.EditMD", category: "starter")

/// The folder EditMD creates for a new user: `~/Documents/EditMD` (or the next
/// free name beside it), holding a README, a small `Guide/`, and — until
/// Settings ▸ Web clips says otherwise — the notes sent from the browser.
///
/// It is seeded once per installation from `Resources/starter/`, only into a
/// directory EditMD created itself, and is an ordinary folder afterwards:
/// nothing re-checks it, nothing repairs it, and a user who deletes it is not
/// given it back (the clips folder is recreated on demand, empty). Pure
/// Foundation, so the copy runs off the main actor.
enum StarterFolder {

    /// UserDefaults flag, so an upgrade seeds the guide exactly once.
    static let seededKey = "starter.seeded"
    /// Path of the folder EditMD ended up owning. Written by
    /// `StarterFolderOwner` the moment the directory exists — before the guide
    /// is copied into it — so a failed copy still leaves clips a home.
    static let folderKey = "starter.folder"
    /// Document identifier of that folder, where the volume provides one: a
    /// path is not an identity, and the thing at that path can be replaced.
    static let folderIDKey = "starter.folderID"

    /// Also the default destination for web clips (`ClipDestination`).
    static var defaultURL: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        return normalized(documents.appendingPathComponent("EditMD"))
    }

    /// Folder URLs have to compare equal however they were built:
    /// `URL(fileURLWithPath:)` stats the path and appends a trailing slash for
    /// a directory that exists, `appendingPathComponent` does not, and URL
    /// equality is by string.
    static func normalized(_ url: URL) -> URL {
        URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: false)
            .standardizedFileURL
    }

    /// Never surfaced to the user — the folder is a courtesy, not a feature a
    /// launch may fail on — so the message stays an unlocalized log string.
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

    /// The folder EditMD owns, as far as anyone can tell without creating
    /// anything: the one already resolved, else where it would go. For display
    /// and for the clips setting's "empty means here" — never for writing.
    static func ownedFolder(defaults: UserDefaults = .standard) -> URL {
        guard let stored = defaults.string(forKey: folderKey), !stored.isEmpty else {
            return defaultURL
        }
        return normalized(URL(fileURLWithPath: stored))
    }

    /// Claims this installation's one attempt at seeding the guide. Claiming
    /// *before* the work is what makes a failure spend the attempt by default:
    /// whatever goes wrong is not retried on the next launch unless the attempt
    /// is explicitly handed back, which only a refused access does — and that
    /// one is retried for as long as the refusal lasts (`returnSeedAttempt`).
    static func claimSeedAttempt(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: seededKey) else { return false }
        defaults.set(true, forKey: seededKey)
        return true
    }

    /// Hands the claimed attempt back, for the one class of failure that may
    /// not be the last word: the access was refused. The prompt for
    /// `~/Documents` is the case that matters — an installation that spent its
    /// only attempt on a "Don't Allow" would never get the folder, not even
    /// after the user grants access under Privacy & Security.
    ///
    /// It cannot be narrowed to that case: consent, POSIX permissions, an ACL,
    /// SIP and data protection all arrive as the same error (see
    /// `NSError.isPermissionDenied`), so every refusal is retried — a location
    /// that stays unwritable is re-attempted on each launch, forever. That
    /// costs one `createDirectory` that fails immediately, off the main actor,
    /// and it is the cheaper mistake: giving up after N launches would put an
    /// expiry date on a folder the user may still enable next month.
    static func returnSeedAttempt(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: seededKey)
    }

    /// The launch task: claim the attempt, ask the owner where the folder is
    /// (creating it if this is the first ask), copy the guide into it. Returns
    /// the folder when the guide landed now — `nil` when it had been seeded
    /// before, or when the copy failed (a missing guide is never worth
    /// blocking a launch, so the failure is logged and swallowed; the folder
    /// itself survives, recorded by the owner). A refused access is the one
    /// failure that gives the attempt back — see `returnSeedAttempt`.
    ///
    /// `defaultsSuite` is a name rather than a `UserDefaults` because the work
    /// crosses actors; `nil` is `.standard`.
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

    /// Creates a folder EditMD can call its own: `preferred` when it is free,
    /// an empty folder of that name when one is already sitting there (nothing
    /// of the user's is at stake), otherwise `EditMD 2`, `EditMD 3`… The
    /// creation itself is the ownership test — `withIntermediateDirectories:
    /// false` fails rather than merging into someone else's directory.
    static func makeOwnFolder(preferring preferred: URL) throws -> URL {
        let manager = FileManager.default
        let parent = preferred.deletingLastPathComponent()
        let base = preferred.lastPathComponent
        // The parent (`~/Documents`) is not the folder whose ownership is in
        // question — only the leaf below must be ours to create.
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

    /// Filesystem identity of a directory: survives renames and moves, and
    /// changes when the thing at a path is replaced by another one. `nil` on
    /// volumes that do not provide it.
    static func identity(of url: URL) -> Int? {
        probe(url).flatMap {
            (try? $0.resourceValues(forKeys: [.documentIdentifierKey]))?.documentIdentifier
        }
    }

    /// A URL instance with nothing cached on it. `URL` memoizes the resource
    /// values it has been asked for, so a URL kept across a deletion happily
    /// reports the directory it used to point at — which is exactly the case
    /// these checks exist for.
    private static func probe(_ url: URL) -> URL? {
        var probe = URL(fileURLWithPath: url.path, isDirectory: false)
        probe.removeAllCachedResourceValues()
        return probe
    }

    /// Is the recorded folder still the one EditMD made?
    ///
    /// Checked on **every** ask, not only when the folder is first chosen: a
    /// user can delete it and leave a symlink in its place, and a recorded
    /// path would otherwise walk straight through it into the target.
    ///
    /// Identity is checked whenever it was recorded. No record at all means
    /// the volume never offered one, and the structural check stands alone
    /// (rather than migrating the folder on every launch). But a record that
    /// cannot be confirmed now — the identifier suddenly unreadable — is not a
    /// pass: that is precisely the case a swapped directory would present on a
    /// volume where the check used to work. Failing closed costs at most a
    /// fresh `EditMD 2`; failing open would hand a stranger's folder our
    /// clips.
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

    /// A directory of that name is nobody's only when it holds **nothing at
    /// all**. Hidden entries count: a `.git` or `.obsidian` inside means the
    /// folder is somebody's vault, and skipping hidden files would have made
    /// EditMD seed straight into it. A symlink is never adopted either,
    /// whatever it points at — the target is not ours to fill.
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

    /// The folder introduces itself only on a genuinely fresh start. An
    /// existing sidebar means an existing user — their tree is theirs, and
    /// nothing is added to it.
    ///
    /// With an empty sidebar the folder is always adopted, including when an
    /// `editmd://` clip beat `applicationDidFinishLaunching` to the window:
    /// that clip landed in this very folder, so showing it in the sidebar is
    /// the point. What the clip keeps is the **document** — the README does
    /// not replace what the user is already looking at.
    static func presentation(
        sidebarIsEmpty: Bool,
        mainPaneIsWelcome: Bool,
        hasEditorModeClaim: Bool
    ) -> Presentation {
        guard sidebarIsEmpty else { return .none }
        return mainPaneIsWelcome && !hasEditorModeClaim ? .adoptAndOpenReadme : .adopt
    }

    /// The bundled documents (sources in `Resources/starter/`) and where each
    /// one goes inside the folder. The build flattens `Resources/` into the
    /// bundle root, so the tree the user receives is described here rather
    /// than mirrored from the bundle layout.
    static let bundledDocuments: [(resource: String, relativePath: String)] = [
        ("README", "README.md"),
        ("Editing modes", "Guide/Editing modes.md"),
        ("Web clipper", "Guide/Web clipper.md"),
        ("Markdown showcase", "Guide/Markdown showcase.md"),
    ]

    /// Writes the bundled documents into `root`, creating it and `Guide/`.
    /// Returns the files it created.
    ///
    /// Never overwrites, and never gives up on the rest because of one file:
    /// a document the user has already edited — or a clip that took the name,
    /// possibly while this very copy was running — wins over the bundled
    /// version, and the remaining documents still land.
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
                // The existing file wins — including one a clip created a
                // moment ago, between a check and a copy. Testing first and
                // copying second would have made that race abort the whole
                // seed and lose the documents after it.
                continue
            }
        }
        return created
    }
}

/// Single owner of the "where is our folder" decision.
///
/// Two independent paths need it on a first launch, and an `editmd://` clip
/// gets there **first**: its Apple Event beats `applicationDidFinishLaunching`.
/// If each answered on its own, a user who already has a `~/Documents/EditMD`
/// would get their folder written into by the clip while the guide stepped
/// aside to `EditMD 2` — two different places, one of them not ours. Both
/// callers await this actor instead, so the directory is created once and
/// everyone is told the same path. Off the main actor by construction.
actor StarterFolderOwner {
    static let shared = StarterFolderOwner()

    private let preferred: URL
    private let defaultsSuite: String?
    private var resolved: URL?
    private var resolvedIdentity: Int?

    /// `defaultsSuite` is a name rather than a `UserDefaults` so the actor
    /// stays free of shared mutable state it does not own; `nil` is `.standard`.
    init(preferring preferred: URL = StarterFolder.defaultURL,
         defaultsSuite: String? = nil) {
        self.preferred = preferred
        self.defaultsSuite = defaultsSuite
    }

    private var defaults: UserDefaults {
        defaultsSuite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    /// The folder EditMD owns: the recorded one, or a freshly created one.
    /// Recording happens as soon as the directory exists, before anything is
    /// written into it — a guide that fails to copy must not cost the clips
    /// their home.
    func folder() throws -> URL {
        let store = defaults
        // Re-checked every time, cache included: what sits at that path can be
        // deleted, replaced, or turned into a symlink between two clips.
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
