import Foundation
import os

let starterFolderLog = Logger(subsystem: "andryushkin.EditMD", category: "starter")

/// The folder EditMD creates for a new user: `~/Documents/EditMD`, holding a
/// README, a small `Guide/`, and — until Settings ▸ Web clips says otherwise —
/// the notes sent from the browser extension.
///
/// It is seeded once per installation from `Resources/starter/` and is an
/// ordinary folder afterwards: nothing re-checks it, nothing repairs it, and a
/// user who deletes it is not given it back (the clips folder is recreated on
/// demand, empty). Pure Foundation, so the copy runs off the main actor.
enum StarterFolder {

    /// UserDefaults flag, so an upgrade seeds the folder exactly once.
    static let seededKey = "starter.seeded"

    /// Also the default destination for web clips (`ClipDestination`).
    static var defaultURL: URL {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents")
        return documents.appendingPathComponent("EditMD").standardizedFileURL
    }

    /// Never surfaced to the user — the folder is a courtesy, not a feature a
    /// launch may fail on — so the message stays an unlocalized log string.
    enum SeedError: Error, CustomStringConvertible, Equatable {
        case missingResources

        var description: String {
            switch self {
            case .missingResources: return "bundled starter documents are missing"
            }
        }
    }

    /// Seeds the folder the first time this installation runs. Returns the
    /// folder when it was seeded now, `nil` when it had been seeded before (or
    /// when the copy failed — a missing guide is never worth blocking a
    /// launch, so the failure is logged and swallowed).
    static func seedIfNeeded(
        at root: URL = StarterFolder.defaultURL,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> URL? {
        guard !defaults.bool(forKey: seededKey) else { return nil }
        do {
            let created = try seedContents(at: root, bundle: bundle)
            defaults.set(true, forKey: seededKey)
            starterFolderLog.info(
                "seeded starter folder with \(created.count, privacy: .public) files")
            return root
        } catch {
            starterFolderLog.error(
                "starter folder not seeded: \(String(describing: error), privacy: .public)")
            return nil
        }
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
    /// existing sidebar means an existing user — their tree is theirs — and a
    /// window that already has a document (an `editmd://` clip beats
    /// `applicationDidFinishLaunching`) must not be taken over by a README.
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
