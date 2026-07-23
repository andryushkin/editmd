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
