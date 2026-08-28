#!/usr/bin/env bash
# Keeps private material out of a public push: the words we do not say are
# listed in a dictionary, and this script looks for them in what the push
# would carry — the message and the patch of every commit in the outgoing
# range — plus the staged and unstaged diffs on their way there.
#
# THREE OUTCOMES, and the third is the point of the script rather than an
# afterthought:
#   0  nothing found
#   1  something found (the findings are printed: where, which entry, the line)
#   2  the run did not happen (no dictionary, no audit base, a broken pattern,
#      an allow entry that cannot be verified, no perl)
# A guard that cannot read its dictionary and reports "clean" is worse than no
# guard, because it is believed. Nothing here is piped into anything that would
# swallow the exit code.
#
# ONE REGEX ENGINE, AND WHY THAT IS THE WHOLE OF IT. Three things happen to a
# pattern here: it is COMPILED (does the entry parse), it is APPLIED to blank
# the permitted spellings out of the text, and it is SEARCHED for. All three
# are done by perl, over the same string, through the same qr//. That is not
# tidiness. The previous version validated entries with `grep -E`, where `\b`
# is a word boundary, and applied them with BSD `sed -E`, where `\b` is not:
# the entry `\bpdm_[a-z0-9_]+` compiled, looked alive, blanked nothing, and
# `pdm_comrak_bridge` was reported as a leak — reproduced on a synthetic
# repository, not argued from the manual. Two engines that agree on the syntax
# they share still disagree at the edges, and an allow list is exactly where a
# disagreement is silent: the entry does not fail, it stops existing.
#
# A pattern from the dictionary is data and stays data: it reaches perl in a
# file, never through a shell word, and it is compiled from a variable, which
# is what makes `(?{ … })` a compile error ("Eval-group not allowed at
# runtime") instead of a way for the private notes file to run a command.
#
# AND SILENCE IS WHAT IS CHECKED FOR. Every allow entry is run through the REAL
# scrubber before any text is collected: a witness string is built from the
# entry, the engine is asked to confirm the witness matches the entry, and the
# scrubber must blank it. An entry whose witness cannot be built, or survives
# its own scrubber, is outcome 2. Inertness is now loud.
#
# WHERE THE DICTIONARY LIVES, and why it is not in this repository: the list of
# what we hide is itself a thing we hide. It is read from DOTMD.md, which is in
# .gitignore, between the markers `publicity-dictionary:begin/end`; a second
# section, `publicity-allow:begin/end`, lists the spellings that are explicitly
# permitted. Set PUBLICITY_DICTIONARY to read the sections from another file.
#
# THE PRICE, stated here so nobody discovers it in a red CI log: in a clone
# without DOTMD.md — and a GitHub Actions runner is exactly that — this check
# is RED, not skipped. That is the fail-closed choice: a checkout that cannot
# see the dictionary cannot promise the diff is clean. The honest way to give a
# runner the dictionary is a repository secret written to a file and pointed at
# with PUBLICITY_DICTIONARY. Until that exists, wiring this check into the Audit
# job of ci.yml FAILS that job on every run. This script does not touch ci.yml:
# that is the maintainer's call, not this script's.
#
# WHAT IT DOES NOT PROVE, in one place instead of scattered through the code:
#   * It reads ADDED lines only (`+` in the diff) plus the path of every file a
#     diff writes to. A forbidden word already in the base is invisible to it —
#     deliberately: scanning removals would make a leak impossible to delete,
#     since the deletion carries the word in the diff too.
#   * The range is read one commit at a time, because a push publishes commits
#     and not their sum. The consequence is deliberate and is not a defect: a
#     word that went into an older commit of the range keeps this check RED
#     until the history is rewritten. It is red because the leak is real — the
#     forge will show that commit's patch to everyone who opens it.
#   * It searches the CONTENT, never the location it prints. A file named after
#     something private is caught once, by its path, and not once per line.
#   * It is a list of spellings. A paraphrase that writes none of the listed
#     words passes, and so does an image, or anything git shows as binary.
#   * It says nothing about untracked files: they are in no diff, and in no push.
#   * `--message-file` checks the given text and NOTHING else — no diff, no
#     history, no base. It exists so a commit-msg hook can ask about a message
#     that has no commit yet.
#   * The witness built for an allow entry is a string the engine confirms the
#     entry matches — not every string it matches. An entry that is alive for
#     its witness and inert for some other spelling passes this.
#   * The witness is built by reducing regex syntax to a literal, and groups
#     and alternation are not reduced. An allow entry that uses them is
#     outcome 2 — loudly unverifiable, never quietly unverified — until this is
#     taught to handle it. The live list has none.
#
# ALL THREE DIFFS ARE READ WITH `--no-renames`, and it costs something. A pure
# rename prints `rename from`/`rename to` and not one `+` line, so a file moved
# to a private name, or moved WITH private content in it, was invisible: a
# `git mv` onto a filename the dictionary lists exited 0 — reproduced on a
# synthetic repository. Without rename detection the same change arrives as a
# deletion plus an addition, and the new path and every line of its content go
# through the search. The price is paid on every large file that is merely
# moved: its whole content is collected and scanned again.
#
# Usage:
#   scripts/check-publicity.sh                     # range + staged + unstaged
#   scripts/check-publicity.sh --message-file FILE # only that text
#
#   AUDIT_BASE             explicit base for the outgoing range
#   PUBLICITY_DICTIONARY   file holding the two marker sections (default DOTMD.md)
set -uo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
Usage: scripts/check-publicity.sh [--message-file FILE]
Exit: 0 clean, 1 forbidden material found, 2 the check could not run.
Env:  AUDIT_BASE, PUBLICITY_DICTIONARY (default DOTMD.md)
USAGE
}

DICT_FILE="${PUBLICITY_DICTIONARY:-DOTMD.md}"
MESSAGE_FILE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --message-file)
            [ $# -ge 2 ] || { echo "check-publicity: --message-file needs a path" >&2; exit 2; }
            MESSAGE_FILE=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-publicity: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

die2() { printf 'check-publicity: cannot run: %s\n' "$1" >&2; exit 2; }

# The one engine. Named once, missing is outcome 2 and never a quiet fall back
# to sed — falling back is precisely the defect this script was repaired for.
command -v perl > /dev/null || die2 "perl is not installed (it is the regex engine here)"

work=$(mktemp -d) || die2 "mktemp failed"
trap 'rm -rf "$work"' EXIT

# -- The engine -------------------------------------------------------------
# Three verbs over one qr//: compile, blank, search. Patterns arrive in a file,
# one per line, so nothing about them is ever passed through a shell word.

compile_patterns() { # compile_patterns <patterns-file> <section-name>
    perl -e '
        my $sect = shift @ARGV;
        my $bad = 0;
        while (my $p = <STDIN>) {
            chomp $p; next if $p eq "";
            my $re = eval { qr/$p/ };
            if (!defined $re) {
                my $err = $@; $err =~ s/\s+\z//; $err =~ s/\n.*//s;
                print STDERR "$sect: not a valid pattern: $p ($err)\n";
                $bad = 1;
            }
        }
        exit($bad ? 3 : 0);
    ' "$2" < "$1"
}

# Blank every permitted spelling out of the text. What survives is exactly the
# text no permission covers; a denied word that merely overlaps a permitted one
# still survives it and is still reported.
scrub_stream() { # scrub_stream <patterns-file> <in-file> <out-file>
    perl -e '
        my $pf = shift @ARGV;
        open(my $fh, "<", $pf) or die "cannot read $pf: $!\n";
        my @res;
        while (my $p = <$fh>) { chomp $p; next if $p eq ""; push @res, qr/$p/; }
        close $fh;
        while (my $line = <>) {
            for my $re (@res) { $line =~ s/$re/ /g; }
            print $line;
        }
    ' "$1" "$2" > "$3"
}

# `lineno<TAB>the entry that fired`, first entry per line: "something was found"
# is not actionable, the author needs to know which word to stop writing.
search_stream() { # search_stream <patterns-file> <in-file>
    perl -e '
        my $pf = shift @ARGV;
        open(my $fh, "<", $pf) or die "cannot read $pf: $!\n";
        my @pats;
        while (my $p = <$fh>) { chomp $p; next if $p eq ""; push @pats, [$p, qr/$p/]; }
        close $fh;
        my $n = 0;
        while (my $line = <>) {
            $n++;
            for my $p (@pats) {
                if ($line =~ $p->[1]) { print "$n\t$p->[0]\n"; last; }
            }
        }
    ' "$1" "$2"
}

# One witness per entry, in order. Regex syntax is reduced to a literal: the
# zero-width assertions vanish, a character class becomes its first member, a
# quantifier becomes one repetition, an escape becomes the character it names.
# The reduction is deliberately crude AND deliberately checked — the engine is
# asked whether the witness really matches the entry, and an entry we cannot
# witness is outcome 2 rather than an entry quietly left unverified.
witness_patterns() { # witness_patterns <patterns-file>   (witnesses on stdout)
    perl -e '
        my $bad = 0;
        while (my $p = <STDIN>) {
            chomp $p; next if $p eq "";
            my $w = $p;
            $w =~ s/\\[bBAzZG]//g;                            # zero-width
            $w =~ s/(?<!\\)[\^\$]//g;                         # anchors
            $w =~ s/(?<!\\)\[\^?(\\.|[^\]\\])[^\]]*\]/$1/g;   # class -> member
            $w =~ s/\\d/0/g; $w =~ s/\\w/a/g; $w =~ s/\\s/ /g;
            $w =~ s/(?<!\\)\{\d+(?:,\d*)?\}//g;               # {n,m} -> one
            $w =~ s/(?<!\\)[*+?]//g;                          # quantifier -> one
            $w =~ s/(?<!\\)\./x/g;                            # any character
            $w =~ s/\\(.)/$1/g;                               # unescape
            if ($w eq "" || $w !~ /$p/) {
                print STDERR "publicity-allow: cannot build a witness for: $p\n";
                $bad = 1;
                print "\n";
            } else {
                print "$w\n";
            }
        }
        exit($bad ? 3 : 0);
    ' < "$1"
}

# The witnesses come back from the REAL scrubber; an entry whose own witness
# survives it is inert, and inertness is the failure this pairing exists for.
assert_scrubbed() { # assert_scrubbed <patterns-file> <scrubbed-witness-file>
    perl -e '
        my ($pf, $wf) = @ARGV;
        open(my $a, "<", $pf) or die "cannot read $pf: $!\n";
        open(my $b, "<", $wf) or die "cannot read $wf: $!\n";
        my $bad = 0;
        while (my $p = <$a>) {
            chomp $p; next if $p eq "";
            my $s = <$b>;
            if (!defined $s) {
                print STDERR "publicity-allow: no scrubbed witness for: $p\n";
                $bad = 1; last;
            }
            chomp $s;
            if ($s =~ /$p/) {
                print STDERR "publicity-allow: the entry is inert — the scrubber left a string it matches: $p\n";
                $bad = 1;
            }
        }
        exit($bad ? 3 : 0);
    ' "$1" "$2"
}

# -- The dictionary ---------------------------------------------------------
# Extracted by markers, not by line numbers: the private file is edited by hand
# and its line numbers move.
extract_section() { # extract_section <marker-name>
    awk -v b="<!-- $1:begin -->" -v e="<!-- $1:end -->" '
        $0 == b { inside = 1; next }
        $0 == e { inside = 0; next }
        inside  { print }
    ' "$DICT_FILE" | sed 's/[[:space:]]*$//' | grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*#'
    return 0
}

[ -f "$DICT_FILE" ] || die2 "no dictionary: $DICT_FILE is missing (see the header)"
[ -r "$DICT_FILE" ] || die2 "no dictionary: $DICT_FILE is not readable"
grep -q -- '<!-- publicity-dictionary:begin -->' "$DICT_FILE" \
    || die2 "$DICT_FILE has no publicity-dictionary section"
grep -q -- '<!-- publicity-allow:begin -->' "$DICT_FILE" \
    || die2 "$DICT_FILE has no publicity-allow section"

extract_section publicity-dictionary > "$work/deny"  || die2 "reading the dictionary failed"
extract_section publicity-allow      > "$work/allow" || die2 "reading the allow list failed"
[ -s "$work/deny" ] || die2 "the publicity-dictionary section is empty"

# Every entry must compile before anything is searched. A dictionary with one
# broken entry would otherwise search with the rest and call the diff clean.
compile_patterns "$work/deny"  publicity-dictionary || die2 "the dictionary has an entry perl will not compile"
compile_patterns "$work/allow" publicity-allow      || die2 "the allow list has an entry perl will not compile"

# …and every allow entry must survive a round trip through the scrubber that
# will be used on the real text. Compiling is not being alive.
if [ -s "$work/allow" ]; then
    witness_patterns "$work/allow" > "$work/witness" \
        || die2 "an allow entry cannot be witnessed (see above)"
    scrub_stream "$work/allow" "$work/witness" "$work/witness.scrubbed" \
        || die2 "blanking the witnesses failed"
    assert_scrubbed "$work/allow" "$work/witness.scrubbed" \
        || die2 "an allow entry is inert (see above)"
fi

# -- Collecting the text ----------------------------------------------------
# One stream, one candidate per line, `LOCATION<TAB>TEXT`. Only TEXT is
# searched; LOCATION is ours, and searching it would report a private file name
# once per line of that file instead of once.
: > "$work/stream"

collect_message() { # collect_message <location> <file>
    sed "s|^|$1	|" "$2" >> "$work/stream"
}

# The hunk body is entered by `@@` and left by the next file's `diff --git`, and
# nothing is taken for a header inside it. Two holes lived in the version that
# had no such state: a CONTENT line reading `++ …` arrives in the diff as
# `+++ …` and was read as a file header, so the line was never searched; and the
# path was compared after its `b/` prefix had been cut, which made the
# `/dev/null` of a deletion read as `ev/null` and the guard against it dead.
collect_diff() { # collect_diff <label>   (a diff arrives on stdin)
    awk -v label="$1" '
        /^diff --git / { inhunk = 0; path = ""; next }
        /^@@/          { inhunk = 1; next }
        !inhunk && /^\+\+\+ / {
            p = substr($0, 5)
            if (p != "/dev/null") {
                sub(/^b\//, "", p)
                path = p
                printf "%s %s\tpath: %s\n", label, path, path
            }
            next
        }
        inhunk && /^\+/ { printf "%s %s\t%s\n", label, (path == "" ? "?" : path), substr($0, 2) }
    ' >> "$work/stream"
}

if [ -n "$MESSAGE_FILE" ]; then
    [ -f "$MESSAGE_FILE" ] || die2 "no such message file: $MESSAGE_FILE"
    collect_message "message $MESSAGE_FILE" "$MESSAGE_FILE" || die2 "reading $MESSAGE_FILE failed"
else
    git rev-parse --git-dir > /dev/null 2>&1 || die2 "not a git repository"

    # The base comes from scripts/audit-base.sh, which is where the chain
    # lives now. It used to be written out here as well, kept in step with
    # audit.sh by a comment — and the two had already drifted on the case that
    # matters: an empty range. Outcome 2 covers both ways of having read
    # nothing, no base and no commits, because both are "this did not run".
    resolver="$(dirname "$0")/audit-base.sh"
    base_err="$work/base-err"
    base=$("$resolver" 2>"$base_err"); base_st=$?
    case "$base_st" in
        0) : ;;
        3) die2 "$(cat "$base_err") — nothing was published for this run to read" ;;
        *) die2 "$(cat "$base_err")" ;;
    esac

    revs=$(git rev-list "$base..HEAD") || die2 "git rev-list $base..HEAD failed"
    # ONE COMMIT AT A TIME, and this is the correction that matters: a push
    # publishes commits, not their sum. `git diff base..HEAD` is the NET diff,
    # and a word added in one commit of the range and removed in another is
    # invisible to it while `git log -p` on the forge shows it to everyone.
    # Measured on this very branch: the net diff of a rename had 0 hits, the
    # patches of its two commits had 2.
    #
    # `-m --first-parent` so a merge commit is not an empty patch: `git show`
    # prints nothing for a merge by default, which would be a hole exactly the
    # size of a merged branch. `--no-renames` for the reason in the header.
    for sha in $revs; do
        short=${sha:0:12}
        git log -1 --format=%B "$sha" > "$work/msg" || die2 "git log -1 $sha failed"
        collect_message "message $short" "$work/msg"
        git show --format= -m --first-parent --no-renames "$sha" > "$work/d" \
            || die2 "git show $sha failed"
        collect_diff "patch $short" < "$work/d"
    done

    git diff --cached --no-renames > "$work/d" || die2 "git diff --cached failed"
    collect_diff "staged" < "$work/d"
    git diff --no-renames > "$work/d" || die2 "git diff failed"
    collect_diff "unstaged" < "$work/d"
fi

# Commits were read and added no lines, and the tree is clean: examined and
# clean, which is a pass. An EMPTY RANGE never reaches here — the resolver
# reports that as outcome 2 above, because reading zero commits is not the
# same fact as reading commits that said nothing. This comment used to claim
# the opposite ("the normal state right after a push"), and right after a push
# is precisely when the claim let a whole published range through unread.
if [ ! -s "$work/stream" ]; then
    echo "check-publicity: nothing to check (commits added no lines, clean tree)."
    exit 0
fi

# -- The search -------------------------------------------------------------
cut -f2- < "$work/stream" > "$work/text" || die2 "splitting the collected text failed"
scrub_stream "$work/allow" "$work/text" "$work/scrubbed" || die2 "blanking the allow list failed"

hits=$(search_stream "$work/deny" "$work/scrubbed") || die2 "the search over the collected text failed"
[ -n "$hits" ] || exit 0

# Report against the ORIGINAL line, not the blanked one: the blanked line is
# what the decision was made on, but it is not what the author wrote.
while IFS=$'\t' read -r n pat; do
    [ -n "$n" ] || continue
    line=$(sed -n "${n}p" "$work/stream")
    where=${line%%	*}
    text=${line#*	}
    printf '%s: matches /%s/\n' "$where" "$pat"
    printf '      %s\n' "$text"
done <<< "$hits"

exit 1
