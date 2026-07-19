# editmd recipes

## Vault graph: fix dead links in a wikillm vault

```bash
# Never grep the vault for links — ask EditMD:
editmdctl index status
editmdctl lint workspace --limit 50 --json      # dead/ambiguous/orphans
editmdctl links backlinks ~/vault/note.md       # who cites this page
editmdctl links resolve "Vitamin D" --from ~/vault/note.md
# Findings carry `suggestion` (best rename guess) + line/offset for jumps:
editmdctl open ~/vault/note.md --line 42
```

## Vault graph with EditMD closed (offline engine)

```bash
editmdctl index rebuild ~/vault                 # fresh vault: initialize the index
editmdctl --root ~/vault lint workspace --json  # answers from disk truth
editmdctl --root ~/vault search "mTOR" --limit 10
# Bulk graph work: read .editmd/link-index.json directly (see reference.md)
```

## Survey a page before editing it

```bash
editmdctl outline ~/vault/note.md          # structure
editmdctl frontmatter get ~/vault/note.md  # status/tags/doi live here
editmdctl links outgoing ~/vault/note.md   # what it cites, what is dead
editmdctl links backlinks ~/vault/note.md  # what depends on it
```

## Process the review queue

```bash
# If EditMD launched you:
cd "${EDITMD_WORKSPACE:-.}"
editmdctl agent-status active --label "processing queue" --harness claude

# Read the queue file (or trust /smotr -pr skill)
cat "${EDITMD_QUEUE:-.smotr-queue.json}"

# Leave replies / suggests in each file's .review.json, then:
editmdctl agent-status completed --harness claude
```

Manual launch from a terminal (matches ✨ prompt palette):

```bash
cd /path/to/workspace && claude -p "/smotr -pr"
```

## Review the active file without a queue

```bash
editmdctl open ~/notes/plan.md
editmdctl marks list --path ~/notes/plan.md
editmdctl marks add --type question --note "What is the success metric?"
editmdctl agent-status completed --label "left questions"
```

## Add a suggest (track-change)

Write into `plan.md.review.json` a mark with:

- `type`: `suggest`
- `quote`: exact fragment from the file
- `replacement`: new text
- `status`: `open`

The user Accepts in the Review sidebar; EditMD applies via `DocumentRegistry`.

## Open a file and jump

```bash
editmdctl open ~/notes/plan.md --heading "Architecture"
editmdctl mode preview
```

## Report presence from a shell agent

```bash
export EDITMD_ENABLED=1   # optional but recommended
~/.config/editmd/agent-status/editmd-agent-status.sh active --harness shell
# … work …
~/.config/editmd/agent-status/editmd-agent-status.sh completed --harness shell
```
