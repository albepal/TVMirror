using System.Collections.Concurrent;
using System.Diagnostics;
using System.Reflection;
using System.Security.Cryptography;

namespace TVMirror;

/// Screen capture + hardware H.264 encoding through a bundled FFmpeg:
/// Desktop Duplication capture (GDI fallback) → the best available encoder
/// (NVIDIA NVENC, Intel Quick Sync, AMD AMF, Windows Media Foundation, or OpenH264 in software),
/// all tuned for zero-latency, then split into frames for the TV.
sealed class VideoPipeline : IDisposable
{
    public record Encoder(string Name, string Label, string[] Options);

    static readonly Encoder[] Candidates =
    {
        new("h264_nvenc", "NVIDIA NVENC", new[] { "-preset", "p1", "-tune", "ull", "-zerolatency", "1", "-rc", "cbr", "-delay", "0", "-forced-idr", "1" }),
        new("h264_qsv", "Intel Quick Sync", new[] { "-preset", "veryfast", "-look_ahead", "0", "-async_depth", "1", "-forced_idr", "1" }),
        new("h264_amf", "AMD AMF", new[] { "-usage", "ultralowlatency", "-quality", "speed", "-rc", "cbr" }),
        new("h264_mf", "Windows Media Foundation", new[] { "-hw_encoding", "1", "-scenario", "display_remoting", "-rate_control", "cbr" }),
        new("libopenh264", "OpenH264 (software)", new[] { "-allow_skip_frames", "1", "-rc_mode", "bitrate" }),
    };

    static Encoder? cachedEncoder;

    readonly string ffmpeg;
    Process? process;
    volatile bool stopped;
    readonly BlockingCollection<byte[]> chunks = new(new ConcurrentQueue<byte[]>());
    readonly long startTicks = Stopwatch.GetTimestamp();

    /// (frame, SPS+PPS if keyframe, isKeyframe, pts µs) on the assembler thread.
    public event Action<byte[], byte[]?, bool, ulong>? Frame;
    public event Action<string>? Failed;
    public event Action<string>? Log;

    public VideoPipeline() { ffmpeg = FfmpegPath(); }

    /// Extracts the FFmpeg bundled inside the exe to %LOCALAPPDATA%\TVMirror (once per version).
    public static string FfmpegPath()
    {
        var dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TVMirror");
        var asm = Assembly.GetExecutingAssembly();
        using var res = asm.GetManifestResourceStream("ffmpeg.exe");
        if (res == null)
        {
            // Development: ffmpeg.exe next to the exe or on PATH.
            var local = Path.Combine(AppContext.BaseDirectory, "ffmpeg.exe");
            return File.Exists(local) ? local : "ffmpeg.exe";
        }
        Directory.CreateDirectory(dir);
        var path = Path.Combine(dir, $"ffmpeg-{res.Length:x}.exe");
        if (!File.Exists(path))
        {
            var tmp = path + ".tmp";
            using (var f = File.Create(tmp)) res.CopyTo(f);
            File.Move(tmp, path, true);
            foreach (var old in Directory.GetFiles(dir, "ffmpeg-*.exe"))
                if (old != path) try { File.Delete(old); } catch { }
        }
        return path;
    }

    /// Finds the first encoder that actually works on this PC (cached for the app's lifetime).
    public Encoder PickEncoder()
    {
        if (cachedEncoder != null) return cachedEncoder;
        foreach (var e in Candidates)
        {
            var args = new List<string> { "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=black:s=1280x720:r=60",
                                          "-frames:v", "5", "-pix_fmt", "nv12", "-c:v", e.Name };
            args.AddRange(e.Options);
            args.AddRange(new[] { "-b:v", "8M", "-f", "null", "-" });
            if (Run(args, 15000) == 0)
            {
                Log?.Invoke($"encoder: {e.Label} ({e.Name})");
                return cachedEncoder = e;
            }
        }
        throw new InvalidOperationException("No working H.264 encoder was found on this PC.");
    }

    int Run(List<string> args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true, RedirectStandardOutput = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        try
        {
            using var p = Process.Start(psi)!;
            p.StandardOutput.ReadToEndAsync();
            p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } return -1; }
            return p.ExitCode;
        }
        catch (Exception) { return -1; }
    }

    public void Start(Screen screen, int screenIndex, int width, int height, int fps, int bitrate, bool useGdi)
    {
        var enc = PickEncoder();
        var args = new List<string> { "-hide_banner", "-loglevel", "error", "-fflags", "nobuffer", "-flags", "low_delay",
                                      "-probesize", "32", "-analyzeduration", "0" };
        string filter;
        if (!useGdi)
        {
            // Desktop Duplication: GPU capture, frames copied to memory once for scaling/conversion.
            args.AddRange(new[] { "-f", "lavfi", "-i", $"ddagrab=output_idx={screenIndex}:framerate={fps}:draw_mouse=1" });
            filter = $"hwdownload,format=bgra,scale={width}:{height}:flags=fast_bilinear,format=nv12";
        }
        else
        {
            var b = screen.Bounds;
            args.AddRange(new[] { "-f", "gdigrab", "-framerate", fps.ToString(), "-draw_mouse", "1",
                                  "-offset_x", b.X.ToString(), "-offset_y", b.Y.ToString(),
                                  "-video_size", $"{b.Width}x{b.Height}", "-i", "desktop" });
            filter = $"scale={width}:{height}:flags=fast_bilinear,format=nv12";
        }
        args.AddRange(new[] { "-vf", filter, "-c:v", enc.Name });
        args.AddRange(enc.Options);
        args.AddRange(new[] {
            "-bf", "0", "-g", fps.ToString(),                 // keyframe every second: recovery after drops
            "-b:v", bitrate.ToString(), "-maxrate", bitrate.ToString(), "-bufsize", (bitrate / fps * 2).ToString(),
            "-bsf:v", "dump_extra=freq=keyframe,h264_metadata=aud=insert",
            "-flush_packets", "1", "-f", "h264", "-" });

        var psi = new ProcessStartInfo(ffmpeg) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        Log?.Invoke($"capture: {(useGdi ? "GDI" : "Desktop Duplication")} {width}x{height}@{fps}, {enc.Label}");
        process = Process.Start(psi) ?? throw new InvalidOperationException("Couldn't start FFmpeg.");
        try { process.PriorityClass = ProcessPriorityClass.AboveNormal; } catch { }

        var errors = new System.Text.StringBuilder();
        process.ErrorDataReceived += (_, e) => { if (e.Data != null) lock (errors) errors.AppendLine(e.Data); };
        process.BeginErrorReadLine();

        var proc = process;
        new Thread(() => ReadLoop(proc, errors)) { IsBackground = true, Name = "tvmirror-ffmpeg-read", Priority = ThreadPriority.AboveNormal }.Start();
        new Thread(AssembleLoop) { IsBackground = true, Name = "tvmirror-frames", Priority = ThreadPriority.AboveNormal }.Start();
    }

    void ReadLoop(Process p, System.Text.StringBuilder errors)
    {
        var s = p.StandardOutput.BaseStream;
        try
        {
            var buf = new byte[256 * 1024];
            int n;
            while ((n = s.Read(buf, 0, buf.Length)) > 0) chunks.Add(buf.AsSpan(0, n).ToArray());
        }
        catch (Exception) { }
        chunks.CompleteAdding();
        if (!stopped)
        {
            p.WaitForExit(2000);
            string msg;
            lock (errors) msg = errors.ToString().Trim();
            Failed?.Invoke(string.IsNullOrEmpty(msg) ? "Screen capture stopped." : msg);
        }
    }

    /// Splits FFmpeg's Annex B stream into frames. Each frame starts with an access unit delimiter;
    /// FFmpeg writes a frame in one burst, so a short pause also marks the end of the current frame
    /// (this avoids waiting a whole frame interval for the next delimiter).
    void AssembleLoop()
    {
        var au = new List<byte>(512 * 1024);
        while (!chunks.IsCompleted)
        {
            if (chunks.TryTake(out var chunk, au.Count > 0 ? 2 : 100))
            {
                int start = 0;
                // Split at any delimiter inside the chunk (beyond the frame's own leading one).
                for (int i = 0; i + 4 < chunk.Length; i++)
                {
                    if (chunk[i] == 0 && chunk[i + 1] == 0 && chunk[i + 2] == 1 && (chunk[i + 3] & 0x1f) == 9)
                    {
                        int sc = (i > 0 && chunk[i - 1] == 0) ? i - 1 : i;
                        if (sc > start || au.Count > 0)
                        {
                            au.AddRange(new ArraySegment<byte>(chunk, start, sc - start));
                            if (HasVcl(au)) Emit(au);
                            start = sc;
                        }
                        i += 3;
                    }
                }
                au.AddRange(new ArraySegment<byte>(chunk, start, chunk.Length - start));
            }
            else if (au.Count > 0 && HasVcl(au))
            {
                Emit(au);
            }
        }
    }

    static bool HasVcl(List<byte> au)
    {
        for (int i = 0; i + 3 < au.Count; i++)
            if (au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1)
            {
                int t = au[i + 3] & 0x1f;
                if (t == 1 || t == 5) return true;
                i += 2;
            }
        return false;
    }

    void Emit(List<byte> au)
    {
        var data = au.ToArray();
        au.Clear();
        bool key = false;
        var config = new List<byte>();
        var nals = new List<(int start, int end, int type)>();
        int prev = -1, prevType = 0;
        for (int i = 0; i + 3 <= data.Length; i++)
        {
            if (i + 3 < data.Length && data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1)
            {
                int sc = (i > 0 && data[i - 1] == 0) ? i - 1 : i;
                if (prev >= 0) nals.Add((prev, sc, prevType));
                prev = i + 3;
                prevType = data[i + 3] & 0x1f;
                i += 2;
            }
        }
        if (prev >= 0) nals.Add((prev, data.Length, prevType));
        foreach (var (s, e, t) in nals)
        {
            if (t == 5) key = true;
            if (t == 7 || t == 8)
            {
                config.AddRange(new byte[] { 0, 0, 0, 1 });
                config.AddRange(new ArraySegment<byte>(data, s, e - s));
            }
        }
        ulong pts = (ulong)((Stopwatch.GetTimestamp() - startTicks) * 1_000_000.0 / Stopwatch.Frequency);
        Frame?.Invoke(data, key && config.Count > 0 ? config.ToArray() : null, key, pts);
    }

    public void Dispose()
    {
        stopped = true;
        try { if (process is { HasExited: false }) process.Kill(); } catch { }
        process?.Dispose();
    }
}
