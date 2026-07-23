---
name: editmd-release
description: Cut an EditMD release — changelog section, annotated tag, GitHub
  Release — following docs/releasing.md. Verifies clean tree and passing
  audit, collects changes since the last tag, drafts user-facing notes, and
  publishes only after the maintainer approves the preview. Trigger on
  "release", "cut a release", "сделай релиз", "зарелизь", "новый релиз".
---

# EditMD release

You are cutting a release, not shipping work-in-progress. The policy is
`docs/releasing.md`; this skill orchestrates it. Nothing is pushed or
published before the maintainer approves the preview.

## Procedure

1. **Preconditions.** The worktree must be clean and the branch `main`.
   Run the `editmd-audit` skill (or `scripts/audit.sh` + the judgment list)
   — a FAIL blocks the release; report it and stop. `git fetch origin
   --tags` first so the tag view is current.
2. **Fix the range.** Last release: `git describe --tags --abbrev=0
   --match "v*"` (no tags at all → treat the range start as the initial
   public release tag). The release covers `<last-tag>..HEAD`. If the range
   is empty, say so and stop.
3. **Pick the version.** Read `MARKETING_VERSION` from `EditMD/project.yml`.
   - If it is already greater than the last tag (the sprint bumped it), the
     release version is the current value — confirm it matches the change
     type (features → MINOR bumped, fixes only → PATCH bumped).
   - Otherwise ask the maintainer for the bump (patch or minor — «подними
     патч» / «подними версию» conventions), edit `project.yml`, regenerate
     with xcodegen, and commit the bump.
   - Abort if tag `vX.Y.Z` already exists.
4. **Draft the changelog section.** From the actual `git log
   <last-tag>..HEAD` and diffs — not from memory or commit subjects alone.
   Format per `docs/releasing.md`: `## vX.Y.Z - YYYY-MM-DD`, then only the
   non-empty groups **New Features**, **Improvements**, **Bug Fixes**; one
   user-facing English line per change. Internal-only work (refactors, test
   plumbing, docs) is folded into Improvements or omitted when invisible to
   users.
5. **Preview.** Show: version, range (`<last-tag>..<sha>`), the full drafted
   section, and the exact actions to follow (changelog commit, push, tag,
   `gh release create`). **Wait for explicit approval.** Any edit requests
   loop back to step 4.
6. **Publish** — only after approval, in this order:
   1. Insert the section at the top of `CHANGELOG.md` (below the intro),
      commit `docs: changelog for vX.Y.Z`.
   2. Push `main`.
   3. `git tag -a vX.Y.Z -m "Version X.Y.Z"` on the changelog commit, then
      push the tag.
   4. `gh release create vX.Y.Z --title "Version X.Y.Z"` with the changelog
      section (verbatim) as notes.
7. **Report.** Version, tag SHA, and the release URL.

## Boundaries

- Never publish, push, or tag before the preview is approved in this
  session.
- Never rewrite an already-published changelog section; corrections are new
  entries in the next release.
- Audit FAIL, dirty worktree, or a non-`main` branch stop the release — fix
  is a separate decision, not part of this skill.
