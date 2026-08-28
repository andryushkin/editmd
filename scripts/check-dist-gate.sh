#!/usr/bin/env bash
# Does the release gate actually run the tests it claims to run?
#
# `scripts/dist.sh` runs PDMCoreTests twice, in Debug and in Release, and the
# two answer different questions (its own header says why). Today the Release
# run is held up by nothing: delete the line and every automatic check in this
# repository stays green. This guard is the missing red.
#
# WHAT IT OBSERVES, and why not the text of the script: dist.sh is EXECUTED,
# with a directory of recording stubs first on PATH, in a throwaway root. Every
# `xcodebuild` invocation the run issues is appended to a log, and the claims
# below are made about that log. A grep over the source would go green on a
# line that is present but unreachable (`if false`, an early `exit`, a branch
# taken only with a Developer ID in the keychain) and red on a legal refactor
# that folds the two runs into one loop. The log is blind to both mistakes: it
# records what was called, in what order, with which arguments.
#
# THREE OUTCOMES, the third being the point:
#   0  the claims hold
#   1  a claim failed (which one is printed)
#   2  the run did not happen — dist.sh exited non-zero under the stubs, or a
#      stub could not be built. A gate that could not run must never look like
#      a gate that passed, and "no Release run in the log" is exactly what an
#      early failure also looks like.
#
# BOTH SIGNING MODES are exercised (`--adhoc` and the default, with a stubbed
# Developer ID), because the two runs sit before the branch that separates
# them and a future edit could move them inside it.
#
# WHERE IT IS CALLED FROM: check 14 of scripts/audit.sh, which forwards the
# three outcomes unchanged. It costs the audit about eight seconds, all of it
# spent executing dist.sh twice under the stubs; that is the price of asking a
# log instead of a text, and it is written here so nobody has to measure it to
# find out why the audit got slower.
#
# WHAT IT DOES NOT PROVE:
#   * That xcodebuild runs any test. The stub is not xcodebuild: a
#     `-only-testing` identifier that matches nothing, a destination that
#     cannot be resolved are invisible here and cost a real build to see.
#     Two halves of that are answered statically instead, against project.yml
#     and the test sources — the target is one the scheme's TEST action runs,
#     and the class exists. The second is a grep for `class <Name>:` and knows
#     nothing else: a suite declared as a struct, or a class whose colon sits
#     on the next line, would read as missing.
#   * That Debug and Release differ in what they check. This guard asserts the
#     two runs EXIST and are ordered; that either one can catch something the
#     other cannot is a claim about the code under test, not about the gate.
#     Check 15 of audit.sh holds the other end of it — that the one test class
#     the Release run names still covers the whole difference.
#   * Anything about the DMG. The stubs sign and package nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

# The scheme whose invocations are read out of the log AND whose test action is
# looked up in project.yml. One name, two readers: a second spelling would be a
# copy of the truth, and it would drift the day the scheme is renamed.
SCHEME=EditMD

TARGET="$ROOT/scripts/dist.sh"
SELFTEST=0
while [ $# -gt 0 ]; do
    case "$1" in
        --script) TARGET=$2; shift 2 ;;
        --selftest) SELFTEST=1; shift ;;
        # The header, however long it grows: everything up to the first line
        # that is not a comment. A fixed line range goes stale in silence.
        -h|--help) sed -n '2,$ { /^[^#]/q; p; }' "$0"; exit 0 ;;
        *) echo "check-dist-gate: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
[ -f "$TARGET" ] || { echo "check-dist-gate: no such script: $TARGET" >&2; exit 2; }

# -- The stub root ----------------------------------------------------------
# Nothing outside this directory is written. The real EditMD/ is not even
# linked: the only thing dist.sh reads out of it is MARKETING_VERSION.
build_root() { # build_root <script> -> prints the root
    local script=$1 root
    root=$(mktemp -d) || return 1
    mkdir -p "$root/scripts" "$root/EditMD" "$root/bin" || return 1
    cp "$script" "$root/scripts/dist.sh" || return 1
    chmod +x "$root/scripts/dist.sh"
    # The core verifier is a different script with a different gate; stubbing
    # it keeps this one about dist.sh.
    printf '#!/bin/bash\necho "verify-core: stub"\n' > "$root/scripts/verify-core.sh"
    chmod +x "$root/scripts/verify-core.sh"
    grep -m1 'MARKETING_VERSION' "$ROOT/EditMD/project.yml" > "$root/EditMD/project.yml" || return 1

    cat > "$root/bin/xcodebuild" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$XCB_LOG"
derived=""; prev=""
for a in "$@"; do
    [ "$prev" = "-derivedDataPath" ] && derived=$a
    prev=$a
done
case " $* " in *" build "*)
    if [ -n "$derived" ]; then
        mkdir -p "$derived/Build/Products/Release/EditMD.app/Contents/MacOS"
        : > "$derived/Build/Products/Release/editmdctl"
    fi ;;
esac
echo "stub xcodebuild ok"
STUB
    printf '#!/bin/bash\nexit 0\n' > "$root/bin/xcodegen"
    printf '#!/bin/bash\necho '"'"'  1) DEAD "Developer ID Application: Stub (TEAM00)"'"'"'\n' \
        > "$root/bin/security"
    printf '#!/bin/bash\nexit 0\n' > "$root/bin/codesign"
    printf '#!/bin/bash\nexit 0\n' > "$root/bin/ditto"
    cat > "$root/bin/hdiutil" <<'STUB'
#!/bin/bash
for a in "$@"; do last=$a; done
: > "$last"
STUB
    cat > "$root/bin/xcrun" <<'STUB'
#!/bin/bash
case "${1:-}" in
    notarytool) echo "  status: Accepted" ;;
    stapler)    echo "stapled" ;;
esac
exit 0
STUB
    printf '#!/bin/bash\necho "0000000000000000000000000000000000000000000000000000000000000000  $*"\n' \
        > "$root/bin/shasum"
    chmod +x "$root"/bin/*
    printf '%s' "$root"
}

# -- One run ----------------------------------------------------------------
# Prints the xcodebuild log on stdout; exit 2 if dist.sh itself failed.
run_once() { # run_once <script> <mode: adhoc|release>
    local script=$1 mode=$2 root log out st
    root=$(build_root "$script") || return 2
    log="$root/xcodebuild.log"; : > "$log"
    if [ "$mode" = adhoc ]; then
        out=$(cd "$root" && XCB_LOG="$log" PATH="$root/bin:$PATH" \
              "$root/scripts/dist.sh" --adhoc 2>&1); st=$?
    else
        out=$(cd "$root" && XCB_LOG="$log" PATH="$root/bin:$PATH" \
              "$root/scripts/dist.sh" 2>&1); st=$?
    fi
    if [ $st -ne 0 ]; then
        printf 'dist.sh exited %s under the stubs (%s mode):\n' "$st" "$mode" >&2
        printf '%s\n' "$out" | tail -20 | sed 's/^/      /' >&2
        rm -rf "$root"; return 2
    fi
    cat "$log"
    rm -rf "$root"
    return 0
}

# The targets the scheme's TEST action runs, out of the spec that generates the
# project. Written as a state machine over the indentation rather than as an awk
# range, because `EditMD:` occurs twice in this file — once as a target and once
# as a scheme — and a range anchored on the name lands on the first of them.
# That is what this used to do: it answered "is EditMDTests mentioned somewhere
# in the EditMD *target*", which is a different question that happened to have
# the same answer.
scheme_test_targets() { # scheme_test_targets <scheme>
    awk -v want="  $1:" '
        /^schemes:/            { insch = 1; next }
        insch && /^[A-Za-z]/   { insch = 0 }
        !insch                 { next }
        $0 == want             { inthis = 1; intest = 0; intargets = 0; next }
        inthis && /^  [A-Za-z]/ { inthis = 0 }
        !inthis                { next }
        /^    test:[[:space:]]*$/ { intest = 1; intargets = 0; next }
        intest && /^    [A-Za-z]/ { intest = 0 }
        !intest                { next }
        /^      targets:[[:space:]]*$/ { intargets = 1; next }
        intargets && /^      [A-Za-z]/ { intargets = 0 }
        intargets && /^        -[[:space:]]/ {
            t = $0; sub(/^[[:space:]]*-[[:space:]]*/, "", t); print t }
    ' "$ROOT/EditMD/project.yml"
}

# -- The claims -------------------------------------------------------------
# Each is asked of the log of one run. `bad` accumulates; empty means green.
claims() { # claims <log-text> <mode>
    local log=$1 mode=$2 bad="" tests builds
    tests=$(printf '%s\n' "$log" | grep -n -- "-scheme $SCHEME " | grep -E '(^| )test( |$)')
    [ -n "$tests" ] || { printf ' %s:no-test-invocation-at-all' "$mode"; return; }

    local dbg rel
    dbg=$(printf '%s\n' "$tests" | grep -- '-configuration Debug'   | head -1)
    rel=$(printf '%s\n' "$tests" | grep -- '-configuration Release' | head -1)
    [ -n "$dbg" ] || bad="$bad $mode:no-Debug-test-run"
    [ -n "$rel" ] || bad="$bad $mode:no-Release-test-run"

    # The scope may widen (no -only-testing at all) but must not narrow away
    # from PDMCoreTests: this gate is about the core, and a future decision to
    # run the whole scheme in Release must not turn it red.
    local inv
    for inv in "$dbg" "$rel"; do
        [ -n "$inv" ] || continue
        case "$inv" in
            *-only-testing*)
                case "$inv" in
                    *-only-testing:EditMDTests/PDMCoreTests*) ;;
                    *) bad="$bad $mode:test-run-does-not-cover-PDMCoreTests" ;;
                esac ;;
        esac
    done
    # `@testable import` does not compile without it; the Release run is the
    # one that needs the override, since Release does not set it.
    if [ -n "$rel" ]; then
        case "$rel" in *ENABLE_TESTABILITY=YES*) ;;
            *) bad="$bad $mode:Release-test-run-without-ENABLE_TESTABILITY" ;;
        esac
    fi
    # An identifier is not a test. `-only-testing:` names a target and a class,
    # and nothing in this repository ties that string to the tree: rename the
    # class in Swift and dist.sh keeps naming the old one. The stub cannot see
    # that (it is not xcodebuild), so this one claim is answered statically,
    # against project.yml and the test sources.
    local ident target cls sch_targets
    sch_targets=$(scheme_test_targets "$SCHEME")
    if [ -z "$sch_targets" ]; then
        bad="$bad $mode:scheme-$SCHEME-has-no-test-targets-in-project.yml"
    fi
    for ident in $(printf '%s\n' "$tests" | tr ' ' '\n' | grep -o -- '-only-testing:[^ ]*'); do
        ident=${ident#-only-testing:}
        target=${ident%%/*}; cls=${ident#*/}
        printf '%s\n' "$sch_targets" | grep -q -x -- "$target" \
            || bad="$bad $mode:only-testing-names-a-target-not-in-the-scheme:$target"
        [ "$cls" = "$ident" ] && continue
        grep -rq "class ${cls}[[:space:]]*:" "$ROOT/EditMD/$target" \
            || bad="$bad $mode:only-testing-names-a-class-not-in-the-tree:$cls"
    done

    # The ordering dist.sh's own comment depends on: the packaging build runs
    # after the testable run and without the override, and it is that build
    # whose product is copied into the DMG.
    builds=$(printf '%s\n' "$log" | grep -n -E '(^| )build( |$)')
    if [ -z "$builds" ]; then
        bad="$bad $mode:no-packaging-build"
    else
        local last_test first_build
        last_test=$(printf '%s\n' "$tests"  | cut -d: -f1 | sort -n | tail -1)
        first_build=$(printf '%s\n' "$builds" | cut -d: -f1 | sort -n | head -1)
        [ "$first_build" -gt "$last_test" ] \
            || bad="$bad $mode:packaging-build-precedes-a-test-run"
        printf '%s\n' "$builds" | grep -q 'ENABLE_TESTABILITY' \
            && bad="$bad $mode:packaging-build-carries-ENABLE_TESTABILITY"
    fi
    printf '%s' "$bad"
}

verdict() { # verdict <script> -> 0 green, 1 red (prints reasons), 2 did not run
    local script=$1 bad="" log mode
    for mode in adhoc release; do
        log=$(run_once "$script" "$mode") || return 2
        bad="$bad$(claims "$log" "$mode")"
    done
    if [ -z "$bad" ]; then return 0; fi
    printf '%s\n' $bad
    return 1
}

# -- Self-test --------------------------------------------------------------
# A guard nobody has seen fail is a guard nobody has seen. Each planting below
# is a change to a COPY of dist.sh; the working tree is never touched.
if [ "$SELFTEST" = 1 ]; then
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mutate() { python3 "$ROOT/scripts/dist-mutate.py" "$TARGET" "$1" "$tmp/$1.sh"; }
    fails=0
    for m in $(python3 "$ROOT/scripts/dist-mutate.py" --list-red); do
        mutate "$m" || { echo "SELFTEST  $m: could not plant"; fails=$((fails+1)); continue; }
        out=$(verdict "$tmp/$m.sh" 2>&1); st=$?
        if [ $st -eq 1 ]; then echo "red-as-planted   $m"
        else echo "MISSED           $m (exit $st) $out"; fails=$((fails+1)); fi
    done
    for m in $(python3 "$ROOT/scripts/dist-mutate.py" --list-green); do
        mutate "$m" || { echo "SELFTEST  $m: could not plant"; fails=$((fails+1)); continue; }
        out=$(verdict "$tmp/$m.sh" 2>&1); st=$?
        if [ $st -eq 0 ]; then echo "green-as-edited  $m"
        else echo "FALSE ALARM      $m (exit $st) $out"; fails=$((fails+1)); fi
    done
    echo
    [ "$fails" -eq 0 ] && { echo "SELFTEST: every planting was named, every legal edit stayed green."; exit 0; }
    echo "SELFTEST: $fails case(s) went the wrong way."; exit 1
fi

verdict "$TARGET"
st=$?
case $st in
    0) echo "dist-gate: Debug and Release test runs both issued, packaging build last." ;;
    1) echo "dist-gate: the release gate does not run what it claims to run." ;;
    2) echo "dist-gate: THE CHECK DID NOT RUN (dist.sh failed under the stubs)." ;;
esac
exit $st
