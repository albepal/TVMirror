using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace TVMirror;

/// Wire format shared with the TV app and the Mac app:
/// type (1) | flags (1) | pts µs (8, big endian) | length (4, big endian) | payload.
static class Packet
{
    public const byte Hello = 0, VideoConfig = 1, VideoFrame = 2, Audio = 3, Bye = 4;
    public const byte RequestKeyframe = 10, Ack = 13;
    public const byte FlagKeyframe = 1;
    public const int HeaderSize = 14;
    public const int DefaultPort = 47800;
    public const string ServiceType = "_tvmirror._tcp.local.";

    public static byte[] Make(byte type, byte flags, ulong pts, ReadOnlySpan<byte> payload)
    {
        var b = new byte[HeaderSize + payload.Length];
        b[0] = type;
        b[1] = flags;
        BinaryPrimitives.WriteUInt64BigEndian(b.AsSpan(2), pts);
        BinaryPrimitives.WriteUInt32BigEndian(b.AsSpan(10), (uint)payload.Length);
        payload.CopyTo(b.AsSpan(HeaderSize));
        return b;
    }
}

/// TCP link to the TV. Video is flow-controlled by the TV's acks: when too many frames are in flight
/// (a Wi-Fi pause), frames are dropped until the next keyframe instead of building up delay.
sealed class StreamConnection : IDisposable
{
    const int MaxUnacked = 8;

    readonly TcpClient client = new();
    NetworkStream? stream;
    readonly BlockingCollection<byte[]> outbox = new(new ConcurrentQueue<byte[]>(), 600);
    readonly object gate = new();
    int unacked;
    bool needKeyframe;
    volatile bool closed;

    // stats
    readonly Dictionary<ulong, long> sentAt = new();
    double rttSum, rttMax; int rttCount, dropped;
    long lastStats = Stopwatch.GetTimestamp();

    public event Action<string?>? Closed;   // null = clean stop
    public event Action? KeyframeRequested;
    public event Action<string>? Log;

    public void Connect(string host, int port, TimeSpan timeout)
    {
        client.NoDelay = true;
        client.SendBufferSize = 512 * 1024;
        var task = client.ConnectAsync(host, port);
        if (!task.Wait(timeout)) throw new TimeoutException($"Couldn't reach {host}.");
        if (task.IsFaulted) throw task.Exception!.InnerException ?? task.Exception;
        stream = client.GetStream();
        new Thread(WriterLoop) { IsBackground = true, Name = "tvmirror-send", Priority = ThreadPriority.AboveNormal }.Start();
        new Thread(ReaderLoop) { IsBackground = true, Name = "tvmirror-recv" }.Start();
    }

    public void SendHello(object hello)
    {
        Enqueue(Packet.Make(Packet.Hello, 0, 0, Encoding.UTF8.GetBytes(JsonSerializer.Serialize(hello))));
    }

    /// `config` is non-null on keyframes; it travels together with the frame.
    public void SendVideo(byte[] frame, byte[]? config, bool keyframe, ulong pts)
    {
        lock (gate)
        {
            if (closed) return;
            if (unacked >= MaxUnacked)
            {
                dropped++;
                needKeyframe = true;
                KeyframeRequested?.Invoke();
                return;
            }
            if (needKeyframe)
            {
                if (!keyframe) return;
                needKeyframe = false;
            }
            if (config != null) Enqueue(Packet.Make(Packet.VideoConfig, 0, 0, config));
            Enqueue(Packet.Make(Packet.VideoFrame, keyframe ? Packet.FlagKeyframe : (byte)0, pts, frame));
            sentAt[pts] = Stopwatch.GetTimestamp();
            unacked++;
        }
    }

    public void SendAudio(byte[] pcm, ulong pts)
    {
        lock (gate) { if (closed || unacked >= MaxUnacked * 2) return; }
        Enqueue(Packet.Make(Packet.Audio, 0, pts, pcm));
    }

    void Enqueue(byte[] packet)
    {
        if (closed) return;
        try { outbox.TryAdd(packet); } catch (InvalidOperationException) { }
    }

    void WriterLoop()
    {
        try
        {
            foreach (var p in outbox.GetConsumingEnumerable())
                stream!.Write(p, 0, p.Length);
        }
        catch (Exception e) when (e is IOException or ObjectDisposedException or InvalidOperationException)
        {
            Finish(closed ? null : "The connection to the TV was lost.");
        }
    }

    void ReaderLoop()
    {
        var header = new byte[Packet.HeaderSize];
        try
        {
            while (!closed)
            {
                stream!.ReadExactly(header);
                ulong pts = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(2));
                int len = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(10));
                if (len > 0) stream.ReadExactly(new byte[len]);
                switch (header[0])
                {
                    case Packet.Ack: OnAck(pts); break;
                    case Packet.RequestKeyframe: KeyframeRequested?.Invoke(); break;
                    case Packet.Bye: Finish("Mirroring was stopped on the TV."); return;
                }
            }
        }
        catch (Exception e) when (e is IOException or EndOfStreamException or ObjectDisposedException or InvalidOperationException)
        {
            Finish(closed ? null : "The TV closed the connection.");
        }
    }

    void OnAck(ulong pts)
    {
        lock (gate)
        {
            unacked = Math.Max(0, unacked - 1);
            long now = Stopwatch.GetTimestamp();
            if (sentAt.Remove(pts, out long sent))
            {
                double ms = (now - sent) * 1000.0 / Stopwatch.Frequency;
                rttSum += ms; rttMax = Math.Max(rttMax, ms); rttCount++;
            }
            if ((now - lastStats) > 2 * Stopwatch.Frequency && rttCount > 0)
            {
                Log?.Invoke($"net: ack rtt avg {rttSum / rttCount:F1} ms max {rttMax:F1} ms, {rttCount} frames, {dropped} dropped");
                rttSum = rttMax = 0; rttCount = 0; dropped = 0; lastStats = now;
                if (sentAt.Count > 500) sentAt.Clear();
            }
        }
    }

    /// Stops the stream; `sayBye` tells the TV to close its screen.
    public void Close(bool sayBye)
    {
        if (closed) return;
        if (sayBye && stream != null)
        {
            try { stream.Write(Packet.Make(Packet.Bye, 0, 0, ReadOnlySpan<byte>.Empty)); } catch { }
        }
        Finish(null);
    }

    void Finish(string? error)
    {
        lock (gate)
        {
            if (closed) return;
            closed = true;
        }
        outbox.CompleteAdding();
        try { client.Close(); } catch { }
        Closed?.Invoke(error);
    }

    public void Dispose() => Close(false);
}
