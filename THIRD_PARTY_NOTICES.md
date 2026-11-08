# Third-party components

The Windows release (`TVMirror-…-windows.exe`) bundles:

- **FFmpeg** (`ffmpeg.exe`, LGPL v2.1+ build from [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds),
  release `ffmpeg-n8.1-latest-win64-lgpl-8.1`). FFmpeg is © the FFmpeg developers and licensed under the
  [GNU LGPL 2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html); source code is at
  <https://ffmpeg.org/download.html> and the exact build recipe at the BtbN repository. TVMirror runs it as a
  separate program (extracted to `%LOCALAPPDATA%\TVMirror`), so it can be replaced with any compatible build.
  It includes OpenH264 (© Cisco, BSD-2-Clause).
- **.NET runtime and Windows Forms** – © .NET Foundation, MIT License.
- **NAudio** – © Mark Heath, MIT License.
- **Zeroconf** – © Claire Novotny, MIT License.

The Mac and TV apps use only Apple and Android system frameworks.
