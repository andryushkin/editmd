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
#    The audit base resolves as: explicit $AUDIT_BASE → the branch upstream →
#    origin/<branch>. A pre-push audit without any determinable base is a
#    FAIL, not a silent skip.
base=""
if [ -n "${AUDIT_BASE:-}" ]; then
    if git rev-parse --verify --quiet "$AUDIT_BASE" > /dev/null; then base=$AUDIT_BASE
    else base="__invalid__"; fi
elif git rev-parse --verify --quiet '@{upstream}' > /dev/null; then
    base='@{upstream}'
else
    branch=$(git rev-parse --abbrev-ref HEAD)
    if git rev-parse --verify --quiet "origin/$branch" > /dev/null; then base="origin/$branch"; fi
fi
if [ "$base" = "__invalid__" ]; then
    fail "git-diff-check" "AUDIT_BASE='$AUDIT_BASE' does not resolve"
elif [ -z "$base" ]; then
    fail "git-diff-check" "no audit base: set an upstream or AUDIT_BASE"
else
    ws=""
    git diff --check > /dev/null 2>&1 || ws="worktree"
    git diff --check --cached > /dev/null 2>&1 || ws="$ws staged"
    git diff --check "$base" HEAD > /dev/null 2>&1 || ws="$ws outgoing($base)"
    if [ -z "$ws" ]; then pass "git-diff-check (base: $base)"; else fail "git-diff-check" $ws; fi
fi

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
#     THE CONTROL HALF is the Preview row, and it is not decoration. A check
#     that only ever asserts "no WebKit token here" is indistinguishable from a
#     check blind to the token altogether — it would stay green if the pattern
#     were misspelled. Preview must CARRY `WKWebView` in its row and in
#     `MarkdownPreviewView.swift`, so a blind pattern turns this check red.
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
#     semicolon-separated fragment of the bullet, which is exactly how that
#     bullet lists its four paths. A WebKit token in a fragment that does not
#     say `Print` is legal — the same bullet describes Preview, and Preview is
#     a web view. That is the ceiling: a description of Print spread across two
#     fragments could put the token in the half that omits the word.
webkit_tokens='WKWebView|WebKit|createPDF|WKPDFConfiguration'
arch=docs/architecture.md
r11=""
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
            # The control half: the same pattern must find something here.
            printf '%s\n' "$prev_row" | grep -q -E 'WKWebView' \
                || r11="$r11 $arch:Preview-row-does-not-name-WKWebView(control-half-blind)"
            pv=$(find_named MarkdownPreviewView.swift | head -1)
            if [ -z "$pv" ]; then
                r11="$r11 MarkdownPreviewView.swift:not-in-tree"
            else
                pvhits=$(grep -c 'WKWebView' "$pv")
                [ "$pvhits" -gt 0 ] || r11="$r11 $pv:0-occurrences-of-WKWebView(control-half-blind)"
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
        one=$(printf '%s' "$bullet" | tr '\n' ' ')
        while IFS= read -r frag; do
            printf '%s\n' "$frag" | grep -q -E '(^|[^A-Za-z0-9_])Print([^A-Za-z0-9_]|$)' || continue
            printf '%s\n' "$frag" | grep -q -E "$webkit_tokens" || continue
            n=$(line_in_range CLAUDE.md "$b_start" "$b_end" "$webkit_tokens")
            calls=0
            renderer=$(find_named PrintPDFRenderer.swift | head -1)
            [ -n "$renderer" ] && calls=$(grep -c 'PDMCore\.' "$renderer")
            r11="$r11 CLAUDE.md:${n:-$b_start}:describes-Print-via-WebKit-but-${renderer:-PrintPDFRenderer.swift}-has-0-of-those-tokens-and-calls-PDMCore.-${calls}-times"
        done <<< "$(printf '%s' "$one" | tr ',;' '\n\n')"
    fi
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
pub_out=$(scripts/check-publicity.sh 2>&1)
pub_st=$?
case "$pub_st" in
    0) pass "publicity-dictionary" ;;
    1) fail "publicity-dictionary" "forbidden material in the outgoing change:"
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
#     NON-EMPTINESS IS PART OF THE CHECK. A whitelist over a tree with no
#     printing at all is vacuously satisfied and green, which is the same
#     report it gives for a healthy tree. So PrintPDFRenderer.swift must itself
#     contain at least one producer token; if it does not, the check FAILs as
#     vacuous rather than passing on nothing.
#
#     WHAT IT DOES NOT PROVE: this too is a list of names, and a producer
#     spelled in a way no token here lists passes — a whitelist bounds WHERE,
#     not HOW. It also says nothing about what the bytes contain, nor about a
#     producer reached through a Process or a plug-in rather than a Swift call.
pdf_places='EditMD/EditMD/Editor/PrintPDFRenderer.swift EditMD/EditMD/Editor/PDMCore.swift'
pdf_hits=$(git -c core.quotepath=false grep -n --untracked -I -E \
        -e 'PDMCore\.render' \
        -e 'NSPrintOperation' \
        -e 'CGPDFContext' \
        -e 'beginPDFPage' \
        -e 'dataRepresentation\(\)' \
        -e '(^|[^A-Za-z0-9_])createPDF' \
        -e 'WKPDFConfiguration' \
        -e 'pdf[[:space:]]*\([[:space:]]*configuration' \
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
    if [ -z "$stray" ] && [ -z "$vac" ]; then pass "pdf-bytes-one-place"
    else fail "pdf-bytes-one-place" ${vac:+"$vac"} $stray; fi
fi

echo
if [ "$fails" -eq 0 ]; then
    echo "AUDIT: all mechanical checks passed."
else
    echo "AUDIT: $fails check(s) failed."
    exit 1
fi
