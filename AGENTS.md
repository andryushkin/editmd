# EditMD agent instructions

## Startup

1. Read `CLAUDE.md` in full — the compressed working guide: project map,
   build/test commands, non-negotiable invariants.
2. Check `git status --short`. Preserve anything already dirty in the
   worktree; never include someone else's changes in your commits.
3. Open `docs/README.md` and read only the domain doc matching your task
   (architecture, vault, review, integration, testing).

## Authority order

When sources disagree: the user's request → current code, tests, and
`project.yml` → `CLAUDE.md` → domain docs. A doc that contradicts the code is
a bug in the doc — fix it in the same change. The maintainer keeps a detailed
decision log outside the repository; ask when historical context would change
a decision.

## Execution

- All prose in English (comments, docs, commits); see "Language policy" in
  `CLAUDE.md` for the deliberate non-English exceptions.
- `EditMD/project.yml` is the source of the project structure; regenerate
  with xcodegen instead of editing the `.xcodeproj`.
- Verify with `xcodebuild`, not single-file diagnostics. After changes:
  targeted tests → full suite in proportion to risk → `git diff --check`.
- Keep commits narrow and single-purpose.
- When you change behavior a domain doc describes, update that doc in the
  same change; add durable new rules briefly to `CLAUDE.md`.
