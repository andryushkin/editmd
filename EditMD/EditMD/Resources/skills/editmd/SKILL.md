---
name: editmd
description: >
  Control the EditMD markdown editor from the terminal via `editmdctl`
  (unix-domain socket). Open files, switch modes, list/add smotr review marks,
  show buffer diffs. Use when the user has EditMD running and wants you to
  drive the editor or work review marks without the /ide channel.
  Triggers: editmdctl, "открой в EditMD", "поставь метку", "editmd mode",
  "review marks in EditMD".
---

# editmd — agent skill

EditMD is a macOS markdown editor (Source / Visual / Preview). Integration
with Claude has three channels; this skill is **channel 3** (always-on socket):

| Channel | When | How |
|---------|------|-----|
| IDE/MCP (`/ide`) | Live selection + openDiff | WebSocket, lock in `~/.claude/ide/` |
| Review marks (smotr) | Async threads on anchors | `*.md.review.json` sidecars |
| **editmdctl** | Scripts / any terminal | `~/Library/Application Support/EditMD/control.sock` |

**Requirements:** EditMD must be running. No API keys — local only.

## Install / check

```bash
# App menu: Help ▸ Install Agent Skill…  (copies this file)
which editmdctl || ls /path/to/EditMD.app/Contents/MacOS/  # may ship next to app later
editmdctl status
```

If `editmdctl` is not on PATH, build the `editmdctl` target and put it on PATH,
or invoke the binary from DerivedData. Socket path override:

```bash
export EDITMD_CONTROL_SOCK="/tmp/editmd-test.sock"
```

## Commands

Human output by default; machine-readable with `--json`.

```bash
editmdctl status
editmdctl ping
editmdctl open ~/notes/plan.md
editmdctl open ~/notes/plan.md --line 42
editmdctl open ~/notes/plan.md --heading "Introduction"
editmdctl reveal --line 10
editmdctl mode preview          # source | visual | preview
editmdctl marks list            # open marks on active file
editmdctl marks list --all --path ~/notes/plan.md
editmdctl marks add --type comment --note "unclear"
editmdctl marks add --type fix --note "typo" --quote "teh"
editmdctl diff show             # buffer vs disk
```

### Types for `marks add`

`question` | `fix` | `rewrite` | `cut` | `keep` | `comment`  
(Do **not** create `suggest` — that is Claude’s track-changes reply type.)

If `--quote` is omitted, EditMD uses the **current selection** in Source, Visual,
or Preview. Prefer **Preview** for review selection.

## Review workflow (with marks)

1. User (or you) places open marks in EditMD Review tab or via `marks add`.
2. User clicks ➤ (or you write `.smotr-queue.json`) and runs:
   ```bash
   cd <workspace> && claude -p "/smotr -pr"
   ```
3. You answer in each mark’s thread and/or add `suggest` marks in the sidecar
   (`quote` → `replacement`). Do **not** rewrite the file directly when the
   user wants Accept/Reject — EditMD applies suggests through the registry.
4. User Accepts/Rejects in the Review tab.

Sidecar path: `note.md` → `note.md.review.json` (smotr-compatible).

## Tips

- **Preview-first for marks:** wash + jump live in Preview; Source/Visual are
  secondary for review.
- **openDiff** still needs `/ide` (phase 1). editmdctl does not replace Accept
  for agent file rewrites — use marks/suggest or tell the user to attach `/ide`.
- `diff show` is buffer-vs-disk, not git. For git, use the app’s Git tab or `git`.
- If connect fails: ensure EditMD is frontmost once after launch (socket is
  created at `applicationDidFinishLaunching`).

## JSON shape (protocol)

Request line:

```json
{"id":"1","cmd":"open","args":{"path":"/abs/file.md","line":10}}
```

Response line:

```json
{"id":"1","ok":true,"data":{"path":"/abs/file.md","offset":120}}
```

```json
{"id":"1","ok":false,"error":"file not found: …"}
```
