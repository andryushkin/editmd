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
   Cyrillic-folding sources, test data, the live root fixture).
2. **Doc links resolve** — every relative link in `docs/*.md` and `README.md`
   points at an existing file.
3. **Code→doc references exist** — every `docs/….md` path mentioned in
   executable sources (app, `editmdctl`, `editmd-mcp`, scripts), guides, or
   `project.yml` exists (stale references were a real post-refactor bug).
   Tests and agent-skill examples are excluded by design — their `docs/…`
   strings are sample vault paths, not repository references.
4. **No xcodegen drift** — regenerating from `project.yml` leaves the
   committed `.xcodeproj` unchanged.
5. **No secret patterns** in tracked files.
6. **Third-party notices coverage** — every SwiftPM pin has a section in
   `THIRD_PARTY_NOTICES.md`; vendored license files (KaTeX, Open Sans) are in
   place.
7. **Guide budgets** — `CLAUDE.md` ≤ 130 lines, `AGENTS.md` ≤ 45. The guides
   are compressed by design; growth is a smell that detail belongs in a
   domain doc.
8. **No junk tracked** — `.DS_Store`, `xcuserdata/`, logs, smotr artifacts.
9. **`git diff --check`** — no whitespace errors in the worktree, the staged
   diff, or (when an upstream is configured) the outgoing commit range.

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
