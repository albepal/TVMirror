using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;

namespace TVMirror;

enum Quality { P1080, P1440, P2160 }
enum Mode { Responsive, Smooth }
enum ScreenUse { Mirror, Extend }

sealed class Settings
{
    public Quality Quality { get; set; } = Quality.P1080;
    public Mode Mode { get; set; } = Mode.Responsive;          // used when mirroring
    public Mode ModeExtend { get; set; } = Mode.Responsive;    // used when extending (mouse is on the TV)
    public ScreenUse ScreenUse { get; set; } = ScreenUse.Mirror;

    /// The mode for the current screen use (Mirror and Extend remember their own).
    [JsonIgnore]
    public Mode CurrentMode
    {
        get => ScreenUse == ScreenUse.Extend ? ModeExtend : Mode;
        set { if (ScreenUse == ScreenUse.Extend) ModeExtend = value; else Mode = value; }
    }
    public bool SendAudio { get; set; } = true;
    public bool MuteSpeakers { get; set; } = false;
    public int DisplayIndex { get; set; } = 0;
    public string LastManualHost { get; set; } = "";
    public bool WelcomeShown { get; set; } = false;

    static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "TVMirror");
    static readonly string File_ = Path.Combine(Dir, "settings.json");

    public static Settings Load()
    {
        try { return JsonSerializer.Deserialize<Settings>(File.ReadAllText(File_)) ?? new(); }
        catch { return new(); }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(File_, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch { }
    }

    public static string Title(Quality q) => q switch
    {
        Quality.P1080 => "1080p (smoothest on Wi-Fi)",
        Quality.P1440 => "1440p",
        _ => "4K",
    };

    public static int BoxHeight(Quality q) => q switch { Quality.P1080 => 1080, Quality.P1440 => 1440, _ => 2160 };
    public static int Bitrate(Quality q) => q switch { Quality.P1080 => 16_000_000, Quality.P1440 => 28_000_000, _ => 45_000_000 };
    public static string Title(Mode m) => m == Mode.Responsive ? "Responsive (mouse && typing)" : "Smooth (videos, sound in sync)";
    public static string Title(ScreenUse u) => u == ScreenUse.Mirror ? "Mirror Screen" : "Extend Screen (second display)";
    public static int PlayoutDelayMs(Mode m) => m == Mode.Smooth ? 150 : 0;

    /// Fits the screen (keeping its aspect ratio) into a 16:9 box of the chosen height, never upscaling.
    public static (int w, int h) Size(Quality q, int nativeW, int nativeH)
    {
        double box = BoxHeight(q);
        double s = Math.Min(1, Math.Min(box * 16 / 9 / nativeW, box / nativeH));
        static int Even(double v) => Math.Max(2, (int)Math.Round(v) & ~1);
        return (Even(nativeW * s), Even(nativeH * s));
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool StartWithWindows
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue("TVMirror") != null;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue("TVMirror", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("TVMirror", false);
        }
    }
}
