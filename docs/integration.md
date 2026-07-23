# Agent integration

EditMD integrates with coding agents in two directions: it acts as an **IDE
for Claude Code** (the agent sees selections, opens files, shows diffs), and
it exposes a **control socket + CLI** so any agent can drive the editor and
query the vault graph. All protocol messages are English and unlocalized.

Code lives in `EditMD/EditMD/Integration/`. Neither service starts under
XCTest.

## Claude Code IDE bridge

`ClaudeIDEService` / `ClaudeIDEServer` implement the IDE side of Claude
Code's MCP-over-WebSocket protocol; `IDELockFile.swift` writes the discovery
lock file that lets `claude` find the running editor. Advertised tools
(`ClaudeIDETools.swift`): `getCurrentSelection`, `getLatestSelection`,
`getOpenEditors`, `getWorkspaceFolders`, `openFile`, `openDiff`,
`checkDocumentDirty`, `saveDocument`, `close_tab`, `closeAllDiffTabs`
(plus handlers for `getDiagnostics` and `executeCode`).

The `tools/list` is **fixed**: the Claude Code CLI aborts the handshake on
unknown tools, so new agent-facing capabilities go into `editmdctl`, not into
the IDE tool list.

`openDiff` is a blocking tool: `DiffApprovalController` completes its
continuation exactly once for Accept / Reject / tab close / disconnect /
timeout. Edits accepted from a diff are applied through
`DocumentRegistry.applyAgentEdit` (see [architecture.md](architecture.md)).

## Control socket and `editmdctl`

`ControlServer` listens on a unix domain socket
(`~/Library/Application Support/EditMD/control.sock`). The protocol
(`ControlProtocol.swift`) is JSON-lines — one request line, one response line:

```
→ {"id":"1","cmd":"open","args":{"path":"/a.md","line":10}}
← {"id":"1","ok":true,"data":{"path":"/a.md"}}
```

`ControlRouter` is two-phase — main-actor state first, deferred disk work
second; socket clients are handled concurrently and never block main.

`editmdctl` (target defined in `EditMD/project.yml`) is the CLI over that
socket. Commands: `ping`, `status`, `open`, `reveal`, `mode`, `marks`,
`diff`, `workspace`, `links` (`outgoing`/`backlinks`/`resolve`), `outline`,
`lint`, `index`, `tags`, `frontmatter`, `search`, `agent-status`.

**Offline engine**: when the app is not running, the same binary answers
vault-graph queries directly from `<workspace>/.editmd/link-index.json`
(`editmdctl/OfflineVault.swift`). That is why the link-graph core files must
stay free of AppKit and app models, and why vault-graph wire shapes are
defined only in `ControlGraphPayload.swift` — the app server and the offline
engine must answer byte-compatibly.

## Shipped agent resources

- `Resources/agent-skill/` — the Claude Code skill EditMD installs
  (`SkillInstaller.swift`): teaches an agent to drive the editor via
  `editmdctl` and to use the review workflow. Trigger phrases include Russian
  ones on purpose (Russian-speaking users talk to their agents in Russian).
- `Resources/agent-status/` — shell/hook integrations
  (`AgentHooksInstaller.swift`): status scripts for Claude Code hooks, Codex,
  and shell prompts so the editor can display what an agent is doing
  (`AgentActivityModel.swift`, `Views/AgentActivityUI.swift`).

## Review handoff

The review queue (`.smotr-queue.json`) and the harness launch line are
described in [review.md](review.md).
