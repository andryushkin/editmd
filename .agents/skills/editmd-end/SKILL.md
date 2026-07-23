---
name: editmd-end
description: Session-end ritual for the EditMD repository — supersedes any
  generic /end here. Verifies the state (audit, branch/upstream), classifies
  loose ends, writes a minimal handoff to persistent memory, and reports
  done / stopped-at / next-start. Verification-only by default — it never
  commits, pushes, or files issues on its own. Trigger on /end, "конец
  сессии", "завершаем", session wrap-up requests in this repo.
---

# EditMD session end

You are closing a session, not finishing its work. This skill verifies,
classifies, and records — it changes nothing in the repository. Commit or
push only if the user explicitly requested those actions earlier and they are
still pending; never create them for the sake of a clean ritual. A known
dirty worktree with an honest handoff beats a mixed "wrap-up" commit.

## Procedure

1. **Audit.** Run the `editmd-audit` skill (or `scripts/audit.sh` + the
   judgment list in `docs/audit.md` if the skill is unavailable). A FAIL
   marks the session end as **blocked**: report it, fix nothing
   automatically, and let the user decide whether to fix now or hand off the
   failure explicitly.
2. **Branch state.** Record the current branch (do not assume `main`),
   `git status --short` (worktree and index), the upstream, and whether
   `HEAD` equals it (`git rev-list --left-right --count @{upstream}...HEAD`
   when an upstream exists). Unpushed commits or a missing upstream are
   facts for the handoff, not problems to auto-solve.
3. **Classify loose ends.** For each open thread from the session:
   - *Standalone debt* (survives on its own, someone could pick it up cold)
     → belongs in a GitHub Issue. Propose the issue; file it only when the
     user approves that specific item.
   - *Immediate next step* (only meaningful with session context) → goes
     into the handoff memory, nowhere else.
   - *Durable rule or subsystem fact* → should already be in `CLAUDE.md` or
     `docs/` from the change that established it; if it is not, that is an
     audit "doc sync" miss to report, not something to silently patch now.
4. **Write the handoff** to the agent's persistent project memory (one
   updated entry, not a new file per session): branch and SHA, upstream
   state, audit and test results, what was NOT verified by eye, issue IDs
   touched or created, and the single first step for the next session.
   During normal work memory is left alone — recording state is this step's
   job, at the explicit session end only.
5. **Report** three short blocks, nothing more:

   ```
   Done:       <what this session actually shipped/verified>
   Stopped at: <exact state — branch/SHA/upstream, dirty files, blockers>
   Next start: <the single first action for the next session>
   ```

## Boundaries

- No commits, no pushes, no `gh issue create`, no file edits — unless the
  user explicitly asked for that specific action.
- No re-running heavy suites "just in case": cite the last real results and
  say when they ran; run tests only if the audit demands evidence that does
  not exist.
- If there is genuinely nothing to hand off (clean tree, everything pushed,
  no threads), say exactly that in the three blocks and stop.
