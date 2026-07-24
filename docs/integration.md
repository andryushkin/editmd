# Agent and external integration

EditMD integrates with coding agents in two directions: it acts as an **IDE
for Claude Code** (the agent sees selections, opens files, shows diffs), and
it exposes a **control socket + CLI** so any agent can drive the editor and
query the vault graph. A third, much smaller entry point — the `editmd://`
**URL scheme** — lets a web clipper hand a note over even when the app is not
running. All protocol messages are English and unlocalized.

Agent code lives in `EditMD/EditMD/Integration/`; neither service starts under
XCTest. The URL scheme lives in `EditMD/EditMD/App/`.

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

## `editmd://` URL scheme (web-clipper handoff)

Registered in `App/Info.plist` (`CFBundleURLTypes`), so LaunchServices starts
EditMD for such a URL even from a cold machine — that is the whole reason the
clipper uses it instead of the control socket, which needs a running app.

Contract v1, fixed by the shipped webtodotmd extension (its sidepanel "EditMD"
button copies the Markdown to the clipboard and opens the URL — do not change
the shape unilaterally):

```
editmd://new?file=<name-without-extension>&clipboard
```

- `new` is the only command; the body comes from
  `NSPasteboard.general` when the `clipboard` flag is present, otherwise the
  file is created empty.
- `workspace=<name>` names an **adopted** workspace (Obsidian's `vault=`) —
  never a path, so an untrusted sender can only pick among folders the user
  already opened; an unknown name falls through to the setting below.
- Reserved and currently ignored: `content`, `append`, `silent`. Unknown
  commands and parameters are dropped rather than failing — any web page can
  open one of these URLs.
- Destination (`ClipDestination`, Settings ▸ General ▸ Web clips):
  a named workspace that is adopted and on disk wins; otherwise the setting
  decides — a fixed **Folder** (default: `~/Documents/EditMD`, the folder
  seeded on first launch, see below) or the **Active workspace** root
  (`WorkspaceModel.activeWorkspaceRoot`). A workspace that no longer exists on
  disk is never recreated: the clip lands in the configured folder instead.
- Only the pasteboard read and the workspace lookup run on the main actor;
  creating the folder and writing the body happen on a detached task, so a
  slow or network-mounted vault cannot freeze the UI from a URL.
- The file is opened through `AppState.openCreatedFile` — write-first Visual
  mode. On a launch caused by the URL the Apple Event arrives **before**
  `applicationDidFinishLaunching`, so `AppState.applyColdLaunchEditorMode()`
  skips the Preview reset when a mode is already applied or *reserved*. A clip
  only reserves it across the write (`reserveEditorModeForCreate`): the
  `editorMode` setting is global, so writing Visual up front would drag the
  document the user is reading into Visual for the length of the write. The
  mode is applied when the file lands; a failed write leaves a running session
  untouched and replays the cold-launch reset when it had stood aside.
- Logging stays out of the way of the note: the query (title, and the reserved
  `content=` body) is never logged, and the created file name is `.private`.

Because the sender is untrusted, `App/URLCommand.swift` keeps the whole
contract in pure Foundation functions (`EditMDURLCommand.parse`,
`ClipFileNaming`, `ClipFile`), unit-tested in `URLCommandTests.swift`:

- the name is re-sanitized (no separators, control characters, or leading
  dots; a trailing `.md` dropped; capped at 100 characters / 200 bytes; empty
  → `Clip`), so a clip can never escape the destination folder;
- a taken name uniquifies (`Name 2.md`, `Name 3.md`…) and every write uses
  `.withoutOverwriting` — this path creates files and never overwrites,
  deletes, or interprets a body;
- oversized bodies are truncated at 4 MB on a character boundary.

## The starter folder

`App/StarterFolder.swift` creates `~/Documents/EditMD` the first time an
installation launches (flag `starter.seeded`, seeded off the main actor):
`README.md` plus `Guide/` — editing modes, the web clipper, a Markdown
showcase. The documents are sources in `Resources/starter/`; because the build
flattens `Resources/` into the bundle root, the tree the user receives is
declared by `StarterFolder.bundledDocuments`, not mirrored from the bundle.

Three rules keep it from being a nuisance:

- **Never overwrite.** A document that already exists — edited, or a clip that
  took the name — always wins over the bundled copy.
- **Never restore.** A user who deletes the folder does not get it back; only
  the clips destination is recreated, empty, on demand.
- **Never take over.** The folder is adopted into the sidebar (and its README
  opened) only when the sidebar is empty and nothing else claimed the window
  — an existing setup, or a launch caused by a clip, is left alone.

It is also the default clips destination, so a new user finds their first clip
next to the instructions.

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
