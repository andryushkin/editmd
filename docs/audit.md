# The auditor

The auditor keeps the repository healthy: a fixed set of checks that any
change must survive. Half is mechanical and scripted; half requires judgment
and is executed by whoever reviews the change (usually an agent). Run it
before pushing and at the end of any multi-commit sprint.

## Layers

- `scripts/audit.sh` — the deterministic core: side-effect free, fail-closed,
  stable exit code. Runnable by a human, CI, a git hook, or any agent.
- `docs/audit.md` (this file) — the public specification of the criteria.
- `.agents/skills/editmd-audit/SKILL.md` — the agent orchestrator: runs the
  script, walks the judgment list against the actual diff, verifies test
  evidence, and emits a standard PASS/FAIL/WAIVED report. It never duplicates
  the shell checks in prose — one implementation, one spec — and it is
  read-only: an audit fixes nothing unless separately asked.

## Mechanical half

```bash
./scripts/audit.sh
```

Static checks, a few seconds, exit code 1 on any failure:

1. **Language policy** — no Cyrillic outside the explicit allowlist
   (localization catalog, the language-name endonym, skill trigger phrases,
   Cyrillic-folding sources, test data, the live root fixture). Only
   `SKILL.md` files of project skills are exempt — they carry bilingual
   trigger phrases; their body prose staying English is judgment item 5.
2. **Doc links resolve** — every relative link in `docs/*.md` and `README.md`
   points at an existing file.
3. **Code→doc references exist** — every `docs/….md` path mentioned in
   executable sources (app, `editmdctl`, `editmd-mcp`, scripts), guides, or
   `project.yml` exists (stale references were a real post-refactor bug).
   Tests and agent-skill examples are excluded by design — their `docs/…`
   strings are sample vault paths, not repository references.
4. **No xcodegen drift** — `project.yml` regenerates to the current
   `.xcodeproj`, verified by generating inside a temporary clone of
   `EditMD/` and comparing byte-for-byte (both directions: changed files and
   files the generator would no longer produce). The working tree is never
   written, so an interrupted audit cannot leave it modified.
5. **No secret patterns** in tracked files.
6. **Third-party notices coverage** — every SwiftPM pin has a section in
   `THIRD_PARTY_NOTICES.md`; vendored license files (KaTeX, Open Sans) are in
   place.
7. **Guide budgets** — `CLAUDE.md` ≤ 130 lines, `AGENTS.md` ≤ 45. The guides
   are compressed by design; growth is a smell that detail belongs in a
   domain doc.
8. **No junk tracked** — `.DS_Store`, `xcuserdata/`, logs, smotr artifacts.
9. **`git diff --check`** — no whitespace errors in the worktree, the staged
   diff, or the outgoing commit range. The audit base resolves as: explicit
   `AUDIT_BASE` env var → the branch upstream → `origin/<branch>`; when no
   base can be determined the check FAILs rather than silently shrinking its
   scope.

10. **One producer of PDF pages** — no occurrence of the names `createPDF`,
    `pdf(configuration:`, `WKPDFConfiguration` or `previewHTMLPage` in any Swift
    source, tracked or not; Preview's own `previewHTMLPageRender(` is
    deliberately not matched. Names are matched rather than calls, and at a
    threshold of zero the distinction costs nothing. What a PASS means is the
    narrow "no second producer on WebKit by any spelling seen so far": this is a
    list of names, three reviews have each added one to it, and a producer that
    is not a web view (`NSPrintOperation`, PDFKit) passes untouched. The whole of
    "one path into a PDF" is held instead by the tests that compare the file an
    export writes with the pages the Print pane shows. Why each name is shaped
    the way it is — the space before the parenthesis, the Objective-C selector,
    the async form — is recorded on check 10 in `scripts/audit.sh`.

11. **Render paths match the code** — the table "Four modes, four code paths"
    in `docs/architecture.md` and the matching invariant in `CLAUDE.md` are
    checked against the Swift sources, never against each other: an oracle
    copied from the line it checks proves the two copies agree, not that either
    is true. Of the `Print` row: every file it names exists, the row carries no
    WebKit token, none of those files carries one either, and the renderer it
    names really reaches the core (`PDMCore.` occurs in it). Of the `Preview`
    row, the reverse — `WKWebView` must be there and in
    `MarkdownPreviewView.swift`; that half is the control, and without it a
    misspelled pattern would look exactly like a clean tree. In `CLAUDE.md` the
    same claim is located by its own words rather than by a line number, and
    the unit of "next to the word Print" is a comma- or semicolon-separated
    fragment of that bullet. Every joint is fail-closed: no heading, no row, no
    bullet, no file are each a FAIL with a reason.
    What is **not** checked: that the described path is the one that runs. A
    second, undescribed producer is check 13's sentence, not this one; the
    `Source` and `Visual` rows are not read at all, since they name globs
    rather than files; and a description of Print split across two fragments
    could keep the WebKit token in the half that omits the word.

12. **Nothing private rides out** — `scripts/check-publicity.sh` reads a
    dictionary of forbidden spellings and looks for them in the commit messages
    of the outgoing range, in the lines each of its commits adds, and in the
    staged and unstaged diffs. The dictionary is deliberately not in this
    repository, so the script has three outcomes and the audit lays out all
    three: clean, found (each finding printed with its place and its line), and
    *did not run* — a guard that could not read its dictionary must never look
    like a clean tree, so that third outcome is a FAIL with the reason.
    What is **not** checked: anything already in the base — only added lines are
    read, because scanning removals would make a leak impossible to delete. The
    range is read one commit at a time, since a push publishes commits and not
    their sum, and a word that went into an older commit of the range keeps the
    check red until the history is rewritten. It is a list of spellings, so a
    paraphrase passes, as does anything git shows as binary. Untracked files
    are in no diff and are not read. The full ceiling, and the price of the
    fail-closed choice in a clone that has no dictionary, are in the script's
    own header.

13. **PDF bytes come from one place** — the whitelist check 10 names in its
    ceiling and does not implement. Every occurrence of a producer token
    (`PDMCore.render`, `NSPrintOperation`, `CGPDFContext`, `beginPDFPage`,
    `dataRepresentation()`, `createPDF`, `WKPDFConfiguration`,
    `pdf(configuration:`) in the shipped targets — the app, `editmdctl`,
    `editmd-mcp`, tracked and untracked — must sit in a listed file:
    `Editor/PrintPDFRenderer.swift`, the producer, or `Editor/PDMCore.swift`,
    the declaration of the door it goes through. `EditMDTests/` is out of scope
    by decision, not by oversight: tests produce PDF bytes on purpose and none
    of it ships. `PDFDocument(url:)` and `PDFDocument(data:)` are not tokens —
    they consume bytes, and a check that reddened on the image viewer would be
    switched off within a week. The whitelist must also be non-empty: no
    producer token in `PrintPDFRenderer.swift` is a FAIL ("vacuous"), because a
    whitelist over a tree with no printing is green for the wrong reason.
    What is **not** checked: this is still a list of names, so it bounds *where*
    and not *how* — a producer spelled in a way no token lists passes, as does
    one reached through a `Process` rather than a Swift call. Nothing here says
    anything about what the bytes contain.

The build and the full test suite are deliberately *not* here — they are the
other, heavier gate and run through `xcodebuild` (see `docs/testing.md`).

## Judgment half

Questions a reviewer answers about the diff; "no" to any of them blocks the
push until fixed or consciously waived by the maintainer.

1. **Doc sync** — if the change alters behavior described in a domain doc,
   is that doc updated in the same change? If it establishes a durable rule,
   is `CLAUDE.md` extended (briefly)?
2. **Three paths** — if a markdown feature changed, were Source, Visual,
   Preview, and the round-trip all checked?
3. **Scope** — is the commit narrow and single-purpose? Is unrelated drive-by
   churn absent?
4. **Unfinished work** — are loose ends filed as GitHub issues instead of
   TODO notes in docs or code?
5. **English prose** — are new comments, docs, and the commit message in
   English (with the allowlisted exceptions untouched)?
6. **Tests** — do new behaviors have direct tests, and did the targeted +
   full suites actually run (not assumed)?
7. **No chronology** — do docs still describe the present tense of the
   system, with history left to the maintainer's decision log?

## Maintenance

The auditor itself is subject to the doc-sync rule: when a new class of
regression slips through, add a check here (scripted if mechanical, listed
above if judgmental) in the same change that fixes the regression.
