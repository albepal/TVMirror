package com.albertopalazzolo.tvmirror;

import android.media.MediaCodec;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * Hardware decoder that renders straight to the screen surface. Each decoded frame is shown the
 * moment it's ready (no playback clock, no buffering), which is what keeps latency low.
 */
final class VideoDecoder {
    private static final String TAG = "TVMirror";

    interface Callbacks {
        void requestKeyframe();
        void onFirstFrame();
    }

    private final Surface surface;
    private final Callbacks callbacks;
    private final HandlerThread thread = new HandlerThread("tvmirror-decoder", android.os.Process.THREAD_PRIORITY_DISPLAY);
    private final Handler handler;
    private final LinkedBlockingQueue<Integer> freeInputs = new LinkedBlockingQueue<>();

    private MediaCodec codec;
    private byte[] currentConfig;
    private boolean waitingForKeyframe = true;
    private volatile boolean sawFirstFrame;
    // Stats: time from queueing a frame to the decoder handing it back for display.
    private final java.util.concurrent.ConcurrentHashMap<Long, Long> queuedAt = new java.util.concurrent.ConcurrentHashMap<>();
    private double decSum, decMax; private int decCount;

    VideoDecoder(Surface surface, Callbacks callbacks) {
        this.surface = surface;
        this.callbacks = callbacks;
        thread.start();
        handler = new Handler(thread.getLooper());
    }

    /** Called before every keyframe; the codec is only rebuilt when the parameters change. */
    synchronized void configure(String mime, int width, int height, byte[] config) {
        if (codec != null && Arrays.equals(config, currentConfig)) return;
        releaseCodec();
        try {
            codec = create(mime, width, height, config, true);
        } catch (Exception e) {
            Log.w(TAG, "low-latency configure failed, retrying without", e);
            releaseCodec();
            try {
                codec = create(mime, width, height, config, false);
            } catch (Exception e2) {
                Log.e(TAG, "decoder configure failed", e2);
                releaseCodec();
                return;
            }
        }
        currentConfig = config;
        waitingForKeyframe = true;
    }

    private MediaCodec create(String mime, int width, int height, byte[] config, boolean lowLatency) throws Exception {
        MediaFormat format = MediaFormat.createVideoFormat(mime, width, height);
        List<byte[]> nals = splitNals(config);
        if (MediaFormat.MIMETYPE_VIDEO_AVC.equals(mime)) {
            // csd-0 = SPS, csd-1 = PPS
            ByteBuffer sps = null, pps = null;
            for (byte[] nal : nals) {
                int type = nal[4] & 0x1f;
                if (type == 7 && sps == null) sps = ByteBuffer.wrap(nal);
                if (type == 8 && pps == null) pps = ByteBuffer.wrap(nal);
            }
            if (sps != null) format.setByteBuffer("csd-0", sps);
            if (pps != null) format.setByteBuffer("csd-1", pps);
        } else {
            format.setByteBuffer("csd-0", ByteBuffer.wrap(config)); // HEVC: VPS+SPS+PPS together
        }
        format.setInteger(MediaFormat.KEY_PRIORITY, 0); // real-time
        format.setInteger(MediaFormat.KEY_MAX_WIDTH, width);
        format.setInteger(MediaFormat.KEY_MAX_HEIGHT, height);
        if (lowLatency) {
            if (Build.VERSION.SDK_INT >= 30) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1);
            // Vendor switches used by MediaTek / Realtek / Amlogic TV chips; ignored elsewhere.
            format.setInteger("vdec-lowlatency", 1);
            format.setInteger("vendor.low-latency.enable", 1);
            format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1);
        }

        MediaCodec c = MediaCodec.createDecoderByType(mime);
        freeInputs.clear();
        c.setCallback(new MediaCodec.Callback() {
            @Override public void onInputBufferAvailable(MediaCodec mc, int index) {
                if (mc == codec) freeInputs.offer(index);
            }

            @Override public void onOutputBufferAvailable(MediaCodec mc, int index, MediaCodec.BufferInfo info) {
                try {
                    mc.releaseOutputBuffer(index, true); // render now
                    Long t = queuedAt.remove(info.presentationTimeUs);
                    if (t != null) recordDecode((System.nanoTime() - t) / 1e6);
                    if (!sawFirstFrame && info.size >= 0) {
                        sawFirstFrame = true;
                        callbacks.onFirstFrame();
                    }
                } catch (IllegalStateException ignored) { }
            }

            @Override public void onError(MediaCodec mc, MediaCodec.CodecException e) {
                Log.e(TAG, "decoder error", e);
                synchronized (VideoDecoder.this) {
                    if (mc == codec) currentConfig = null; // rebuild on next keyframe
                }
                callbacks.requestKeyframe();
            }

            @Override public void onOutputFormatChanged(MediaCodec mc, MediaFormat f) { }
        }, handler);
        c.configure(format, surface, null, 0);
        c.setVideoScalingMode(MediaCodec.VIDEO_SCALING_MODE_SCALE_TO_FIT);
        c.start();
        return c;
    }

    synchronized void feed(byte[] data, long ptsUs, boolean keyframe) {
        if (codec == null || currentConfig == null) {
            callbacks.requestKeyframe();
            return;
        }
        if (waitingForKeyframe) {
            if (!keyframe) return;
            waitingForKeyframe = false;
        }
        try {
            Integer index = freeInputs.poll(40, TimeUnit.MILLISECONDS);
            if (index == null) {
                // Decoder is stalled; skipping a frame breaks the reference chain, so get a keyframe.
                waitingForKeyframe = true;
                callbacks.requestKeyframe();
                return;
            }
            ByteBuffer buf = codec.getInputBuffer(index);
            if (buf == null || buf.capacity() < data.length) {
                Log.w(TAG, "input buffer too small: " + data.length);
                codec.queueInputBuffer(index, 0, 0, ptsUs, 0);
                waitingForKeyframe = true;
                callbacks.requestKeyframe();
                return;
            }
            buf.clear();
            buf.put(data);
            queuedAt.put(ptsUs, System.nanoTime());
            codec.queueInputBuffer(index, 0, data.length, ptsUs, keyframe ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (IllegalStateException e) {
            Log.w(TAG, "feed failed", e);
            currentConfig = null;
            callbacks.requestKeyframe();
        }
    }

    private void recordDecode(double ms) {
        decSum += ms; decMax = Math.max(decMax, ms); decCount++;
        if (decCount >= 120) {
            Log.i(TAG, String.format("stats decode: avg %.1f ms max %.1f ms", decSum / decCount, decMax));
            decSum = decMax = 0; decCount = 0;
            if (queuedAt.size() > 300) queuedAt.clear();
        }
    }

    synchronized void release() {
        releaseCodec();
        thread.quitSafely();
    }

    private void releaseCodec() {
        MediaCodec c = codec;
        codec = null;
        currentConfig = null;
        freeInputs.clear();
        if (c != null) {
            try { c.stop(); } catch (Exception ignored) { }
            try { c.release(); } catch (Exception ignored) { }
        }
    }

    /** Splits an Annex B buffer into NAL units, each kept with its 4-byte start code. */
    private static List<byte[]> splitNals(byte[] data) {
        List<Integer> starts = new ArrayList<>();
        for (int i = 0; i + 3 < data.length; i++) {
            if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1) {
                starts.add(i);
                i += 3;
            }
        }
        List<byte[]> nals = new ArrayList<>();
        for (int k = 0; k < starts.size(); k++) {
            int from = starts.get(k);
            int to = k + 1 < starts.size() ? starts.get(k + 1) : data.length;
            if (to - from > 4) nals.add(Arrays.copyOfRange(data, from, to));
        }
        return nals;
    }
}
