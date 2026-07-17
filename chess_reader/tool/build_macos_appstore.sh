#!/usr/bin/env bash
# Builds a distribution-signed .pkg for the Mac App Store — the local
# equivalent of the `macos-appstore` Codemagic workflow (minus the upload,
# which needs a GUI login and isn't scriptable).
#
# This relies on Xcode's *automatic* signing manager rather than hand-rolling
# certificates the way the Codemagic workflow has to (no interactive login on
# a CI runner). That manual approach hit real snags there (see the long
# comments in codemagic.yaml: exportArchive re-signing the app with the
# installer cert and failing). A local Mac with Xcode signed into the
# developer account doesn't have that problem — the same signingStyle the
# Xcode Organizer's "Distribute App" flow uses — so it can create/reuse the
# Apple Distribution + Mac Installer Distribution certificates and the Mac
# App Store profile on its own.
#
# One-time setup before the first run:
#   1. Sign into your Apple ID in Xcode (Xcode -> Settings -> Accounts), with
#      access to team 8CZSU66MX5.
#   2. In App Store Connect, make sure the macOS platform is enabled on the
#      com.alpinist.chessBookReader app record.
#   3. macos/Runner.xcodeproj already has CODE_SIGN_STYLE = Automatic for
#      Release; DEVELOPMENT_TEAM is passed on the command line below instead
#      of being committed to the project (unlike the iOS project).
#
# Run on macOS (Flutter + Xcode required):
#   tool/build_macos_appstore.sh
#
# Output: dist/chessbook-reader-<version>-macos.pkg (App Store-signed)
#
# To upload: open the free "Transporter" app from the Mac App Store, sign in
# with the same Apple ID, drag the .pkg in, and click Deliver.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM_ID="8CZSU66MX5"

VERSION=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f1)
BUILD_NUMBER=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f2)
DIST="dist"
PKG="$DIST/chessbook-reader-${VERSION}-macos.pkg"
ARCHIVE="/tmp/ChessBookReader-macos.xcarchive"
EXPORT_DIR="/tmp/mas-export"
EXPORT_OPTIONS="/tmp/mas_export_options.plist"

echo "Building ChessBook Reader ${VERSION} (${BUILD_NUMBER}) for the Mac App Store..."
flutter pub get
flutter build macos --release --build-number="$BUILD_NUMBER"

rm -rf "$ARCHIVE"
# -allowProvisioningUpdates lets xcodebuild create the missing Apple
# Distribution / Mac Installer Distribution cert + App Store profile itself
# (via the Xcode account signed into $TEAM_ID); without it, a team that has
# never done a Mac App Store export fails at export time with "No profiles"
# / "No signing certificate" even though the archive step succeeds.
xcodebuild \
  -workspace macos/Runner.xcworkspace \
  -scheme Runner \
  -configuration Release \
  archive \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

EXPORTED_PKG=$(ls "$EXPORT_DIR"/*.pkg 2>/dev/null | head -1)
if [ -z "$EXPORTED_PKG" ]; then
  echo "error: no .pkg found in $EXPORT_DIR after export" >&2
  exit 1
fi

mkdir -p "$DIST"
cp "$EXPORTED_PKG" "$PKG"

echo
echo "Created $PKG"
echo "To upload: open Transporter, sign in, drag the .pkg in, click Deliver."
