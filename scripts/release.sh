#!/bin/bash
# Builds every download and publishes a GitHub release.
# File names carry no version, so releases/latest/download/<name> links (used by the apps) always work.
#   scripts/release.sh 1.0.0          → dist/ + GitHub release v1.0.0
#   scripts/release.sh 1.0.0 --local  → dist/ only
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release.sh <version> [--local]}
export JAVA_HOME=/opt/homebrew/opt/openjdk@17
rm -rf dist && mkdir dist

# Version numbers everywhere.
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" mac/scripts/Info.plist
/usr/libexec/PlistBuddy -c "Set CFBundleVersion $VERSION" mac/scripts/Info.plist
sed -i '' -E "s/versionName '[^']*'/versionName '$VERSION'/" tv/app/build.gradle
CODE=$(echo "$VERSION" | awk -F. '{print $1*10000 + $2*100 + $3}')
sed -i '' -E "s/versionCode [0-9]+/versionCode $CODE/" tv/app/build.gradle
sed -i '' -E "s#<Version>[^<]*</Version>#<Version>$VERSION</Version>#" windows/TVMirror.csproj

echo "== Mac"
mac/scripts/build.sh --universal
STAGE=$(mktemp -d)
cp -R mac/build/TVMirror.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TVMirror $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/TVMirror-mac.dmg" >/dev/null
rm -rf "$STAGE"

echo "== TV"
(cd tv && ./gradlew assembleRelease -q)
cp tv/app/build/outputs/apk/release/app-release.apk "dist/TVMirror-tv.apk"

echo "== Windows"
windows/get-ffmpeg.sh >/dev/null
dotnet publish windows/TVMirror.csproj -c Release -o windows/bin/publish -v quiet -nologo
cp windows/bin/publish/TVMirror.exe "dist/TVMirror-windows.exe"

ls -lh dist
[ "${2:-}" = "--local" ] && exit 0

git add -A && git commit -q -m "Release $VERSION" || true
git push -q
gh release create "v$VERSION" dist/* --title "TVMirror $VERSION" --notes-file scripts/release-notes.md
