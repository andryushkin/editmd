import AppKit
import Foundation

/// Installs agent-status hooks package into `~/.config/editmd/agent-status/`
/// and optionally merges Claude hooks fragment (plan 09 stage 2/4).
enum AgentHooksInstaller {

    static let configDirName = "editmd"
    static let packageDirName = "agent-status"

    static func installDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(".config/\(configDirName)/\(packageDirName)", isDirectory: true)
    }

    /// Copy bundled agent-status tree. Returns destination directory.
    static func installPackage(
        bundle: Bundle = .main,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        editmdctlPath: String? = nil
    ) throws -> URL {
        let dest = installDirectory(home: home)
        try fileManager.createDirectory(at: dest, withIntermediateDirectories: true)

        // Resolve bundled resources (may be flat or nested after copy).
        let names = [
            "editmd-agent-status.sh",
            "editmd-codex-status.sh",
            "hooks.fragment.json",
            "editmd-status.ts",
            "integration.sh",
            "integration.fish",
        ]
        for name in names {
            if let url = findBundled(name: name, bundle: bundle),
               let data = try? Data(contentsOf: url) {
                var text = String(decoding: data, as: UTF8.self)
                if name == "editmd-agent-status.sh", let ctl = editmdctlPath {
                    // Bake absolute editmdctl for hooks when available.
                    text = text.replacingOccurrences(
                        of: "EDITMDCTL_DEFAULT=\"${EDITMDCTL_DEFAULT:-editmdctl}\"",
                        with: "EDITMDCTL_DEFAULT=\"${EDITMDCTL_DEFAULT:-\(ctl)}\""
                    )
                }
                let target = dest.appendingPathComponent(name)
                try text.write(to: target, atomically: true, encoding: .utf8)
                if name.hasSuffix(".sh") {
                    try? fileManager.setAttributes(
                        [.posixPermissions: 0o755], ofItemAtPath: target.path)
                }
            }
        }
        return dest
    }

    static func isInstalled(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> Bool {
        let wrapper = installDirectory(home: home)
            .appendingPathComponent("editmd-agent-status.sh")
        return fileManager.isExecutableFile(atPath: wrapper.path)
            || fileManager.fileExists(atPath: wrapper.path)
    }

    /// Merge Claude hooks fragment into `~/.claude/settings.json` without wiping foreign hooks.
    static func mergeClaudeHooks(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws {
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let wrapper = installDirectory(home: home)
            .appendingPathComponent("editmd-agent-status.sh").path
        let editmdHooks = claudeHooksToInstall(wrapper: wrapper, home: home)

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = obj
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for (key, value) in editmdHooks {
            // Append EditMD entries; do not remove existing arrays.
            var list = hooks[key] as? [Any] ?? []
            // Drop previous EditMD-marked entries.
            list = list.filter { item in
                guard let dict = item as? [String: Any],
                      let inner = dict["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains { ($0["command"] as? String)?.contains("editmd-agent-status") == true }
            }
            if let arr = value as? [Any] {
                list.append(contentsOf: arr)
            }
            hooks[key] = list
        }
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try fileManager.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: settingsURL, options: .atomic)
    }

    /// Hooks to merge: the INSTALLED copy of hooks.fragment.json (the full set —
    /// UserPromptSubmit→active and Notification→blocked drive the ✨ working /
    /// needs-attention states), with `$HOME/…` rewritten to the real wrapper
    /// path. Falls back to a minimal idle/completed pair only when the
    /// fragment is unreadable.
    static func claudeHooksToInstall(
        wrapper: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [String: Any] {
        let fragmentURL = installDirectory(home: home)
            .appendingPathComponent("hooks.fragment.json")
        if let data = try? Data(contentsOf: fragmentURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var hooks = obj["hooks"] as? [String: Any], !hooks.isEmpty {
            let placeholder = "$HOME/.config/editmd/agent-status/editmd-agent-status.sh"
            for (event, value) in hooks {
                // .withoutEscapingSlashes: the default `\/` escaping would
                // break the plain-text placeholder match below.
                guard let json = try? JSONSerialization.data(
                        withJSONObject: value, options: [.withoutEscapingSlashes]),
                      let text = String(data: json, encoding: .utf8) else { continue }
                let rewritten = text.replacingOccurrences(of: placeholder, with: wrapper)
                if let back = try? JSONSerialization.jsonObject(
                    with: Data(rewritten.utf8)) as? [Any] {
                    hooks[event] = back
                }
            }
            return hooks
        }
        return [
            "SessionStart": [[
                "hooks": [[
                    "type": "command",
                    "command": "\"\(wrapper)\" idle --harness claude",
                ]]
            ]],
            "Stop": [[
                "hooks": [[
                    "type": "command",
                    "command": "\"\(wrapper)\" completed --harness claude",
                ]]
            ]],
        ]
    }

    private static func findBundled(name: String, bundle: Bundle) -> URL? {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let subs = [
            "agent-status",
            "agent-status/claude",
            "agent-status/pi",
            "agent-status/shell",
        ]
        for sub in subs {
            if let u = bundle.url(forResource: base, withExtension: ext.isEmpty ? nil : ext,
                                  subdirectory: sub) {
                return u
            }
        }
        return bundle.url(forResource: base, withExtension: ext.isEmpty ? nil : ext)
    }
}

/// Symlink `editmdctl` into `/usr/local/bin` when possible.
enum EditMDCtlInstaller {
    static let linkPath = "/usr/local/bin/editmdctl"

    static func bundledBinaryURL(bundle: Bundle = .main) -> URL? {
        // Next to the app executable when packaged; or sibling product.
        if let exe = bundle.executableURL {
            let candidate = exe.deletingLastPathComponent().appendingPathComponent("editmdctl")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func isLinked() -> Bool {
        FileManager.default.fileExists(atPath: linkPath)
    }

    @MainActor
    static func installWithUI() {
        guard let src = bundledBinaryURL() else {
            let alert = NSAlert()
            alert.messageText = String(localized: "editmdctl not found in this build")
            alert.informativeText = String(localized: "Build the editmdctl target, or invoke it from DerivedData. You can still set EDITMDCTL to an absolute path for hooks.")
            alert.runModal()
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: URL(fileURLWithPath: "/usr/local/bin"), withIntermediateDirectories: true)
            if fm.fileExists(atPath: linkPath) {
                try fm.removeItem(atPath: linkPath)
            }
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: src.path)
            let alert = NSAlert()
            alert.messageText = String(localized: "Command Line Tool installed")
            alert.informativeText = linkPath
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = String(localized: "Could not install symlink")
            alert.informativeText =
                String(localized: "\(error.localizedDescription)\n\nYou can copy manually:\n  ln -sf \(src.path) \(linkPath)")
            alert.runModal()
        }
    }
}
