#!/bin/zsh
# Builds Lens for Emma and drops Lens.zip on the Desktop.
#
#   ./package.sh
#
# - Builds a Release copy that runs on both Apple-silicon and Intel Macs (macOS 14 Sonoma or newer).
# - If a "Developer ID Application" certificate is in your keychain, signs with it, and if a notary
#   profile named "lens-notary" exists, notarizes it too, so Emma can just double-click it.
#   Otherwise it signs locally, and Emma opens it the first time from System Settings (see below).
# - Never includes any data: Lens starts empty on her Mac. Projects, deals and log-ins live in
#   ~/Library/Application Support/Deadweight on each Mac, not inside the app.
set -euo pipefail
cd "${0:A:h}"

BUILD="$PWD/build/release"
APP="$BUILD/Build/Products/Release/Deadweight.app"
OUT="$HOME/Desktop/Lens.zip"

python3 generate_xcodeproj.py >/dev/null
rm -rf "$BUILD"
xcodebuild -project Deadweight.xcodeproj -scheme Deadweight -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$BUILD" \
  ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
[[ -d "$APP" ]] || { echo "Build failed"; exit 1; }

# Ship it as Lens.app
STAGE="$BUILD/stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Lens.app"

# Only ever sign with Sean's own team.
TEAM_ID="J55RP92WN6"
IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | grep "($TEAM_ID)" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --deep --options runtime --timestamp \
    --entitlements Deadweight/Deadweight.entitlements --sign "$IDENTITY" "$STAGE/Lens.app"
else
  echo "No Developer ID certificate found: signing locally (Emma uses Open Anyway the first time)."
  codesign --force --deep --sign - "$STAGE/Lens.app"
fi

rm -f "$OUT"
ditto -c -k --keepParent "$STAGE/Lens.app" "$OUT"

if [[ -n "$IDENTITY" ]] && xcrun notarytool history --keychain-profile lens-notary >/dev/null 2>&1; then
  echo "Notarizing (a few minutes)…"
  xcrun notarytool submit "$OUT" --keychain-profile lens-notary --wait
  xcrun stapler staple "$STAGE/Lens.app"
  rm -f "$OUT" && ditto -c -k --keepParent "$STAGE/Lens.app" "$OUT"
  echo "Notarized: double-click to open."
fi

echo "Done: $OUT ($(du -h "$OUT" | cut -f1))"
