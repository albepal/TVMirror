using System.Drawing;
using System.Reflection;
using Zeroconf;

namespace TVMirror;

/// The notification-area icon and its menu: the Windows counterpart of the Mac menu-bar app.
sealed class TrayApp : ApplicationContext
{
    record Tv(string Name, string Host, int Port);

    readonly NotifyIcon icon;
    readonly ContextMenuStrip menu = new();
    readonly Settings settings = Settings.Load();
    readonly SynchronizationContext ui;
    readonly System.Threading.Timer discoveryTimer;
    List<Tv> tvs = new();
    MirrorSession? session;
    (string host, int port, string name)? lastTarget;
    string state = "idle"; // idle | connecting | mirroring
    readonly Icon idleIcon, activeIcon;

    public TrayApp()
    {
        ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
        using (var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("app.ico")!)
            idleIcon = new Icon(s, SystemInformation.SmallIconSize);
        activeIcon = idleIcon;
        icon = new NotifyIcon { Icon = idleIcon, Text = "TVMirror", Visible = true, ContextMenuStrip = menu };
        menu.Opening += (_, e) => { Build(); e.Cancel = false; };
        icon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
                typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(icon, null);
        };
        discoveryTimer = new System.Threading.Timer(_ => Discover(), null, 0, 8000);
        Application.ApplicationExit += (_, _) => { session?.Stop(); SpeakerMute.Restore(); icon.Visible = false; };
    }

    async void Discover()
    {
        try
        {
            var hosts = await ZeroconfResolver.ResolveAsync(Packet.ServiceType, TimeSpan.FromSeconds(2));
            var found = new List<Tv>();
            foreach (var h in hosts)
            {
                var svc = h.Services.Values.FirstOrDefault();
                found.Add(new Tv(h.DisplayName, h.IPAddress, svc?.Port ?? Packet.DefaultPort));
            }
            ui.Post(_ => tvs = found.OrderBy(t => t.Name).ToList(), null);
        }
        catch { }
    }

    void Build()
    {
        menu.Items.Clear();
        switch (state)
        {
            case "idle":
                menu.Items.Add(Header("Mirror to"));
                if (tvs.Count == 0) menu.Items.Add(new ToolStripMenuItem("Looking for TVs… (open TVMirror on the TV)") { Enabled = false });
                foreach (var tv in tvs)
                {
                    var t = tv;
                    menu.Items.Add(new ToolStripMenuItem(tv.Name, null, (_, _) => Connect(t.Host, t.Port, t.Name)));
                }
                menu.Items.Add(new ToolStripMenuItem("Connect to IP Address…", null, (_, _) => ConnectManually()));
                break;
            case "connecting":
                menu.Items.Add(Header($"Connecting to {session?.Name}…"));
                menu.Items.Add(new ToolStripMenuItem("Cancel", null, (_, _) => session?.Stop()));
                break;
            default:
                menu.Items.Add(Header($"Mirroring to {session?.Name}"));
                menu.Items.Add(new ToolStripMenuItem("Stop Mirroring", null, (_, _) => session?.Stop()));
                break;
        }
        menu.Items.Add(new ToolStripSeparator());

        foreach (var m in Enum.GetValues<Mode>())
        {
            var mode = m;
            menu.Items.Add(new ToolStripMenuItem(Settings.Title(m), null, (_, _) => { settings.Mode = mode; Changed(); })
            { Checked = settings.Mode == m });
        }
        menu.Items.Add(new ToolStripSeparator());

        var screens = Screen.AllScreens;
        if (screens.Length > 1)
        {
            var display = new ToolStripMenuItem("Display");
            for (int i = 0; i < screens.Length; i++)
            {
                int idx = i;
                var b = screens[i].Bounds;
                display.DropDownItems.Add(new ToolStripMenuItem($"Display {i + 1} ({b.Width}×{b.Height}){(screens[i].Primary ? " – main" : "")}",
                    null, (_, _) => { settings.DisplayIndex = idx; Changed(); }) { Checked = settings.DisplayIndex == i });
            }
            menu.Items.Add(display);
        }

        var quality = new ToolStripMenuItem("Quality");
        foreach (var q in Enum.GetValues<Quality>())
        {
            var qq = q;
            quality.DropDownItems.Add(new ToolStripMenuItem(Settings.Title(q), null, (_, _) => { settings.Quality = qq; Changed(); })
            { Checked = settings.Quality == q });
        }
        menu.Items.Add(quality);

        menu.Items.Add(new ToolStripMenuItem("Play Sound on TV", null, (_, _) => { settings.SendAudio = !settings.SendAudio; Changed(); })
        { Checked = settings.SendAudio });
        menu.Items.Add(new ToolStripMenuItem("Mute PC Speakers While Mirroring", null, (_, _) => { settings.MuteSpeakers = !settings.MuteSpeakers; Changed(); })
        { Checked = settings.MuteSpeakers, Enabled = settings.SendAudio });

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Start with Windows", null, (_, _) => Settings.StartWithWindows = !Settings.StartWithWindows)
        { Checked = Settings.StartWithWindows });
        menu.Items.Add(new ToolStripMenuItem("Quit TVMirror", null, (_, _) => { session?.Stop(); Application.Exit(); }));
    }

    static ToolStripMenuItem Header(string text) =>
        new(text) { Enabled = false, Font = new Font(SystemFonts.MenuFont ?? Control.DefaultFont, FontStyle.Bold) };

    void ConnectManually()
    {
        using var form = new Form { Text = "Connect to IP Address", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false,
                                    MinimizeBox = false, StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size(360, 120),
                                    Icon = idleIcon, TopMost = true };
        var label = new Label { Text = "Enter the TV's address, as shown in the TVMirror app on the TV:", Left = 12, Top = 12, Width = 336 };
        var box = new TextBox { Left = 12, Top = 40, Width = 336, Text = settings.LastManualHost, PlaceholderText = "192.168.1.50" };
        var ok = new Button { Text = "Connect", Left = 192, Top = 78, Width = 75, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", Left = 273, Top = 78, Width = 75, DialogResult = DialogResult.Cancel };
        form.Controls.AddRange(new Control[] { label, box, ok, cancel });
        form.AcceptButton = ok; form.CancelButton = cancel;
        if (form.ShowDialog() != DialogResult.OK) return;
        var text = box.Text.Trim();
        if (text.Length == 0) return;
        int port = Packet.DefaultPort;
        var host = text;
        var colon = text.LastIndexOf(':');
        if (colon > 0 && int.TryParse(text[(colon + 1)..], out var p)) { port = p; host = text[..colon]; }
        settings.LastManualHost = text;
        settings.Save();
        Connect(host, port, host);
    }

    void Connect(string host, int port, string name)
    {
        session?.Stop();
        var s = new MirrorSession(host, port, name, settings);
        session = s;
        lastTarget = (host, port, name);
        SetState("connecting");
        s.Mirroring += () => ui.Post(_ => { if (session == s) SetState("mirroring"); }, null);
        s.Ended += err => ui.Post(_ =>
        {
            if (session != s) return;
            session = null;
            SetState("idle");
            if (err != null) icon.ShowBalloonTip(5000, "TVMirror", err, ToolTipIcon.Info);
        }, null);
        s.Start();
    }

    /// Settings apply immediately: an active session restarts with them.
    void Changed()
    {
        settings.Save();
        if (session != null && lastTarget is { } t) Connect(t.host, t.port, t.name);
    }

    void SetState(string s)
    {
        state = s;
        icon.Icon = s == "idle" ? idleIcon : activeIcon;
        icon.Text = s switch
        {
            "connecting" => $"TVMirror – connecting to {session?.Name}",
            "mirroring" => $"TVMirror – mirroring to {session?.Name}",
            _ => "TVMirror",
        };
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { discoveryTimer.Dispose(); icon.Dispose(); menu.Dispose(); }
        base.Dispose(disposing);
    }
}
