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

## Update check

EditMD ships outside the App Store and has no updater: it can tell you a
release exists, and that is all it claims to do. Replacing the app stays
manual — `UpdateChecker.swift` never downloads or installs anything.

The question goes to **`https://dotmd.tools/editmd/latest.json`**, not to
GitHub's API: the request stays with the site the app belongs to, has no rate
limit, and lets the site decide what a released copy is told. The document is
generated at deploy time by the site's `build.py` from `products.yaml`
(`update_feed:`), so **cutting a release ends with rebuilding and deploying
dotmd.tools** — see [releasing.md](releasing.md).

```json
{ "version": "0.47.14", "page": "https://dotmd.tools/editmd",
  "notes": "https://dotmd.tools/editmd/changelog", "minimumSystemVersion": "14.0" }
```

The shape is a contract with copies we can no longer change: **add fields,
never rename or drop them**. Decoding tolerates missing and empty values.

The feed is **untrusted input** — a document off the network, parsed by copies
we cannot patch — and is handled as such:

- Only **HTTPS links on `dotmd.tools`** survive decoding. The alert opens one
  behind a label the reader trusts, so a tampered feed must not be able to aim
  it at an attacker's build, plain HTTP, or a look-alike domain. A rejected or
  absent link falls back to `UpdateFeed.productPage`, compiled into the binary,
  so the button is never a no-op.
- The body is **capped at 64 KB** and streamed, so a server ignoring its own
  `Content-Length` cannot make the app hold the whole thing.
- Network wait, parse and the install-channel probes all run **off the main
  actor** (`Task.detached` in `UpdateChecker.probe()`).

What the decision rests on is pure and tested (`UpdateCheckerTests`):

- `AppVersion.parse` — **strict**: an optional `v`, then 1–4 groups of at most
  six digits. Anything else does not parse, and an unparsable version means
  silence. Reading junk as zero is how a feed saying `.999` would otherwise
  become a confident "version 999 is available".
- `UpdateDecision.evaluate` — the verdict. A missing or unparsable version is
  silence, never an invented prompt. A release the Mac cannot run is
  *explained* (silence there reads as "no updates"), but announced **once per
  version** — it cannot change until they upgrade macOS. An unparsable
  `minimumSystemVersion` is ignored rather than obeyed: one malformed field
  must not swallow a real release. A skipped version mutes **only itself**, and
  only on the automatic path — `Check for Updates…` always answers honestly.
- `InstallChannel.detect` — Homebrew only when the cask exists *and* the
  running bundle is exactly the app a cask installs (`EditMD.app`, directly
  inside an Applications folder). It decides the **advice**, not the download:
  telling a brew user to drag a DMG desynchronizes them from brew, and telling
  everyone else to run `brew` hands out a command most of them do not have.
- `UpdateDecision.canPresentNow` — an alert waits for the app to be active with
  no modal up. `runModal` nested inside an open panel traps the user, and an
  alert raised while they are in another app lands where they are not looking.

`UpdateChecker` keeps **one request in flight**: a manual click during the
daily check joins it rather than racing it, and whichever path presents first
claims the answer, so one request can never raise two alerts. Automatic
checking is one request a day, on by default, switchable in Settings ▸ General,
and never runs under XCTest. The request carries a deliberate `User-Agent`
(`EditMD/<version> (macOS <version>)`) instead of URLSession's default, which
already leaks a build number — nothing in it distinguishes one copy from
another. `UpdatePrompt.swift` (`UpdateAlertPresenter`) is the only part that
needs a screen, behind the `UpdatePresenting` seam the service tests use.

## Review handoff

The review queue (`.smotr-queue.json`) and the harness launch line are
described in [review.md](review.md).
