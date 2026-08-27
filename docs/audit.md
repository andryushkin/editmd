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

10. **One producer of PDF pages** — no occurrence of the names `createPDF` or
    `previewHTMLPage` in any Swift source, tracked or not. The app prints
    through the prebuilt core; a second producer means a web view rendering
    pages of its own, and WebKit's `createPDF(` is the call it cannot avoid
    whatever file or type it lives in. Preview's own `previewHTMLPageRender(`
    is deliberately not matched. The name is matched rather than the call:
    Swift accepts a space before the parenthesis, and the first version of this
    check passed a file that built and printed pages that way. The check counts
    occurrences of those two names, not calls — at a threshold of zero the distinction costs nothing,
    and it is stated so that nobody later reads more into a PASS than a grep
    can give. It does not see a producer that is not a web view
    (`NSPrintOperation`, pages written through PDFKit): what passes here is
    "no second producer on WebKit", not the whole of "one path into a PDF".
    The rest of that sentence is held by the tests that compare the file an
    export writes with the pages the Print pane shows.

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
