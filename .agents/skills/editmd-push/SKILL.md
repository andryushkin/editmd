---
name: editmd-push
description: Ship EditMD end to end — audit, version bump, changelog, push,
  tag, GitHub Release with a notarized DMG, the dotmd.tools changelog page
  and update feed, and the Homebrew cask. Pushing code alone leaves installed
  copies behind and silent, so a push is the start of the release cycle, not
  the end of the work. Use whenever the maintainer asks to push, ship,
  release, publish, tag, or cut a version of EditMD — "запушь", "пушим",
  "выкатывай", "шипни", "сделай релиз", "зарелизь", "подними патч и запушь",
  "ship it" — even when they name only one of the steps.
---

# EditMD push

A push is not "send the commits". Since 0.47.15 every installed copy asks
`dotmd.tools/editmd/latest.json` once a day, so people learn about a release
from the **site deploy**, not from the tag. Ship the code and stop, and the
release exists only for whoever happens to look at GitHub.

The policy is `docs/releasing.md`; this skill orchestrates it. Nothing is
pushed or published before the maintainer approves a preview.

Five things follow a push, and the maintainer expects all of them:
**changelog → push → tag + GitHub Release → DMG → site → Homebrew cask.**

## Procedure

1. **Preconditions.** Branch `main`; the worktree clean apart from the work
   being shipped — anything unrelated stops the push rather than being swept
   into the commit. `git fetch origin --tags` so the tag view is current.
   Run the `editmd-audit` skill (or `scripts/audit.sh` + the judgment list
   in `docs/audit.md`). A FAIL blocks everything: report it and stop, since
   fixing it is new work and a separate decision.

2. **Fix the range.** `git describe --tags --abbrev=0 --match "v*"` is the
   last release; the range is `<last-tag>..HEAD`. An empty range means there
   is nothing to ship — say so and stop.

3. **Pick the version.** Read `MARKETING_VERSION` from `EditMD/project.yml`.
   If a sprint already bumped it past the last tag, that is the version —
   confirm it matches the change type. Otherwise ask for the bump: «подними
   патч» is the last number, «подними версию» is MINOR. Edit `project.yml`
   (`CURRENT_PROJECT_VERSION` only ever grows), run `xcodegen generate
   --spec EditMD/project.yml` — never edit the `.xcodeproj` — and build once
   to prove the regenerated project compiles. Abort if `vX.Y.Z` already
   exists.

4. **Draft the changelog section** from the real `git log <last-tag>..HEAD`
   and its diffs, not from memory or commit subjects. Format per
   `docs/releasing.md`: `## vX.Y.Z - YYYY-MM-DD`, then only the non-empty
   groups **New Features**, **Improvements**, **Bug Fixes**; one user-facing
   English line per change. Internal work — refactors, test plumbing, review
   fixes to a feature that never shipped broken — folds into Improvements or
   is left out, because users never experienced it.

5. **Preview and wait.** Show the version, the range, the drafted section,
   and the exact steps to follow. **Wait for explicit approval**; edits loop
   back to step 4.

6. **Publish**, in this order — each step depends on the one before:
   1. Commit the bump; insert the section at the top of `CHANGELOG.md`
      (below the intro) and commit `docs: changelog for vX.Y.Z`.
   2. Push `main`.
   3. `git tag -a vX.Y.Z -m "Version X.Y.Z"` on the changelog commit, push
      the tag.
   4. `gh release create vX.Y.Z --title "Version X.Y.Z"` with the section
      verbatim as notes.
   5. **DMG**: `scripts/dist.sh` — Release build, Developer ID, notarization,
      `dist/EditMD-v<version>.dmg`. Fail-closed by design, so a DMG it
      reports as done is safe to attach; `--adhoc` tests packaging only and
      must never be distributed. `gh release upload vX.Y.Z dist/EditMD-vX.Y.Z.dmg`.
   6. **Site** (`~/dev/dotMD/dotmdtools`): rewrite
      `content/editmd-changelog.md` — the site's rule is that this page is
      **rewritten, not copied**: drop the New Features / Improvements / Bug
      Fixes headings and give each entry a bold lead naming the change and a
      remainder saying why it mattered, since a reader there did not come to
      sort their own news. Keep its `version:` front matter in step with the
      newest `## ` heading. Then `uv run build.py && npx wrangler deploy` —
      always both, in that order, because `dist/` is gitignored and
      deploying without building ships the previous build. Commit the site
      repo (it has no remote; the commit is the record).
   7. **Homebrew cask** in the `andryushkin/homebrew-apps` tap: bump
      `version` and `sha256` (`shasum -a 256 dist/EditMD-vX.Y.Z.dmg`),
      commit, push. `brew audit` wants the tap trusted, so verify the
      checksum by hand against the file you uploaded rather than trusting a
      green audit you had to coax.

7. **Verify what a user would see**, and report each:
   `curl -s https://dotmd.tools/editmd/latest.json` names the new version;
   `gh release view vX.Y.Z` has the DMG attached; `brew update && brew info
   andryushkin/apps/editmd` offers it. Report the version, tag SHA and
   release URL.

## When the full cycle does not apply

A push that ships nothing a user can see — documentation, tests, agent
skills — needs steps 1–2 and 6.2 only. Say plainly that you are skipping the
release, and why. This is the exception; the default is the whole cycle,
because the maintainer's rule is that a push carries its consequences with
it.

## Boundaries

- **Push only on an explicit request.** This skill says what a push drags
  behind it, not that you may start one.
- Steps 6.5–6.7 touch things people download. If one fails, stop and say so:
  a half-shipped release (a tag with no DMG, a DMG the feed does not know
  about) is worse than an unshipped one, because the update notice sends
  people to a page with nothing on it.
- Never rewrite a published changelog section; corrections are entries in
  the next release.
- The site repo and the tap are separate repositories — keep their commits
  out of the EditMD worktree and out of each other.
