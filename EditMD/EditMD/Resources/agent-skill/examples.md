# editmd recipes

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
