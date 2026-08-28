#!/usr/bin/env bash
# Mechanical half of the repo auditor (docs/audit.md). Static checks only —
# fast enough to run before every push, side-effect free, and fail-closed:
# a check that cannot run reports FAIL, never a silent PASS. Build/tests are
# the heavier gate and run through xcodebuild (see docs/testing.md).
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { # fail <name> <detail…>
    local name=$1; shift
    printf 'FAIL  %s\n' "$name"
    [ $# -gt 0 ] && printf '      %s\n' "$@"
    fails=$((fails + 1))
}

grep_tracked() { git -c core.quotepath=false grep -I -l "$@" 2>/dev/null; }

# The verdict of a search for something that must NOT be there. Absence is code 1
# from git grep and only that: 0 means found, anything else means git grep did not
# run, which is a FAIL and never a PASS. The header's promise — "a check that
# cannot run reports FAIL" — lives here, in one place, instead of in the third
# branch of an `if` copied per check, where the copy that forgets it reports PASS
# on an error.
absent_or_fail() {
    name=$1 st=$2
    shift 2
    if [ "$st" -eq 1 ]; then pass "$name"
    elif [ "$st" -eq 0 ]; then fail "$name" "$@"
    else fail "$name" "git grep errored ($st)"; fi
}

# 1. Cyrillic outside the allowlist (language policy, CLAUDE.md).
#    \p{Cyrillic} keeps this script free of Cyrillic itself. Allowed:
#    the localization catalogs (both the app strings and the Info.plist
#    ones the system shows in its own prompts), the endonym, skill trigger
#    phrases, Cyrillic-folding sources, test data, and the live root fixture.
cyr=$(grep_tracked -P '\p{Cyrillic}' -- \
    ':!EditMD/EditMD/Resources/Localizable.xcstrings' \
    ':!EditMD/EditMD/Resources/InfoPlist.xcstrings' \
    ':!EditMD/EditMD/Views/AppLanguage.swift' \
    ':!EditMD/EditMD/Resources/agent-skill/SKILL.md' \
    ':!.agents/skills/*/SKILL.md' \
    ':!EditMD/EditMD/Editor/SearchMatch.swift' \
    ':!EditMD/EditMD/Editor/SearchQuery.swift' \
    ':!EditMD/EditMDTests/' \
    ':!test-all-elements.md' \
    ':!test-all-elements.md.review.json')
absent_or_fail cyrillic-outside-allowlist $? $cyr

# 2. Relative markdown links inside docs/ and README resolve.
badlinks=""
for f in docs/*.md README.md; do
    [ -f "$f" ] || { badlinks="$badlinks missing:$f"; continue; }
    raw=$(grep -o '](\([^)]*\))' "$f" 2>/dev/null)
    st=$?
    [ $st -gt 1 ] && { badlinks="$badlinks grep-error:$f"; continue; }
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        case "$target" in http*|\#*|mailto:*) continue ;; esac
        rel="${target%%#*}"
        [ -e "$(dirname "$f")/$rel" ] || [ -e "$rel" ] || badlinks="$badlinks $f->$target"
    done <<< "$(printf '%s\n' "$raw" | sed 's/^](//; s/)$//')"
done
if [ -z "$badlinks" ]; then pass "doc-links-resolve"; else fail "doc-links-resolve" $badlinks; fi

# 3. docs/ paths referenced from executable sources and guides exist.
#    Tests and agent-skill examples are excluded by design: their docs/…
#    strings are sample vault paths, not references to this repository.
refs=$(grep -rho 'docs/[A-Za-z0-9._/-]*\.md' \
        EditMD/EditMD EditMD/editmdctl EditMD/editmd-mcp EditMD/scripts \
        scripts CLAUDE.md AGENTS.md README.md EditMD/project.yml \
        --exclude-dir=Resources 2>/dev/null | sort -u)
st=$?
if [ $st -gt 1 ]; then
    fail "code-doc-refs-exist" "grep errored ($st)"
else
    badrefs=""
    for p in $refs; do [ -e "$p" ] || badrefs="$badrefs $p"; done
    if [ -z "$badrefs" ]; then pass "code-doc-refs-exist"; else fail "code-doc-refs-exist" $badrefs; fi
fi

# 4. xcodegen drift: project.yml must regenerate to the current .xcodeproj.
#    Generation happens in a temporary CoW clone of EditMD/ — the working
#    tree is never written, so an interruption cannot leave it modified.
proj=EditMD/EditMD.xcodeproj
if ! command -v xcodegen > /dev/null; then
    fail "xcodegen-no-drift" "xcodegen not installed"
elif [ ! -d "$proj" ]; then
    fail "xcodegen-no-drift" "$proj missing"
else
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    if { cp -cR EditMD "$tmp/EditMD" 2>/dev/null || cp -R EditMD "$tmp/EditMD"; } \
        && rm -rf "$tmp/EditMD/EditMD.xcodeproj" \
        && xcodegen generate --spec "$tmp/EditMD/project.yml" --quiet > /dev/null 2>&1; then
        drift=""
        # Every generated file must match the worktree byte-for-byte…
        while IFS= read -r g; do
            rel="${g#"$tmp/EditMD/EditMD.xcodeproj/"}"
            cmp -s "$g" "$proj/$rel" || drift="$drift $rel"
        done < <(find "$tmp/EditMD/EditMD.xcodeproj" -type f)
        # …and every tracked project file (minus SPM state, which Xcode owns)
        # must still be produced by the generator.
        while IFS= read -r t; do
            rel="${t#"$proj/"}"
            case "$rel" in *xcshareddata/swiftpm/*) continue ;; esac
            [ -f "$tmp/EditMD/EditMD.xcodeproj/$rel" ] || drift="$drift missing:$rel"
        done < <(git ls-files "$proj")
        if [ -z "$drift" ]; then pass "xcodegen-no-drift"; else fail "xcodegen-no-drift" $drift; fi
    else
        fail "xcodegen-no-drift" "could not clone EditMD/ or xcodegen generate failed"
    fi
    rm -rf "$tmp"
    trap - EXIT
fi

# 5. Secret patterns in tracked files.
secrets=$(grep_tracked -E \
    'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(ant|proj|live)-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|xox[bp]-[0-9A-Za-z-]{10,}|BEGIN [A-Z ]*PRIVATE KEY')
absent_or_fail no-secret-patterns $? $secrets

# 6. Third-party notices cover every SwiftPM pin; vendored licenses present.
resolved=EditMD/EditMD.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
if [ ! -f "$resolved" ] || [ ! -f THIRD_PARTY_NOTICES.md ]; then
    fail "third-party-notices" "Package.resolved or THIRD_PARTY_NOTICES.md missing"
else
    missing=""
    pins=$(grep -o '"identity" : "[a-z-]*"' "$resolved" | sed 's/.*: "//; s/"//')
    [ -z "$pins" ] && missing="no-pins-parsed"
    for dep in $pins; do
        grep -qi "$dep" THIRD_PARTY_NOTICES.md || missing="$missing $dep"
    done
    [ -f EditMD/EditMD/Resources/katex/katex-LICENSE.txt ] || missing="$missing katex-LICENSE"
    [ -f EditMD/EditMD/Resources/opensans/opensans-LICENSE.txt ] || missing="$missing opensans-LICENSE"
    if [ -z "$missing" ]; then pass "third-party-notices"; else fail "third-party-notices" $missing; fi
fi

# 7. Guide budgets: the compressed guides must stay compressed.
if [ -f CLAUDE.md ] && [ -f AGENTS.md ]; then
    cl=$(wc -l < CLAUDE.md); ag=$(wc -l < AGENTS.md)
    if [ "$cl" -le 130 ] && [ "$ag" -le 45 ]; then pass "guide-budget (CLAUDE<=130 AGENTS<=45)"
    else fail "guide-budget (CLAUDE<=130 AGENTS<=45)" "CLAUDE.md=$cl AGENTS.md=$ag"; fi
else
    fail "guide-budget (CLAUDE<=130 AGENTS<=45)" "guide file missing"
fi

# 8. Junk files never tracked.
tracked=$(git ls-files)
if [ $? -ne 0 ]; then
    fail "no-junk-tracked" "git ls-files errored"
else
    junk=$(printf '%s\n' "$tracked" | grep -E '\.DS_Store|xcuserdata/|\.log$|\.smotr')
    if [ -z "$junk" ]; then pass "no-junk-tracked"; else fail "no-junk-tracked" $junk; fi
fi

# 9. Whitespace errors: unstaged, staged, and the outgoing commit range.
#    The base comes from scripts/audit-base.sh — one resolver for every guard
#    that needs one, because this chain used to be written here and again in
#    check-publicity.sh with nothing but a comment holding the two together.
#    A pre-push audit without any determinable base is a FAIL, not a silent
#    skip; and an EMPTY range is its own outcome, because a range with no
#    commits in it means this check read no commits — which is not the same
#    fact as "the commits were read and were clean".
base_err=$(mktemp) || { fail "git-diff-check" "cannot make a temporary file"; base_err=/dev/null; }
base=$(scripts/audit-base.sh 2>"$base_err"); base_st=$?
base_why=$(cat "$base_err"); rm -f "$base_err"
case "$base_st" in
    0)  ws=""
        git diff --check > /dev/null 2>&1 || ws="worktree"
        git diff --check --cached > /dev/null 2>&1 || ws="$ws staged"
        git diff --check "$base" HEAD > /dev/null 2>&1 || ws="$ws outgoing($base)"
        if [ -z "$ws" ]; then pass "git-diff-check (base: $base)"
        else fail "git-diff-check" $ws; fi ;;
    3)  fail "git-diff-check" "$base_why" \
             "The worktree and the index were still read; the published range" \
             "was not. Name the commit the range starts at:" \
             "AUDIT_BASE=<sha> scripts/audit.sh" ;;
    *)  fail "git-diff-check" "$base_why" ;;
esac

# 10. One producer of PDF pages. The app prints through the core and nowhere
#     else; a second producer is what this looks for, and what it looks for is
#     WebKit's `createPDF(` — the call any web-view export needs, whatever file
#     or type name it hides behind. A grep for a file or a type would have
#     caught nothing: the name of the file that used to do this appears nowhere
#     in the call.
#
#     What it counts is *occurrences of the two names in tracked and untracked
#     Swift sources*, not calls: it is a grep, and a declaration named
#     `createPDF` would count too. At a threshold of zero the difference costs
#     nothing, and the check is written to claim only what it can see.
#
#     It matches the NAME and not the call, and that is a correction rather than
#     a simplification. The first version looked for the literal `createPDF(`,
#     and a review found the hole: Swift accepts a space before the parenthesis,
#     `webView.createPDF (configuration: cfg)` compiles and builds, and the
#     literal pattern reported PASS on it — measured, not argued. Matching the
#     bare identifier also covers the call whose parenthesis sits on the next
#     line, which no line-oriented grep could ever see.
#
#     `createPDF` has no right-hand boundary for the same reason. WebKit's
#     Objective-C name is `createPDFWithConfiguration:completionHandler:`, and a
#     selector built from that string is a way to reach the same method that a
#     bounded pattern would let through — a second review found that one.
#
#     `pdf(configuration:` and `WKPDFConfiguration` are the async form of the
#     same export (`WKWebView.pdf(configuration:) async throws -> Data`), which
#     a third review found passing a pattern built out of `createPDF` alone:
#     the modern call shares no identifier with the old one. Neither name occurs
#     in this tree today.
#
#     THIS IS A LIST OF NAMES, and that is its ceiling: three reviews have each
#     added one, because a blacklist closes doors and not the room. `webView.pdf()`
#     — the same method with its default configuration — names neither pattern
#     and passes. Closing the class means the opposite shape: a WHITELIST of
#     places, "bytes of a PDF are produced in PrintPDFRenderer.swift and nowhere
#     else", which is a different check and is not written.
#
#     `previewHTMLPage` was the wrapper that fed the old exporter its HTML.
#     Preview itself calls `previewHTMLPageRender`, which this pattern does not
#     match: the character after the name must not be one that could continue
#     an identifier, and `R` is.
#
#     `--untracked` on purpose: a new file that has not been `git add`ed yet is
#     exactly where a second producer appears first, and a check that reports
#     PASS until someone stages it is a check with a hole the size of a commit.
#
#     WHAT IT DOES NOT SEE, stated here because a PASS will be read years from
#     now by someone the reason has left: a producer of PDFs that is not a web
#     view — `NSPrintOperation`, pages written through PDFKit — needs none of
#     these names and passes this check untouched, and so does a web-view export
#     spelled in a way no name here lists. What is proved is the narrow "no
#     occurrence of the four names below", read as "no second producer on WebKit
#     by any spelling seen so far" — not the whole of "one path into a PDF"; the
#     rest of that sentence is held by the probes that compare what the export
#     writes with what the pane prints.
raw=$(git -c core.quotepath=false grep -n --untracked -I -E \
        -e '(^|[^A-Za-z0-9_])createPDF' \
        -e '(^|[^A-Za-z0-9_])pdf[[:space:]]*\([[:space:]]*configuration' \
        -e 'WKPDFConfiguration' \
        -e '(^|[^A-Za-z0-9_])previewHTMLPage([^A-Za-z0-9_]|$)' -- '*.swift')
st=$?
absent_or_fail one-pdf-producer "$st" $(printf '%s\n' "$raw" | cut -d: -f1,2)

# 11. The prose about render paths says what the code does.
#
#     THE TRAP THIS IS BUILT AGAINST: an oracle copied from the line it checks
#     proves the two copies agree, not that either is true. So nothing here
#     compares text with text. Each claim is lifted out of the prose and asked
#     of the SWIFT SOURCES: does the file exist, does it call the core, does it
#     mention a web view. The prose is the question; the code is the answer.
#
#     Fail-closed at every joint: a table that is not found, a row that is not
#     found, a file that is not found are each a FAIL with a reason. There is no
#     branch here that reports PASS because it could not look.
#
#     THE CONTROL HALF is Preview, and it is not decoration. A check that only
#     ever asserts "no WebKit token here" is indistinguishable from a check
#     blind to the token altogether — it would stay green if the pattern were
#     misspelled. Preview must CARRY the pattern in its row of the table, in
#     `MarkdownPreviewView.swift`, and in a fragment of CLAUDE.md, so a blind
#     pattern turns this check red on three separate joints.
#
#     THE CONTROL IS RUN WITH THE SEARCHING EXPRESSION and never with a literal
#     copy of one of its alternatives. Both control branches used to grep
#     `WKWebView` while the search grepped `$webkit_tokens`; that is the shape
#     of the hole, and it was measured, not argued: a deliberately misspelled
#     pattern kept this check green over a tree that carried the defect. A
#     control answering a different question from the one under test is a
#     witness to something else.
#
#     THE ALTERNATIVES ARE PROBED ONE BY ONE, split out of the variable itself
#     rather than written down a second time — a second list is a copy of the
#     truth and drifts in silence. What the probe proves is narrow: every branch
#     of the alternation compiles and matches its own spelling, so a branch that
#     can never fire (an unbalanced bracket, a stray quote) is loud. It does NOT
#     prove the spellings are the right ones — that is the Preview control's
#     job — and an alternative deliberately written to match something other
#     than itself (`createPDF\(` would be one) would be a false alarm here.
#     There is none today, and adding one means teaching this probe.
#
#     WHAT IT DOES NOT PROVE: that the described path is the one that runs. It
#     proves the named files exist, that the one named as the renderer reaches
#     the core by name, and that no file of that path mentions a web view. A
#     second, undescribed path through some other file is invisible to it —
#     that sentence belongs to check 13. It also does not read the Source or
#     Visual rows at all: they name globs, not files, and no claim about them
#     was made worth checking.
#
#     THE UNIT OF "NEAR THE WORD Print" in CLAUDE.md is a comma- or
#     semicolon-separated fragment, which is exactly how the guide lists the
#     four paths. A WebKit token in a fragment that does not say `Print` is
#     legal — the opening paragraph describes Preview, and Preview is a web
#     view. That is the ceiling: a description of Print spread across two
#     fragments could put the token in the half that omits the word.
#
#     THE SCAN READS THE WHOLE GUIDE, not one bullet. The four modes are
#     INTRODUCED in the opening paragraph and only recapitulated in the
#     invariant bullet, so a scan anchored on the bullet could not see the
#     sentence that names them first: a planted `Print (PDF via WKWebView and
#     createPDF, in` on that line passed — measured. Fragments are cut out of
#     paragraphs rather than out of physical lines, because the guide is
#     hard-wrapped and the sentence about Print already spans a line break.
#     A paragraph is what a blank line separates; a fenced code block is a
#     paragraph like any other, and no claim is made about its contents beyond
#     the same fragment rule.
webkit_tokens='WKWebView|WebKit|createPDF|WKPDFConfiguration'
arch=docs/architecture.md
r11=""
# Every alternative of the searching expression must match its own spelling.
# The alternatives come from splitting the expression, never from a second list.
IFS='|' read -r -a wk_alts <<< "$webkit_tokens"
for wk_alt in "${wk_alts[@]}"; do
    [ -n "$wk_alt" ] || { r11="$r11 audit.sh:webkit-tokens-has-an-empty-alternative"; continue; }
    printf '%s\n' "$wk_alt" | grep -q -E "$webkit_tokens" \
        || r11="$r11 audit.sh:webkit-token-does-not-match-its-own-spelling:$wk_alt"
done
# Absolute line number of the first line in [start,end] of FILE matching RE.
line_in_range() { # line_in_range <file> <start> <end> <ere>
    local n
    n=$(sed -n "$2,$3p" "$1" | grep -n -E "$4" | head -1 | cut -d: -f1)
    [ -n "$n" ] && echo $(( $2 + n - 1 ))
}
# Every file the tree holds under that basename, tracked or not.
find_named() { find EditMD -type f -name "$1" 2>/dev/null; }

if [ ! -f "$arch" ]; then
    r11="$r11 missing:$arch"
elif [ ! -f CLAUDE.md ]; then
    r11="$r11 missing:CLAUDE.md"
else
    t_start=$(grep -n '^## Four modes, four code paths$' "$arch" | head -1 | cut -d: -f1)
    if [ -z "$t_start" ]; then
        r11="$r11 $arch:no-heading:'Four-modes,-four-code-paths'"
    else
        t_end=$(awk -v s="$t_start" 'NR>s && /^## / {print NR-1; f=1; exit} END {if (!f) print NR}' "$arch")
        table=$(sed -n "$t_start,$t_end p" "$arch" | grep '^|')
        [ -n "$table" ] || r11="$r11 $arch:no-table-under-heading"
        print_row=$(printf '%s\n' "$table" | grep -E '^\|[[:space:]]*Print[[:space:]]*\|' | head -1)
        prev_row=$(printf '%s\n' "$table" | grep -E '^\|[[:space:]]*Preview[[:space:]]*\|' | head -1)
        [ -n "$print_row" ] || r11="$r11 $arch:no-Print-row"
        [ -n "$prev_row" ] || r11="$r11 $arch:no-Preview-row"

        if [ -n "$print_row" ]; then
            # (b) the row itself must not describe Print through a web view.
            if printf '%s\n' "$print_row" | grep -q -E "$webkit_tokens"; then
                n=$(line_in_range "$arch" "$t_start" "$t_end" '^\|[[:space:]]*Print[[:space:]]*\|')
                r11="$r11 $arch:${n:-?}:Print-row-names-WebKit"
            fi
            # (a) every file named in the Files column exists, and (g) none of
            #     them mentions a web view.
            files=$(printf '%s\n' "$print_row" | cut -d'|' -f4 | tr -d '`' | tr ',' '\n' \
                        | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
            [ -n "$files" ] || r11="$r11 $arch:Print-row-names-no-files"
            # read, not `for … in $files`: a name from the prose is untrusted
            # text, and an unquoted expansion of it would glob against the cwd.
            while IFS= read -r f; do
                [ -z "$f" ] && continue
                found=$(find_named "$f")
                if [ -z "$found" ]; then
                    r11="$r11 $arch:Print-row-file-missing:$f"
                    continue
                fi
                while IFS= read -r path; do
                    [ -z "$path" ] && continue
                    hit=$(grep -n -E "$webkit_tokens" "$path" | head -1 | cut -d: -f1)
                    [ -n "$hit" ] && r11="$r11 $path:$hit:WebKit-in-Print-path"
                done <<< "$found"
            done <<< "$files"
            # (c) the renderer the prose names must actually reach the core.
            printf '%s\n' "$print_row" | grep -q 'PrintPDFRenderer\.swift' \
                || r11="$r11 $arch:Print-row-does-not-name-PrintPDFRenderer.swift"
            renderer=$(find_named PrintPDFRenderer.swift | head -1)
            if [ -z "$renderer" ]; then
                r11="$r11 PrintPDFRenderer.swift:not-in-tree"
            else
                calls=$(grep -c 'PDMCore\.' "$renderer")
                [ "$calls" -gt 0 ] || r11="$r11 $renderer:0-occurrences-of-PDMCore."
            fi
        fi

        if [ -n "$prev_row" ]; then
            # The control half: THE SEARCHING EXPRESSION, not a literal copy of
            # one of its alternatives, must find something here.
            printf '%s\n' "$prev_row" | grep -q -E "$webkit_tokens" \
                || r11="$r11 $arch:Preview-row-matches-no-WebKit-token(control-half-blind)"
            pv=$(find_named MarkdownPreviewView.swift | head -1)
            if [ -z "$pv" ]; then
                r11="$r11 MarkdownPreviewView.swift:not-in-tree"
            else
                pvhits=$(grep -c -E "$webkit_tokens" "$pv")
                [ "$pvhits" -gt 0 ] \
                    || r11="$r11 $pv:0-WebKit-tokens(control-half-blind)"
            fi
        fi
    fi

    # The same claim in CLAUDE.md, located by its own words rather than by a
    # line number: the guide is edited constantly and line numbers move.
    b_start=$(grep -n '^- A markdown feature spans four independent render paths' CLAUDE.md \
                | head -1 | cut -d: -f1)
    if [ -z "$b_start" ]; then
        r11="$r11 CLAUDE.md:no-bullet:'A-markdown-feature-spans-four-independent-render-paths'"
    else
        b_end=$(awk -v s="$b_start" 'NR>s && /^-[[:space:]]/ {print NR-1; f=1; exit} END {if (!f) print NR}' CLAUDE.md)
        bullet=$(sed -n "$b_start,$b_end p" CLAUDE.md)
        printf '%s\n' "$bullet" | grep -q 'PrintPDFRenderer' \
            || r11="$r11 CLAUDE.md:$b_start:bullet-does-not-name-PrintPDFRenderer"
    fi

    # The fragment scan, over the WHOLE guide rather than that one bullet.
    # Paragraphs are folded into a single line each — the guide is hard-wrapped
    # and the sentence introducing the four modes already spans a break — and
    # each carries the line it starts on, so a finding names a place to open.
    paras=$(awk '
        /^[[:space:]]*$/ { if (buf != "") { print start "\t" buf; buf = "" } next }
        { t = $0; sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
          if (buf == "") { start = FNR; buf = t } else { buf = buf " " t } }
        END { if (buf != "") print start "\t" buf }' CLAUDE.md)
    if [ -z "$paras" ]; then
        r11="$r11 CLAUDE.md:no-paragraphs-parsed"
    fi
    # The control half of THIS file, which until now had none at all: the whole
    # control of check 11 lived in the architecture.md branch, so a blind
    # pattern was silent here. Preview is legally a web view, and the guide says
    # so; a fragment naming Preview with a WebKit token must exist.
    preview_control=""
    while IFS= read -r para; do
        [ -z "$para" ] && continue
        p_line=${para%%$'\t'*}
        p_text=${para#*$'\t'}
        while IFS= read -r frag; do
            printf '%s\n' "$frag" | grep -q -E "$webkit_tokens" || continue
            printf '%s\n' "$frag" \
                | grep -q -E '(^|[^A-Za-z0-9_])Preview([^A-Za-z0-9_]|$)' \
                && preview_control=yes
            printf '%s\n' "$frag" \
                | grep -q -E '(^|[^A-Za-z0-9_])Print([^A-Za-z0-9_]|$)' || continue
            calls=0
            renderer=$(find_named PrintPDFRenderer.swift | head -1)
            [ -n "$renderer" ] && calls=$(grep -c 'PDMCore\.' "$renderer")
            r11="$r11 CLAUDE.md:$p_line:describes-Print-via-WebKit-but-${renderer:-PrintPDFRenderer.swift}-has-0-of-those-tokens-and-calls-PDMCore.-${calls}-times"
        done <<< "$(printf '%s' "$p_text" | tr ',;' '\n\n')"
    done <<< "$paras"
    [ -n "$preview_control" ] \
        || r11="$r11 CLAUDE.md:no-fragment-names-Preview-with-a-WebKit-token(control-half-blind)"
fi
if [ -z "$r11" ]; then pass "render-paths-match-code"; else fail "render-paths-match-code" $r11; fi

# 12. Nothing private rides out with the push. The dictionary of forbidden
#     spellings is not in this repository — the list of what we hide is itself
#     a thing we hide — so the work is done by scripts/check-publicity.sh,
#     which reads it from the private notes file. Its header carries the whole
#     rationale, including the price: a clone without that file is RED here,
#     not skipped.
#
#     Three outcomes are laid out by hand rather than folded into a truthy
#     test, because the third one is the interesting one: 2 means the guard did
#     not run, and a guard that did not run must never look like a clean tree.
#
#     WHAT IT DOES NOT PROVE: it reads added lines and commit messages, so a
#     word already in the base is invisible; and it is a list of spellings, so
#     a paraphrase passes. Its full ceiling is written where it belongs, in the
#     script's own header.
#
#     FOUR OUTCOMES NOW, AND THE PASS IS NO LONGER SILENT. A leak the owner
#     decided to accept rather than rewrite history for is forgiven by name,
#     one expression in one named commit, and the guard prints what it forgave.
#     That text is the only thing separating "accepted" from "quietly deleted
#     from the dictionary", so the audit prints it under the PASS instead of
#     swallowing it — a whitelist nobody ever reads is a whitelist nobody ever
#     retires. Exit 3 is the guard asking for one of its own exceptions to be
#     deleted, which is neither a leak nor a guard that failed to start, and it
#     gets its own branch for that reason.
pub_out=$(scripts/check-publicity.sh 2>&1)
pub_st=$?
case "$pub_st" in
    0) pass "publicity-dictionary"
       if [ -n "$pub_out" ]; then printf '%s\n' "$pub_out" | sed 's/^/      /'; fi ;;
    1) fail "publicity-dictionary" "forbidden material in the outgoing change:"
       printf '%s\n' "$pub_out" | sed 's/^/      /' ;;
    3) fail "publicity-dictionary" "a standing exception outlived its reason and must be deleted:"
       printf '%s\n' "$pub_out" | sed 's/^/      /' ;;
    *) fail "publicity-dictionary" "the check did not run (exit $pub_st):"
       printf '%s\n' "$pub_out" | sed 's/^/      /' ;;
esac

# 13. Bytes of a PDF are produced in PrintPDFRenderer.swift and nowhere else.
#
#     This is the WHITELIST that check 10 names in its own ceiling and does not
#     implement, and the two are complementary rather than redundant: check 10
#     forbids a set of names anywhere, this one permits a set of PLACES. Adding
#     a name to check 10 closes one more door; this closes the room. Check 10
#     is not touched by this — its ceiling is recorded in its own header, and
#     rewriting it into this shape would lose the four spellings it argues for.
#
#     SCOPE IS THE SHIPPED TARGETS, tracked and untracked: the app, editmdctl,
#     editmd-mcp. EditMDTests/ is deliberately OUT, named here rather than left
#     to be inferred — tests produce PDF bytes on purpose (PrintCoreRenderTests
#     calls the core, PrintModeTests draws a page through PDFKit to have
#     something to compare against) and none of it ships. A producer that hides
#     in a test file and is called from the app would be caught by the call
#     site, which is in the app and therefore in scope.
#
#     THE TOKENS ARE PRODUCERS ONLY. `PDFDocument(url:)` and `PDFDocument(data:)`
#     are deliberately absent: they CONSUME bytes (PDFViewerView, PrintPaneView
#     both do), and a check that reddened on the viewer would be turned off
#     within a week.
#
#     NON-EMPTINESS IS PART OF THE CHECK, AND IT IS NOT THE SAME AS COMPLETENESS.
#     A whitelist over a tree with no printing at all is vacuously satisfied and
#     green, which is the same report it gives for a healthy tree — so
#     PrintPDFRenderer.swift must itself contain at least one producer token.
#     That answers "is anything being matched", and for a long time it was all
#     that was answered: the scope holds exactly ONE hit (`PDMCore.render`), so
#     misspelling any of the other seven tokens left this check green over a
#     tree that carried the defect — measured, not argued. Non-emptiness is
#     satisfied by one live token; completeness is a claim about all eight.
#
#     SO EVERY TOKEN CARRIES THE LINE IT MUST CATCH, and each is run against it
#     before the search. The list is written ONCE, below, and both the search
#     and the probe are built from it; a second list would be a copy of the
#     truth and would drift in silence. What the probe proves is narrow: each
#     token, as spelled, still matches an example of the thing it is named for.
#     It does not prove the example resembles real code, nor that the token is
#     the right token — a whitelist bounds WHERE, and its ceiling is below.
#
#     WHAT IT DOES NOT PROVE: this too is a list of names, and a producer
#     spelled in a way no token here lists passes — a whitelist bounds WHERE,
#     not HOW. It also says nothing about what the bytes contain, nor about a
#     producer reached through a Process or a plug-in rather than a Swift call.
pdf_places='EditMD/EditMD/Editor/PrintPDFRenderer.swift EditMD/EditMD/Editor/PDMCore.swift'
# token<TAB>a line the token is required to match. One list, two readers.
pdf_tokens=(
    $'PDMCore\\.render\tlet bytes = try PDMCore.render(job)'
    $'NSPrintOperation\tlet op = NSPrintOperation(view: v, printInfo: info)'
    $'CGPDFContext\tlet ctx = CGPDFContext(consumer: c, mediaBox: &box, nil)'
    $'beginPDFPage\tctx.beginPDFPage(nil)'
    $'dataRepresentation\\(\\)\tlet bytes = document.dataRepresentation()'
    $'(^|[^A-Za-z0-9_])createPDF\twebView.createPDF(configuration: cfg) { _ in }'
    $'WKPDFConfiguration\tlet cfg = WKPDFConfiguration()'
    $'pdf[[:space:]]*\\([[:space:]]*configuration\tlet bytes = try await webView.pdf(configuration: cfg)'
)
pdf_probe=""
pdf_args=()
for pdf_pair in "${pdf_tokens[@]}"; do
    pdf_pat=${pdf_pair%%$'\t'*}
    pdf_fixture=${pdf_pair#*$'\t'}
    pdf_args+=(-e "$pdf_pat")
    printf '%s\n' "$pdf_fixture" | grep -q -E -e "$pdf_pat" \
        || pdf_probe="$pdf_probe token-does-not-match-its-own-example:/$pdf_pat/"
done
pdf_hits=$(git -c core.quotepath=false grep -n --untracked -I -E "${pdf_args[@]}" \
        -- 'EditMD/EditMD/*.swift' 'EditMD/editmdctl/*.swift' 'EditMD/editmd-mcp/*.swift')
pdf_st=$?
if [ "$pdf_st" -gt 1 ]; then
    fail "pdf-bytes-one-place" "git grep errored ($pdf_st)"
else
    stray=""
    while IFS= read -r h; do
        [ -z "$h" ] && continue
        hf=${h%%:*}
        case " $pdf_places " in
            *" $hf "*) ;;
            *) stray="$stray $(printf '%s' "$h" | cut -d: -f1,2)" ;;
        esac
    done <<< "$pdf_hits"
    # The whitelist must not be vacuous: no producer in the one place that is
    # supposed to have one means this check is measuring nothing.
    vac=""
    renderer=EditMD/EditMD/Editor/PrintPDFRenderer.swift
    if [ ! -f "$renderer" ]; then
        vac="whitelist is vacuous: $renderer is missing"
    elif ! printf '%s\n' "$pdf_hits" | grep -q "^$renderer:"; then
        vac="whitelist is vacuous: no producer token in $renderer"
    fi
    if [ -z "$stray" ] && [ -z "$vac" ] && [ -z "$pdf_probe" ]; then pass "pdf-bytes-one-place"
    else fail "pdf-bytes-one-place" ${vac:+"$vac"} $pdf_probe $stray; fi
fi

# 14. The release gate runs the tests it says it runs.
#
#     `scripts/dist.sh` runs PDMCoreTests twice, in Debug and in Release, and
#     the two answer different questions — its own header says why, and check
#     15 below is the reason the Release half is not redundant. Until this
#     check existed, nothing held that line up: deleting it left every
#     automatic check in this repository green.
#
#     THE WORK IS NOT DONE HERE. scripts/check-dist-gate.sh EXECUTES dist.sh in
#     a throwaway root with a directory of recording stubs first on PATH and
#     asks its claims of the log of xcodebuild invocations, not of the text of
#     the script. Its header carries the rationale and the ceiling; this check
#     is the wiring, and it forwards the three outcomes unchanged.
#
#     Three outcomes by hand, as in check 12: 2 means the gate did not run, and
#     a gate that did not run must never look like a gate that passed — "no
#     Release run in the log" is exactly what an early failure looks like too.
#
#     WHAT IT DOES NOT PROVE: nothing that the gate itself does not prove. In
#     particular the stubs are not xcodebuild, so a test that is invoked and
#     does not exist is invisible here; and it costs the audit some eight
#     seconds, which is the price of executing rather than reading.
dist_out=$(scripts/check-dist-gate.sh 2>&1)
dist_st=$?
case "$dist_st" in
    0) pass "dist-gate-runs-what-it-claims" ;;
    1) fail "dist-gate-runs-what-it-claims" "the release gate does not run what it claims:"
       printf '%s\n' "$dist_out" | sed 's/^/      /' ;;
    *) fail "dist-gate-runs-what-it-claims" "the check did not run (exit $dist_st):"
       printf '%s\n' "$dist_out" | sed 's/^/      /' ;;
esac

# 15. The narrow Release run still covers the whole Debug/Release difference.
#
#     THIS IS AN INVARIANT STANDING IN FOR A MEASUREMENT. dist.sh runs exactly
#     one test class in Release (`-only-testing:EditMDTests/PDMCoreTests`), and
#     that is enough only while the SHIPPED sources hold one single place where
#     the two configurations mean different things. Measured across the six
#     constructs that produce such a place: `#if DEBUG` 0 outside a doc
#     comment, `assert(` 0, `precondition(` 0, `preconditionFailure(` 0,
#     `fatalError(` 0, `assertionFailure(` 1 — the wrapper's report of a core
#     contract mismatch in PDMCore.swift, which compiles to nothing in Release.
#     A measurement decays; this check turns it into something that reddens the
#     day a second such place appears, because on that day the one-class
#     Release run stops covering the difference and somebody must widen it.
#
#     THE ONE PERMITTED PLACE IS NAMED, as in check 13, rather than left to be
#     inferred from a count. Zero places is a FAIL too: it means either that
#     the wrapper stopped reporting or that this check went blind, and both are
#     news.
#
#     COMMENTS ARE STRIPPED, FILES ARE NOT EXCLUDED. The only `#if DEBUG` in
#     the tree sits inside a doc comment in ClaudeIDEBridge.swift explaining
#     why the conditional is NOT there — a true sentence that a naive grep
#     reads as the thing it denies. Excluding that file would have been a hole
#     the size of a file, and a moving one: the prose could move, or real code
#     could arrive under it. So the sources are read with line and block
#     comments removed and the line numbers kept, and every file stays in scope.
#
#     WHAT IT DOES NOT PROVE: it is a list of six constructs, and a difference
#     spelled some other way — a `#if` on a different flag, behaviour that
#     depends on the optimizer alone, a `Bundle`-inspected build configuration
#     — is not one of them. The comment stripper knows nothing of string
#     literals: a `//` or `/*` inside a string truncates or swallows what
#     follows, which can only LOSE a hit, and a construct written inside a
#     multi-line string literal would be counted as if it were code. Neither
#     shape occurs today. And it says nothing about the tests: EditMDTests is
#     out of scope here exactly as it is in check 13, because it does not ship.
debug_only_place=EditMD/EditMD/Editor/PDMCore.swift
# construct<TAB>a line it is required to match. One list, two readers.
debug_only_tokens=(
    $'#if[[:space:]]+DEBUG\t#if DEBUG'
    $'(^|[^A-Za-z0-9_])assert\\(\tassert(index >= 0)'
    $'(^|[^A-Za-z0-9_])assertionFailure\\(\tassertionFailure("\\(error)")'
    $'(^|[^A-Za-z0-9_])precondition\\(\tprecondition(index >= 0)'
    $'(^|[^A-Za-z0-9_])preconditionFailure\\(\tpreconditionFailure("unreachable")'
    $'(^|[^A-Za-z0-9_])fatalError\\(\tfatalError("unreachable")'
)
r15=""
dbg_args=()
for dbg_pair in "${debug_only_tokens[@]}"; do
    dbg_pat=${dbg_pair%%$'\t'*}
    dbg_fixture=${dbg_pair#*$'\t'}
    dbg_args+=(-e "$dbg_pat")
    printf '%s\n' "$dbg_fixture" | grep -q -E -e "$dbg_pat" \
        || r15="$r15 construct-does-not-match-its-own-example:/$dbg_pat/"
done
dbg_files=()
while IFS= read -r dbg_f; do
    [ -n "$dbg_f" ] && dbg_files+=("$dbg_f")
done < <(git ls-files -c -o --exclude-standard -- \
            'EditMD/EditMD/*.swift' 'EditMD/editmdctl/*.swift' 'EditMD/editmd-mcp/*.swift' 2>/dev/null)
if [ ${#dbg_files[@]} -eq 0 ]; then
    r15="$r15 no-swift-sources-found-in-the-shipped-targets"
else
    # Comments out, line numbers kept: `file:line:code-without-comments`.
    dbg_hits=$(awk '
        FNR == 1 { inblock = 0 }
        {
            line = $0; out = ""; i = 1; n = length(line)
            while (i <= n) {
                two = substr(line, i, 2)
                if (inblock) {
                    if (two == "*/") { inblock = 0; i += 2 } else { i++ }
                    continue
                }
                if (two == "//") break
                if (two == "/*") { inblock = 1; i += 2; continue }
                out = out substr(line, i, 1); i++
            }
            print FILENAME ":" FNR ":" out
        }' "${dbg_files[@]}" | grep -E "${dbg_args[@]}")
    dbg_count=$(printf '%s\n' "$dbg_hits" | grep -c '.')
    if [ "$dbg_count" -eq 0 ]; then
        r15="$r15 no-configuration-difference-left:$debug_only_place-no-longer-carries-one"
    else
        while IFS= read -r dbg_h; do
            [ -z "$dbg_h" ] && continue
            dbg_hf=${dbg_h%%:*}
            [ "$dbg_hf" = "$debug_only_place" ] \
                || r15="$r15 $(printf '%s' "$dbg_h" | cut -d: -f1,2):outside-the-one-declared-place"
        done <<< "$dbg_hits"
        [ "$dbg_count" -le 1 ] \
            || r15="$r15 $dbg_count-places-differ-between-Debug-and-Release-but-the-Release-run-is-one-class"
    fi
fi
if [ -z "$r15" ]; then pass "one-debug-release-difference"
else fail "one-debug-release-difference" $r15; fi

# 16. The two records of the minimum macOS agree.
#
#     `Vendor/core.expected.json` says what the vendored core may demand;
#     `EditMD/project.yml` says what the app promises the person installing it.
#     Nothing tied them together, so raising the first alongside a new core let
#     the package pass for an app still shipping the old promise — the gate
#     would be measuring the library against a number no longer connected to
#     anybody.
#
#     IT LIVES HERE AND NOT IN THE GATE, and the reason is measured rather than
#     preferred. `verify-core.sh` runs as a pre-build phase under
#     ENABLE_USER_SCRIPT_SANDBOXING, which denies reading SRCROOT — the sandbox
#     said so in as many words: `Sandbox: awk(68283) deny(1) file-read-data
#     .../EditMD/project.yml`, and every build stopped there. The gate is about
#     the artifact; a disagreement between two tracked files of this repository
#     is a question for the repository's own auditor, which is this.
r16=""
spec=EditMD/project.yml
frozen=Vendor/core.expected.json
if [ ! -f "$spec" ]; then r16="missing:$spec"
elif [ ! -f "$frozen" ]; then r16="missing:$frozen (untracked pair member; restore from git)"
else
    # The app target only: the other three link no core, and one of them
    # promising something else is not this check's business.
    app_min=$(awk '
        /^  EditMD:$/            { inapp = 1; next }
        inapp && /^  [A-Za-z]/   { inapp = 0 }
        inapp && $1 == "MACOSX_DEPLOYMENT_TARGET:" { gsub(/"/, "", $2); print $2; exit }
    ' "$spec")
    core_min=$(sed -n 's/.*"min_macos"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$frozen" | head -1)
    if [ -z "$app_min" ]; then r16="cannot-read-MACOSX_DEPLOYMENT_TARGET-of-the-EditMD-target"
    elif [ -z "$core_min" ]; then r16="cannot-read-min_macos"
    elif [ "$app_min" != "$core_min" ]; then
        r16="core.expected.json:min_macos=$core_min project.yml:MACOSX_DEPLOYMENT_TARGET=$app_min"
    fi
fi
if [ -z "$r16" ]; then pass "min-macos-promises-agree"
else fail "min-macos-promises-agree" $r16; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "AUDIT: all mechanical checks passed."
else
    echo "AUDIT: $fails check(s) failed."
    exit 1
fi
