#!/bin/bash
# Builds TVMirror.app into build/ and, with --install, copies it to /Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
# Same SDK choice as Sweep: the command-line tools' 27 SDK lacks pieces; 26.5 works.
[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ] && export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk

swift build -c release
APP=build/TVMirror.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TVMirror "$APP/Contents/MacOS/TVMirror"
cp scripts/Info.plist "$APP/Contents/Info.plist"
if [ ! -f build/AppIcon.icns ] || [ ../scripts/make-icons.swift -nt build/AppIcon.icns ]; then
    rm -rf build/art build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
    swift ../scripts/make-icons.swift build/art >/dev/null
    for s in 16 32 128 256 512; do
        sips -z $s $s build/art/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        sips -z $((s * 2)) $((s * 2)) build/art/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# A stable signing identity keeps the Screen Recording permission across rebuilds (ad-hoc would reset it).
IDENTITY=$(security find-certificate -c "Sweep Code Signing" -Z 2>/dev/null | awk '/SHA-1/ {print $3}')
SIGN=${IDENTITY:--}
codesign --force --options runtime --sign "$SIGN" "$APP"
[ "$SIGN" = "-" ] && echo "warning: ad-hoc signed; Screen Recording permission will reset on every build"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x TVMirror 2>/dev/null || true
    rm -rf /Applications/TVMirror.app
    cp -R "$APP" /Applications/TVMirror.app
    open /Applications/TVMirror.app
    echo "Installed and launched /Applications/TVMirror.app"
fi
