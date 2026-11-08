package com.albertopalazzolo.tvmirror;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Outline;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.WindowManager;
import android.view.ViewOutlineProvider;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONObject;

/** Full-screen video. One activity instance per connection; Back stops mirroring. */
public class MirrorActivity extends Activity implements SurfaceHolder.Callback, Session.Listener {
    private FrameLayout root;
    private SurfaceView surfaceView;
    private TextView status;
    private View splash;
    private TextView hint;
    private volatile String peerName = "your computer";

    private Session session;
    private VideoDecoder decoder;
    private final AudioPlayer audio = new AudioPlayer();
    /** Smooth mode: frames are held back this long (beyond the best-case arrival) to hide Wi-Fi pauses. */
    private volatile long playoutDelayUs;
    private final java.util.concurrent.LinkedBlockingQueue<Object[]> pending = new java.util.concurrent.LinkedBlockingQueue<>();
    private Thread scheduler;
    private WifiManager.WifiLock wifiLock;

    private volatile String mime = "video/avc";
    private volatile int videoWidth, videoHeight;
    private volatile boolean ended;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        session = Session.current();
        if (session == null) { finish(); return; }

        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON | WindowManager.LayoutParams.FLAG_FULLSCREEN);
        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        surfaceView = new SurfaceView(this);
        root.addView(surfaceView, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT, Gravity.CENTER));
        // Splash shown until the first frame arrives, in the same style as the home screen.
        LinearLayout splashBox = new LinearLayout(this);
        splashBox.setOrientation(LinearLayout.VERTICAL);
        splashBox.setGravity(Gravity.CENTER);
        splashBox.setBackground(Ui.background());
        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.ic_launcher);
        final int radius = Ui.dp(this, 30);
        icon.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View v, Outline o) { o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), radius); }
        });
        icon.setClipToOutline(true);
        splashBox.addView(icon, new LinearLayout.LayoutParams(Ui.dp(this, 130), Ui.dp(this, 130)));
        status = Ui.text(this, "Connecting…", 24, Ui.TEXT, true);
        status.setPadding(0, Ui.dp(this, 28), 0, Ui.dp(this, 8));
        splashBox.addView(status);
        splashBox.addView(Ui.text(this, "from " + session.peer, 16, Ui.TEXT_DIM, false));
        splash = splashBox;
        root.addView(splash, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT));

        // "Mirroring from …" pill, shown briefly once the picture appears.
        hint = Ui.pill(this, "", Color.argb(170, 15, 20, 50), Color.WHITE);
        hint.setAlpha(0f);
        FrameLayout.LayoutParams hintLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
        hintLp.topMargin = Ui.dp(this, 24);
        root.addView(hint, hintLp);
        setContentView(root);
        root.setSystemUiVisibility(View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                | View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        surfaceView.getHolder().addCallback(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifi != null && wifiLock == null) {
            // Turns off Wi-Fi power saving while visible: the single biggest latency win on Wi-Fi.
            int mode = Build.VERSION.SDK_INT >= 29 ? WifiManager.WIFI_MODE_FULL_LOW_LATENCY : WifiManager.WIFI_MODE_FULL_HIGH_PERF;
            wifiLock = wifi.createWifiLock(mode, "tvmirror");
            wifiLock.acquire();
        }
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (wifiLock != null) { wifiLock.release(); wifiLock = null; }
    }

    @Override
    protected void onStop() {
        super.onStop();
        endSession(false); // Home or another app: stop mirroring and let that screen show
    }

    @Override
    public void onBackPressed() {
        endSession(true);
    }

    /**
     * Leaves the video screen at once (optionally landing on TVMirror's home screen), then tears down
     * the connection, sound and decoder in the background: releasing the hardware decoder can take a
     * moment on TV chips, and the last frame shouldn't linger meanwhile.
     */
    private void endSession(boolean goHome) {
        if (ended) return;
        ended = true;
        if (goHome) {
            startActivity(new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                    | Intent.FLAG_ACTIVITY_CLEAR_TOP | Intent.FLAG_ACTIVITY_SINGLE_TOP | Intent.FLAG_ACTIVITY_NO_ANIMATION));
        }
        if (!isFinishing()) {
            finish();
            overridePendingTransition(0, 0);
        }
        final Session s = session;
        final Thread sch = scheduler;
        final VideoDecoder d = decoder;
        new Thread(() -> {
            if (s != null) s.close();
            if (sch != null) sch.interrupt();
            audio.stop();
            if (d != null) d.release();
        }, "tvmirror-teardown").start();
    }

    // MARK: Surface

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        if (ended || decoder != null) return;
        final Session s = session;
        decoder = new VideoDecoder(holder.getSurface(), new VideoDecoder.Callbacks() {
            @Override public void requestKeyframe() { s.requestKeyframe(); }
            @Override public void onFirstFrame() { runOnUiThread(MirrorActivity.this::showPicture); }
        });
        s.start(this);
        s.requestKeyframe();
    }

    @Override public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) { }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        endSession(false);
    }

    // MARK: Session.Listener (reader thread)

    @Override
    public void onHello(JSONObject hello) {
        playoutDelayUs = hello.optInt("playoutDelayMs", 0) * 1000L;
        if (playoutDelayUs > 0 && scheduler == null) {
            scheduler = new Thread(this::runScheduler, "tvmirror-playout");
            scheduler.setPriority(Thread.MAX_PRIORITY);
            scheduler.start();
        }
        videoWidth = hello.optInt("width", 1920);
        videoHeight = hello.optInt("height", 1080);
        mime = "hevc".equals(hello.optString("codec")) ? "video/hevc" : "video/avc";
        final String name = hello.optString("name", "your computer");
        if (hello.optBoolean("audio", false)) {
            audio.start(hello.optInt("sampleRate", 48000), hello.optInt("channels", 2), hello.optInt("playoutDelayMs", 0) > 0);
        }
        runOnUiThread(() -> {
            peerName = name;
            status.setText("Connecting to " + name + "…");
            fitVideo();
        });
    }

    @Override
    public void onVideoConfig(byte[] config) {
        VideoDecoder d = decoder;
        if (d != null && videoWidth > 0) d.configure(mime, videoWidth, videoHeight, config);
    }

    @Override
    public void onVideoFrame(byte[] frame, long ptsUs, boolean keyframe) {
        if (playoutDelayUs > 0) {
            pending.offer(new Object[]{frame, ptsUs, keyframe});
            return;
        }
        VideoDecoder d = decoder;
        if (d != null) d.feed(frame, ptsUs, keyframe);
    }

    @Override
    public void onAudio(byte[] pcm) {
        audio.write(pcm);
    }

    @Override
    public void onClosed(String reason) {
        runOnUiThread(() -> {
            if (reason != null && !ended) Toast.makeText(this, reason, Toast.LENGTH_LONG).show();
            endSession(true); // stopped from the computer: back to TVMirror's home screen
        });
    }

    /** Smooth mode: feeds each frame to the decoder at a steady delay after its best-case arrival time. */
    private void runScheduler() {
        final long decodeAllowanceUs = 12_000;
        try {
            while (!ended) {
                Object[] f = pending.take();
                long pts = (Long) f[1];
                long offset = session.offsetUs;
                if (offset != Long.MIN_VALUE) {
                    long waitUs = pts + offset + playoutDelayUs - decodeAllowanceUs - System.nanoTime() / 1000;
                    if (waitUs > 0) Thread.sleep(Math.min(waitUs, 500_000) / 1000, (int) (Math.min(waitUs, 500_000) % 1000) * 1000);
                }
                VideoDecoder d = decoder;
                if (d != null) d.feed((byte[]) f[0], pts, (Boolean) f[2]);
            }
        } catch (InterruptedException ignored) { }
    }

    /** Fades the splash away and briefly shows who is mirroring. */
    private void showPicture() {
        splash.animate().alpha(0f).setDuration(350).withEndAction(() -> splash.setVisibility(View.GONE)).start();
        hint.setText("Mirroring from " + peerName + "  ·  Press Back to stop");
        hint.animate().alpha(1f).setStartDelay(300).setDuration(300).withEndAction(() ->
                hint.animate().alpha(0f).setStartDelay(3500).setDuration(600).start()).start();
    }

    /** Letterboxes the video to its own aspect ratio (e.g. a 16:10 laptop screen on a 16:9 TV). */
    private void fitVideo() {
        int w = root.getWidth(), h = root.getHeight();
        if (w == 0 || h == 0 || videoWidth == 0) {
            root.post(this::fitVideo);
            return;
        }
        float scale = Math.min((float) w / videoWidth, (float) h / videoHeight);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                Math.round(videoWidth * scale), Math.round(videoHeight * scale), Gravity.CENTER);
        surfaceView.setLayoutParams(lp);
    }
}
