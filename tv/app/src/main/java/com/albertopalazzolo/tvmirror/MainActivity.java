package com.albertopalazzolo.tvmirror;

import android.animation.ObjectAnimator;
import android.animation.ValueAnimator;
import android.app.Activity;
import android.graphics.Color;
import android.graphics.Outline;
import android.os.Bundle;
import android.provider.Settings;
import android.view.Gravity;
import android.view.View;
import android.view.ViewOutlineProvider;
import android.widget.FrameLayout;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.TextView;

import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Home screen of the TV app: starts the receiver and shows how to connect. */
public class MainActivity extends Activity {
    private ObjectAnimator pulse;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        MirrorService.start(this);
    }

    @Override
    protected void onResume() {
        super.onResume();
        setContentView(build());
    }

    @Override
    protected void onPause() {
        super.onPause();
        if (pulse != null) pulse.cancel();
    }

    private View build() {
        FrameLayout root = new FrameLayout(this);
        root.setBackground(Ui.background());

        // Centre block: icon on the left, text on the right.
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.ic_launcher);
        final int radius = Ui.dp(this, 40);
        icon.setOutlineProvider(new ViewOutlineProvider() {
            @Override public void getOutline(View v, Outline o) { o.setRoundRect(0, 0, v.getWidth(), v.getHeight(), radius); }
        });
        icon.setClipToOutline(true);
        icon.setElevation(Ui.dp(this, 16));
        LinearLayout.LayoutParams iconLp = new LinearLayout.LayoutParams(Ui.dp(this, 180), Ui.dp(this, 180));
        iconLp.rightMargin = Ui.dp(this, 56);
        row.addView(icon, iconLp);

        LinearLayout col = new LinearLayout(this);
        col.setOrientation(LinearLayout.VERTICAL);

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleRow.addView(Ui.text(this, "TVMirror", 46, Ui.TEXT, true));
        LinearLayout status = new LinearLayout(this);
        status.setGravity(Gravity.CENTER_VERTICAL);
        status.setPadding(Ui.dp(this, 12), Ui.dp(this, 6), Ui.dp(this, 14), Ui.dp(this, 6));
        status.setBackground(Ui.rounded(Color.argb(40, 52, 211, 153), Ui.dp(this, 20)));
        View dot = Ui.dot(this, Ui.READY, 10);
        status.addView(dot, new LinearLayout.LayoutParams(Ui.dp(this, 10), Ui.dp(this, 10)));
        TextView ready = Ui.text(this, "Ready", 15, Ui.READY, true);
        ready.setPadding(Ui.dp(this, 8), 0, 0, 0);
        status.addView(ready);
        LinearLayout.LayoutParams statusLp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        statusLp.leftMargin = Ui.dp(this, 20);
        titleRow.addView(status, statusLp);
        col.addView(titleRow);

        TextView tagline = Ui.text(this, "Your computer, on the big screen", 20, Ui.TEXT_DIM, false);
        tagline.setPadding(0, Ui.dp(this, 10), 0, Ui.dp(this, 28));
        col.addView(tagline);

        // Steps card.
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setPadding(Ui.dp(this, 26), Ui.dp(this, 20), Ui.dp(this, 26), Ui.dp(this, 20));
        card.setBackground(Ui.rounded(Color.argb(22, 255, 255, 255), Ui.dp(this, 20)));
        String name = MirrorService.deviceName(this);
        card.addView(step("1", "On your computer, click the TVMirror icon"));
        card.addView(step("2", "Choose “" + name + "”"));
        card.addView(step("3", "Press Back on the remote to stop"));
        col.addView(card, new LinearLayout.LayoutParams(Ui.dp(this, 470), LinearLayout.LayoutParams.WRAP_CONTENT));

        row.addView(col);
        root.addView(row, new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));

        // Footer.
        List<String> ips = addresses();
        String footer = ips.isEmpty() ? "Not connected to a network"
                : "TV address " + String.join(" · ", ips) + "   —   use “Connect to IP Address…” on your computer if the TV isn't listed";
        TextView foot = Ui.text(this, footer, 13, Ui.TEXT_FAINT, false);
        FrameLayout.LayoutParams footLp = new FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL);
        footLp.bottomMargin = Ui.dp(this, 28);
        root.addView(foot, footLp);

        if (!Settings.canDrawOverlays(this)) {
            TextView warn = Ui.pill(this, "Mirroring opens by itself only while this app is open — see README to allow it from anywhere",
                    Color.argb(50, 251, 191, 36), Color.rgb(251, 211, 106));
            FrameLayout.LayoutParams wLp = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.WRAP_CONTENT, FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.TOP | Gravity.CENTER_HORIZONTAL);
            wLp.topMargin = Ui.dp(this, 28);
            root.addView(warn, wLp);
        }

        pulse = ObjectAnimator.ofFloat(dot, View.ALPHA, 1f, 0.25f);
        pulse.setDuration(1100);
        pulse.setRepeatMode(ValueAnimator.REVERSE);
        pulse.setRepeatCount(ValueAnimator.INFINITE);
        pulse.start();
        return root;
    }

    private View step(String number, String label) {
        LinearLayout r = new LinearLayout(this);
        r.setGravity(Gravity.CENTER_VERTICAL);
        r.setPadding(0, Ui.dp(this, 7), 0, Ui.dp(this, 7));
        TextView n = Ui.text(this, number, 15, Color.WHITE, true);
        n.setGravity(Gravity.CENTER);
        n.setBackground(Ui.rounded(Color.argb(70, 143, 180, 255), Ui.dp(this, 14)));
        r.addView(n, new LinearLayout.LayoutParams(Ui.dp(this, 28), Ui.dp(this, 28)));
        TextView t = Ui.text(this, label, 18, Ui.TEXT, false);
        t.setPadding(Ui.dp(this, 16), 0, 0, 0);
        r.addView(t);
        return r;
    }

    private static List<String> addresses() {
        List<String> out = new ArrayList<>();
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                    if (a instanceof Inet4Address) out.add(a.getHostAddress());
                }
            }
        } catch (Exception ignored) { }
        return out;
    }
}
