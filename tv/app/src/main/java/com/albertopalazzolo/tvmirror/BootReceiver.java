package com.albertopalazzolo.tvmirror;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Starts the receiver when the TV boots, so computers can find it without opening the app. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        if (Intent.ACTION_BOOT_COMPLETED.equals(intent.getAction())) MirrorService.start(context);
    }
}
