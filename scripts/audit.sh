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
st=$?
if [ $st -eq 1 ]; then pass "cyrillic-outside-allowlist"
elif [ $st -eq 0 ]; then fail "cyrillic-outside-allowlist" $cyr
else fail "cyrillic-outside-allowlist" "git grep errored ($st)"; fi

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
st=$?
if [ $st -eq 1 ]; then pass "no-secret-patterns"
elif [ $st -eq 0 ]; then fail "no-secret-patterns" $secrets
else fail "no-secret-patterns" "git grep errored ($st)"; fi

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
#     these two names and passes this check untouched. What is proved here is
#     the narrower "no second producer on WebKit", not the whole of "one path
#     into a PDF"; the rest of that sentence is held by the probes that compare
#     what the export writes with what the pane prints.
raw=$(git -c core.quotepath=false grep -n --untracked -I -E \
        -e '(^|[^A-Za-z0-9_])createPDF([^A-Za-z0-9_]|$)' \
        -e '(^|[^A-Za-z0-9_])previewHTMLPage([^A-Za-z0-9_]|$)' -- '*.swift')
st=$?
if [ $st -eq 1 ]; then pass "one-pdf-producer"
elif [ $st -eq 0 ]; then fail "one-pdf-producer" $(printf '%s\n' "$raw" | cut -d: -f1,2)
else fail "one-pdf-producer" "git grep errored ($st)"; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "AUDIT: all mechanical checks passed."
else
    echo "AUDIT: $fails check(s) failed."
    exit 1
fi
