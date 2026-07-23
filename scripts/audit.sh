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
#    localization catalog, the endonym, skill trigger phrases,
#    Cyrillic-folding sources, test data, and the live root fixture.
cyr=$(grep_tracked -P '\p{Cyrillic}' -- \
    ':!EditMD/EditMD/Resources/Localizable.xcstrings' \
    ':!EditMD/EditMD/Views/AppLanguage.swift' \
    ':!EditMD/EditMD/Resources/agent-skill/SKILL.md' \
    ':!.agents/skills/' \
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
    while IFS= read -r target; do
        case "$target" in http*|\#*|mailto:*) continue ;; esac
        rel="${target%%#*}"
        [ -e "$(dirname "$f")/$rel" ] || [ -e "$rel" ] || badlinks="$badlinks $f->$target"
    done < <(grep -o '](\([^)]*\))' "$f" 2>/dev/null | sed 's/^](//; s/)$//')
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

# 4. xcodegen drift: project.yml must regenerate to the committed .xcodeproj.
#    The current project dir is snapshotted first and restored afterwards, so
#    the auditor never leaves the working tree modified.
proj=EditMD/EditMD.xcodeproj
if ! command -v xcodegen > /dev/null; then
    fail "xcodegen-no-drift" "xcodegen not installed"
elif [ ! -d "$proj" ]; then
    fail "xcodegen-no-drift" "$proj missing"
else
    saved=$(mktemp -d)
    if cp -R "$proj" "$saved/"; then
        if xcodegen generate --spec EditMD/project.yml --quiet > /dev/null 2>&1; then
            drift=$(git status --porcelain "$proj")
            if [ -z "$drift" ]; then pass "xcodegen-no-drift"; else fail "xcodegen-no-drift" $drift; fi
        else
            fail "xcodegen-no-drift" "xcodegen generate failed"
        fi
        rm -rf "$proj" && mv "$saved/EditMD.xcodeproj" "$proj"
    else
        fail "xcodegen-no-drift" "could not snapshot $proj"
    fi
    rm -rf "$saved"
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
junk=$(git ls-files | grep -E '\.DS_Store|xcuserdata/|\.log$|\.smotr')
if [ -z "$junk" ]; then pass "no-junk-tracked"; else fail "no-junk-tracked" $junk; fi

# 9. Whitespace errors: unstaged, staged, and (when an upstream exists) the
#    outgoing commit range — a pre-push audit must see already-committed
#    whitespace too.
ws=""
git diff --check > /dev/null 2>&1 || ws="worktree"
git diff --check --cached > /dev/null 2>&1 || ws="$ws staged"
if up=$(git rev-parse --verify --quiet '@{upstream}'); then
    git diff --check "$up" HEAD > /dev/null 2>&1 || ws="$ws outgoing"
fi
if [ -z "$ws" ]; then pass "git-diff-check"; else fail "git-diff-check" $ws; fi

echo
if [ "$fails" -eq 0 ]; then
    echo "AUDIT: all mechanical checks passed."
else
    echo "AUDIT: $fails check(s) failed."
    exit 1
fi
