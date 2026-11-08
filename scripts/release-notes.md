AirPlay-style screen mirroring from a Mac or Windows PC to a Google TV / Android TV.

## Downloads

| File | For |
|---|---|
| `TVMirror-…-mac.dmg` | Mac (macOS 14+, Apple Silicon and Intel). Open it and drag TVMirror to Applications. |
| `TVMirror-…-windows.exe` | Windows 10/11 (64-bit). Portable: just run it; it appears next to the clock. |
| `TVMirror-…-tv.apk` | The TV app (Google TV / Android TV 8+). Install it once on the TV. |

## Setup

1. **TV:** install the APK (see README: developer mode + `scripts/install-tv.sh <TV-IP>`, or any APK sideloading app). Open TVMirror on the TV once.
2. **Computer:** click the TV icon (menu bar on Mac, notification area on Windows) → choose your TV.

**First launch:** these builds aren't signed by Apple/Microsoft.
- Mac: right-click TVMirror.app → **Open** → **Open**, then allow *Screen & System Audio Recording* when asked.
- Windows: if SmartScreen appears, click **More info → Run anyway**.

## Modes
- **Responsive** – lowest delay, for mouse and typing.
- **Smooth** – holds the picture ~150 ms to ride out Wi-Fi pauses; best for videos, and keeps sound in sync.
