#!/bin/bash
# Distribution build: Release EditMD.app with editmdctl embedded, signed,
# notarized, and packaged as a DMG.
#
# Default mode is fail-closed: it errors out unless a Developer ID
# Application identity is present AND notarization succeeds — the resulting
# DMG is safe to attach to a GitHub Release. `--adhoc` builds a local,
# ad-hoc-signed DMG for testing the packaging itself; its filename says so
# and it must never be distributed.
#
# Usage: scripts/dist.sh [--adhoc]
#   EDITMD_NOTARY_PROFILE  notarytool keychain profile (default: editmd-notary)
#
# One-time notarization setup (app-specific password from account.apple.com):
#   xcrun notarytool store-credentials editmd-notary \
#     --apple-id <apple-id> --team-id <team> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

# The core library is checked before anything else happens. The app target
# runs the same script as a pre-build phase, but a release must not depend on
# that: the check belongs on the path that produces the thing users install,
# and it costs three seconds.
scripts/verify-core.sh

ADHOC=0
[ "${1:-}" = "--adhoc" ] && ADHOC=1

PROJECT=EditMD/EditMD.xcodeproj
SPEC=EditMD/project.yml
DIST=dist
DERIVED="$DIST/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$DIST/EditMD.app"
PROFILE="${EDITMD_NOTARY_PROFILE:-editmd-notary}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$SPEC" | head -1)
[ -n "$VERSION" ] || { echo "error: MARKETING_VERSION not found in $SPEC"; exit 1; }
if [ "$ADHOC" = 1 ]; then
    DMG="$DIST/EditMD-v$VERSION-adhoc.dmg"
else
    DMG="$DIST/EditMD-v$VERSION.dmg"
fi

IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')
if [ "$ADHOC" = 0 ] && [ -z "$IDENTITY" ]; then
    echo "error: no Developer ID Application identity in the keychain."
    echo "       A distributable build requires one. For a local packaging"
    echo "       test use: scripts/dist.sh --adhoc"
    exit 1
fi

echo "== EditMD dist v$VERSION"
if [ "$ADHOC" = 1 ]; then
    echo "   signing: AD-HOC — local test build, NOT distributable"
else
    echo "   signing: $IDENTITY"
fi

# -- Build ------------------------------------------------------------------
xcodegen generate --spec "$SPEC" --quiet

# The other half of the core's ABI check, and the half no gate can do: the
# pre-build script reads the vendored *header*, `PDMCoreTests` asks the linked
# *library* through the wrapper. A header copied next to a mismatched archive
# passes the first and fails the second, and in Release the wrapper's
# `assertionFailure` compiles to nothing — so without this line such a core
# ships silently. Before the Release build rather than after it: the failure
# costs seconds here and ten minutes there.
#
# Debug, and a DerivedData of its own, on purpose. `@testable import` needs
# ENABLE_TESTABILITY, which Release does not set; setting it would put
# testability into the very binary this script packages. What is being checked
# is the bytes in Vendor/, and those do not know which configuration links
# them.
xcodebuild -project "$PROJECT" -scheme EditMD -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$DIST/DerivedDataABI" \
    -only-testing:EditMDTests/PDMCoreTests test | tail -3

for scheme in EditMD editmdctl; do
    xcodebuild -project "$PROJECT" -scheme "$scheme" -configuration Release \
        -destination 'platform=macOS' -derivedDataPath "$DERIVED" \
        build | tail -2
done

# -- Assemble ---------------------------------------------------------------
rm -rf "$APP" "$DIST/dmg-stage" "$DIST/EditMD.zip" "$DMG"
mkdir -p "$DIST"
cp -R "$PRODUCTS/EditMD.app" "$APP"
# The app looks for editmdctl next to its own executable (EditMDCtlInstaller).
cp "$PRODUCTS/editmdctl" "$APP/Contents/MacOS/editmdctl"

# -- Sign (inside out) ------------------------------------------------------
sign() {
    if [ "$ADHOC" = 1 ]; then
        codesign --force --sign - "$1"
    else
        codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"
    fi
}
if [ -d "$APP/Contents/Frameworks" ]; then
    find "$APP/Contents/Frameworks" -depth 1 | while read -r item; do
        sign "$item"
    done
fi
sign "$APP/Contents/MacOS/editmdctl"
sign "$APP"
codesign --verify --strict --deep "$APP"
echo "   codesign verify: OK"

# -- Notarize (release mode; any failure aborts) ----------------------------
notarize() {
    # notarytool exits 0 even for an Invalid verdict — check the status line.
    local out
    if ! out=$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" \
            --wait 2>&1); then
        echo "$out"
        echo "error: notarization submit failed — missing/expired profile"
        echo "       '$PROFILE', network, or notary-service error. One-time"
        echo "       setup is in the header of this script."
        exit 1
    fi
    echo "$out"
    if ! echo "$out" | grep -q "status: Accepted"; then
        echo "error: notarization was not accepted; see the log above and"
        echo "       'xcrun notarytool log <submission-id>'."
        exit 1
    fi
}
if [ "$ADHOC" = 0 ]; then
    ditto -c -k --keepParent "$APP" "$DIST/EditMD.zip"
    notarize "$DIST/EditMD.zip"
    xcrun stapler staple "$APP"
fi

# -- DMG --------------------------------------------------------------------
mkdir -p "$DIST/dmg-stage"
cp -R "$APP" "$DIST/dmg-stage/EditMD.app"
ln -s /Applications "$DIST/dmg-stage/Applications"
hdiutil create -volname "EditMD" -srcfolder "$DIST/dmg-stage" -ov -quiet \
    -format UDZO "$DMG"
rm -rf "$DIST/dmg-stage"
if [ "$ADHOC" = 0 ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    echo "== Done: $DMG (signed + notarized, distributable)"
else
    echo "== Done: $DMG — AD-HOC test build, do NOT distribute"
fi
shasum -a 256 "$DMG"
