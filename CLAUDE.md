# EditMD — working guide

Native macOS Markdown editor: SwiftUI + AppKit/TextKit 1. Three modes over one
source of truth — the markdown string in `MarkdownDocument`. Source (raw text
+ highlight/lint), Visual (attributed WYSIWYG with synchronous serialization),
Preview (HTML in WKWebView). Sidebar: Files / Outline / Git / Review / Tags.

Domain documentation lives in `docs/` (`docs/README.md` is the index) — read
the doc matching your task's subsystem before changing it, and update it in
the same change when you alter behavior it describes. The historical decision
log is kept outside the repository; do not add chronology here.

## Project map

- `EditMD/EditMD/App/` — lifecycle, windows, commands, open routing.
- `EditMD/EditMD/Document/` — `MarkdownDocument`, `DocumentStore`,
  `DocumentRegistry`.
- `EditMD/EditMD/Editor/` — Source/Visual, round-trip, tables, formulas,
  highlighting, lint, review model, diff, PDF export.
- `EditMD/EditMD/Views/` — layout, Preview, sidebars, settings, viewers.
- `EditMD/EditMD/Integration/` — Claude IDE WebSocket/MCP, diff approval,
  control socket, skill installer.
- `EditMD/EditMDTests/` — unit/integration tests.
- `EditMD/project.yml` — the single source of the Xcode project; run xcodegen
  after changing targets/resources, never edit the `.xcodeproj`.
- `docs/` — architecture, vault, review, integration, testing.

Dependencies: `swift-markdown`, `SwiftMath`, `HighlighterSwift`; KaTeX bundled
offline in `Resources/katex/`.

## Build and test

```bash
xcodegen generate --spec EditMD/project.yml
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' build
xcodebuild -project EditMD/EditMD.xcodeproj -scheme EditMD -destination 'platform=macOS' test
```

Verify real errors with `xcodebuild`, not single-file editor diagnostics.
After changes: targeted tests → full suite (in proportion to risk) →
`git diff --check`. Before pushing, use the audit skill
(`.agents/skills/editmd-audit`) when available; otherwise run
`scripts/audit.sh` and follow `docs/audit.md`. More in `docs/testing.md`.

Building to a throwaway `-derivedDataPath` (review builds, signed copies,
`.xcresult` bundles) is fine, but **delete it before ending the session** —
nothing reclaims those paths automatically and each is 0.5–1 GB; leftovers
accumulate into tens of gigabytes. Check with
`ls -d /tmp/*editmd* /tmp/EditMD* 2>/dev/null` and remove what the session
created. The default DerivedData location needs no such cleanup.

## Non-negotiable invariants

Cross-system rules that hold everywhere; the *why* and the detail live in the
domain docs.

- One model per URL in `DocumentRegistry`. Agent edits and accepted review
  suggestions go only through `DocumentRegistry.applyAgentEdit`; any other
  write path makes the file watcher report an external change.
- A markdown feature spans three independent render paths
  (Source `collectSpans`, Visual `VisualRenderer`, Preview `HTMLBodyVisitor`)
  plus the Visual round-trip — check all of them.
- `.raw` islands are verbatim source of truth; frontmatter must survive
  byte-exact through `composeDocumentWithFrontmatter`. All offsets are UTF-16.
- Plugins are built-in Swift types only (`BuiltInPluginRegistry`), activated
  per document via frontmatter; never add JavaScript loading, external
  bundles, or downloaded executable code.
- No synchronous disk I/O, `Process` runs, or full diffs on the main actor or
  inside SwiftUI `body` — cache + background refresh
  (`docs/architecture.md` § Performance).
- The link-graph core files (list in `project.yml`) also compile into
  `editmdctl` and must stay free of AppKit and app models; vault-graph wire
  shapes only via `ControlGraphPayload.swift`; the IDE MCP `tools/list` is
  fixed — new agent capabilities go to `editmdctl`.
- `openDiff` is blocking: its continuation completes exactly once for
  Accept/Reject/close/disconnect/timeout.
- IDE/control services do not start under XCTest.
- The Edit menu's Cut/Copy/Paste/Select All stay stock SwiftUI items, and an
  alert with a text field runs through `runModal(_:focusing:)` — otherwise the
  keyboard dies inside the app's own dialogs
  (`docs/architecture.md` § Menus and AppKit panels).
- The `editmd://` scheme is an untrusted entry point (any web page can open
  one): it only creates files — re-sanitized name, uniquified, never
  overwriting — and ignores what it does not understand
  (`docs/integration.md` § URL scheme).

## Localization

Development language is English: user-facing strings are English literals,
translated to Russian in `Resources/Localizable.xcstrings` — and, for the
strings the system shows in its own prompts, `Resources/InfoPlist.xcstrings`;
every new user-facing string needs a ru entry with matching format specifiers.
Protocol messages and logs are never localized. Details (language switch,
test-host `-AppleLanguages (en)`) in `docs/architecture.md` § Localization.

## Language policy

English for all prose: code comments, documentation, commit messages, string
literals in code that are not data. Deliberate exceptions that must **not** be
"cleaned up": the ru localization catalogs and the language-name endonym in
`AppLanguage.swift`, Cyrillic test data and fixtures (they cover UTF-16 and
case-folding paths),
language-sensitive examples, and Russian trigger phrases in the shipped agent
skill.

## Working rules

- Do not mix unrelated changes; preserve someone else's dirty worktree and
  keep it out of your commits.
- Shared logic goes into testable pure/internal functions; paste routing and
  contextual guards must have direct tests.
- On a hang, capture `sample <pid> 3` first, then optimize the confirmed hot
  path.
- External contributions follow `CONTRIBUTING.md`: bugs → Issues, ideas and
  questions → Discussions, anything beyond a small fix needs a discussion
  before a PR. When triaging or drafting replies, apply that policy — a
  design-based decline of clean code is a normal outcome. Never reply
  publicly, close, or merge an outside issue/PR without the maintainer's
  explicit approval.
- Releases follow `docs/releasing.md`: version bumps in `project.yml` are
  routine, but `CHANGELOG.md` sections, tags, and GitHub Releases are cut
  only on the maintainer's explicit request (`.agents/skills/editmd-push`).
  A release ends with redeploying `dotmd.tools` — installed copies learn about
  it from `/editmd/latest.json`, which is only as fresh as that deploy.
- Durable new rules are added here briefly; subsystem explanations belong in
  the matching `docs/` file; unfinished work is tracked in GitHub Issues.
