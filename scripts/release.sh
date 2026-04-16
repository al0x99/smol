#!/usr/bin/env bash
# Build, sign (Developer ID), notarize, staple, and package smol as a .dmg
# Usage:
#   scripts/release.sh <version> [--skip-notarize]
# Env vars (required unless --skip-notarize):
#   DEV_ID_APPLICATION    "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE        Name of the keychain profile created via:
#                         xcrun notarytool store-credentials <profile> \
#                           --apple-id <you@example.com> \
#                           --team-id <TEAMID> \
#                           --password <APP-SPECIFIC-PASSWORD>
# Outputs: build/release/smol-<version>.dmg
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/release.sh <version> [--skip-notarize]" >&2
  exit 64
fi
SKIP_NOTARIZE=0
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/release"
DD="$REPO/build/DerivedData-release"
APP_SRC="$DD/Build/Products/Release/smol.app"
APP_DMG_ROOT="$OUT/dmg-root"
DMG="$OUT/smol-$VERSION.dmg"

mkdir -p "$OUT"
rm -rf "$DD" "$APP_DMG_ROOT" "$DMG"

echo "==> Building Release configuration"
xcodebuild \
  -project "$REPO/smol.xcodeproj" \
  -scheme smol \
  -configuration Release \
  -derivedDataPath "$DD" \
  CODE_SIGN_STYLE=Manual \
  ${DEV_ID_APPLICATION:+CODE_SIGN_IDENTITY="$DEV_ID_APPLICATION"} \
  clean build | xcpretty || true

[[ -d "$APP_SRC" ]] || { echo "build failed, no .app at $APP_SRC" >&2; exit 1; }

if [[ -n "${DEV_ID_APPLICATION:-}" ]]; then
  echo "==> Re-signing with Developer ID + hardened runtime"
  codesign --force --deep --timestamp --options=runtime \
    --entitlements "$REPO/smol/smol.entitlements" \
    --sign "$DEV_ID_APPLICATION" \
    "$APP_SRC"

  echo "==> Verifying signature"
  codesign -dv --verbose=4 "$APP_SRC" 2>&1 | grep -E "Authority|Identifier|TeamIdentifier|Runtime"
  spctl -a -vv -t execute "$APP_SRC" || echo "spctl check (notarization not yet stapled — expected)"
fi

echo "==> Preparing DMG staging"
mkdir -p "$APP_DMG_ROOT"
cp -R "$APP_SRC" "$APP_DMG_ROOT/"
ln -s /Applications "$APP_DMG_ROOT/Applications"

echo "==> Creating $DMG"
hdiutil create -volname "smol $VERSION" -srcfolder "$APP_DMG_ROOT" \
  -ov -format UDZO "$DMG"

if [[ -n "${DEV_ID_APPLICATION:-}" ]]; then
  echo "==> Signing DMG"
  codesign --force --timestamp --sign "$DEV_ID_APPLICATION" "$DMG"
fi

if [[ $SKIP_NOTARIZE -eq 0 && -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Submitting to Apple notary service ($NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vv -t open --context context:primary-signature "$DMG" || true
else
  echo "==> Skipping notarization (SKIP_NOTARIZE=$SKIP_NOTARIZE, NOTARY_PROFILE='${NOTARY_PROFILE:-}')"
fi

echo ""
echo "Done: $DMG"
ls -lh "$DMG"
shasum -a 256 "$DMG"
