#!/usr/bin/env bash
# Uploads the release App Bundle to Google Play via the Play Developer
# Publishing API, using a dedicated service account instead of the Play
# Console web UI (mirrors upload_macos_appstore.sh's approach for Apple).
#
# One-time setup (already done for chess-reader as of 2026-08-19):
#   1. GCP project "chess-reader-play-deploy" with the Android Publisher API
#      (androidpublisher.googleapis.com) enabled.
#   2. Service account
#      play-beta-deploy@chess-reader-play-deploy.iam.gserviceaccount.com,
#      with its JSON key saved to
#      ~/.config/gcloud/chess-reader-play-deploy.json (Google only lets you
#      download it once at creation).
#   3. Still required in Play Console -> Setup -> API access: link the
#      "chess-reader-play-deploy" Cloud project and grant
#      play-beta-deploy@... access to this app (at least "Release apps to
#      testing tracks"; add "Release to production" once ready to ship
#      straight to prod from here). If the app doesn't exist in Play Console
#      yet, create it first (store listing, content rating, data safety,
#      etc. — that part is manual and not something this script can do).
#
# Run after `flutter build appbundle --release`:
#   tool/upload_playstore.sh [internal|alpha|beta|production]
set -euo pipefail

cd "$(dirname "$0")/.."

TRACK="${1:-internal}"
KEY_FILE="$HOME/.config/gcloud/chess-reader-play-deploy.json"
PACKAGE_NAME="com.alpinist.chessbook_reader"
AAB="build/app/outputs/bundle/release/app-release.aab"

if [ ! -f "$KEY_FILE" ]; then
  echo "error: service account key not found at $KEY_FILE" >&2
  exit 1
fi
if [ ! -f "$AAB" ]; then
  echo "error: $AAB not found -- run 'flutter build appbundle --release' first" >&2
  exit 1
fi

VERSION=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f1)
BUILD_NUMBER=$(grep '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*//' | cut -d'+' -f2)

echo "Authenticating as play-beta-deploy service account..."
# gcloud's own print-access-token only mints cloud-platform-scoped tokens,
# which the Android Publisher API rejects (ACCESS_TOKEN_SCOPE_INSUFFICIENT)
# -- it needs the androidpublisher scope specifically. Mint that token
# ourselves via the standard service-account JWT-bearer flow (RS256-signed
# with openssl) instead of adding a Python dependency for this one call.
CLIENT_EMAIL=$(python3 -c "import json; print(json.load(open('$KEY_FILE'))['client_email'])")
PRIVATE_KEY_FILE=$(mktemp)
trap 'rm -f "$PRIVATE_KEY_FILE"' EXIT
python3 -c "import json; print(json.load(open('$KEY_FILE'))['private_key'], end='')" > "$PRIVATE_KEY_FILE"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

NOW=$(date +%s)
EXP=$((NOW + 3600))
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
CLAIMS=$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"https://oauth2.googleapis.com/token","exp":%d,"iat":%d}' \
  "$CLIENT_EMAIL" "$EXP" "$NOW" | b64url)
SIGNING_INPUT="$HEADER.$CLAIMS"
SIGNATURE=$(printf '%s' "$SIGNING_INPUT" | openssl dgst -sha256 -sign "$PRIVATE_KEY_FILE" | b64url)
JWT="$SIGNING_INPUT.$SIGNATURE"

TOKEN=$(curl -sf -X POST "https://oauth2.googleapis.com/token" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" \
  -d "assertion=$JWT" | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE_NAME"

echo "Opening an edit..."
EDIT_ID=$(curl -sf -X POST "$API/edits" \
  -H "Authorization: Bearer $TOKEN" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
echo "Edit ID: $EDIT_ID"

echo "Uploading $AAB (version ${VERSION}, build ${BUILD_NUMBER})..."
# Binary media uploads need the separate /upload/ API path prefix -- posting
# to the plain (metadata-only) path makes the server try to parse the AAB's
# raw bytes as a JSON request body and reject it.
UPLOAD_API="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PACKAGE_NAME"
VERSION_CODE=$(curl -sf -X POST \
  "$UPLOAD_API/edits/$EDIT_ID/bundles?uploadType=media" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary "@$AAB" | python3 -c 'import sys,json; print(json.load(sys.stdin)["versionCode"])')
echo "Uploaded as versionCode $VERSION_CODE"

echo "Assigning to track: $TRACK..."
curl -sf -X PUT "$API/edits/$EDIT_ID/tracks/$TRACK" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"releases\":[{\"versionCodes\":[\"$VERSION_CODE\"],\"status\":\"completed\"}]}" > /dev/null

echo "Committing edit..."
curl -sf -X POST "$API/edits/$EDIT_ID:commit" \
  -H "Authorization: Bearer $TOKEN" > /dev/null

echo
echo "Done. $PACKAGE_NAME versionCode $VERSION_CODE released to the $TRACK track."
