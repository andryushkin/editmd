---
name: editmd-audit
description: Read-only audit of the EditMD repository before a push or at the
  end of a sprint. Runs scripts/audit.sh (deterministic checks), walks the
  judgment list from docs/audit.md against the actual diff, verifies test
  evidence, and reports PASS / FAIL / WAIVED with facts. Trigger on "audit",
  "прогони аудит", "проверь репо", pre-push review requests.
---

# EditMD repository audit

You are auditing, not fixing. Do not modify any file, stage anything, or
create commits unless the user separately asks for fixes after seeing the
report.

## Procedure

1. **Load context.** Read `CLAUDE.md` and `docs/audit.md`. The doc is the
   specification; this skill only orchestrates it.
2. **Fix the scope.** Record `git status --short`, the current branch, the
   upstream (`git rev-parse --abbrev-ref @{upstream}`, may be absent), and
   the commit range under audit: outgoing commits (`@{upstream}..HEAD`) plus
   any staged/unstaged changes. If there is nothing to audit, say so and
   stop.
3. **Run the mechanical half:** `./scripts/audit.sh`. Never re-implement its
   checks by hand; if the script cannot run, that is a FAIL of the audit
   itself. Quote failing check names verbatim.
4. **Walk the judgment half** of `docs/audit.md` against the *actual* diff of
   the audited range (`git diff <range>`), not against commit messages or
   assumptions. For every item record a verdict with evidence: file:line
   references, diff hunks, or the absence you verified.
5. **Verify test evidence.** If the conversation or commit claims tests ran,
   check the claim is concrete (which suite, what result). When the diff
   touches code and no credible evidence exists, run the targeted tests
   yourself (`xcodebuild … test -only-testing:…`) and, when risk warrants,
   the full suite — see `docs/testing.md`.
6. **Report** in this exact shape:

   ```
   AUDIT REPORT — <branch> <range>
   Mechanical: PASS | FAIL (failed checks verbatim)
   Judgment:
     1. doc sync        — PASS/FAIL/WAIVED: <one-line evidence>
     2. three paths     — …
     3. narrow scope    — …
     4. unfinished work — …
     5. english prose   — …
     6. tests           — …
     7. no chronology   — …
   Verdict: PASS | FAIL | WAIVED (waivers listed with who granted them)
   ```

   WAIVED is only valid when the maintainer explicitly accepted a specific
   deviation — name it. Facts over adjectives: every FAIL must carry a
   reproducible pointer.
