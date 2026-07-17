---
name: editmd
description: >
  Control the EditMD markdown editor from the terminal via `editmdctl` (unix-domain
  socket). Open files, switch modes, list/add smotr review marks, report agent-status,
  show buffer diffs. Use when EditMD is running and the user wants you to drive the
  editor or work review marks without relying only on /ide.
when_to_use: >
  Trigger on: editmd, editmdctl, EditMD, review marks, .review.json, smotr-queue,
  openDiff, /smotr -pr, agent-status, "поставь метку", "открой в EditMD",
  EDITMD_ENABLED, EDITMD_SOCKET, control.sock.
allowed-tools: Bash(editmdctl *)
---

<!-- editmd-skill -->

# editmd — agent skill

EditMD is a native macOS markdown editor (Source / Visual / Preview) with a
local control socket. **No API keys** — everything is on-device.

## Am I inside an EditMD workspace?

When EditMD launches the ✈️ review agent it injects:

| Env | Meaning |
|-----|---------|
| `EDITMD_ENABLED=1` | You were started from EditMD |
| `EDITMD_SOCKET` | Control socket path |
| `EDITMD_WORKSPACE` | Workspace root |
| `EDITMD_QUEUE` | Path to `.smotr-queue.json` |

You can also drive EditMD from any terminal while it is running:

```bash
editmdctl status
editmdctl ping
```

Socket default: `~/Library/Application Support/EditMD/control.sock`  
Override: `EDITMD_CONTROL_SOCK` or `editmdctl --socket PATH …`

## Channels (pick the thinnest that works)

| Channel | When | How |
|---------|------|-----|
| **Files** | Always | `*.md.review.json`, `.smotr-queue.json` |
| **editmdctl** | Scripts / any harness | control socket |
| **/ide** (Claude Code) | Live selection + blocking `openDiff` | WebSocket lock in `~/.claude/ide/` |
| **agent-status** | Presence in the ✨ toolbar | `editmdctl agent-status …` |

Prefer **editmdctl + files** unless the user needs live selection / openDiff.

## Quick commands

```bash
editmdctl status
editmdctl open ~/notes/plan.md --line 42
editmdctl mode preview
editmdctl marks list
editmdctl marks add --type comment --note "unclear"
editmdctl agent-status active --label "reviewing" --harness claude
editmdctl agent-status completed --harness claude
editmdctl diff show
```

Mark types for **authors**: `question | fix | rewrite | cut | keep | comment`  
Do **not** invent `suggest` as an author — that is the agent’s track-changes reply.

## Review loop

1. User places open marks (Review tab or `marks add`).
2. Queue: `.smotr-queue.json` at the workspace root (✈️ or you write it).
3. Process with the user’s harness, e.g. `cd "$EDITMD_WORKSPACE" && claude -p "/smotr -pr"`.
4. Reply in mark threads and/or add `suggest` marks (`quote` → `replacement`).
5. User Accepts/Rejects in Review — do **not** rewrite the file directly when a suggest is enough.
6. Report status: `editmdctl agent-status completed`.

Sidecar: `note.md` → `note.md.review.json` (smotr-compatible).

## More

- Full CLI + wire shapes → `reference.md`
- Recipes → `examples.md`
- Problems → `troubleshooting.md`
