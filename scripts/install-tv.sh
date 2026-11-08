#!/bin/bash
# Builds the TV app and installs it on the TV over Wi-Fi.
# Usage: scripts/install-tv.sh <TV-IP>[:port]     (port defaults to 5555)
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: $0 <TV-IP>[:port]"; exit 1; }
TV=$1; [[ $TV == *:* ]] || TV="$TV:5555"
PKG=com.albertopalazzolo.tvmirror

export JAVA_HOME=/opt/homebrew/opt/openjdk@17
(cd tv && ./gradlew assembleRelease -q)

adb connect "$TV"
echo "If the TV shows 'Allow USB debugging?', choose 'Always allow from this computer'."
adb -s "$TV" wait-for-device
adb -s "$TV" install -r tv/app/build/outputs/apk/release/app-release.apk
# Let the receiver open the video screen by itself when the Mac connects (from any app).
adb -s "$TV" shell appops set $PKG SYSTEM_ALERT_WINDOW allow
# TCL TVs: allow starting by itself after boot / updates (TCL Guard's "Auto Launch Permission").
adb -s "$TV" shell appops set $PKG APP_AUTO_START allow 2>/dev/null || true
# Keep the background receiver from being put to sleep.
adb -s "$TV" shell dumpsys deviceidle whitelist +$PKG >/dev/null || true
adb -s "$TV" shell am start -n $PKG/.MainActivity
echo "Installed. The TV should now show the TVMirror screen."
