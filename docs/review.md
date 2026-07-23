# Review marks

A mark is a review thread anchored to a text fragment. Marks let an author
annotate a document (questions, fix requests, style notes) and let an agent
answer them with tracked edits — without ever touching the file body outside
the accepted-edit path.

Model: `Editor/ReviewMarks.swift` (pure value types, Foundation only).
UI: `Views/ReviewModel.swift`, `Views/ReviewSidebar.swift`,
`Editor/ReviewHighlight.swift`.

## Sidecar

Marks live in `<file>.md.review.json` **next to** the file; the original is
never modified by marking. The schema is smotr-compatible — EditMD is a second
frontend for the same marks, so a sidecar written by either tool must open in
the other without loss. Two rules follow:

- **Fidelity**: unknown fields (html-mark `selector`/`vtype`, future schema
  additions) are preserved verbatim through an `extra` bag. Known fields are
  only added, never dropped.
- **Raw anchors**: `quote` + `prefix` + `start` are resolved against the raw
  markdown (the source of truth). Resolution is best-effort with an honest
  `needs-rebase` status when the fragment is gone — never "approximately
  there". Anchors are computed once, off-main, and cached.

Persist/reload is strictly FIFO. A physical path change (rename/move) first
takes the `ReviewModel` FIFO permit, then without suspension sets the
`AppState` gates and reserves in `DocumentRegistry` all destinations before
all sources; completion hands exact relocate/drop outcomes to all three
coordinators.

## Mark types

Author intent, processed by agents in priority order:

| Type | Meaning |
| --- | --- |
| `question` | blocking question — processed first |
| `fix` | factual/correctness problem |
| `rewrite` | tone or clarity |
| `cut` | remove the fragment |
| `keep` | wording is final — do not touch |
| `comment` | neutral note |
| `suggest` | an agent's track-changes edit (quote → replacement) |

Accepted `suggest` edits are the only path that rewrites the file, and they go
through `DocumentRegistry.applyAgentEdit`.

## Agent handoff

The Review sidebar can hand open marks to an agent: it builds
`.smotr-queue.json` under the workspace root and (opt-in) spawns the
configured harness — `claude -p "/smotr -pr"` or `codex exec …`
(`Views/EditorSettings.swift`). Agents can also add/list marks over the
control socket (`marks` command, see [integration.md](integration.md)); the
router keeps queue writes consistent with the UI's FIFO pipeline.
