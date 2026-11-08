# TVMirror – notes for Claude

AirPlay-style screen mirroring from a Mac or Windows PC to an Android TV / Google TV / Fire TV.
Three apps share one TCP protocol; there is no server.

## Layout

| Dir | What | Stack |
|---|---|---|
| `mac/` | Menu-bar sender | Swift, SwiftPM (no Xcode project), AppKit, ScreenCaptureKit, VideoToolbox |
| `windows/` | Tray sender | .NET 10 WinForms, bundled FFmpeg (LGPL, BtbN build), NAudio, Zeroconf |
| `tv/` | Receiver | Android, plain Java (no AndroidX), minSdk 26, AGP 8.7.3, Gradle wrapper 8.11.1 |
| `tools/fake_tv.py` | Fake receiver for testing senders without a TV | Python |
| `scripts/` | `install-tv.sh`, `release.sh`, `make-icons.swift`, release notes | |

## Protocol (Protocol.swift / Session.java / StreamConnection.cs)

Packet = type(1) | flags(1) | pts µs (8, BE) | length (4, BE) | payload.
Mac→TV: 0 HELLO (JSON: width, height, codec, audio, sampleRate, playoutDelayMs, name), 1 VIDEO_CONFIG (Annex B
SPS/PPS, sent before every keyframe), 2 VIDEO_FRAME (Annex B), 3 AUDIO (s16le stereo), 4 BYE.
TV→Mac: 10 REQUEST_KEYFRAME, 13 ACK (one per frame; sender drops frames when >8 unacked, then waits for a keyframe).
Discovery: Bonjour `_tvmirror._tcp`, port 47800. The menu path connects over IPv6 link-local; `--connect IP` uses IPv4.

## Build / install / release

```bash
mac/scripts/build.sh --install            # → /Applications, signed with the "Sweep Code Signing" cert (keeps TCC grants)
scripts/install-tv.sh <TV-IP>             # adb over Wi-Fi; also grants overlay + TCL auto-start appops
windows/get-ffmpeg.sh && dotnet publish windows/TVMirror.csproj -c Release   # cross-builds on macOS
scripts/release.sh <version> [--local]    # DMG (universal) + EXE + APK → dist/ + GitHub release
```

- Mac builds use `SDKROOT=…/MacOSX26.5.sdk` (CLT's newer SDK lacks pieces). JDK: `/opt/homebrew/opt/openjdk@17`.
- Release asset names have no version, so `releases/latest/download/TVMirror-tv.apk` always works
  (the apps' setup guides tell users to type it into the "Downloader" TV app).
- Check the real exit status of builds; `build.sh | grep` hides failures.
- CI (`.github/workflows/windows.yml`) builds the exe on a real Windows runner and runs end-to-end self-tests
  (`TVMirror.exe --selftest host:port secs log [extend]`) against `fake_tv.py`, then decodes the result with ffprobe.

## Test hooks

- Mac: `open TVMirror.app --args --connect-name "Smart TV"` (same path as the menu), `--connect IP[:port]`,
  `--dump-menu` (writes the menu tree to the log).
- Logs: Mac `/usr/bin/log stream --predicate 'subsystem == "com.albertopalazzolo.tvmirror"'` (zsh's `log` is a
  builtin – use the full path); TV `adb logcat -s TVMirror` (hello / decoder ready / first frame / stats every ~2 s).
- Don't drive the user's desktop with simulated input/screenshots (blocked by the harness); use the hooks above.

## Hard-won facts (don't re-learn these)

- **macOS 27 virtual displays (Extend):** `CGVirtualDisplay` only comes online if the *first* mode in
  `settings.modes` is 1280×720 or 1600×900; 1920×1080 or 960×540 first never comes online (colours, vendor IDs,
  queues, packaging are irrelevant). Found by bisecting against BetterDummy 1.0.11 (MIT). After it's online,
  `VirtualScreen.arrange()` switches to the HiDPI 1280×720@2560×1440 mode (macOS otherwise picks a tiny 1× 2560×1440)
  and places it bottom-aligned right of the main display. Standalone test harnesses gave contradictory results;
  verify inside the app.
- **VideoToolbox:** never hold a lock while calling `VTCompressionSessionInvalidate` – it waits for in-flight
  frames whose output handler takes the same lock (froze the menu bar app).
- **Android:** no network I/O on the UI thread – `Session` sends through a single-thread executor
  (a `NetworkOnMainThreadException` once left sessions stuck on "Connecting…"). A watchdog rebuilds the decoder
  and re-requests a keyframe if no picture arrives within 2.5 s.
- **TCL TVs:** TCL Guard blocks self-start (boot, updates) unless appop `APP_AUTO_START` is allowed; users can do it
  in TCL Guard › Permission Shield › Auto Launch Permission (intent `com.tcl.guard.action.PermissionManager`).
  The TV home screen shows banners for this and for "display over other apps" only while needed.
- **Wi-Fi:** the TCL's Wi-Fi stalls 40–100 ms every ~1.15 s regardless of Wi-Fi locks; that's the main source of
  hiccups. "Smooth" mode (150 ms playout buffer on the TV) hides it and also lines audio up with video
  (the TV's own audio path adds ~76 ms). Extend keeps its own mode, default Responsive.
- **Windows Extend** needs a virtual display driver (detected via `EnumDisplayDevices` adapter names);
  otherwise the app explains and links the open-source Virtual Display Driver. Uses GDI capture for that screen.
- Stopping from the TV (Back) is a clean end, not an error – no dialogs on the computer.

## Status / open items

- Dock disappearing after an Extend session: mode/placement fixed in ccbc5e8; awaiting confirmation.
- Untested: Fire TV, Windows on a real PC with a GPU, Windows Extend with a real virtual display driver.
- Commits made by Claude end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
