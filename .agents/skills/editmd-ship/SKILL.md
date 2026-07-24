---
name: editmd-ship
description: Patch-ship for the EditMD repository — bump the patch version,
  write the changelog section, pass the audit, push to origin/main. No tag
  and no GitHub Release (those belong to editmd-release). Trigger on "ship",
  "шипни", "patch-ship", "подними патч и запушь", requests to bump + changelog
  + push in one step.
---

# EditMD patch-ship

One command for the lightweight landing path defined in
`docs/releasing.md` § Patch-ship: version bump → changelog → audit → push.
It never tags and never publishes a GitHub Release — a cut release is a
separate, explicit request (`editmd-release`).

## Preconditions

- Working tree is clean apart from the changes being shipped; you are on
  `main`. Anything unrelated in the worktree stops the ship — never sweep
  someone else's dirty files into the ship commit.
- The work being shipped is already committed and verified (tests were run
  as part of the work; the audit below is the final gate, not the first).

## Procedure

1. **Bump.** In `EditMD/project.yml`: `MARKETING_VERSION` patch +1,
   `CURRENT_PROJECT_VERSION` +1 (build only ever grows). Then
   `xcodegen generate --spec EditMD/project.yml` — never edit the
   `.xcodeproj`.
2. **Changelog.** Add `## v<new> - YYYY-MM-DD` at the top of `CHANGELOG.md`
   from the actual `git log <last shipped version's section or tag>..HEAD`
   range — user-facing wording, sections in order and only when non-empty:
   **New Features**, **Improvements**, **Bug Fixes** (format in
   `docs/releasing.md`). If the range has no user-visible changes, skip the
   section entirely — a bare bump ships without one.
3. **Verify.** Build once (`xcodebuild … build`) to prove the regenerated
   project compiles. Full tests are not repeated here if the shipped work
   already ran them and nothing but version/changelog changed since.
4. **Commit** the bump + changelog (+ any policy/doc edits that belong to
   the ship) as one commit: `Ship v<new>: <one-line summary>`.
5. **Audit.** Run the `editmd-audit` skill (or `scripts/audit.sh` +
   `docs/audit.md` when unavailable). FAIL blocks the push — report and
   stop; fixes are new work, not part of the ship.
6. **Push** `main` to `origin`. Nothing else: no tags, no releases.
7. **Report**: version, changelog section (or "no user-visible changes"),
   audit verdict, pushed commit range.

## Hard rules

- Maintainer-triggered only; never ship as a side effect of finishing work.
- A FAIL audit or a dirty/unrelated worktree aborts the push — no partial
  ships.
- Published changelog sections are never rewritten afterwards; a correction
  gets its own entry next time (same rule as releases).
