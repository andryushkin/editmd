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
  already opened. It is honoured only when exactly one adopted root of that
  name exists on disk: nothing stops a user from adopting two roots with the
  same name, and guessing beats neither the setting nor the user's trust.
  Unknown, ambiguous, or missing → the setting below.
- Reserved and currently ignored: `content`, `append`, `silent`. Unknown
  commands and parameters are dropped rather than failing — any web page can
  open one of these URLs.
- Destination (`ClipDestination`, Settings ▸ General ▸ Web clips):
  a named workspace that is adopted and on disk wins; otherwise the setting
  decides — a fixed **Folder** or the **Active workspace** root
  (`WorkspaceModel.activeWorkspaceRoot`). A workspace that no longer exists on
  disk is never recreated: the clip lands in the configured folder instead.
  An unset folder setting (the default) resolves to `.starterFolder` — not to
  a path, but to a question for `StarterFolderOwner`, because the folder may
  still have to be created and only one place may decide where.
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

`App/StarterFolder.swift` creates `~/Documents/EditMD` — or the next free name
beside it — the first time an installation launches (flag `starter.seeded`,
one attempt per installation, seeded off the main actor): `README.md` plus
`Guide/` — editing modes, the web clipper, a Markdown showcase. The documents
are sources in `Resources/starter/`; because the build flattens `Resources/`
into the bundle root, the tree the user receives is declared by
`StarterFolder.bundledDocuments`, not mirrored from the bundle.

**One owner.** `StarterFolderOwner` (an actor) answers *where* that folder is,
creates it on the first ask, and records the path in `starter.folder` — plus
its document identifier in `starter.folderID`, where the volume provides one —
the moment the directory exists, before anything is copied into it. The record
is re-checked on every ask (cache included, through a URL with nothing memoized
on it): a path is not an identity, and a folder deleted and replaced by a
symlink must not be walked through. An identifier that was recorded and cannot
be confirmed now fails **closed** — the folder is not assumed ours — because
that is exactly what a swapped directory looks like on a volume where the
check used to work. Two callers
need the answer on a first launch and a clip gets there first (its Apple Event
beats `applicationDidFinishLaunching`): if each decided on its own, a user who
already owns `~/Documents/EditMD` would get the clip written into their folder
while the guide stepped aside to `EditMD 2`. Both await the actor, so the
decision happens once — and a guide that fails to copy still leaves the clips
a recorded home.

Three rules keep it from being a nuisance:

- **Never overwrite.** A document that already exists — edited, or a clip that
  took the name — always wins over the bundled copy. The copy itself is the
  check (`copyItem` failing with file-exists), so a clip landing mid-seed loses
  neither its file nor the documents that were still to come.
- **Never restore.** A user who deletes the folder does not get it back; only
  the clips destination is recreated, empty, on demand.
- **Never take over.** Only a directory EditMD created itself is ever written
  into: creation *is* the ownership test (`withIntermediateDirectories: false`
  fails instead of merging), so a `~/Documents/EditMD` that already holds the
  user's files is left untouched and everything steps aside to `EditMD 2`. A
  folder counts as free only when it holds **nothing at all** — a lone `.git`
  or `.obsidian` marks somebody's vault — and a symlink is never adopted,
  whatever it points at. An existing sidebar is never rearranged. With an
  empty sidebar the folder is adopted — including on a launch that carried a
  clip, since the clip landed in it — but the README opens only when the
  window is still empty, so a clip keeps its document.

**A refused access is retried; nothing else is.** `~/Documents` sits behind the
system's Files and Folders consent, so a first launch can meet "Don't Allow" —
the prompt carries `NSDocumentsFolderUsageDescription` (localized in
`Resources/InfoPlist.xcstrings`) to say what the folder is for. An answer like
that is reversible under Privacy & Security, so it hands the attempt back
(`StarterFolder.returnSeedAttempt` on `NSError.isPermissionDenied`) instead of
costing the installation its only one.

The retry is silent and unbounded, and the contract has to be read that way.
Silent: the system remembers the refusal and keeps returning the same error
without prompting again — a later launch re-attempts the access, it does not
re-ask the user, who has to grant it under Privacy & Security ▸ Files and
Folders. Unbounded and *wider than TCC*: a denial reaches us as `EACCES`/`EPERM`
or its Cocoa equivalent whether it came from consent, POSIX permissions, an ACL,
SIP, or data protection, and one `NSError` cannot tell those apart — so a
permanently unwritable location is re-attempted on every launch, forever. That
is deliberate. The cost is one `createDirectory` that fails immediately on a
detached task; a bounded retry would instead put an expiry date on a folder the
user may still enable next month. Failures that are not about access — no free
name, missing bundled documents — spend the attempt as before.

The consent itself is granted once per installed app: outside the sandbox it is
bound to the code signature, so a Developer ID build keeps it across updates,
while an ad-hoc local build asks again after every rebuild.

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
