#!/usr/bin/env bash
# Builds a signed, App Store-ready .ipa for TestFlight — the local equivalent
# of the `ios-testflight` Codemagic workflow (minus the upload, which needs a
# GUI login and isn't scriptable).
#
# One-time setup before the first run:
#   1. Sign into your Apple ID in Xcode (Xcode -> Settings -> Accounts).
#   2. ios/Runner.xcodeproj must have CODE_SIGN_STYLE = Automatic and
#      DEVELOPMENT_TEAM = 8CZSU66MX5 (already committed in the project).
#      Xcode creates/reuses the Apple Distribution cert + App Store
#      provisioning profile automatically on first archive.
#
# Run on macOS (Flutter + Xcode required):
#   tool/build_ios_signed.sh
#
# Output: build/ios/ipa/ChessBook Reader.ipa (signed, ready to upload)
#
# To upload to TestFlight: open the free "Transporter" app from the Mac App
# Store, sign in with the same Apple ID, drag the .ipa in, and click Deliver.
set -euo pipefail

cd "$(dirname "$0")/.."

# ONNX Runtime's Swift Package Manager framework ships without a
# MinimumOSVersion in its Info.plist, which fails App Store validation
# (ITMS-90208: "Invalid Bundle ... does not support the minimum OS Version").
# Routing every plugin through CocoaPods instead avoids shipping that broken
# framework at all.
flutter config --no-enable-swift-package-manager

flutter build ipa --release

echo
echo "Signed IPA: build/ios/ipa/"
ls -la build/ios/ipa/*.ipa
echo
echo "To upload to TestFlight: open Transporter, sign in, drag the .ipa in, click Deliver."
