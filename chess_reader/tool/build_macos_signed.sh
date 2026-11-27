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
# DISTRIBUTION=devid tells the app it's the Developer-ID build (not from the
# Mac App Store), so it doesn't offer a "Buy Pro" button StoreKit can't
# actually complete outside App Store distribution. See
# lib/core/entitlements/pro_purchase_dialog.dart.
flutter build macos --release --dart-define=DISTRIBUTION=devid

if [ ! -d "$APP" ]; then
  echo "error: $APP not found after build" >&2
  exit 1
fi

echo "=== built APP: $APP ==="
du -sh "$APP"
echo "=== Contents/Frameworks (expect FlutterMacOS, multistockfish, onnxruntime) ==="
ls -la "$APP/Contents/Frameworks/" || echo "NO Frameworks dir — app is hollow"

# Stage a clean copy before signing. Finder metadata can invalidate a bundle.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
SOURCE_APP="$APP"
APP="$STAGE/ChessBook Reader.app"
ditto --norsrc --noextattr --noqtn "$SOURCE_APP" "$APP"
ln -s /Applications "$STAGE/Applications"

# CocoaPods and Flutter's native asset use different casing for PDFium.
# Match the executable's load command and folder casing to the embedded dylib.
EXECUTABLE="$APP/Contents/MacOS/ChessBook Reader"
for FRAMEWORK in "$APP"/Contents/Frameworks/[Pp][Dd][Ff][Ii][Uu][Mm].framework; do
  [ -d "$FRAMEWORK" ] || continue
  for LIBRARY in "$FRAMEWORK"/[Pp][Dd][Ff][Ii][Uu][Mm]; do
    [ -f "$LIBRARY" ] || continue
    INSTALL_NAMES=$(otool -arch all -D "$LIBRARY" | grep '^@rpath/' | sort -u)
    case "$INSTALL_NAMES" in
      '@rpath/PDFium.framework/PDFium') OLD_NAME='@rpath/pdfium.framework/pdfium' ;;
      '@rpath/pdfium.framework/pdfium') OLD_NAME='@rpath/PDFium.framework/PDFium' ;;
      *) echo "Unexpected PDFium install name: $INSTALL_NAMES" >&2; exit 1 ;;
    esac
    if otool -arch all -L "$EXECUTABLE" | grep -F "$OLD_NAME" >/dev/null; then
      install_name_tool -change "$OLD_NAME" "$INSTALL_NAMES" "$EXECUTABLE"
    fi
    EXPECTED_FRAMEWORK="$APP/Contents/Frameworks/${INSTALL_NAMES#@rpath/}"
    EXPECTED_FRAMEWORK="${EXPECTED_FRAMEWORK%/*}"
    if [ "$FRAMEWORK" != "$EXPECTED_FRAMEWORK" ]; then
      mv "$FRAMEWORK" "$FRAMEWORK.staging"
      mv "$FRAMEWORK.staging" "$EXPECTED_FRAMEWORK"
    fi
    break
  done
done

echo "Signing app + embedded frameworks..."
codesign --force --deep --options runtime --timestamp \
  --entitlements macos/Runner/Release.entitlements \
  --sign "$CERT" "$APP"

echo "=== verifying signature ==="
codesign -dvvv "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$DIST"
rm -f "$DMG"

hdiutil create -volname "ChessBook Reader" -srcfolder "$STAGE" \
  -ov -format UDZO "$DMG"

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
