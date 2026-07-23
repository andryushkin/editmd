#!/usr/bin/env bash
# Mechanical half of the repo auditor (docs/audit.md). Static checks only —
# fast enough to run before every push. Build/tests are the other half and
# run through xcodebuild (see docs/testing.md).
set -uo pipefail
cd "$(dirname "$0")/.."

fails=0
check() { # check <name> <0|1 ok> <detail-on-fail…>
    local name=$1 ok=$2; shift 2
    if [ "$ok" -eq 0 ]; then
        printf 'PASS  %s\n' "$name"
    else
        printf 'FAIL  %s\n' "$name"
        [ $# -gt 0 ] && printf '      %s\n' "$@"
        fails=$((fails + 1))
    fi
}

# 1. Cyrillic outside the allowlist (language policy, CLAUDE.md).
#    Allowed: localization catalog, the endonym, skill trigger phrases,
#    Cyrillic-folding sources, test data, and the live root fixture.
cyr=$(git -c core.quotepath=false grep -I -lP '[а-яА-ЯёЁ]' -- \
    ':!EditMD/EditMD/Resources/Localizable.xcstrings' \
    ':!EditMD/EditMD/Views/AppLanguage.swift' \
    ':!EditMD/EditMD/Resources/agent-skill/SKILL.md' \
    ':!EditMD/EditMD/Editor/SearchMatch.swift' \
    ':!EditMD/EditMD/Editor/SearchQuery.swift' \
    ':!EditMD/EditMDTests/' \
    ':!test-all-elements.md' \
    ':!test-all-elements.md.review.json' \
    2>/dev/null)
check "cyrillic-outside-allowlist" "$([ -z "$cyr" ]; echo $?)" $cyr

# 2. Relative markdown links inside docs/ resolve.
badlinks=""
for f in docs/*.md README.md; do
    while IFS= read -r target; do
        case "$target" in http*|\#*|mailto:*) continue ;; esac
        rel="${target%%#*}"
        [ -e "$(dirname "$f")/$rel" ] || [ -e "$rel" ] || badlinks="$badlinks $f->$target"
    done < <(grep -o '](\([^)]*\))' "$f" 2>/dev/null | sed 's/^](//; s/)$//')
done
check "doc-links-resolve" "$([ -z "$badlinks" ]; echo $?)" $badlinks

# 3. docs/ paths referenced from app sources and root guides exist.
badrefs=""
while IFS= read -r p; do
    [ -e "$p" ] || badrefs="$badrefs $p"
done < <(grep -rho 'docs/[A-Za-z0-9._/-]*\.md' \
        EditMD/EditMD CLAUDE.md AGENTS.md README.md EditMD/project.yml \
        2>/dev/null | sort -u)
check "code-doc-refs-exist" "$([ -z "$badrefs" ]; echo $?)" $badrefs

# 4. xcodegen drift: project.yml must regenerate to the committed .xcodeproj.
if command -v xcodegen > /dev/null; then
    xcodegen generate --spec EditMD/project.yml --quiet > /dev/null 2>&1
    drift=$(git status --porcelain EditMD/EditMD.xcodeproj)
    check "xcodegen-no-drift" "$([ -z "$drift" ]; echo $?)" $drift
else
    check "xcodegen-no-drift" 1 "xcodegen not installed"
fi

# 5. Secret patterns in tracked files.
secrets=$(git grep -I -l -E \
    'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-(ant|proj|live)-[A-Za-z0-9_-]{10,}|AKIA[0-9A-Z]{16}|xox[bp]-[0-9A-Za-z-]{10,}|BEGIN [A-Z ]*PRIVATE KEY' \
    2>/dev/null)
check "no-secret-patterns" "$([ -z "$secrets" ]; echo $?)" $secrets

# 6. Third-party notices cover every SwiftPM pin; vendored licenses present.
missing=""
for dep in $(grep -o '"identity" : "[a-z-]*"' \
        EditMD/EditMD.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved \
        | sed 's/.*: "//; s/"//'); do
    grep -qi "$dep" THIRD_PARTY_NOTICES.md || missing="$missing $dep"
done
[ -f EditMD/EditMD/Resources/katex/katex-LICENSE.txt ] || missing="$missing katex-LICENSE"
[ -f EditMD/EditMD/Resources/opensans/opensans-LICENSE.txt ] || missing="$missing opensans-LICENSE"
check "third-party-notices" "$([ -z "$missing" ]; echo $?)" $missing

# 7. Guide budgets: the compressed guides must stay compressed.
cl=$(wc -l < CLAUDE.md); ag=$(wc -l < AGENTS.md)
check "guide-budget (CLAUDE<=130 AGENTS<=45)" \
    "$([ "$cl" -le 130 ] && [ "$ag" -le 45 ]; echo $?)" "CLAUDE.md=$cl AGENTS.md=$ag"

# 8. Junk files never tracked.
junk=$(git ls-files | grep -E '\.DS_Store|xcuserdata/|\.log$|\.smotr' || true)
check "no-junk-tracked" "$([ -z "$junk" ]; echo $?)" $junk

# 9. Whitespace errors in the pending diff.
git diff --check > /dev/null 2>&1
check "git-diff-check" $?

echo
if [ "$fails" -eq 0 ]; then
    echo "AUDIT: all mechanical checks passed."
else
    echo "AUDIT: $fails check(s) failed."
    exit 1
fi
