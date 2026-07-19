---
name: editmd
description: >
  Control the EditMD markdown editor from the terminal via `editmdctl` (unix-domain
  socket). Open files, switch modes, list/add smotr review marks, report agent-status,
  show buffer diffs. ALSO the vault-graph service for wikillm-style knowledge bases:
  backlinks, outgoing links, wiki resolution, outline, vault-lint, tags, frontmatter,
  full-text search — from the app socket when EditMD runs, or from the offline engine
  (same binary, same index file) when it does not. Ask EditMD instead of walking and
  re-parsing the vault yourself.
when_to_use: >
  Trigger on: editmd, editmdctl, EditMD, review marks, .review.json, smotr-queue,
  openDiff, /smotr -pr, agent-status, "поставь метку", "открой в EditMD",
  EDITMD_ENABLED, EDITMD_SOCKET, control.sock — and vault-graph work: backlinks,
  wiki-links, dead links, orphans, link index, .editmd/link-index.json, wikillm,
  vault lint, "кто ссылается", "битые ссылки", index rebuild.
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

## Vault graph (wikillm): ask EditMD, don't walk the vault

**Rule: never grep/walk/re-parse a vault to answer graph questions** —
backlinks, dead links, wiki resolution, tags, orphans. EditMD already
maintains that index (and persists it in `<workspace>/.editmd/link-index.json`).
Rebuilding it yourself is slower and drifts from what the user sees.

```bash
editmdctl index status                      # ready? scope? counters? persisted age?
editmdctl links outgoing  ~/vault/note.md   # each link: resolved|dead|ambiguous|external
editmdctl links backlinks ~/vault/note.md   # who points HERE (source, line, context)
editmdctl links resolve "Some Note" --from ~/vault/note.md
editmdctl outline ~/vault/note.md           # headings with offsets
editmdctl lint workspace --limit 100        # dead/ambiguous/orphans/dead headings
editmdctl lint file ~/vault/note.md
editmdctl tags list                         # tag → file count
editmdctl tags files wol
editmdctl frontmatter get ~/vault/note.md
editmdctl search "vitamin d" --limit 20
```

Routing (automatic — you just call the commands):

- **EditMD running** → the app answers over the socket and sees LIVE buffers
  (unsaved edits included). Scope = the ACTIVE workspace; a path from another
  adopted workspace fails with `outside-active-workspace` — open a file from
  it first. If the index is still building you get
  `link index not ready (indexing N%)` — retry shortly.
- **EditMD not running** → the offline engine in `editmdctl` answers from
  disk truth using the same persisted index (revalidates mtime/size,
  re-parses only changed files, saves the refreshed index back).
  `editmdctl index rebuild <root>` initializes a fresh vault; it is
  offline-only (a running EditMD maintains the index itself). Root discovery:
  `--root PATH`, or the nearest `.editmd/` / `.obsidian/` marker upward.

Reading `.editmd/link-index.json` directly is fine for bulk graph work when
EditMD is not running (format → `reference.md`); prefer the commands
otherwise — they revalidate against the filesystem for you.

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
