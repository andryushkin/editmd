import AppKit
import Foundation
import os

/// Installs the bundled EditMD agent skill package into
/// `~/.claude/skills/editmd/` and `~/.codex/skills/editmd/` (plan 09 stage 3).
enum SkillInstaller {

    static let skillFolderName = "editmd"
    static let skillFileName = "SKILL.md"
    /// Extra docs shipped next to SKILL.md.
    static let packageFiles = [
        "SKILL.md", "reference.md", "examples.md", "troubleshooting.md", "prompts.md"
    ]

    enum Result: Equatable {
        case installed(URL)
        case updated(URL)
        case unchanged(URL)
        case cancelled
        case failed(String)
    }

    static func claudeDestination(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".claude/skills/\(skillFolderName)", isDirectory: true)
    }

    static func codexDestination(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".codex/skills/\(skillFolderName)", isDirectory: true)
    }

    /// All known skill destinations (easy to extend for other harnesses).
    static func destinations(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [(name: String, url: URL)] {
        [
            ("Claude", claudeDestination(home: home)),
            ("Codex", codexDestination(home: home)),
        ]
    }

    /// Bundled SKILL.md lookup (new package layout first).
    static func bundledSkillURL(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "SKILL", withExtension: "md",
                                subdirectory: "agent-skill") {
            return url
        }
        if let url = bundle.url(forResource: "SKILL", withExtension: "md",
                                subdirectory: "skills/editmd") {
            return url
        }
        if let url = bundle.url(forResource: "SKILL", withExtension: "md",
                                subdirectory: "editmd") {
            return url
        }
        // Flat resource (legacy xcodegen file ref).
        return bundle.url(forResource: "SKILL", withExtension: "md")
    }

    static func bundledContent(bundle: Bundle = .main) -> String? {
        guard let url = bundledSkillURL(bundle: bundle) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Bundled companion files (reference/examples/…) keyed by file name.
    static func bundledPackageContents(bundle: Bundle = .main) -> [String: String] {
        var out: [String: String] = [:]
        for name in packageFiles {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            let url =
                bundle.url(forResource: base, withExtension: ext,
                           subdirectory: "agent-skill")
                ?? bundle.url(forResource: base, withExtension: ext,
                              subdirectory: "skills/editmd")
                ?? (name == skillFileName ? bundledSkillURL(bundle: bundle) : nil)
            if let url, let text = try? String(contentsOf: url, encoding: .utf8) {
                out[name] = text
            }
        }
        return out
    }

    /// Pure install of SKILL.md only (existing tests / simple path).
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

    /// Install full package (SKILL + companions). Returns SKILL.md result.
    static func installPackage(
        files: [String: String],
        to destination: URL,
        fileManager: FileManager = .default
    ) throws -> Result {
        guard let skill = files[skillFileName] ?? files["SKILL.md"] else {
            throw CocoaError(.fileNoSuchFile)
        }
        let skillResult = try install(content: skill, to: destination, fileManager: fileManager)
        for (name, body) in files where name != skillFileName {
            let target = destination.appendingPathComponent(name)
            try body.write(to: target, atomically: true, encoding: .utf8)
        }
        return skillResult
    }

    static func unifiedDiff(old: String, new: String) -> String {
        formatUnifiedDiff(old: old, new: new,
                          oldName: "installed/SKILL.md",
                          newName: "bundled/SKILL.md")
    }

    /// Whether skill is installed and matches bundled SKILL.md.
    static func isInstalled(
        at destination: URL = claudeDestination(),
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let bundled = bundledContent(bundle: bundle) else { return false }
        let target = destination.appendingPathComponent(skillFileName)
        guard let existing = try? String(contentsOf: target, encoding: .utf8) else {
            return false
        }
        return existing == bundled
    }

    // MARK: UI entry (Help menu / Integrations)

    @MainActor
    static func installWithUI() {
        let package = bundledPackageContents()
        guard let content = package[skillFileName] ?? bundledContent() else {
            presentAlert(title: "Skill missing",
                         text: "This build has no bundled editmd skill.")
            return
        }
        let dest = claudeDestination()
        let target = dest.appendingPathComponent(skillFileName)
        let fm = FileManager.default

        if fm.fileExists(atPath: target.path),
           let existing = try? String(contentsOf: target, encoding: .utf8) {
            if existing == content, package.keys.count <= 1 {
                presentAlert(title: String(localized: "Already up to date"),
                             text: String(localized: "editmd skill is already installed at\n\(target.path)"))
                return
            }
            if existing != content {
                let diff = unifiedDiff(old: existing, new: content)
                let alert = NSAlert()
                alert.messageText = String(localized: "Update editmd agent skill?")
                alert.informativeText =
                    String(localized: "An older skill exists at \(target.path).\n\nDiff (truncated):\n")
                    + String(diff.prefix(2000))
                alert.alertStyle = .informational
                alert.addButton(withTitle: String(localized: "Update"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
        } else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Install editmd agent skill?")
            alert.informativeText =
                String(localized: "Copies the skill package to \(dest.path) (and Codex if present) so agents can run editmdctl and the review-mark workflow.")
            alert.alertStyle = .informational
            alert.addButton(withTitle: String(localized: "Install"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            let files = package.isEmpty ? [skillFileName: content] : package
            let result = try installPackage(files: files, to: dest)
            // Always try Codex destination (create tree if parent exists or always).
            _ = try? installPackage(files: files, to: codexDestination())
            switch result {
            case .installed(let url):
                presentAlert(title: String(localized: "Skill installed"),
                             text: String(localized: "\(url.path)\nAlso installed for Codex when possible."))
            case .updated(let url):
                presentAlert(title: String(localized: "Skill updated"), text: url.path)
            case .unchanged(let url):
                presentAlert(title: String(localized: "Already up to date"), text: url.path)
            case .cancelled:
                break
            case .failed(let msg):
                presentAlert(title: String(localized: "Install failed"), text: msg)
            }
        } catch {
            presentAlert(title: String(localized: "Install failed"), text: String(describing: error))
        }
    }

    @MainActor
    private static func presentAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}
