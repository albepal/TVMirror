# Downloads the FFmpeg build bundled into TVMirror.exe (LGPL, BtbN/FFmpeg-Builds). Used by CI.
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot
if (Test-Path ffmpeg/ffmpeg.exe) { exit 0 }
$zip = "ffmpeg-n8.1-latest-win64-lgpl-8.1.zip"
Invoke-WebRequest "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/$zip" -OutFile "$env:RUNNER_TEMP/ff.zip"
Expand-Archive "$env:RUNNER_TEMP/ff.zip" "$env:RUNNER_TEMP/ff" -Force
New-Item -ItemType Directory -Force ffmpeg | Out-Null
Get-ChildItem "$env:RUNNER_TEMP/ff" -Recurse -Include ffmpeg.exe, ffprobe.exe, LICENSE.txt | Copy-Item -Destination ffmpeg
