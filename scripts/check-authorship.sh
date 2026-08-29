#!/usr/bin/env bash
# Keeps a borrowed identity out of a public push: every commit the push would
# publish must be authored by an address we meant to publish under.
#
# WHY THIS IS NOT COVERED BY ANYTHING ELSE. The other sixteen checks read what
# a commit CONTAINS — its patch, its message, the files it leaves behind. A
# commit's author is none of those: it is a header, it is published with the
# commit, and it is the one field a diff-shaped guard cannot see. Measured, not
# supposed: a local `user.name`/`user.email` set by hand on 28 Aug 2026 signed
# twelve commits and survived a full audit at 16/16, and it was a person, not a
# check, who eventually noticed.
#
# THREE OUTCOMES:
#   0  every commit in the outgoing range is authored by an allowed address
#   1  a commit is authored by an address that is not on the list
#   2  the run did not happen — no list, no audit base, a malformed entry, or
#      an EMPTY outgoing range
#
# The empty range belongs with the failures, not with the successes, and this
# is the one judgement in the script worth arguing. Immediately after a push
# `origin/<branch>..HEAD` is empty, and a guard that walks zero commits and
# reports "clean" is making a promise it did not check — the same hole
# scripts/audit-base.sh was written to close, and the same reason
# check-publicity.sh refuses there too. "Nothing was examined" is not "nothing
# is wrong", and only one of the two may be printed green.
#
# WHY AN ALLOW LIST AND NOT `git config user.email`. The obvious form — "does
# every commit match the configured identity" — reddens on any co-author, any
# patch taken from someone else, any commit made on another machine with a
# different spelling. A guard that reddens on legitimate work gets switched
# off, and a guard that is off is worse than one that never existed. So the
# question is not "is this me" but "is this an address we decided to publish
# under", and the answer is a list somebody had to write down.
#
# WHY THE LIST IS IN THE REPOSITORY, unlike the publicity dictionary's. That
# one is private because the list of what we hide is itself a thing we hide.
# This one hides nothing: every address it names is already printed in the
# public history of every commit it allows. Keeping it here also spares us the
# failure mode the private list has — a clone without the file is RED, which is
# correct there and would only be noise here. Set AUTHORSHIP_ALLOW to read the
# list from another file; the plants use that, and nothing else should.
#
# THERE IS NO EXCEPTION LIST, AND THAT IS DELIBERATE. check-publicity.sh has
# one because a forbidden word can sit in history nobody will rewrite. The
# equivalent here — eleven commits signed by a leftover identity — was decided
# on 29 Aug 2026 and published as-is, which puts them behind the pushed tip
# where this guard cannot see them anyway. An empty exception list is not free:
# it is a shape waiting for somebody to add a line to it without thinking. So
# there is none. If a borrowed identity ever has to be published again, add the
# mechanism then, with a live entry to test it against — copy the four axes
# from check-publicity.sh's `publicity-accepted`, which argues them properly.
#
# WHAT IT DOES NOT PROVE. It reads the AUTHOR (%ae) and not the committer
# (%ce): the author is the field that travels with a patch and the one that was
# actually borrowed, and reading both would redden every rebase and every
# cherry-pick. It compares addresses, not names: `user.name` is free text and
# two people may share one. And it sees only the outgoing range — an address
# already published is this guard's blind spot by construction.
#
# FILE FORMAT — TAB-separated, `#` comments and blank lines ignored:
#     allow<TAB>address
set -uo pipefail

ALLOW_FILE=${AUTHORSHIP_ALLOW:-scripts/authorship-allow.txt}

die2() { printf 'check-authorship: %s\n' "$1" >&2; exit 2; }

[ -f "$ALLOW_FILE" ] || die2 "no allow list at $ALLOW_FILE"

base=$(scripts/audit-base.sh 2>/dev/null)
case $? in
    0) ;;
    3) die2 "the outgoing range is empty: no commit was examined, so no author was checked" ;;
    *) die2 "no audit base: set an upstream or AUDIT_BASE" ;;
esac

work=$(mktemp -d) || die2 "cannot create a work directory"
trap 'rm -rf "$work"' EXIT

# Parse and validate in one pass: a malformed line is outcome 2, never a
# silently skipped rule.
awk -F'\t' -v allowed="$work/allowed" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == "allow" {
        if (NF != 2 || $2 == "") {
            printf "allow: line %d needs exactly one address\n", NR > "/dev/stderr"; bad = 1; next
        }
        print $2 > allowed; next
    }
    { printf "unknown entry kind on line %d: %s\n", NR, $1 > "/dev/stderr"; bad = 1 }
    END { exit bad ? 1 : 0 }
' "$ALLOW_FILE" || die2 "the allow list has entries this guard cannot act on"

touch "$work/allowed"
[ -s "$work/allowed" ] || die2 "the allow list names no address: every commit would be a finding"

git log --format='%H%x09%ae' "$base..HEAD" > "$work/commits" \
    || die2 "git log $base..HEAD failed"

findings=""
while IFS=$'\t' read -r sha email; do
    [ -n "$sha" ] || continue
    grep -Fxq -- "$email" "$work/allowed" && continue
    findings="${findings}commit ${sha:0:12} is authored by <$email>, which is not an allowed address
  $(git log -1 --format='%s' "$sha")
"
done < "$work/commits"

if [ -n "$findings" ]; then
    printf '%s' "$findings"
    exit 1
fi
exit 0
