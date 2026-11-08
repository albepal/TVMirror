#!/bin/bash
# Downloads the FFmpeg build that gets bundled into TVMirror.exe (LGPL, from BtbN/FFmpeg-Builds).
set -euo pipefail
cd "$(dirname "$0")"
ZIP=ffmpeg-n8.1-latest-win64-lgpl-8.1.zip
[ -f ffmpeg/ffmpeg.exe ] && { echo "ffmpeg already present"; exit 0; }
TMP=$(mktemp -d)
curl -fsSL -o "$TMP/ff.zip" "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$ZIP"
mkdir -p ffmpeg
unzip -q -j "$TMP/ff.zip" '*/bin/ffmpeg.exe' '*/bin/ffprobe.exe' -d ffmpeg
unzip -q -j -o "$TMP/ff.zip" '*/LICENSE.txt' -d ffmpeg 2>/dev/null || true
rm -rf "$TMP"
ls -la ffmpeg
