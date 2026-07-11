#!/usr/bin/env bash
# Builds the macOS app, Developer ID-signs it, packages a .dmg, and notarizes it.
# This is the local equivalent of the `macos-devid` Codemagic workflow — use it
# to produce the same signed, notarized artifact directly on a Mac.
#
# One-time setup before the first run:
#   1. A "Developer ID Application" certificate + its private key must be in
#      your login keychain (check with: security find-identity -v -p codesigning).
#   2. Notarization credentials stored under the profile name below:
#        xcrun notarytool store-credentials "chessbook-notary" \
#          --apple-id YOUR_APPLE_ID_EMAIL \
#          --team-id 8CZSU66MX5 \
#          --password xxxx-xxxx-xxxx-xxxx   # app-specific password from appleid.apple.com
#
# Run on macOS (Flutter + Xcode required):
#   tool/build_macos_signed.sh
#
# Output: dist/chessbook-reader-<version>-macos.dmg (signed + notarized + stapled)
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="chessbook-notary"

VERSION=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f1)
APP="build/macos/Build/Products/Release/ChessBook Reader.app"
DIST="dist"
DMG="$DIST/chessbook-reader-${VERSION}-macos.dmg"

CERT=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 \
  | sed -E 's/.*"(.*)"/\1/')
if [ -z "$CERT" ]; then
  echo "error: no 'Developer ID Application' identity found in the keychain" >&2
  echo "       run: security find-identity -v -p codesigning" >&2
  exit 1
fi
echo "Signing identity: $CERT"

echo "Building ChessBook Reader ${VERSION} for macOS..."
flutter build macos --release

if [ ! -d "$APP" ]; then
  echo "error: $APP not found after build" >&2
  exit 1
fi

echo "=== built APP: $APP ==="
du -sh "$APP"
echo "=== Contents/Frameworks (expect FlutterMacOS, multistockfish, onnxruntime) ==="
ls -la "$APP/Contents/Frameworks/" || echo "NO Frameworks dir — app is hollow"

echo "Signing app + embedded frameworks..."
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "$CERT" "$APP"

echo "=== verifying signature ==="
codesign -dvvv "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
rm -f "$DMG"

# Stage the .app alongside an /Applications symlink for drag-to-install.
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "ChessBook Reader" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# Fail loudly instead of notarizing/shipping a hollow image.
DMG_SIZE=$(stat -f%z "$DMG")
echo "=== DMG size: $DMG_SIZE bytes ==="
[ "$DMG_SIZE" -gt 50000000 ] || { echo "ERROR: DMG only $DMG_SIZE bytes — frameworks missing, aborting"; exit 1; }

echo "Submitting for notarization (this can take a few minutes)..."
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "Stapling notarization ticket..."
xcrun stapler staple "$DMG"

echo "Created $DMG (signed + notarized)"
