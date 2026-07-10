import AppKit
import Foundation
import os

/// Installs the bundled EditMD agent skill into `~/.claude/skills/editmd/`
/// (and `~/.codex/skills/editmd/` when present) — agterm-style Help menu action.
enum SkillInstaller {

    static let skillFolderName = "editmd"
    static let skillFileName = "SKILL.md"

    enum Result: Equatable {
        case installed(URL)
        case updated(URL)
        case unchanged(URL)
        case cancelled
        case failed(String)
    }

    /// Destination under the user's Claude skills tree.
    static func claudeDestination(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/skills/\(skillFolderName)", isDirectory: true)
    }

    /// Optional Codex sibling (same layout as agterm).
    static func codexDestination(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".codex/skills/\(skillFolderName)", isDirectory: true)
    }

    /// Bundled skill markdown from the app Resources.
    static func bundledSkillURL(
        bundle: Bundle = .main
    ) -> URL? {
        // xcodegen resources: EditMD/Resources/skills/editmd/SKILL.md
        if let url = bundle.url(forResource: "SKILL",
                                withExtension: "md",
                                subdirectory: "skills/editmd") {
            return url
        }
        // Fallback: flat copy path.
        return bundle.url(forResource: "SKILL", withExtension: "md",
                          subdirectory: "editmd")
    }

    /// Reads bundled content, or nil if missing.
    static func bundledContent(bundle: Bundle = .main) -> String? {
        guard let url = bundledSkillURL(bundle: bundle) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Pure install into `destination` from `content`. Testable without UI.
    static func install(content: String, to destination: URL,
                        fileManager: FileManager = .default) throws -> Result {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let target = destination.appendingPathComponent(skillFileName)
        if fileManager.fileExists(atPath: target.path) {
            let existing = try String(contentsOf: target, encoding: .utf8)
            if existing == content {
                return .unchanged(target)
            }
            try content.write(to: target, atomically: true, encoding: .utf8)
            return .updated(target)
        } else {
            try content.write(to: target, atomically: true, encoding: .utf8)
            return .installed(target)
        }
    }

    /// Diff text for confirmation when updating an existing skill.
    static func unifiedDiff(old: String, new: String) -> String {
        formatUnifiedDiff(old: old, new: new,
                          oldName: "installed/SKILL.md",
                          newName: "bundled/SKILL.md")
    }

    // MARK: UI entry (Help menu)

    @MainActor
    static func installWithUI() {
        guard let content = bundledContent() else {
            presentAlert(title: "Skill missing",
                         text: "This build has no bundled editmd skill.")
            return
        }
        let dest = claudeDestination()
        let target = dest.appendingPathComponent(skillFileName)
        let fm = FileManager.default

        if fm.fileExists(atPath: target.path),
           let existing = try? String(contentsOf: target, encoding: .utf8) {
            if existing == content {
                presentAlert(title: "Already up to date",
                             text: "editmd skill is already installed at\n\(target.path)")
                return
            }
            let diff = unifiedDiff(old: existing, new: content)
            let alert = NSAlert()
            alert.messageText = "Update editmd agent skill?"
            alert.informativeText =
                "An older skill exists at \(target.path).\n\nDiff (truncated):\n"
                + String(diff.prefix(2000))
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Update")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        } else {
            let alert = NSAlert()
            alert.messageText = "Install editmd agent skill?"
            alert.informativeText =
                "Copies the skill to \(dest.path) so Claude Code can run "
                + "`editmdctl` and the review-mark workflow."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            let result = try install(content: content, to: dest)
            // Best-effort Codex copy (no extra prompts).
            if FileManager.default.fileExists(
                atPath: codexDestination().deletingLastPathComponent().path) {
                _ = try? install(content: content, to: codexDestination())
            }
            switch result {
            case .installed(let url):
                presentAlert(title: "Skill installed", text: url.path)
            case .updated(let url):
                presentAlert(title: "Skill updated", text: url.path)
            case .unchanged(let url):
                presentAlert(title: "Already up to date", text: url.path)
            case .cancelled:
                break
            case .failed(let msg):
                presentAlert(title: "Install failed", text: msg)
            }
        } catch {
            presentAlert(title: "Install failed", text: String(describing: error))
        }
    }

    @MainActor
    private static func presentAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
