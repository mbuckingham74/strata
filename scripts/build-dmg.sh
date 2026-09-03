#!/usr/bin/env bash
# build-dmg.sh
#
# Builds Strata in Release configuration and packages it into a
# double-clickable .dmg for personal distribution (no App Store,
# no paid Developer ID required). Run this from a Terminal on the
# Mac that has Xcode installed -- not inside any sandboxed shell.
#
# Usage:
#   ./scripts/build-dmg.sh
#
# Optional env vars:
#   TEAM_ID   Apple Developer Team ID to sign with (defaults to the
#             team found via `security find-identity`, if only one).
#   APP_NAME  Product name (defaults to Strata).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"

APP_NAME="${APP_NAME:-Strata}"
SCHEME="Strata"
CONFIGURATION="Release"
BUILD_DIR="$repo_root/build/dmg-build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
STAGING_DIR="$BUILD_DIR/staging"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Building $APP_NAME ($CONFIGURATION) (unsigned -- we sign explicitly below)..."
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: build succeeded but $APP_PATH not found" >&2
  exit 1
fi

# Resolve the signing identity: explicit SIGN_IDENTITY env var, or the sole
# "Apple Development" identity found in the keychain (free personal-team cert).
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning \
    | grep 'Apple Development' | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"
fi
if [[ -z "$SIGN_IDENTITY" ]]; then
  echo "error: no 'Apple Development' signing identity found in keychain" >&2
  echo "       (check: security find-identity -v -p codesigning)" >&2
  exit 1
fi

echo "==> Signing with: $SIGN_IDENTITY"
codesign --force --deep --options runtime --timestamp=none \
  --sign "$SIGN_IDENTITY" "$APP_PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "1.0")"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
DMG_PATH="$repo_root/build/$DMG_NAME"

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign --display --verbose=2 "$APP_PATH"

echo "==> Staging .dmg contents..."
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "==> Creating $DMG_NAME..."
rm -f "$DMG_PATH"
# Plain hdiutil: fully non-interactive, no Finder/AppleScript styling that can
# hang when run outside an interactive Terminal session.
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"

echo ""
echo "==> Done: $DMG_PATH"
echo ""
echo "This .dmg is signed with a local/personal certificate, not a notarized"
echo "Developer ID. On another Mac, Gatekeeper will block it on first open."
echo "Two ways around that on the receiving Mac, after copying Strata.app"
echo "to Applications:"
echo "  1. Right-click (or Control-click) the app -> Open -> Open, or"
echo "  2. Terminal: xattr -cr /Applications/$APP_NAME.app"
