package com.albertopalazzolo.tvmirror;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.Socket;
import java.nio.charset.StandardCharsets;

/**
 * One connection from a computer (Mac or Windows). Wire format (shared with mac/Sources/TVMirror/Protocol.swift):
 * type (1) | flags (1) | pts µs (8, big endian) | length (4, big endian) | payload.
 */
final class Session {
    static final int HELLO = 0, VIDEO_CONFIG = 1, VIDEO_FRAME = 2, AUDIO = 3, BYE = 4;
    static final int REQUEST_KEYFRAME = 10, ACK = 13;
    static final int FLAG_KEYFRAME = 1;
    private static final int MAX_PACKET = 16 * 1024 * 1024;

    interface Listener {
        void onHello(JSONObject hello);
        void onVideoConfig(byte[] config);
        void onVideoFrame(byte[] frame, long ptsUs, boolean keyframe);
        void onAudio(byte[] pcm);
        /** reason == null for a clean stop. */
        void onClosed(String reason);
    }

    private static Session current;

    static synchronized Session current() { return current; }

    /** A new connection always replaces the previous one, like AirPlay. */
    static synchronized void replace(Session s) {
        if (current != null) current.close();
        current = s;
    }

    private static synchronized void clearIfCurrent(Session s) {
        if (current == s) current = null;
    }

    final String peer;
    private final Socket socket;
    private final DataInputStream in;
    private final OutputStream out;
    private volatile boolean closed;
    private Thread reader;
    private final byte[] header = new byte[14];
    // Stats: arrival time minus send pts (clocks differ, so only the excess over the best case matters).
    // The best case is a minimum over the last 5-10 s, so it follows slow clock drift between computer and TV.
    private long winMin = Long.MAX_VALUE, prevWinMin = Long.MAX_VALUE, winStart, excessSum, excessMax; private int excessCount;
    /** Best-case (arrival time − pts) in µs: maps a frame's sender timestamp to the earliest TV time it can arrive. */
    volatile long offsetUs = Long.MIN_VALUE;

    Session(Socket socket) throws IOException {
        this.socket = socket;
        socket.setTcpNoDelay(true);
        socket.setReceiveBufferSize(1 << 20);
        peer = socket.getInetAddress().getHostAddress();
        in = new DataInputStream(new BufferedInputStream(socket.getInputStream(), 1 << 18));
        out = socket.getOutputStream();
    }

    synchronized void start(Listener listener) {
        if (reader != null) return;
        reader = new Thread(() -> run(listener), "tvmirror-reader");
        reader.setPriority(Thread.MAX_PRIORITY);
        reader.start();
    }

    private void run(Listener l) {
        String reason = null;
        try {
            while (!closed) {
                int type = in.readUnsignedByte();
                int flags = in.readUnsignedByte();
                long pts = in.readLong();
                int len = in.readInt();
                if (len < 0 || len > MAX_PACKET) throw new IOException("bad packet length " + len);
                byte[] payload = new byte[len];
                in.readFully(payload);
                switch (type) {
                    case HELLO:
                        l.onHello(new JSONObject(new String(payload, StandardCharsets.UTF_8)));
                        break;
                    case VIDEO_CONFIG:
                        l.onVideoConfig(payload);
                        break;
                    case VIDEO_FRAME:
                        send(ACK, pts);
                        recordArrival(pts);
                        l.onVideoFrame(payload, pts, (flags & FLAG_KEYFRAME) != 0);
                        break;
                    case AUDIO:
                        l.onAudio(payload);
                        break;
                    case BYE:
                        closed = true;
                        break;
                    default:
                        break; // unknown packet types are skipped for forward compatibility
                }
            }
        } catch (IOException e) {
            if (!closed) reason = "The connection to the computer was lost.";
        } catch (JSONException e) {
            reason = "The computer sent data this app doesn't understand. Update both apps.";
        }
        closeSocket();
        l.onClosed(reason);
    }

    private void recordArrival(long pts) {
        long now = System.nanoTime() / 1000;
        long offset = now - pts;
        if (now - winStart > 5_000_000) { prevWinMin = winMin; winMin = Long.MAX_VALUE; winStart = now; }
        winMin = Math.min(winMin, offset);
        offsetUs = Math.min(winMin, prevWinMin);
        long excess = offset - offsetUs;
        excessSum += excess; excessMax = Math.max(excessMax, excess); excessCount++;
        if (excessCount >= 120) {
            android.util.Log.i("TVMirror", String.format("stats network: extra delay over best case avg %.1f ms max %.1f ms",
                    excessSum / 1000.0 / excessCount, excessMax / 1000.0));
            excessSum = excessMax = 0; excessCount = 0;
        }
    }

    /** Outgoing messages go through one background thread: Android forbids network calls on the UI thread. */
    private final java.util.concurrent.ExecutorService sender = java.util.concurrent.Executors.newSingleThreadExecutor();

    /** Safe to call from any thread. */
    void requestKeyframe() { post(REQUEST_KEYFRAME, 0); }

    private void post(int type, long pts) {
        if (closed) return;
        try { sender.execute(() -> send(type, pts)); } catch (java.util.concurrent.RejectedExecutionException ignored) { }
    }

    /** Writes immediately; only call from a background thread (the reader thread or the sender). */
    private synchronized void send(int type, long pts) {
        if (closed) return;
        try {
            header[0] = (byte) type;
            header[1] = 0;
            for (int i = 0; i < 8; i++) header[2 + i] = (byte) (pts >>> (56 - 8 * i));
            header[10] = header[11] = header[12] = header[13] = 0;
            out.write(header);
            out.flush();
        } catch (IOException ignored) {
            // the reader thread notices the broken socket
        }
    }

    /** Stops the session and tells the computer (it shows "stopped on the TV"). */
    void close() {
        synchronized (this) {
            if (closed) return;
        }
        try {
            sender.execute(() -> {
                send(BYE, 0);
                closeSocket();
            });
        } catch (java.util.concurrent.RejectedExecutionException e) {
            closeSocket();
        }
        sender.shutdown();
    }

    private void closeSocket() {
        closed = true;
        sender.shutdown();
        clearIfCurrent(this);
        try { socket.close(); } catch (IOException ignored) { }
    }
}
