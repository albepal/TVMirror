package com.albertopalazzolo.tvmirror;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.util.Log;

/**
 * Plays the Mac's sound. The amount of sound waiting in the buffer is capped: when the Mac's clock
 * runs slightly faster than the TV's, or the network delivers a burst, the excess is dropped instead
 * of turning into permanent delay.
 */
final class AudioPlayer {
    private static final String TAG = "TVMirror";
    private AudioTrack track;
    private int bytesPerFrame, sampleRate;
    private long framesWritten;
    private int maxQueuedFrames, targetMinFrames, windowMin;
    private long windowStart;
    private boolean trimNext;
    // stats
    private long queuedSum; private int queuedMax, writes, drops, chunkFrames;
    private long lastStats;

    synchronized void start(int sampleRate, int channels, boolean smooth) {
        stop();
        this.sampleRate = sampleRate;
        int channelMask = channels == 1 ? AudioFormat.CHANNEL_OUT_MONO : AudioFormat.CHANNEL_OUT_STEREO;
        bytesPerFrame = 2 * channels;
        int min = AudioTrack.getMinBufferSize(sampleRate, channelMask, AudioFormat.ENCODING_PCM_16BIT);
        track = new AudioTrack.Builder()
                .setAudioAttributes(new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_GAME) // games get the shortest output path on most TVs
                        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                        .build())
                .setAudioFormat(new AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(channelMask)
                        .build())
                .setBufferSizeInBytes(Math.max(min, sampleRate * bytesPerFrame * 60 / 1000))
                .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build();
        maxQueuedFrames = sampleRate * 150 / 1000; // hard cap after a long Wi-Fi stall
        // Lowest point the buffer should reach each second. Smooth mode keeps a bigger cushion so Wi-Fi
        // pauses don't cause gaps; the extra delay matches the delayed picture.
        targetMinFrames = sampleRate * (smooth ? 60 : 10) / 1000;
        windowMin = Integer.MAX_VALUE;
        windowStart = System.nanoTime();
        trimNext = false;
        framesWritten = 0;
        lastStats = System.nanoTime();
        track.play();
        Log.i(TAG, "audio track: min buffer " + min / bytesPerFrame + " frames, buffer "
                + track.getBufferSizeInFrames() + " frames, fast=" + (track.getPerformanceMode() == AudioTrack.PERFORMANCE_MODE_LOW_LATENCY));
    }

    synchronized void write(byte[] pcm) {
        if (track == null) return;
        long head = track.getPlaybackHeadPosition() & 0xffffffffL;
        int queued = (int) ((framesWritten - head) & 0xffffffffL);
        if (queued > 1 << 30) queued = 0; // head briefly ahead after an underrun
        chunkFrames = pcm.length / bytesPerFrame;
        queuedSum += queued; queuedMax = Math.max(queuedMax, queued); writes++;
        // Adaptive jitter buffer: if the buffer never ran low during the last second, the cushion is
        // bigger than the network needs, so skip one chunk to shave off delay.
        windowMin = Math.min(windowMin, queued);
        long now0 = System.nanoTime();
        if (now0 - windowStart > 1_000_000_000L) {
            if (windowMin > targetMinFrames + chunkFrames) trimNext = true;
            windowMin = Integer.MAX_VALUE;
            windowStart = now0;
        }
        if (queued > maxQueuedFrames || trimNext) {
            trimNext = false;
            drops++;
        } else {
            int n = track.write(pcm, 0, pcm.length, AudioTrack.WRITE_NON_BLOCKING);
            if (n > 0) framesWritten += n / bytesPerFrame;
        }
        long now = System.nanoTime();
        if (now - lastStats > 2_000_000_000L && writes > 0) {
            Log.i(TAG, String.format("stats audio: queued avg %.1f ms max %.1f ms, chunk %.1f ms, %d drops, %d underruns, output latency %s ms",
                    queuedSum * 1000.0 / sampleRate / writes, queuedMax * 1000.0 / sampleRate, chunkFrames * 1000.0 / sampleRate,
                    drops, track.getUnderrunCount(), outputLatency()));
            queuedSum = 0; queuedMax = 0; writes = 0; drops = 0; lastStats = now;
        }
    }

    /** AudioTrack.getLatency() is hidden but present on most builds; it includes the TV's audio pipeline. */
    private String outputLatency() {
        try {
            return String.valueOf(AudioTrack.class.getMethod("getLatency").invoke(track));
        } catch (Exception e) {
            return "?";
        }
    }

    synchronized void stop() {
        if (track == null) return;
        try {
            track.pause();
            track.flush();
            track.release();
        } catch (Exception ignored) { }
        track = null;
    }
}
