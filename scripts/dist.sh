#!/bin/bash
# Distribution build: Release EditMD.app with editmdctl embedded, signed with
# Developer ID when one is present (ad-hoc otherwise), notarized when the
# notarytool keychain profile exists, packaged as a DMG.
#
# Usage: scripts/dist.sh
#   EDITMD_NOTARY_PROFILE  notarytool keychain profile (default: editmd-notary)
#
# One-time notarization setup (app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials editmd-notary \
#     --apple-id <apple-id> --team-id <team> --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=EditMD/EditMD.xcodeproj
SPEC=EditMD/project.yml
DIST=dist
DERIVED="$DIST/DerivedData"
PRODUCTS="$DERIVED/Build/Products/Release"
APP="$DIST/EditMD.app"
PROFILE="${EDITMD_NOTARY_PROFILE:-editmd-notary}"

VERSION=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$SPEC" | head -1)
[ -n "$VERSION" ] || { echo "error: MARKETING_VERSION not found in $SPEC"; exit 1; }
DMG="$DIST/EditMD-v$VERSION.dmg"

IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')

echo "== EditMD dist v$VERSION"
if [ -n "$IDENTITY" ]; then
    echo "   signing: $IDENTITY"
else
    echo "   signing: ad-hoc (no Developer ID Application identity found)"
fi

# -- Build ------------------------------------------------------------------
xcodegen generate --spec "$SPEC" --quiet
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
    if [ -n "$IDENTITY" ]; then
        codesign --force --timestamp --options runtime --sign "$IDENTITY" "$1"
    else
        codesign --force --sign - "$1"
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

# -- Notarize the app -------------------------------------------------------
NOTARIZED=0
if [ -n "$IDENTITY" ] && xcrun notarytool history --keychain-profile "$PROFILE" \
        >/dev/null 2>&1; then
    ditto -c -k --keepParent "$APP" "$DIST/EditMD.zip"
    xcrun notarytool submit "$DIST/EditMD.zip" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$APP"
    NOTARIZED=1
else
    echo "   notarization: SKIPPED (profile '$PROFILE' not set up — see header)"
fi

# -- DMG --------------------------------------------------------------------
mkdir -p "$DIST/dmg-stage"
cp -R "$APP" "$DIST/dmg-stage/EditMD.app"
ln -s /Applications "$DIST/dmg-stage/Applications"
hdiutil create -volname "EditMD" -srcfolder "$DIST/dmg-stage" -ov -quiet \
    -format UDZO "$DMG"
rm -rf "$DIST/dmg-stage"
if [ -n "$IDENTITY" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ "$NOTARIZED" = 1 ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "== Done: $DMG"
shasum -a 256 "$DMG"
