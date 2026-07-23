# EditMD documentation

Project documentation written for two audiences at once: people reading the
repository and AI agents working in it. Every file describes **stable facts**
about one domain — what exists, how it fits together, and which contracts must
not be broken. Release chronology and investigation write-ups do not live here
(the historical decision log is kept outside the repository).

## Map

| File | Domain |
| --- | --- |
| [architecture.md](architecture.md) | Document model, windows, the three editing modes, round-trip pipeline, performance rules |
| [vault.md](vault.md) | Workspaces, wiki-links, link index, vault lint, search, tags, frontmatter |
| [review.md](review.md) | Review marks: sidecar schema, anchoring, lifecycle, agent processing |
| [integration.md](integration.md) | Claude Code IDE bridge (MCP), control socket, `editmdctl`, agent skill and status |
| [testing.md](testing.md) | Build commands, test layout, fixtures, conventions |
| [audit.md](audit.md) | The repo auditor: mechanical checks (`scripts/audit.sh`) + review judgment list |
| [releasing.md](releasing.md) | Version scheme, when a release is cut, changelog format, release process |

`CLAUDE.md` at the repository root stays the compressed working guide —
invariants and rules an agent must load before editing. These docs are the
expanded explanation behind those rules; when they disagree with the code, the
code wins and the doc must be fixed in the same change.

## Rules for writing here

- English for all prose, like code comments and commit messages elsewhere in
  the repository. This does **not** license removing intentional non-English
  content: the ru localization catalog, Cyrillic test data and fixtures,
  language-sensitive examples, and the Russian trigger phrases in the shipped
  agent skill stay.
- One domain per file; link between files instead of repeating content.
- Reference code by path (`EditMD/EditMD/Editor/…`) so readers and agents can
  jump straight to it.
- Record the *why* behind non-obvious contracts — that is what saves the next
  reader from re-deriving or breaking them.
- No chronology: if a fact is only interesting as history, it belongs in the
  author's decision log, not here.
