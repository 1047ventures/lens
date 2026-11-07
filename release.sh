#!/bin/zsh
# Ships a new version of Lens to Emma: Lens picks it up on its own and offers "Install".
#
#   ./release.sh 1.0.1 "What changed, in plain words for Emma"
#
# Bumps the version, builds, signs and notarizes (package.sh), refuses to publish anything
# Apple hasn't notarized, saves the code to the private repo, and posts Lens.zip to the
# public releases repo that Lens checks for updates.
set -euo pipefail
cd "${0:A:h}"

VERSION="${1:?Usage: ./release.sh <version> \"what changed\"}"
NOTES="${2:-Improvements and fixes.}"
PLIST=Lens/Info.plist

BUILD_NUM=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD_NUM" "$PLIST"

./package.sh
spctl --assess --type execute build/release/stage/Lens.app || { echo "Not notarized: refusing to publish."; exit 1; }

git add -A
git commit -m "Release $VERSION" -m "$NOTES"
git tag "v$VERSION"
git push origin main --tags

gh release create "v$VERSION" "$HOME/Desktop/Lens.zip" --repo 1047ventures/lens-releases \
  --title "Lens $VERSION" --notes "$NOTES"
echo "Released Lens $VERSION. Emma's copy will offer it within a few hours (or at next launch)."
