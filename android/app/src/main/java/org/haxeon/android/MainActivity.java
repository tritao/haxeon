package org.haxeon.android;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;

public final class MainActivity extends Activity {
    private static final int PATCH_PORT = 39817;
    private static MainActivity instance;
    private volatile boolean stopping;
    private volatile ServerSocket patchServer;

    static {
        System.loadLibrary("haxeon");
    }

    public static android.content.Context getContext() {
        return instance;
    }

    private static native int nativeLoad(android.content.res.AssetManager assets);
    private static native int nativeApplyPatch(byte[] patch);
    private static native int nativeRevision();
    private static native int nativeDispose();

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        instance = this;

        TextView status = new TextView(this);
        status.setText("Haxeon starting...");
        status.setTextSize(20.0f);
        status.setPadding(32, 32, 32, 32);
        setContentView(status);

        new Thread(() -> {
            try {
                int result = nativeLoad(getAssets());
                if (result != 0) {
                    runOnUiThread(() -> status.setText("Haxeon failed to load app.hl\nstatus: " + result));
                    return;
                }
                runOnUiThread(() -> status.setText("Haxeon running revision " + nativeRevision()
                    + "\npatch port: " + PATCH_PORT));
                startPatchServer(status);
            } catch (Throwable error) {
                runOnUiThread(() -> status.setText("Haxeon failed: " + error));
            }
        }, "haxeon-main").start();
    }

    private void startPatchServer(TextView status) {
        if (stopping)
            return;
        new Thread(() -> {
            try (ServerSocket server = new ServerSocket(PATCH_PORT, 4, InetAddress.getLoopbackAddress())) {
                patchServer = server;
                while (!stopping) {
                    try (Socket client = server.accept()) {
                        handlePatch(client, status);
                    } catch (IOException error) {
                        if (!stopping)
                            throw error;
                    }
                }
            } catch (IOException error) {
                if (!stopping)
                    runOnUiThread(() -> status.setText("Haxeon patch server failed: " + error));
            }
        }, "haxeon-patch-server").start();
    }

    private void handlePatch(Socket client, TextView status) throws IOException {
        DataInputStream input = new DataInputStream(new BufferedInputStream(client.getInputStream()));
        int length = input.readInt();
        if (length <= 0 || length > 32 * 1024 * 1024)
            throw new IOException("invalid HLP length: " + length);
        byte[] patch = new byte[length];
        input.readFully(patch);

        int result = nativeApplyPatch(patch);
        int revision = nativeRevision();
        DataOutputStream output = new DataOutputStream(new BufferedOutputStream(client.getOutputStream()));
        output.writeInt(result);
        output.writeInt(revision);
        output.flush();
        runOnUiThread(() -> status.setText(result == 0
            ? "Haxeon applied patch\nrevision: " + revision
            : "Haxeon rejected patch\nstatus: " + result + "\nrevision: " + revision));
    }

    @Override
    protected void onDestroy() {
        stopping = true;
        ServerSocket server = patchServer;
        if (server != null) {
            try {
                server.close();
            } catch (IOException ignored) {
                // The native runtime still gets its normal shutdown path.
            }
        }
        nativeDispose();
        super.onDestroy();
    }
}
