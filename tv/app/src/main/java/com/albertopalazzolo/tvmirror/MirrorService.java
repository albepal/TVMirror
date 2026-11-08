package com.albertopalazzolo.tvmirror;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.provider.Settings;
import android.util.Log;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;

/**
 * Always-on receiver, like the AirPlay receiver on an Apple TV: listens for computers, announces the
 * TV on the network (Bonjour/NSD), and opens the video screen when a connection arrives.
 */
public class MirrorService extends Service {
    static final int PORT = 47800;
    static final String SERVICE_TYPE = "_tvmirror._tcp";
    private static final String TAG = "TVMirror";

    private ServerSocket server;
    private Thread acceptThread;
    private NsdManager nsd;
    private NsdManager.RegistrationListener registration;

    static void start(Context context) {
        context.startForegroundService(new Intent(context, MirrorService.class));
    }

    static String deviceName(Context context) {
        String name = Settings.Global.getString(context.getContentResolver(), "device_name");
        if (name == null || name.isEmpty()) name = Build.MANUFACTURER + " " + Build.MODEL;
        return name;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        goForeground();
        startServer();
        advertise();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();
        return START_STICKY;
    }

    private void goForeground() {
        NotificationManager nm = getSystemService(NotificationManager.class);
        nm.createNotificationChannel(new NotificationChannel("receiver", "Mirroring receiver", NotificationManager.IMPORTANCE_MIN));
        Notification n = new Notification.Builder(this, "receiver")
                .setContentTitle("TVMirror")
                .setContentText("Ready to show your computer's screen")
                .setSmallIcon(R.drawable.ic_stat)
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
        } else {
            startForeground(1, n);
        }
    }

    private void startServer() {
        if (acceptThread != null) return;
        acceptThread = new Thread(() -> {
            try {
                server = new ServerSocket();
                server.setReuseAddress(true);
                server.bind(new InetSocketAddress(PORT));
                while (!server.isClosed()) {
                    Socket socket = server.accept();
                    try {
                        Session.replace(new Session(socket));
                        openMirrorScreen();
                    } catch (IOException e) {
                        Log.w(TAG, "connection setup failed", e);
                        try { socket.close(); } catch (IOException ignored) { }
                    }
                }
            } catch (IOException e) {
                Log.e(TAG, "server stopped", e);
            }
        }, "tvmirror-accept");
        acceptThread.start();
    }

    private void openMirrorScreen() {
        Intent i = new Intent(this, MirrorActivity.class);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK | Intent.FLAG_ACTIVITY_NO_ANIMATION);
        startActivity(i);
    }

    private void advertise() {
        nsd = getSystemService(NsdManager.class);
        NsdServiceInfo info = new NsdServiceInfo();
        info.setServiceName(deviceName(this));
        info.setServiceType(SERVICE_TYPE);
        info.setPort(PORT);
        registration = new NsdManager.RegistrationListener() {
            @Override public void onServiceRegistered(NsdServiceInfo s) { Log.i(TAG, "advertised as " + s.getServiceName()); }
            @Override public void onRegistrationFailed(NsdServiceInfo s, int error) { Log.w(TAG, "NSD registration failed " + error); }
            @Override public void onServiceUnregistered(NsdServiceInfo s) { }
            @Override public void onUnregistrationFailed(NsdServiceInfo s, int error) { }
        };
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration);
    }

    @Override
    public void onDestroy() {
        try { if (nsd != null && registration != null) nsd.unregisterService(registration); } catch (Exception ignored) { }
        try { if (server != null) server.close(); } catch (IOException ignored) { }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }
}
