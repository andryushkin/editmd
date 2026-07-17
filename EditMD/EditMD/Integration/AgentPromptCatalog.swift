import Foundation

// MARK: - Prompt palette (single source for popover ✨ and skill templates)

/// Context for building copy-ready agent prompts.
struct AgentPromptContext: Equatable, Sendable {
    var activeFilePath: String?
    var workspaceRootPath: String?
    var openMarkCount: Int
    /// Preferred harness launch line (e.g. `claude -p "/smotr -pr"`).
    var agentLaunchCommand: String
    /// True when Claude IDE bridge has a connected client.
    var ideConnected: Bool
}

/// One palette entry: short title + shell command (or pasteable instruction).
struct AgentPromptItem: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let detail: String
    let command: String
}

/// Pure prompt builder — same texts as skill package (stage 3 keeps them aligned).
func buildAgentPromptItems(_ ctx: AgentPromptContext) -> [AgentPromptItem] {
    var items: [AgentPromptItem] = []
    let root = ctx.workspaceRootPath
    let file = ctx.activeFilePath

    if ctx.openMarkCount > 0, let root {
        let cmd: String
        if ctx.agentLaunchCommand.contains("cd ") {
            cmd = ctx.agentLaunchCommand
        } else {
            cmd = "cd \(shellQuote(root)) && \(ctx.agentLaunchCommand)"
        }
        items.append(AgentPromptItem(
            id: "process-queue",
            title: String(localized: "Process review queue"),
            detail: String(localized: "\(ctx.openMarkCount) open mark(s) → ✈️ agent"),
            command: cmd
        ))
    }

    if let file {
        let reviewPrompt = """
        Review this markdown file in EditMD and leave open review marks via editmdctl \
        (types: question|fix|rewrite|cut|keep|comment). Do not rewrite the file directly \
        when a suggest mark is enough.

        File: \(file)
        \(root.map { "Workspace: \($0)" } ?? "")

        Commands:
          editmdctl open \(shellQuote(file))
          editmdctl marks list --path \(shellQuote(file))
          editmdctl marks add --type comment --note "…"
        """.trimmingCharacters(in: .whitespacesAndNewlines)
        items.append(AgentPromptItem(
            id: "review-file",
            title: String(localized: "Ask agent to review active file"),
            detail: (file as NSString).lastPathComponent,
            command: reviewPrompt
        ))
    }

    if !ctx.ideConnected {
        let connect = """
        You are helping inside EditMD. Prefer editmdctl (control socket) for open/mode/marks. \
        If Claude Code is available, the user can also run /ide for live selection and openDiff. \
        Install skill: Help ▸ Install Agent Skill… in EditMD. Then: editmdctl status
        """
        items.append(AgentPromptItem(
            id: "connect-editmd",
            title: String(localized: "Tell agent how to use EditMD"),
            detail: String(localized: "Skill + editmdctl discovery"),
            command: connect
        ))
    }

    if items.isEmpty {
        items.append(AgentPromptItem(
            id: "install-start",
            title: String(localized: "Get started"),
            detail: String(localized: "Install skill and check the socket"),
            command: """
            # In EditMD: Help ▸ Install Agent Skill…
            editmdctl status
            editmdctl ping
            """
        ))
    }

    return items
}

/// Default ✈️ launch argv as a single shell line.
func defaultAgentLaunchLine() -> String {
    ReviewQueue.defaultAgentCommand
        .map { ReviewQueue.shellEscapeIfNeeded($0) }
        .joined(separator: " ")
}

private func shellQuote(_ path: String) -> String {
    ReviewQueue.shellEscape(path)
}
