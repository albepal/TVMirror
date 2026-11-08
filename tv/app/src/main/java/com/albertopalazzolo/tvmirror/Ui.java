package com.albertopalazzolo.tvmirror;

import android.content.Context;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.widget.TextView;

/** Shared look for the TV screens: colours match the app icon (blue → violet on deep navy). */
final class Ui {
    static final int TEXT = Color.WHITE;
    static final int TEXT_DIM = Color.argb(178, 255, 255, 255);
    static final int TEXT_FAINT = Color.argb(115, 255, 255, 255);
    static final int ACCENT = Color.rgb(0x8F, 0xB4, 0xFF);
    static final int READY = Color.rgb(0x34, 0xD3, 0x99);

    private Ui() { }

    static int dp(Context c, float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, c.getResources().getDisplayMetrics()));
    }

    static GradientDrawable background() {
        GradientDrawable g = new GradientDrawable(GradientDrawable.Orientation.TL_BR,
                new int[]{Color.rgb(0x0B, 0x12, 0x33), Color.rgb(0x15, 0x14, 0x45), Color.rgb(0x2A, 0x14, 0x5C)});
        return g;
    }

    static GradientDrawable rounded(int color, float radiusPx) {
        GradientDrawable g = new GradientDrawable();
        g.setColor(color);
        g.setCornerRadius(radiusPx);
        return g;
    }

    static TextView text(Context c, String s, float sp, int color, boolean bold) {
        TextView t = new TextView(c);
        t.setText(s);
        t.setTextSize(sp);
        t.setTextColor(color);
        t.setTypeface(Typeface.create(bold ? "sans-serif-medium" : "sans-serif", bold ? Typeface.BOLD : Typeface.NORMAL));
        t.setIncludeFontPadding(false);
        return t;
    }

    static View dot(Context c, int color, int sizeDp) {
        View v = new View(c);
        GradientDrawable g = new GradientDrawable();
        g.setShape(GradientDrawable.OVAL);
        g.setColor(color);
        v.setBackground(g);
        v.setMinimumWidth(dp(c, sizeDp));
        v.setMinimumHeight(dp(c, sizeDp));
        return v;
    }

    /** A pill-shaped label, e.g. the "Ready" status. */
    static TextView pill(Context c, String s, int bg, int fg) {
        TextView t = text(c, s, 15, fg, true);
        t.setGravity(Gravity.CENTER_VERTICAL);
        t.setPadding(dp(c, 14), dp(c, 7), dp(c, 14), dp(c, 7));
        t.setBackground(rounded(bg, dp(c, 20)));
        return t;
    }
}
