namespace TVMirror;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // Headless test used by CI: TVMirror.exe --selftest 127.0.0.1:47800 <seconds> <logfile> [extend]
        if (args.Length >= 1 && args[0] == "--selftest") return SelfTest(args);

        using var single = new Mutex(true, @"Local\TVMirror", out bool first);
        if (!first) return 0; // already running (check the notification area)

        ApplicationConfiguration.Initialize();
        Application.Run(new TrayApp());
        return 0;
    }

    static int SelfTest(string[] args)
    {
        var target = args.Length > 1 ? args[1] : "127.0.0.1:47800";
        int seconds = args.Length > 2 ? int.Parse(args[2]) : 5;
        var logPath = args.Length > 3 ? args[3] : "selftest.log";
        using var log = new StreamWriter(logPath) { AutoFlush = true };
        void L(string s) { lock (log) log.WriteLine($"{DateTime.Now:HH:mm:ss.fff} {s}"); }

        var parts = target.Split(':');
        bool extend = args.Length > 4 && args[4] == "extend";
        var settings = new Settings { SendAudio = true, ScreenUse = extend ? ScreenUse.Extend : ScreenUse.Mirror };
        var session = new MirrorSession(parts[0], parts.Length > 1 ? int.Parse(parts[1]) : Packet.DefaultPort, parts[0], settings);
        string? endError = null;
        bool ended = false;
        session.Log += L;
        session.Mirroring += () => L("mirroring");
        session.Ended += err => { endError = err; ended = true; L("ended: " + (err ?? "clean")); };
        session.Start();
        var until = DateTime.Now.AddSeconds(seconds);
        while (DateTime.Now < until && !ended) Thread.Sleep(100);
        session.Stop();
        L($"frames sent: {session.FramesSent}");
        // Extend on a PC without a virtual monitor must end with the "install a driver" signal.
        if (extend && VirtualDisplays.Find() < 0) return endError == NeedsVirtualDisplayException.Marker ? 0 : 1;
        return session.FramesSent > seconds * 10 && (endError == null || endError.Contains("stopped on the TV")) ? 0 : 1;
    }
}
