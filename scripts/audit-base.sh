#!/usr/bin/env bash
# Which commits is an audit supposed to look at?
#
# One answer, for every guard that needs it. It used to be two: `audit.sh`
# check 9 and `check-publicity.sh` each spelled the same chain out, and the
# only thing holding them together was a comment saying "the same base order as
# audit.sh check 9". Prose is not a check, and the two had already drifted in
# the part that matters — what to do when the range comes out empty.
#
# ORDER: explicit $AUDIT_BASE → the branch's upstream → origin/<branch>.
#
# EXIT CODES, and the third one is the repair:
#
#     0 — a base was found and `base..HEAD` contains commits. The base is on
#         stdout; that is the range to audit.
#     2 — NO BASE. Nothing was audited and nothing may be reported as clean.
#         Both callers already treat 2 as "the check did not run".
#     3 — a base was found and the range is EMPTY. Also nothing audited — but
#         for a different reason, and the difference is worth a code of its
#         own because this is the state a runner is in immediately after a
#         push: `origin/<branch>` has already moved to the commit that was
#         just published, so `origin/<branch>..HEAD` is empty and every guard
#         reading it walks over zero commits and returns success.
#
# Measured on a planted tree, 28 Aug 2026: with a forbidden word committed and
# the base handed in as the tip itself, `audit.sh` printed
# "AUDIT: all mechanical checks passed" and `check-publicity.sh` printed
# "nothing to check (empty range, clean tree)" and exited 0. The word was in
# the tree the whole time. The promise these guards make — refuse rather than
# audit less than you say — was open at exactly the moment it is relied upon.
#
# Usage: base=$(scripts/audit-base.sh) ; case $? in 0) … ;; 2) … ;; 3) … ;; esac
set -uo pipefail

resolves() { git rev-parse --verify --quiet "$1" > /dev/null; }

if [ -n "${AUDIT_BASE:-}" ]; then
    resolves "$AUDIT_BASE" \
        || { echo "AUDIT_BASE='$AUDIT_BASE' does not resolve" >&2; exit 2; }
    base=$AUDIT_BASE
elif resolves '@{upstream}'; then
    base='@{upstream}'
else
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""
    if [ -n "$branch" ] && resolves "origin/$branch"; then
        base="origin/$branch"
    else
        echo "no audit base: set an upstream or AUDIT_BASE" >&2
        exit 2
    fi
fi

# `git rev-list --count` rather than a diff: a commit that changes nothing is
# still a commit that gets published, and the guards read commits one at a
# time for exactly that reason.
count=$(git rev-list --count "$base..HEAD" 2>/dev/null) || {
    echo "git rev-list $base..HEAD failed" >&2
    exit 2
}

printf '%s\n' "$base"
[ "$count" -gt 0 ] || {
    echo "the outgoing range $base..HEAD is empty: no commit was examined" >&2
    exit 3
}
exit 0
