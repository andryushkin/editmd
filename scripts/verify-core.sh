#!/bin/bash
# Gate on the prebuilt core library before anything links against it.
#
# `Vendor/PrintDotMD.xcframework` is the one binary dependency of the app that
# is not fetched by SwiftPM: it is built elsewhere and copied in, so nothing
# but this script stands between "some directory named PrintDotMD" and the
# linker. It checks five things against `Vendor/core.expected.json`, the only
# tracked file of the pair, and refuses with a named cause:
#
#   0. `Info.plist` names the files      — which library and which header the
#                                          package offers; every check below
#                                          reads THOSE files
#   1. sha256 of the static library      — the bytes that get linked
#   2. `codesign --verify --strict`      — the seal over every file of the
#                                          package, the static library included
#   3. TeamIdentifier of the signature   — signed by us, not by a stranger
#   4. max deployment target of every
#      object in every slice             — no object may demand a macOS newer
#                                          than the app promises (14.0)
#   5. PDM_ABI_VERSION in the header     — the C contract the wrapper expects,
#                                          checked before Swift compiles
#
# It runs as a pre-build phase of the app target, so it must stay cheap:
# ~3 s total, no unpacking, no smoke run. Everything here reads the vendored
# directory in place.
#
# Two of the values move for honest reasons and are meant to be updated in
# `core.expected.json` when they do: `library_sha256` after a legitimate core
# rebuild (a toolchain bump alone changes it), and `abi_version` when the C
# contract itself changes. `team_identifier` and `min_macos` are not expected
# to move at all.
#
# WHAT EACH CHECK CAN AND CANNOT CATCH — measured, not assumed.
#
# The signature is the only check here whose oracle is not ours. The frozen
# checksum and the manifest it lives in were written by the same run of the
# core's build script that produced the artifact, so agreeing with it proves
# the file has not moved since — not where it came from. `codesign` asks
# Apple's certificate chain instead, and check 3 asks it for OUR team.
#
# Which means check 1 catches no class of substitution that check 2 does not:
# measured 28 Aug 2026 — `_CodeSignature/CodeResources` lists
# `macos-arm64_x86_64/libprintdotmd_ffi.a` with hash1 and hash2, and a planting
# that changed only the `.a` was refused by `codesign --strict`. The seal covers
# the static library too; an earlier version of this comment said it did not.
#
# What check 1 is for, then, is two things the seal does badly. It NAMES THE
# CAUSE — "these are not the frozen bytes", with both sums, against
# `codesign`'s "something in here changed" — and it is the only check that
# speaks on an HONEST UNDECLARED REBUILD: an artifact legitimately rebuilt and
# legitimately re-signed by us, copied in while `core.expected.json` was left
# behind. That is not an attack, it is forgetfulness, and it is the failure
# this gate actually meets.
#
# Checks 1-3 (checksum, signature, certificate) guard every single build.
# Checks 4 and 5 (deployment target, ABI version) can only ever speak on the
# day `library_sha256` is updated: the deployment target is a function of the
# very bytes check 1 pins, and the header is sealed by the signature check 2
# verifies. That is not a defect, it is the shape of the thing — but a planting
# that skips updating `library_sha256` tests check 1, not the check it aimed at.
#
# THE FROZEN CHECKSUM IS A CLEAN-BUILD VALUE. Measured 25 Aug 2026: the same
# sources rebuilt after `cargo clean` give the same library byte for byte
# (three times over), while an incremental rebuild after editing the sources
# and reverting them gave a different one. So "rebuilt on purpose" below means
# a clean build; a checksum taken from an incremental rebuild will drift again
# on the next clean one, and freezing it would break this gate on the second day.
#
# Usage: scripts/verify-core.sh [path-to-repo-root]
set -euo pipefail

fail() {
    echo "error: $1" >&2
    shift
    for line in "$@"; do echo "       $line" >&2; done
    exit 1
}

# Is macOS version $1 no newer than version $2?
#
# All three components, and that is the repair rather than a tidy-up: the
# previous comparison read the first two and stopped, so an object built
# against `14.0.1` counted as equal to a promise of `14.0` and walked through.
# A missing component is zero — `14` and `14.0.0` are the same version — which
# is why the loop reads past the end of the shorter list rather than refusing
# to compare lists of different lengths.
# The rule itself, written once and shared by both users below rather than
# spelled twice. Two spellings of "which version is newer" is what this repair
# removed from check 4 in the first place.
VERSION_CMP_AWK='
function newer(a, b,   n, m, i, p, q, x, y) {
    n = split(a, x, "."); m = split(b, y, ".")
    for (i = 1; i <= 3; i++) {
        p = (i <= n) ? x[i] + 0 : 0
        q = (i <= m) ? y[i] + 0 : 0
        if (p < q) return -1
        if (p > q) return 1
    }
    return 0
}'

version_le() {
    awk -v a="$1" -v b="$2" "$VERSION_CMP_AWK"'BEGIN { exit newer(a, b) > 0 }'
}

# The newest of the versions on stdin, one per line — in one process, not one
# per value. Measured: the archive carries 1 557 build records in the arm64
# slice and 1 479 in x86_64, so a shell loop calling `version_le` on each
# forked `awk` three thousand times and took the gate from 1.9 s to 7.4 s.
version_max() {
    awk "$VERSION_CMP_AWK"'
        { if (best == "" || newer($1, best) > 0) best = $1 }
        END { print best }'
}

# `verify-core.sh --selftest` — the comparison above, on a table, with no
# package anywhere near it. Spelled as the other gates in this repository spell
# it (`check-dist-gate.sh --selftest`, `docs/audit.md`), because a flag that
# differs by a hyphen from the four its reader already knows is a flag that
# gets typed wrong; and an argument this script does not recognise is refused
# rather than taken for a repository root, which used to answer a mistyped flag
# with "the core library is missing: --selftest/Vendor/PrintDotMD.xcframework".
#
# Every expectation is written out by hand. Computing them from `version_le`
# would be the same function agreeing with itself, and the four rows are chosen
# to be the ones a two-component comparison gets wrong: `14.0.1` against `14.0`
# is the case that was live, and `14.10` against `14.9` is the case a string
# comparison gets wrong in the other direction.
if [ "${1:-}" = --selftest ]; then
    bad=0
    while read -r a b want; do
        [ -n "$a" ] || continue
        if version_le "$a" "$b"; then got=le; else got=gt; fi
        if [ "$got" = "$want" ]; then
            printf '  ok    %-8s vs %-8s -> %s\n' "$a" "$b" "$got"
        else
            printf '  WRONG %-8s vs %-8s -> %s, expected %s\n' "$a" "$b" "$got" "$want"
            bad=$((bad + 1))
        fi
    done <<'TABLE'
14.0     14.0     le
14.0.1   14.0     gt
14.10    14.9     gt
13.9     14.0     le
TABLE
    # And the other user of the same rule. Check 4 does not compare two
    # versions, it picks the newest of some fifteen hundred — and while that
    # was a `sort -t. -kN,Nn` pipeline it had the very bug this table was
    # written for, invisibly: reverting the sort keys left the table green.
    # Expectations by hand again, and the last row is the one a two-component
    # rule gets wrong.
    while read -r want values; do
        [ -n "$want" ] || continue
        got=$(printf '%s\n' $values | version_max)
        if [ "$got" = "$want" ]; then
            printf '  ok    max(%-22s) -> %s\n' "$values" "$got"
        else
            printf '  WRONG max(%-22s) -> %s, expected %s\n' "$values" "$got" "$want"
            bad=$((bad + 1))
        fi
    done <<'MAXTABLE'
14.0     14.0
14.9     13.9 14.9 14.0
14.10    14.9 14.10 14.2
14.0.1   14.0 14.0.1 13.9
MAXTABLE
    [ "$bad" -eq 0 ] || fail "the version rule is wrong on $bad row(s)."
    echo "verify-core --selftest: version rule ok on 4 comparisons and 4 maxima"
    exit 0
fi

case "${1:-}" in
    -*) fail "unknown argument: $1" \
             "Usage: verify-core.sh [--selftest] [path-to-repo-root]" ;;
esac

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
XCF="$ROOT/Vendor/PrintDotMD.xcframework"
EXPECTED="$ROOT/Vendor/core.expected.json"
PLIST="$XCF/Info.plist"

# -- 0. Is the artifact here at all? ----------------------------------------
# Its own failure, deliberately: "no such file" from shasum or `ld: library
# not found` half an hour later tell the reader nothing about what to do.
if [ ! -d "$XCF" ]; then
    fail "the core library is missing: $XCF" \
         "This is a prebuilt binary dependency and is not in the repository" \
         "(277 MB, ignored by git). Build it with the core's own build script" \
         "and copy the resulting PrintDotMD.xcframework to the path above."
fi
[ -f "$EXPECTED" ] || fail "the frozen values are missing: $EXPECTED" \
    "This file is tracked; restore it from git rather than writing a new one."

# WHICH library and WHICH header — asked of Info.plist, because that is what
# Xcode asks. The package is handed to the build whole (project.yml:83) and the
# build reads `AvailableLibraries` to pick a slice; this script used to read a
# path spelled out here instead. The two agree by convention, and a convention
# is not a check: a package whose `LibraryPath` names one file while another
# sits at the conventional path would be verified in the second and linked from
# the first. Naming the same file twice, once here and once in the package, is
# the same two-copies-of-one-fact this gate exists to refuse.
#
# Two of the three names come from the package; the third, `printdotmd.h`, is
# still spelled here, because `Info.plist` names the headers *directory* and
# not the umbrella header inside it. That is the honest limit of the move
# rather than an oversight, and the producer's own check has the same limit.
[ -f "$PLIST" ] || fail "the core library is damaged: $PLIST is missing" \
    "An XCFramework without an Info.plist is not one; Xcode would refuse it" \
    "too. Re-copy the whole PrintDotMD.xcframework directory."

# Exactly one library in the package. More than one is a shape this gate has
# never been asked to reason about — which slice the app would get then depends
# on the destination — and saying so is better than checking the first and
# implying the rest were looked at. `plutil` prints the count of an array, so
# the refusal can name it, the way the producer's own check does.
LIB_COUNT=$(plutil -extract AvailableLibraries raw -o - "$PLIST" 2>/dev/null) \
    || fail "$PLIST declares no libraries at all." \
            "AvailableLibraries is missing. Re-copy the package."
[ "$LIB_COUNT" = 1 ] || fail "$PLIST declares $LIB_COUNT libraries, expected one." \
    "This gate verifies one, and which one the build picks would then" \
    "depend on the destination. Vendor a single-library package."

# Absent and empty are one answer here — a key that names nothing names no
# file — so the extractor refuses both and every caller gets to say what was
# missing in its own words.
plist_string() {
    local value
    value=$(plutil -extract "AvailableLibraries.0.$1" raw -o - "$PLIST" 2>/dev/null) \
        && [ -n "$value" ] || return 1
    printf '%s' "$value"
}
SLICE_ID=$(plist_string LibraryIdentifier) \
    || fail "$PLIST names no LibraryIdentifier."
LIB_NAME=$(plist_string LibraryPath) \
    || fail "$PLIST names no LibraryPath."
# No fallback to "Headers". A package that declares no headers is one Xcode
# builds without them, and substituting the conventional name here would accept
# a package whose header sits on disk where the compiler will never look.
HEADERS_NAME=$(plist_string HeadersPath) \
    || fail "$PLIST declares no HeadersPath." \
            "The package offers no headers, so nothing that imports" \
            "PrintDotMD would compile against it. Re-build the core with" \
            "headers and vendor that package."

LIB="$XCF/$SLICE_ID/$LIB_NAME"
HEADER="$XCF/$SLICE_ID/$HEADERS_NAME/printdotmd.h"

[ -f "$LIB" ] || fail "the core library is damaged: $LIB is missing" \
    "Info.plist names this file as the one the build links, and it is not" \
    "there. Re-copy the whole PrintDotMD.xcframework directory; a partial" \
    "copy does not verify."
[ -f "$HEADER" ] || fail "the core library is damaged: $HEADER is missing" \
    "Info.plist points HeadersPath at $HEADERS_NAME, and printdotmd.h is not" \
    "in it. Re-copy the whole PrintDotMD.xcframework directory."

# Values are all JSON strings, one per line in the file as written.
expect() {
    local value
    value=$(sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
        "$EXPECTED" | head -1)
    [ -n "$value" ] || fail "$EXPECTED has no \"$1\"" \
        "The four keys are library_sha256, team_identifier, abi_version," \
        "min_macos."
    printf '%s' "$value"
}

WANT_SHA=$(expect library_sha256)
WANT_TEAM=$(expect team_identifier)
WANT_ABI=$(expect abi_version)
WANT_MIN=$(expect min_macos)

# -- 1. The bytes that get linked -------------------------------------------
GOT_SHA=$(shasum -a 256 "$LIB" | awk '{print $1}')
[ "$GOT_SHA" = "$WANT_SHA" ] || fail \
    "core library checksum mismatch — these are not the frozen bytes." \
    "expected sha256 $WANT_SHA" \
    "found    sha256 $GOT_SHA" \
    "$LIB" \
    "If the core was rebuilt on purpose, update library_sha256 in" \
    "Vendor/core.expected.json in the same commit."

# -- 2. The seal over every file of the package -----------------------------
if ! codesign --verify --strict "$XCF" 2>/dev/null; then
    fail "the core library signature does not verify (codesign --strict)." \
         "Something in $XCF changed after signing — the static library, a" \
         "header, the module map, Info.plist, or an added or removed file." \
         "The seal covers all of them; the checksum above covers the library" \
         "alone, and names the cause when it is the library that moved." \
         "Diagnose with: codesign --verify --strict --verbose=4 \"$XCF\""
fi

# -- 3. Signed by us ---------------------------------------------------------
# `codesign --display` writes to stderr; without 2>&1 the grep sees nothing
# and the check passes on every artifact, honest or not.
#
# THE TEAM FIELD ALONE PROVES NOTHING, and that is not a theoretical worry: it
# was the finding that held this step open. `codesign --sign - --team-identifier
# DZQ4PU9975` stamps the field onto an ad-hoc signature that carries no
# certificate at all, and every check below used to pass on it. The requirement
# says "verify the signature", so the requirement is a certificate requirement:
# the anchor must be Apple's and the leaf must belong to our team.
codesign --verify \
    -R "=anchor apple generic and certificate leaf[subject.OU] = \"$WANT_TEAM\"" \
    "$XCF" 2>/dev/null || fail \
    "the core library is not signed by an Apple-issued certificate of team $WANT_TEAM." \
    "The team field on its own is not evidence: 'codesign --sign -" \
    "--team-identifier $WANT_TEAM' sets that field on an ad-hoc signature" \
    "that has no certificate behind it. This check asks for the certificate."
GOT_TEAM=$(codesign --display --verbose=2 "$XCF" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' | head -1)
# `codesign --display` prints the words "not set" rather than an empty value,
# so an emptiness test never fires and this diagnosis was unreachable.
[ "$GOT_TEAM" != "not set" ] || fail \
    "the core library signature carries no team identifier." \
    "An ad-hoc signature (codesign --sign -) looks like this. The artifact" \
    "must be signed with an Apple Development identity of team $WANT_TEAM."
[ "$GOT_TEAM" = "$WANT_TEAM" ] || fail \
    "the core library is signed by a different team." \
    "expected TeamIdentifier=$WANT_TEAM" \
    "found    TeamIdentifier=$GOT_TEAM" \
    "The bytes may well be intact — this says they came from someone else."

# -- 4. No object may outrun the app's deployment target --------------------
# Both architectures of the fat archive, every object in each: LC_BUILD_VERSION
# reports `minos`, the older LC_VERSION_MIN_MACOSX reports `version`, and a
# single stray object built against a newer SDK is enough to break the app on
# a machine the app claims to support.
# An empty architecture list used to walk straight through: the guard for "no
# deployment target found" lives inside the loop, so a body that never runs
# left HIGHEST empty, and the comparison below read that as 0 — pass. errexit
# does not help, a failed substitution in a `for` list does not raise it.
#
# `grep` ahead of `awk` because this is a pre-build phase and the archive is
# large: `otool -l` on this artifact prints 479 411 lines, of which fewer than
# a hundred matter. Measured on the vendored library — 0.93 s through `awk`
# alone, 0.069 s with the filter first, same output on both slices, which is
# 45 % of the whole gate's ~1.9 s. The `^ +cmd ` line is kept in the filter on
# purpose: it is what resets the state machine, and dropping it would let an
# unrelated `version` line inside a later load command be read as a target.
#
# The maximum is taken with `version_le` rather than `sort -t. -kN,Nn`, and
# that is not tidiness: `sort` was a second implementation of "which version is
# newer", it had the same two-component bug, and the self-test could not see
# it — reverting the sort keys left `--selftest` green. One rule, one function,
# one table that covers it.
ARCHS=$(lipo -archs "$LIB") || fail "cannot read the architectures of $LIB"
[ -n "$ARCHS" ] || fail "$LIB carries no architecture slices at all."
HIGHEST=""
for arch in $ARCHS; do
    found=$(otool -arch "$arch" -l "$LIB" \
        | grep -E '^ +(cmd |minos |version )' | awk '
            /^ +cmd LC_BUILD_VERSION/       { c = "build";   next }
            /^ +cmd LC_VERSION_MIN_MACOSX/  { c = "version"; next }
            /^ +cmd /                       { c = "";        next }
            c == "build"   && $1 == "minos"   { print $2; c = "" }
            c == "version" && $1 == "version" { print $2; c = "" }
        ' | version_max)
    [ -n "$found" ] || fail \
        "cannot read the deployment target of the $arch slice of $LIB" \
        "otool reported no LC_BUILD_VERSION and no LC_VERSION_MIN_MACOSX."
    if [ -z "$HIGHEST" ] || version_le "$HIGHEST" "$found"; then
        HIGHEST=$found
    fi
done
if ! version_le "$HIGHEST" "$WANT_MIN"; then
    fail "the core library requires macOS $HIGHEST, the app promises $WANT_MIN." \
         "At least one object in the archive was built against a newer" \
         "deployment target. Such an object links today with only a warning" \
         "(ld: ... built for newer 'macOS' version), and fails at the user's" \
         "machine the day it calls an API that is not there." \
         "Rebuild the core with MACOSX_DEPLOYMENT_TARGET=$WANT_MIN."
fi

# -- 5. The C contract, before Swift compiles -------------------------------
# The wrapper compares against a Swift literal of its own; this catches the
# mismatch at the gate instead of at test time.
GOT_ABI=$(sed -n 's/^#define PDM_ABI_VERSION \([0-9][0-9]*\)u\{0,1\}.*/\1/p' \
    "$HEADER" | head -1)
[ -n "$GOT_ABI" ] || fail \
    "cannot find #define PDM_ABI_VERSION in $HEADER" \
    "The vendored header is not the one this app was written against."
[ "$GOT_ABI" = "$WANT_ABI" ] || fail \
    "core ABI version is $GOT_ABI, expected $WANT_ABI." \
    "$HEADER declares a different contract than the app speaks. Update the" \
    "Swift wrapper (EditMD/Editor/PDMCore.swift) and abi_version in" \
    "Vendor/core.expected.json together, or vendor the matching build."

echo "verify-core: slice $SLICE_ID/$LIB_NAME, sha256 ok, signature ok, team $GOT_TEAM, macOS $HIGHEST, ABI $GOT_ABI"
