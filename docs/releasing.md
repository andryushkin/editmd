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

## Process

The project skill `.agents/skills/editmd-release` orchestrates a release:
verify a clean tree and a passing audit, collect changes since the last tag,
draft the changelog section, show a preview, and only after the maintainer
approves it — commit, tag, push, and publish the GitHub Release. Nothing is
pushed or published before that approval.
