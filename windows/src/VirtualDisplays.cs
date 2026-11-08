using System.Runtime.InteropServices;

namespace TVMirror;

/// Finds a virtual monitor to extend onto. Windows can't create one by itself; a virtual display
/// driver (e.g. the free, open-source Virtual Display Driver) adds it, and it then shows up as a
/// normal monitor whose adapter name says "Virtual" / "Indirect" / "IddCx".
static class VirtualDisplays
{
    public const string DriverUrl = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/latest";

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplayDevices(string? device, uint index, ref DISPLAY_DEVICE dd, uint flags);

    static readonly string[] Markers = { "virtual", "indirect", "iddcx", "idd " };

    /// Index into Screen.AllScreens of the first virtual monitor, or -1.
    public static int Find()
    {
        var screens = Screen.AllScreens;
        for (uint i = 0; ; i++)
        {
            var dd = new DISPLAY_DEVICE { cb = Marshal.SizeOf<DISPLAY_DEVICE>() };
            if (!EnumDisplayDevices(null, i, ref dd, 0)) break;
            var desc = (dd.DeviceString ?? "").ToLowerInvariant();
            if (!Markers.Any(desc.Contains)) continue;
            for (int s = 0; s < screens.Length; s++)
                if (string.Equals(screens[s].DeviceName, dd.DeviceName, StringComparison.OrdinalIgnoreCase)) return s;
        }
        return -1;
    }
}
