# EditMD agent instructions

## Mandatory entry point

Before any work in this repository read `CLAUDE.md` in full. It is the
project's primary up-to-date guide: architecture, verification commands,
working rules, and invariants. Do not rely on this pointer alone — open the
file explicitly at the start of a task.

The detailed decision log (`HISTORY.md`) moved out of the repository on
2026-07-23 to the author's vault. If the current code contradicts something you
believe was decided earlier, the code and `CLAUDE.md` win; ask the author when
history context is needed.

## Other documentation

- `THIRD_PARTY_NOTICES.md` — dependency licenses; update it when vendored
  assets or packages change.
- `README.md` — the public face of the repository; keep build instructions
  accurate.

## Execution

- All repository artifacts are in English: code comments, docs, commit
  messages.
- `EditMD/project.yml` is the source of the project structure; do not edit the
  generated `.xcodeproj` instead of it.
- Preserve other people's changes in a dirty worktree and do not include them
  in your commits.
- After changes run the targeted tests, then the full suite in reasonable
  proportion to the risk, and `git diff --check`.
- Add durable new rules briefly to `CLAUDE.md`.
