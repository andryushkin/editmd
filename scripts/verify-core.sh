#!/bin/bash
# Gate on the prebuilt core library before anything links against it.
#
# `Vendor/PrintDotMD.xcframework` is the one binary dependency of the app that
# is not fetched by SwiftPM: it is built elsewhere and copied in, so nothing
# but this script stands between "some directory named PrintDotMD" and the
# linker. It checks five things against `Vendor/core.expected.json`, the only
# tracked file of the pair, and refuses with a named cause:
#
#   1. sha256 of the static library      — the bytes that get linked
#   2. `codesign --verify --strict`      — every other file of the package;
#                                          the seal covers the headers, the
#                                          module map and `Info.plist`, which
#                                          the sha256 does not
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

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
XCF="$ROOT/Vendor/PrintDotMD.xcframework"
EXPECTED="$ROOT/Vendor/core.expected.json"
SLICE="$XCF/macos-arm64_x86_64"
LIB="$SLICE/libprintdotmd_ffi.a"
HEADER="$SLICE/Headers/printdotmd.h"

fail() {
    echo "error: $1" >&2
    shift
    for line in "$@"; do echo "       $line" >&2; done
    exit 1
}

# -- 0. Is the artifact here at all? ----------------------------------------
# Its own failure, deliberately: "no such file" from shasum or `ld: library
# not found` half an hour later tell the reader nothing about what to do.
if [ ! -d "$XCF" ]; then
    fail "the core library is missing: $XCF" \
         "This is a prebuilt binary dependency and is not in the repository" \
         "(277 MB, ignored by git). Build it with scripts/build-xcframework.sh" \
         "in the PrintDotMD sources and copy dist/PrintDotMD.xcframework to" \
         "the path above."
fi
[ -f "$LIB" ] || fail "the core library is damaged: $LIB is missing" \
    "Re-copy the whole PrintDotMD.xcframework directory; a partial copy" \
    "does not verify."
[ -f "$HEADER" ] || fail "the core library is damaged: $HEADER is missing" \
    "Re-copy the whole PrintDotMD.xcframework directory."
[ -f "$EXPECTED" ] || fail "the frozen values are missing: $EXPECTED" \
    "This file is tracked; restore it from git rather than writing a new one."

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

# -- 2. The seal over every other file of the package -----------------------
if ! codesign --verify --strict "$XCF" 2>/dev/null; then
    fail "the core library signature does not verify (codesign --strict)." \
         "Something in $XCF changed after signing — a header, the module map," \
         "Info.plist, or an added or removed file. The checksum above covers" \
         "only the static library; the signature covers the rest." \
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
ARCHS=$(lipo -archs "$LIB") || fail "cannot read the architectures of $LIB"
[ -n "$ARCHS" ] || fail "$LIB carries no architecture slices at all."
HIGHEST=""
for arch in $ARCHS; do
    found=$(otool -arch "$arch" -l "$LIB" | awk '
        /^ +cmd LC_BUILD_VERSION/       { c = "build";   next }
        /^ +cmd LC_VERSION_MIN_MACOSX/  { c = "version"; next }
        /^ +cmd /                       { c = "";        next }
        c == "build"   && $1 == "minos"   { print $2; c = "" }
        c == "version" && $1 == "version" { print $2; c = "" }
    ' | sort -t. -k1,1n -k2,2n | tail -1)
    [ -n "$found" ] || fail \
        "cannot read the deployment target of the $arch slice of $LIB" \
        "otool reported no LC_BUILD_VERSION and no LC_VERSION_MIN_MACOSX."
    HIGHEST=$(printf '%s\n%s\n' "$HIGHEST" "$found" | grep . \
        | sort -t. -k1,1n -k2,2n | tail -1)
done
if ! awk -v got="$HIGHEST" -v max="$WANT_MIN" 'BEGIN {
        split(got, g, "."); split(max, m, ".");
        exit ((g[1] + 0 < m[1] + 0) || (g[1] + 0 == m[1] + 0 && g[2] + 0 <= m[2] + 0)) ? 0 : 1
    }'; then
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

echo "verify-core: sha256 ok, signature ok, team $GOT_TEAM, macOS $HIGHEST, ABI $GOT_ABI"
