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

    /// UserDefaults flag, so an upgrade seeds the folder exactly once.
    static let seededKey = "starter.seeded"

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

    /// Seeds the folder the first time this installation runs. Returns the
    /// folder when it was seeded now, `nil` when it had been seeded before (or
    /// when it could not be created — a missing guide is never worth blocking
    /// a launch, so the failure is logged and swallowed).
    ///
    /// The folder is only ever one EditMD **created itself**: a
    /// `~/Documents/EditMD` that already belongs to the user is not adopted,
    /// not written into, and not opened — the guide goes to `EditMD 2` beside
    /// it instead.
    static func seedIfNeeded(
        at preferredRoot: URL = StarterFolder.defaultURL,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> URL? {
        guard !defaults.bool(forKey: seededKey) else { return nil }
        // One attempt per installation, whatever the outcome: a launch must
        // not keep retrying a location the filesystem refuses.
        defaults.set(true, forKey: seededKey)
        do {
            let root = try makeOwnFolder(preferring: preferredRoot)
            let created = try seedContents(at: root, bundle: bundle)
            starterFolderLog.info(
                "seeded starter folder with \(created.count, privacy: .public) files")
            return root
        } catch {
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
        for attempt in 1...maxNameAttempts {
            let candidate = attempt == 1
                ? preferred
                : parent.appendingPathComponent("\(base) \(attempt)")
            do {
                try manager.createDirectory(
                    at: candidate, withIntermediateDirectories: false)
                return normalized(candidate)
            } catch let error as NSError where error.isFileExists {
                if isEmptyDirectory(candidate) { return normalized(candidate) }
                continue
            }
        }
        throw SeedError.noFreeFolderName
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        return contents.isEmpty
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
    /// Never overwrites: a document the user has already edited (or a clip
    /// that happens to share a name) wins over the bundled copy, so running
    /// this twice is safe and lossless.
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
            guard !manager.fileExists(atPath: target.path) else { continue }
            try manager.copyItem(at: source, to: target)
            created.append(target.standardizedFileURL)
        }
        return created
    }
}
