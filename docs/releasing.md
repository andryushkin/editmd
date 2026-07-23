# Versioning and releases

How EditMD versions are numbered, when a release is cut, and what a release
consists of. The changelog itself is [`CHANGELOG.md`](../CHANGELOG.md) at the
repository root — the one deliberate place where release chronology lives;
domain docs stay present-tense.

## Version scheme

`0.MINOR.PATCH`, kept in `MARKETING_VERSION` in `EditMD/project.yml`
(`CURRENT_PROJECT_VERSION` is the build number and only ever grows).

- **MINOR** — new user-visible features or behavior changes, typically the
  outcome of a sprint.
- **PATCH** — fixes and polish with no new features.
- **1.0.0** is deferred until EditMD ships binaries to users (packaging and
  notarization); until then no compatibility promises are implied by the
  version number.

The version in `project.yml` may tick several times between releases;
intermediate versions get no tag and no changelog section.

## When a release is cut

Only when the maintainer says so — usually at the end of a sprint, after the
audit passes and `main` is pushed. A release consists of:

1. a `## vX.Y.Z - YYYY-MM-DD` section at the top of `CHANGELOG.md`,
2. an annotated git tag `vX.Y.Z` on the released commit,
3. a GitHub Release with that changelog section as its notes (no binaries
   yet; artifacts join when packaging exists).

## Changelog format

- Sections in order, present only when non-empty: **New Features**,
  **Improvements**, **Bug Fixes**.
- Each entry is one line describing the change as the user experiences it,
  in English — not commit-message prose. Issue references only when one
  exists and adds context.
- Written from the actual `git log <last-tag>..HEAD` range, not from memory.
- Published sections are never rewritten; a correction gets its own entry in
  the next release.

## Branching

Trunk-based: `main` is the only permanent branch, history is linear, and a
release is a tag on `main`. A branch is a short-lived isolation tool, not
project structure — it lives days, merges, and is deleted. The cases that
warrant one:

- **Experiment** that may not survive — branch, then merge or delete; `main`
  never sees the failed attempt.
- **Long refactor** that would leave `main` unbuildable for days — branch so
  `main` stays releasable throughout.
- **External PR** — contributors bring branches from their forks; they are
  merged with **squash and merge** only (the sole merge method enabled on
  GitHub), keeping history linear.
- **Hotfix for a released version** while `main` carries unreleased work —
  the one case a branch starts from a tag, not from `main`:

  ```bash
  git switch -c hotfix-0.48.1 v0.48.0
  # fix, commit, then:
  git tag -a v0.48.1 -m "Version 0.48.1"
  git push origin hotfix-0.48.1 v0.48.1
  git switch main && git merge hotfix-0.48.1
  ```

  When `main` is green and releasable, a patch release is cut from `main`
  directly — no branch needed.

Published tags are never moved or deleted: a broken release is superseded by
the next patch version, not re-tagged.

## Process

The project skill `.agents/skills/editmd-release` orchestrates a release:
verify a clean tree and a passing audit, collect changes since the last tag,
draft the changelog section, show a preview, and only after the maintainer
approves it — commit, tag, push, and publish the GitHub Release. Nothing is
pushed or published before that approval.
