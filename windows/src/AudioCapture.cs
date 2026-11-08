using System.Diagnostics;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace TVMirror;

/// Captures what the PC is playing (WASAPI loopback) and converts it to 16-bit stereo PCM for the TV.
sealed class AudioCapture : IDisposable
{
    readonly WasapiLoopbackCapture capture;
    readonly long startTicks;
    public int SampleRate => capture.WaveFormat.SampleRate;
    static readonly Guid IeeeFloatSubtype = new("00000003-0000-0010-8000-00aa00389b71");

    /// (pcm s16le stereo, pts µs)
    public event Action<byte[], ulong>? Data;

    public AudioCapture(long startTicks)
    {
        this.startTicks = startTicks;
        capture = new WasapiLoopbackCapture();
        capture.DataAvailable += OnData;
    }

    public void Start() => capture.StartRecording();

    void OnData(object? sender, WaveInEventArgs e)
    {
        if (e.BytesRecorded == 0) return;
        var fmt = capture.WaveFormat;
        int channels = fmt.Channels;
        bool isFloat = fmt.Encoding == WaveFormatEncoding.IeeeFloat
                       || (fmt is WaveFormatExtensible ext && ext.SubFormat == IeeeFloatSubtype);
        int bytesPerSample = fmt.BitsPerSample / 8;
        int frames = e.BytesRecorded / (bytesPerSample * channels);
        var pcm = new byte[frames * 4];
        var src = e.Buffer.AsSpan(0, e.BytesRecorded);
        for (int i = 0; i < frames; i++)
        {
            short l = Sample(src, (i * channels) * bytesPerSample, isFloat, bytesPerSample);
            short r = channels > 1 ? Sample(src, (i * channels + 1) * bytesPerSample, isFloat, bytesPerSample) : l;
            pcm[4 * i] = (byte)l; pcm[4 * i + 1] = (byte)(l >> 8);
            pcm[4 * i + 2] = (byte)r; pcm[4 * i + 3] = (byte)(r >> 8);
        }
        ulong pts = (ulong)((Stopwatch.GetTimestamp() - startTicks) * 1_000_000.0 / Stopwatch.Frequency);
        Data?.Invoke(pcm, pts);
    }

    static short Sample(ReadOnlySpan<byte> s, int offset, bool isFloat, int bytes)
    {
        if (isFloat && bytes == 4)
        {
            float v = BitConverter.ToSingle(s.Slice(offset, 4));
            return (short)(Math.Clamp(v, -1f, 1f) * 32767);
        }
        if (bytes == 2) return BitConverter.ToInt16(s.Slice(offset, 2));
        if (bytes == 3) return (short)(s[offset + 1] | s[offset + 2] << 8);
        if (bytes == 4) return (short)(BitConverter.ToInt32(s.Slice(offset, 4)) >> 16);
        return 0;
    }

    public void Dispose()
    {
        try { capture.StopRecording(); } catch { }
        capture.Dispose();
    }
}

/// Mutes the PC's speakers while mirroring and restores the previous state afterwards.
static class SpeakerMute
{
    static bool? previous;

    public static void Mute()
    {
        try
        {
            using var dev = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            previous ??= dev.AudioEndpointVolume.Mute;
            dev.AudioEndpointVolume.Mute = true;
        }
        catch { }
    }

    public static void Restore()
    {
        if (previous is not bool was) return;
        try
        {
            using var dev = new MMDeviceEnumerator().GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            dev.AudioEndpointVolume.Mute = was;
        }
        catch { }
        previous = null;
    }
}
