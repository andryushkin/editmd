# The auditor

The auditor keeps the repository healthy: a fixed set of checks that any
change must survive. Half is mechanical and scripted; half requires judgment
and is executed by whoever reviews the change (usually an agent). Run it
before pushing and at the end of any multi-commit sprint.

## Layers

- `scripts/audit.sh` — the deterministic core: fail-closed, stable exit code,
  and it never writes to the working tree. Runnable by a human, CI, a git
  hook, or any agent. Two checks do run something — check 4 generates the
  Xcode project inside a temporary clone, check 14 executes `scripts/dist.sh`
  inside a throwaway root — and both keep every byte they write in a
  `mktemp -d` they delete.
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

About ten seconds, exit code 1 on any failure:

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
    row, the reverse — a WebKit token must be there, in
    `MarkdownPreviewView.swift`, and in a fragment of `CLAUDE.md`; that is the
    control, and without it a misspelled pattern would look exactly like a
    clean tree. Every control branch is run with the *searching expression*
    and never with a literal copy of one of its alternatives: a control that
    greps `WKWebView` while the search greps the pattern answers a different
    question, and a deliberately misspelled pattern stayed green through it.
    Each alternative of the pattern is additionally probed against its own
    spelling, so an alternative that can never fire is loud.
    In `CLAUDE.md` the bullet is located by its own words rather than by a line
    number, and the fragment scan reads the **whole guide**, not that bullet:
    the four modes are introduced in the opening paragraph and only recapped in
    the bullet. The unit of "next to the word Print" is a comma- or
    semicolon-separated fragment of a paragraph. Every joint is fail-closed: no
    heading, no row, no bullet, no file are each a FAIL with a reason.
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
    One regex engine does all three jobs — compiling an entry, blanking the
    permitted spellings, searching for the forbidden ones — and it is perl.
    Two engines are how an allow entry dies quietly: `\b` is a word boundary
    to `grep -E` and a plain `b` to BSD `sed -E`, so `\bpdm_[a-z0-9_]+`
    validated, blanked nothing, and turned a permitted spelling into a
    reported leak. Every allow entry is now run through the real scrubber
    before any text is collected — a witness string is built from the entry,
    the engine confirms the witness matches it, and the scrubber must blank it;
    an entry that cannot be witnessed or survives its own scrubber is *did not
    run*, not a pass.
    All three diffs are read with `--no-renames`. A pure rename prints no `+`
    line at all, so a file moved onto a forbidden name — or moved with
    forbidden content inside it — used to exit 0. The price is that a large
    file which is merely moved is collected and scanned in full.

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
    Non-emptiness is **not** completeness, and for a while only the first was
    held: the scope contains exactly one hit, so misspelling any of the other
    seven tokens left the check green. Each token now carries the line it must
    catch, and is run against it before the search; the list is written once
    and both the search and the probe are built from it.
    What is **not** checked: this is still a list of names, so it bounds *where*
    and not *how* — a producer spelled in a way no token lists passes, as does
    one reached through a `Process` rather than a Swift call. Nothing here says
    anything about what the bytes contain.

14. **The release gate runs what it claims** — `scripts/dist.sh` runs
    `PDMCoreTests` twice, in Debug and in Release, and until this check existed
    nothing held the second run up: deleting it left every automatic check
    green. `scripts/check-dist-gate.sh` **executes** `dist.sh` in a throwaway
    root with a directory of recording stubs first on `PATH`, in both signing
    modes, and asks its claims of the log of `xcodebuild` invocations rather
    than of the text of the script: both runs exist, neither narrows away from
    `PDMCoreTests`, the Release run carries `ENABLE_TESTABILITY=YES`, the
    packaging build comes last and without that override. Two claims a stub
    cannot answer are answered statically against `project.yml` and the test
    sources: the `-only-testing` identifier names a target the scheme's test
    action actually runs, and a class that exists. Three outcomes, laid out as
    in check 12 — clean, failed with the list, and *did not run*.
    `--selftest` plants eight regressions it must name and eight legal rewrites
    it must sit through; a grep over the same script text catches three of the
    eight and cries wolf on three of the others.
    What is **not** checked: the stubs are not `xcodebuild`, so nothing here
    says a test was compiled, resolved or executed; nothing about signing,
    notarization or the DMG; and nothing about Debug and Release differing in
    what they check — that last one is check 15.

15. **One Debug/Release difference** — the Release run of check 14 is a single
    test class, and that is enough only while the shipped sources hold one
    single place where the two configurations mean different things. Six
    constructs make such a place (`#if DEBUG`, `assert(`, `assertionFailure(`,
    `precondition(`, `preconditionFailure(`, `fatalError(`); across the app,
    `editmdctl` and `editmd-mcp` there is exactly one, the core-contract
    `assertionFailure` in `Editor/PDMCore.swift`, and it is named here the way
    check 13 names its places. Zero is a FAIL as well as two: it means either
    that the report disappeared or that the check went blind. The sources are
    read with line and block comments stripped, because the only `#if DEBUG`
    in the tree sits inside a doc comment explaining why the conditional is not
    there — excluding that file would have been a hole the size of a file.
    Each construct carries a line it must catch and is run against it first.
    What is **not** checked: a difference spelled some other way — a `#if` on
    another flag, behaviour that depends on the optimizer alone — is not one of
    the six; and the comment stripper knows nothing of string literals, so a
    `//` inside a string can only lose a hit.

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

## Self-tests

Two gates in `scripts/` carry a `--selftest` flag: they plant the defect they
exist to catch and require themselves to name it. Neither is run by
`audit.sh` — they guard the guards, and are run when a guard is changed.

| Command | What it plants |
|---|---|
| `scripts/check-dist-gate.sh --selftest` | eight regressions the gate must name, eight legal rewrites it must sit through |
| `scripts/verify-core.sh --selftest` | the version rule of check 4 against a table of comparisons and maxima, expectations written by hand — the two-component bug this replaced left the table green while the gate was wrong |

## Maintenance

The auditor itself is subject to the doc-sync rule: when a new class of
regression slips through, add a check here (scripted if mechanical, listed
above if judgmental) in the same change that fixes the regression.
