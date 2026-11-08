# TVMirror

AirPlay-style screen mirroring from a Mac or Windows PC to a Google TV (e.g. TCL).
Downloads (DMG, EXE, TV APK) are on the Releases page.

- `mac/` – menu-bar app. ScreenCaptureKit → VideoToolbox hardware H.264/HEVC (low-latency mode) → TCP.
- `windows/` – tray app (.NET 10, WinForms). Bundled FFmpeg: Desktop Duplication capture (GDI fallback) → NVENC / Quick Sync / AMF / Media Foundation / OpenH264, zero-latency settings; WASAPI loopback audio; mDNS discovery.
- `tv/` – Google TV app. Always-on receiver (Bonjour + port 47800) → MediaCodec hardware decode straight to the screen, PCM audio via AudioTrack.

Latency control: no B-frames, no decoder buffering, the TV acks each frame and the Mac drops frames and
asks for a keyframe when more than 8 are in flight, and the TV disables Wi-Fi power saving while mirroring.

## Build & install

```bash
mac/scripts/build.sh --install          # Mac app → /Applications, launches it (TV icon in the menu bar)
scripts/install-tv.sh 192.168.1.50      # TV app over Wi-Fi (the TV's IP)
```

One-time TV setup for adb: Settings → System → About → click "Android TV OS build" 7 times, then
Settings → System → Developer options → turn on "USB debugging" / "Network debugging" (or "Wireless debugging").
The TV's IP is in Settings → Network & Internet.

Windows: `windows/get-ffmpeg.sh && dotnet publish windows/TVMirror.csproj -c Release` (cross-builds on a Mac).
CI (`.github/workflows/windows.yml`) builds the exe and runs an end-to-end self-test on a real Windows machine
against `tools/fake_tv.py`, then checks the received video decodes.

Release everything: `scripts/release.sh <version>` → `dist/` (DMG, EXE, APK) + GitHub release.

## Use

Click the TV icon in the Mac menu bar → choose the TV. Back (or Home) on the TV remote, or "Stop Mirroring" on the Mac, ends it.
Quality, codec, display, and sound options are in the same menu and apply immediately.

Modes:
- **Responsive** – lowest delay, for mouse and typing.
- **Smooth** – the TV holds frames back ~150 ms to ride out Wi-Fi pauses; best for videos, and keeps sound in sync
  (the TV's own audio output adds ~76 ms that can't be removed).

## Diagnostics

Both apps log timing every ~2 s:
- Mac: `/usr/bin/log stream --predicate 'subsystem == "com.albertopalazzolo.tvmirror"'` (encode time, ack round trip, dropped frames)
- TV: `adb logcat -s TVMirror` (network delay over best case, decode time, audio buffer)

## Troubleshooting

- TV not listed: open TVMirror on the TV once (starts the receiver), or use "Connect to IP Address…".
- Stutter on Wi-Fi: use 1080p, put the TV on Ethernet or 5 GHz.
- Testing without a TV: `open /Applications/TVMirror.app --args --connect 127.0.0.1:47800` against a fake receiver.

## Credits

Built by Alberto Palazzolo together with **Claude** (Anthropic's AI model), using Claude Code.
Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MIT – see [LICENSE](LICENSE). Bundled third-party components keep their own licenses ([THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
