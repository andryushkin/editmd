# Building and testing

From the repository root:

```bash
xcodegen generate --spec EditMD/project.yml
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' build
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' test
```

Requires macOS 14+, Xcode 26+ (Swift 6.2), and XcodeGen.

## Rules

- `EditMD/project.yml` is the single source of the Xcode project. Never edit
  the generated `.xcodeproj`; regenerate after changing targets or resources.
  The shared scheme is generated from `project.yml` too (Xcode used to keep it
  in `xcuserdata`, where regeneration lost it) and already disables code
  coverage.
- Verify real errors with `xcodebuild`, not with single-file editor
  diagnostics — SourceKit without full project context reports false
  "cannot find type" errors.
- After changes: run the targeted tests, then the full suite in proportion to
  the risk, then `git diff --check`.
- Shared logic belongs in testable pure/internal functions; paste routing and
  contextual guards must have direct tests.
- On a hang, capture `sample <pid> 3` first and optimize the confirmed hot
  path, not the suspected one.

## Continuous integration

`.github/workflows/ci.yml` runs on every push to `main` and on every pull
request, in two jobs on the `macos-26` image (pinned because the project needs
Xcode 26; XcodeGen is installed by the workflow):

- **Audit** — `scripts/audit.sh` with `AUDIT_BASE` set explicitly by a step of
  its own. The script fails closed without a base, and a default shallow
  checkout has none, so the job clones with full history. On a pull request the
  base is the target branch; on a push it is the range the push publishes. Two
  pushes have no such range, and the step refuses rather than audit less than it
  says — why, and why not a wider base instead, is recorded on the step itself
  in `ci.yml`.

  A superseded push does not cancel this job. `cancel-in-progress` used to sit
  at workflow level and reach the audit too, and an audit reads only the range
  of the push that started it: measured on a planted branch, push A publishes a
  commit with a forbidden word and fails on its own range, push B's range holds
  one commit — its own — and passes, so cancelling A leaves the word inside
  nobody's range and the surviving run green. A cancelled build costs a rebuild;
  a cancelled audit costs the only reading a commit ever gets.
- **Build and test** — generate, build, then the full suite with
  `-retry-tests-on-failure -test-iterations 2`. The retry is there for the two
  known warm-up/timing flakes only; remove it once they are fixed, because it
  hides a genuine intermittent failure just as effectively. Signing is
  overridden to ad-hoc on the command line: `project.yml` asks for a
  development identity (so a local rebuild keeps its Files-and-Folders grant)
  and no runner has that certificate. Ad-hoc rather than unsigned, because the
  test bundle is loaded into the host app and both must carry a signature with
  the same (here empty) team.

CI is a second opinion, not a substitute for running the suite locally before
pushing: it starts after the push it is meant to protect.

## Test layout

All tests live in `EditMD/EditMDTests/` (XCTest). The test host forces
English via the scheme argument `-AppleLanguages (en)` — write string
assertions in English. IDE/control services do not start under XCTest, so
socket tests construct servers explicitly.

Cyrillic strings in test data are deliberate: they cover UTF-16 offset math,
the Cyrillic search fold, and non-ASCII round-trips. Do not "clean them up".

## Fixtures

- `test-all-elements.md` (repo root) — a **live** round-trip corpus:
  `RoundTripTests` reads it, and the app itself writes to it during manual
  testing. If `testCorpusRoundTrip` goes red, first check
  `git diff test-all-elements.md` — the fixture may have changed on disk —
  before hunting for a regression.
- `test-all-elements.md.review.json` — a real review sidecar used by
  `ReviewMarksTests` as a decode→encode→decode fixed-point fixture (with an
  inline stand-in when the file is absent).
- `Resources/KitchenSink.md` — the Help ▸ Demo Markup document; also serves
  as a manual smoke corpus for all three modes.
