#!/usr/bin/env bash
# Uploads the Mac App Store .pkg (built by build_macos_appstore.sh) to App
# Store Connect. Uses the same App Store Connect API key auth as the
# ios-testflight Codemagic pipeline, run locally instead of on CI.
#
# One-time setup: download the API key's .p8 once from App Store Connect ->
# Users and Access -> Integrations -> App Store Connect API (Apple only lets
# you download it once) and save it to ~/.private_keys/AuthKey_<KEY_ID>.p8 --
# altool finds it there automatically. Never commit the .p8 itself; the
# IDs below are not secret on their own without it.
#
# Run after build_macos_appstore.sh:
#   tool/upload_macos_appstore.sh
set -euo pipefail

cd "$(dirname "$0")/.."

APPLE_ID="6782721529"                                    # App Store Connect numeric app ID (not email)
BUNDLE_ID="com.alpinist.chessBookReader"
API_KEY_ID="4YW8HDR6V4"
API_ISSUER_ID="083d194d-3c4c-4393-a150-824541678f15"

VERSION=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f1)
BUILD_NUMBER=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f2)
PKG="dist/chessbook-reader-${VERSION}-macos.pkg"

if [ ! -f "$PKG" ]; then
  echo "error: $PKG not found -- run tool/build_macos_appstore.sh first" >&2
  exit 1
fi

echo "Uploading $PKG (build $BUILD_NUMBER) to App Store Connect..."
xcrun altool --upload-package "$PKG" \
  --type macos \
  --apple-id "$APPLE_ID" \
  --bundle-id "$BUNDLE_ID" \
  --bundle-version "$BUILD_NUMBER" \
  --bundle-short-version-string "$VERSION" \
  --apiKey "$API_KEY_ID" \
  --apiIssuer "$API_ISSUER_ID"

echo
echo "Uploaded. Check processing status in App Store Connect -> TestFlight/Distribution."
