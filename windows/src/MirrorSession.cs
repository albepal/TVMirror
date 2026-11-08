using System.Diagnostics;

namespace TVMirror;

/// One mirroring run: capture → encode → send, plus system audio.
sealed class MirrorSession : IDisposable
{
    public string Name { get; }
    readonly string host;
    readonly int port;
    readonly Settings settings;
    StreamConnection? conn;
    VideoPipeline? video;
    AudioCapture? audio;
    int ended;
    bool triedGdi;
    Screen? screen;
    int screenIndex, width, height;
    const int Fps = 60;

    public event Action? Mirroring;
    public event Action<string?>? Ended;   // null = clean stop
    public event Action<string>? Log;

    public long FramesSent;

    public MirrorSession(string host, int port, string name, Settings settings)
    {
        this.host = host; this.port = port; Name = name; this.settings = settings;
    }

    /// Runs on a background thread; reports through events.
    public void Start()
    {
        new Thread(() =>
        {
            try { Run(); }
            catch (NeedsVirtualDisplayException) { End(NeedsVirtualDisplayException.Marker); }
            catch (Exception e) { End(e.Message); }
        }) { IsBackground = true, Name = "tvmirror-session" }.Start();
    }

    void Run()
    {
        var screens = Screen.AllScreens;
        bool extend = settings.ScreenUse == ScreenUse.Extend;
        if (extend)
        {
            screenIndex = VirtualDisplays.Find();
            if (screenIndex < 0) throw new NeedsVirtualDisplayException();
        }
        else
        {
            screenIndex = Math.Clamp(settings.DisplayIndex, 0, screens.Length - 1);
        }
        screen = screens[screenIndex];
        (width, height) = Settings.Size(settings.Quality, screen.Bounds.Width, screen.Bounds.Height);

        conn = new StreamConnection();
        conn.Log += s => Log?.Invoke(s);
        conn.Closed += err => End(err);
        conn.Connect(host, port, TimeSpan.FromSeconds(6));

        long start = Stopwatch.GetTimestamp();
        if (settings.SendAudio)
        {
            try { audio = new AudioCapture(start); }
            catch (Exception e) { Log?.Invoke("audio unavailable: " + e.Message); audio = null; }
        }

        conn.SendHello(new Dictionary<string, object>
        {
            ["v"] = 1,
            ["name"] = Environment.MachineName,
            ["width"] = width, ["height"] = height, ["fps"] = Fps,
            ["codec"] = "h264",
            ["audio"] = audio != null, ["sampleRate"] = audio?.SampleRate ?? 48000, ["channels"] = 2,
            ["playoutDelayMs"] = Settings.PlayoutDelayMs(settings.CurrentMode),
        });

        // Virtual monitors often sit on their own adapter, which Desktop Duplication's output index
        // doesn't reach reliably; GDI capture works for any monitor.
        triedGdi = extend;
        StartVideo(useGdi: extend);
        if (audio != null)
        {
            audio.Data += (pcm, pts) => conn.SendAudio(pcm, pts);
            audio.Start();
            if (settings.MuteSpeakers) SpeakerMute.Mute();
        }
        Mirroring?.Invoke();
    }

    void StartVideo(bool useGdi)
    {
        var v = new VideoPipeline();
        v.Log += s => Log?.Invoke(s);
        v.Frame += (frame, config, key, pts) =>
        {
            Interlocked.Increment(ref FramesSent);
            conn?.SendVideo(frame, config, key, pts);
        };
        v.Failed += err =>
        {
            if (Volatile.Read(ref ended) != 0) return;
            // Desktop Duplication isn't available everywhere (remote desktop, some GPUs): fall back to GDI once.
            if (!triedGdi && Interlocked.Read(ref FramesSent) == 0)
            {
                triedGdi = true;
                Log?.Invoke("desktop duplication failed, trying GDI capture: " + err);
                video?.Dispose();
                StartVideo(useGdi: true);
                return;
            }
            End("Screen capture stopped: " + err);
        };
        video = v;
        v.Start(screen!, screenIndex, width, height, Fps, Settings.Bitrate(settings.Quality), useGdi);
    }

    public void Stop() => End(null);

    void End(string? error)
    {
        if (Interlocked.Exchange(ref ended, 1) != 0) return;
        video?.Dispose();
        audio?.Dispose();
        conn?.Close(sayBye: error == null);
        SpeakerMute.Restore();
        Ended?.Invoke(error);
    }

    public void Dispose() => Stop();
}

/// Extend was chosen but no virtual monitor exists (Windows needs a driver for one).
sealed class NeedsVirtualDisplayException : Exception
{
    public const string Marker = "needs-virtual-display";
}
