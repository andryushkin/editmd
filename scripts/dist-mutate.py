#!/usr/bin/env python3
"""Plantings for scripts/check-dist-gate.sh --selftest.

Two lists, and the second is the one that costs work: RED plantings are the
regressions the guard must name, GREEN edits are legal rewrites it must sit
through.  A guard measured only against RED cases is indistinguishable from
`exit 1`.

Every planting is applied to a copy; the working tree is never written.
A planting that does not apply is an error, not a skip: a pattern that stopped
matching after dist.sh was edited would otherwise quietly stop testing.
"""
import re
import sys

DEBUG_RUN = """xcodebuild -project "$PROJECT" -scheme EditMD -configuration Debug \\
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \\
    -only-testing:EditMDTests/PDMCoreTests test | tail -3
"""

RELEASE_RUN = """xcodebuild -project "$PROJECT" -scheme EditMD -configuration Release \\
    ENABLE_TESTABILITY=YES \\
    -destination 'platform=macOS' -derivedDataPath "$DERIVED" \\
    -only-testing:EditMDTests/PDMCoreTests test | tail -3
"""

BUILD_LOOP = """for scheme in EditMD editmdctl; do
    xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release \\
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \\
        build | tail -2
done
"""


def need(text, needle, what):
    if needle not in text:
        sys.exit(f"dist-mutate: {what}: anchor not found in dist.sh")
    return text


# -- RED: the guard must go red on each of these ----------------------------

def red_delete_release_run(t):
    """The whole point: the line is gone and nothing else notices."""
    need(t, RELEASE_RUN, "delete-release-run")
    return t.replace(RELEASE_RUN, "")


def red_release_becomes_debug(t):
    """A one-word edit: the second run repeats the first."""
    need(t, RELEASE_RUN, "release-becomes-debug")
    return t.replace(RELEASE_RUN, RELEASE_RUN.replace("-configuration Release",
                                                      "-configuration Debug"))


def red_release_unreachable(t):
    """Present in the text, never executed — what a grep cannot see."""
    need(t, RELEASE_RUN, "release-unreachable")
    return t.replace(RELEASE_RUN, "if false; then\n" + RELEASE_RUN + "fi\n")


def red_early_exit(t):
    """Everything after the Debug run is dead, and the script still exits 0."""
    need(t, DEBUG_RUN, "early-exit")
    return t.replace(DEBUG_RUN, DEBUG_RUN + "exit 0\n")


def red_scope_narrowed(t):
    """Still a Release test run — of something that is not the core."""
    need(t, RELEASE_RUN, "scope-narrowed")
    return t.replace(RELEASE_RUN,
                     RELEASE_RUN.replace("-only-testing:EditMDTests/PDMCoreTests",
                                         "-only-testing:EditMDTests/PrintModeTests"))


def red_testability_dropped(t):
    """`@testable import` stops compiling; the run would fail for real."""
    need(t, RELEASE_RUN, "testability-dropped")
    return t.replace(RELEASE_RUN, RELEASE_RUN.replace("    ENABLE_TESTABILITY=YES \\\n", ""))


def red_scope_names_a_ghost(t):
    """A second identifier that resolves to nothing. PDMCoreTests is still
    covered, so this fires the static resolution claim and nothing else — the
    isolation matters: a planting that trips two claims proves neither."""
    need(t, RELEASE_RUN, "scope-names-a-ghost")
    return t.replace(RELEASE_RUN,
                     RELEASE_RUN.replace("-only-testing:EditMDTests/PDMCoreTests test",
                                         "-only-testing:EditMDTests/PDMCoreTests "
                                         "-only-testing:EditMDTests/GhostTests test"))


def red_packaging_build_moved_up(t):
    """The ordering dependency dist.sh's own comment names: move the packaging
    build above the testable run and the DMG gets the testable binary."""
    need(t, BUILD_LOOP, "packaging-build-moved-up")
    need(t, RELEASE_RUN, "packaging-build-moved-up")
    return t.replace(BUILD_LOOP, "").replace(RELEASE_RUN, BUILD_LOOP + "\n" + RELEASE_RUN)


# -- GREEN: legal edits the guard must not flinch at ------------------------

def green_tail_depth(t):
    """Someone wants more output."""
    return t.replace("| tail -3", "| tail -5")


def green_flag_order(t):
    """The same invocation, arguments written in another order."""
    need(t, RELEASE_RUN, "flag-order")
    return t.replace(RELEASE_RUN, """xcodebuild -scheme EditMD -project "$PROJECT" \\
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \\
    -configuration Release ENABLE_TESTABILITY=YES \\
    -only-testing:EditMDTests/PDMCoreTests test | tail -3
""")


def green_derived_renamed(t):
    """A variable rename that touches both runs."""
    return t.replace('DERIVED="$DIST/DerivedData"', 'DERIVED="$DIST/dd"')


def green_folded_into_a_loop(t):
    """The refactor that kills every text-matching guard: two invocations
    become one, and the configuration is a variable."""
    need(t, DEBUG_RUN, "folded-into-a-loop")
    need(t, RELEASE_RUN, "folded-into-a-loop")
    loop = """for cfg in Debug Release; do
    extra=""
    [ "$cfg" = Release ] && extra="ENABLE_TESTABILITY=YES"
    xcodebuild -project "$PROJECT" -scheme EditMD -configuration "$cfg" \\
        $extra \\
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \\
        -only-testing:EditMDTests/PDMCoreTests test | tail -3
done
"""
    return t.replace(DEBUG_RUN, "").replace(RELEASE_RUN, loop)


def green_result_bundle(t):
    """Evidence added to the Release run."""
    need(t, RELEASE_RUN, "result-bundle")
    return t.replace(RELEASE_RUN,
                     RELEASE_RUN.replace("-only-testing:EditMDTests/PDMCoreTests test",
                                         '-resultBundlePath "$DIST/rel.xcresult" '
                                         '-only-testing:EditMDTests/PDMCoreTests test'))


def green_scope_widened(t):
    """The whole scheme in Release: more checking, not less."""
    need(t, RELEASE_RUN, "scope-widened")
    return t.replace(RELEASE_RUN,
                     RELEASE_RUN.replace("-only-testing:EditMDTests/PDMCoreTests test",
                                         "test"))


def green_comments_rewritten(t):
    """Every comment line in the file replaced. A guard that reads prose dies
    here; one that reads behaviour does not notice."""
    out = []
    for line in t.splitlines(True):
        if re.match(r"^\s*#", line) and not line.startswith("#!"):
            out.append("# rewritten\n")
        else:
            out.append(line)
    return "".join(out)


def green_third_configuration(t):
    """A third run added next to the two."""
    need(t, RELEASE_RUN, "third-configuration")
    extra = RELEASE_RUN.replace("-scheme EditMD", "-scheme EditMD -quiet")
    return t.replace(RELEASE_RUN, RELEASE_RUN + extra)


RED = {
    "delete-release-run": red_delete_release_run,
    "release-becomes-debug": red_release_becomes_debug,
    "release-unreachable": red_release_unreachable,
    "early-exit": red_early_exit,
    "scope-narrowed": red_scope_narrowed,
    "testability-dropped": red_testability_dropped,
    "packaging-build-moved-up": red_packaging_build_moved_up,
    "scope-names-a-ghost": red_scope_names_a_ghost,
}

GREEN = {
    "tail-depth": green_tail_depth,
    "flag-order": green_flag_order,
    "derived-renamed": green_derived_renamed,
    "folded-into-a-loop": green_folded_into_a_loop,
    "result-bundle": green_result_bundle,
    "scope-widened": green_scope_widened,
    "comments-rewritten": green_comments_rewritten,
    "third-configuration": green_third_configuration,
}


def main(argv):
    if len(argv) == 2 and argv[1] == "--list-red":
        print("\n".join(RED))
        return 0
    if len(argv) == 2 and argv[1] == "--list-green":
        print("\n".join(GREEN))
        return 0
    if len(argv) != 4:
        sys.exit("usage: dist-mutate.py <dist.sh> <planting> <out> | --list-red | --list-green")
    src, name, out = argv[1:]
    fn = RED.get(name) or GREEN.get(name)
    if fn is None:
        sys.exit(f"dist-mutate: no such planting: {name}")
    text = open(src).read()
    new = fn(text)
    if new == text:
        sys.exit(f"dist-mutate: planting {name} changed nothing")
    open(out, "w").write(new)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
