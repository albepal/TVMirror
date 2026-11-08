using System.Drawing;

namespace TVMirror;

/// First-run guide for Windows: install the TV app, then pick the TV. Re-opened from "Setup Guide…".
sealed class WelcomeForm : Form
{
    public const string TvAppUrl = "github.com/albepal/TVMirror/releases/latest/download/TVMirror-tv.apk";

    readonly Func<IReadOnlyList<(string Name, string Host, int Port)>> tvs;
    readonly Action<(string Name, string Host, int Port)> connect;
    readonly Label tvStatus = new() { AutoSize = true };
    readonly Button mirror = new() { AutoSize = true, Visible = false };
    readonly System.Windows.Forms.Timer timer = new() { Interval = 1000 };

    public WelcomeForm(Icon icon, Func<IReadOnlyList<(string Name, string Host, int Port)>> tvs, Action<(string Name, string Host, int Port)> connect)
    {
        this.tvs = tvs;
        this.connect = connect;
        Text = "Welcome to TVMirror";
        Icon = icon;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        Font = new Font("Segoe UI", 10f);
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(20);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        Controls.Add(layout);

        layout.Controls.Add(new Label { Text = "Mirror your PC to your TV", AutoSize = true, Font = new Font("Segoe UI Semibold", 15f) });
        layout.Controls.Add(new Label { Text = "Two quick steps. You only do this once.", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(3, 0, 3, 14) });

        layout.Controls.Add(Heading("1   Install TVMirror on your TV"));
        layout.Controls.Add(Body("On the TV, install the free app “Downloader” from Google Play. Open it, type this address and install:"));
        var urlRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        var url = new TextBox { Text = TvAppUrl, ReadOnly = true, Width = 470, Font = new Font("Consolas", 9.5f) };
        var copy = new Button { Text = "Copy", AutoSize = true };
        copy.Click += (_, _) => Clipboard.SetText(TvAppUrl);
        urlRow.Controls.Add(url);
        urlRow.Controls.Add(copy);
        layout.Controls.Add(urlRow);
        layout.Controls.Add(Body("Then open TVMirror on the TV. (If the TV asks, allow Downloader to install apps.)", gray: true));

        layout.Controls.Add(Heading("2   Pick your TV"));
        var tvRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false };
        tvStatus.Margin = new Padding(3, 8, 10, 3);
        tvRow.Controls.Add(tvStatus);
        tvRow.Controls.Add(mirror);
        layout.Controls.Add(tvRow);
        layout.Controls.Add(Body("Later, use the TVMirror icon next to the clock. Press Back on the TV remote to stop.", gray: true));

        mirror.Click += (_, _) =>
        {
            var list = this.tvs();
            if (list.Count == 0) return;
            Close();
            this.connect(list[0]);
        };
        AcceptButton = mirror;
        timer.Tick += (_, _) => Refresh_();
        timer.Start();
        FormClosed += (_, _) => timer.Dispose();
        Refresh_();
    }

    void Refresh_()
    {
        var list = tvs();
        if (list.Count > 0)
        {
            tvStatus.Text = list.Count == 1 ? $"✔  Found “{list[0].Name}”" : $"✔  Found {list.Count} TVs";
            mirror.Text = $"Mirror to {list[0].Name}";
            mirror.Visible = true;
        }
        else
        {
            tvStatus.Text = "Looking for TVs… open TVMirror on the TV (same Wi-Fi).";
            mirror.Visible = false;
        }
    }

    static Label Heading(string t) => new() { Text = t, AutoSize = true, Font = new Font("Segoe UI Semibold", 11f), Margin = new Padding(3, 10, 3, 4) };

    static Label Body(string t, bool gray = false) => new()
    {
        Text = t, AutoSize = true, MaximumSize = new Size(560, 0),
        ForeColor = gray ? SystemColors.GrayText : SystemColors.ControlText,
    };
}
