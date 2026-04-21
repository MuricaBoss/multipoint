package com.multipoint_new;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.WritableArray;
import com.facebook.react.bridge.Arguments;
import android.os.Build;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.content.Context;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.nio.charset.StandardCharsets;
import java.util.Collections;
import java.util.HashMap;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.Timer;
import java.util.TimerTask;
import com.facebook.react.bridge.Promise;

import android.net.wifi.WifiManager;
import android.util.Log;

public class UdpAudioModule extends ReactContextBaseJavaModule {
    private Map<String, AudioTrack> playerMap = new HashMap<>();
    private Map<String, String> deviceNames = new HashMap<>();
    private Map<String, Long> lastActivity = new HashMap<>();
    private DatagramSocket socket;
    private DatagramSocket metaSocket;
    private boolean isRunning = false;
    private int port = 9999;
    private int metaPort = 9998;
    private Timer cleanupTimer;

    private NsdManager nsdManager;
    private NsdManager.RegistrationListener registrationListener;
    private WifiManager.MulticastLock multicastLock;
    private static final String TAG = "MultipointUDP";

    private String normalizeIp(String ip) {
        if (ip == null) return null;
        if (ip.startsWith("::ffff:")) return ip.substring(7);
        return ip;
    }

    private void startCleanupTimer() {
        cleanupTimer = new Timer();
        cleanupTimer.scheduleAtFixedRate(new TimerTask() {
            @Override
            public void run() {
                long now = System.currentTimeMillis();
                boolean changed = false;
                synchronized (playerMap) {
                    Iterator<Map.Entry<String, Long>> it = lastActivity.entrySet().iterator();
                    while (it.hasNext()) {
                        Map.Entry<String, Long> entry = it.next();
                        if (now - entry.getValue() > 10000) { // 10s timeout
                            String ip = normalizeIp(entry.getKey());
                            Log.d(TAG, "🏚️ Removing stale source: " + ip);
                            AudioTrack track = playerMap.get(ip);
                            if (track != null) {
                                try { track.stop(); track.release(); } catch (Exception e) {}
                                playerMap.remove(ip);
                            }
                            deviceNames.remove(ip);
                            it.remove();
                            changed = true;
                        }
                    }
                }
                if (changed) emitSources();
            }
        }, 5000, 5000);
    }

    public UdpAudioModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "UdpAudio";
    }

    private String lastEmittedSources = "";

    private void emitSources() {
        WritableArray array = Arguments.createArray();
        StringBuilder sb = new StringBuilder();
        
        synchronized (lastActivity) {
            if (lastActivity.isEmpty()) {
                if (!lastEmittedSources.equals("[]")) {
                    sendEvent("onSourcesChanged", array);
                    lastEmittedSources = "[]";
                }
                return;
            }
            
            List<String> sortedIps = new java.util.ArrayList<>(lastActivity.keySet());
            java.util.Collections.sort(sortedIps);

            for (String ip : sortedIps) {
                com.facebook.react.bridge.WritableMap map = Arguments.createMap();
                map.putString("ip", ip);
                String name = deviceNames.get(ip);
                String displayName = name != null ? name : ip;
                map.putString("name", displayName);
                array.pushMap(map);
                sb.append(ip).append(":").append(displayName).append(";");
            }
        }
        
        String currentSources = sb.toString();
        if (!currentSources.equals(lastEmittedSources)) {
            sendEvent("onSourcesChanged", array);
            lastEmittedSources = currentSources;
            Log.d(TAG, "📱 UI Updated with sources: " + currentSources);
        }
    }

    @ReactMethod
    public void setSourceVolume(String ip, float volume) {
        AudioTrack track = playerMap.get(ip);
        if (track != null) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    track.setVolume(volume);
                } else {
                    track.setStereoVolume(volume, volume);
                }
            } catch (Exception e) {}
        }
    }

    private void registerService(int port) {
        try {
            // Acquire Multicast Lock
            WifiManager wifi = (WifiManager) getReactApplicationContext().getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wifi != null) {
                multicastLock = wifi.createMulticastLock("MultipointLock");
                multicastLock.setReferenceCounted(true);
                multicastLock.acquire();
                Log.d(TAG, "🔒 Multicast Lock Acquired");
            }

            NsdServiceInfo serviceInfo = new NsdServiceInfo();
            serviceInfo.setServiceName("MultipointReceiver");
            serviceInfo.setServiceType("_multipoint._udp");
            serviceInfo.setPort(port);

            nsdManager = (NsdManager) getReactApplicationContext().getSystemService(Context.NSD_SERVICE);
            registrationListener = new NsdManager.RegistrationListener() {
                @Override
                public void onServiceRegistered(NsdServiceInfo NsdServiceInfo) {
                    Log.d(TAG, "📡 NSD Service Registered: " + NsdServiceInfo.getServiceName());
                    System.out.println("📡 NSD Service Registered: " + NsdServiceInfo.getServiceName());
                }

                @Override
                public void onRegistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    Log.e(TAG, "❌ NSD Registration Failed: " + errorCode);
                }

                @Override
                public void onServiceUnregistered(NsdServiceInfo arg0) {
                    Log.d(TAG, "📡 NSD Service Unregistered");
                }

                @Override
                public void onUnregistrationFailed(NsdServiceInfo serviceInfo, int errorCode) {
                    Log.e(TAG, "❌ NSD Unregistration Failed: " + errorCode);
                }
            };

            nsdManager.registerService(serviceInfo, NsdManager.PROTOCOL_DNS_SD, registrationListener);
        } catch (Exception e) {
            Log.e(TAG, "❌ Error setting up NSD: " + e.getMessage());
        }
    }

    @ReactMethod
    public void startServer() {
        if (isRunning) return;
        isRunning = true;
        
        registerService(9999);
        startCleanupTimer();

        // 1. Audio Data Thread (Port 9999)
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    socket = new DatagramSocket(null);
                    socket.setReuseAddress(true);
                    socket.bind(new java.net.InetSocketAddress(9999));
                    
                    // SAFE MODE: Increase OS buffer to 128KB to handle bursts better.
                    socket.setReceiveBufferSize(128 * 1024); 
                    
                    byte[] buffer = new byte[8192];
                    
                    while (isRunning) {
                        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                        socket.receive(packet);
                        String senderIp = normalizeIp(packet.getAddress().getHostAddress());
                        int length = packet.getLength();
                        lastActivity.put(senderIp, System.currentTimeMillis());

                        AudioTrack track = getOrCreateTrack(senderIp, 48000);
                        if (track != null && isRunning && length > 8) {
                            // DIAGNOSTIC: Extract 8-byte timestamp (Big Endian)
                            long remoteTime = 0;
                            for (int i = 0; i < 8; i++) {
                                remoteTime = (remoteTime << 8) | (buffer[i] & 0xFF);
                            }
                            long localTime = System.currentTimeMillis();
                            long transitTime = localTime - remoteTime;
                            
                            // Log latency every 300 packets (~1.5 seconds)
                            packetCount++;
                            if (packetCount % 300 == 0) {
                                Log.d(TAG, "⏱ Latency Diagnostic: Network Transit = " + transitTime + "ms");
                            }

                            // Skip the 8-byte timestamp header for audio playback
                            track.write(buffer, 8, length - 8);
                        }
                    }
                } catch (Exception e) {
                    if (isRunning) Log.e(TAG, "❌ Audio Port Error: " + e.getMessage());
                } finally {
                    stopServerInternal();
                }
            }
        }).start();

        // 2. Metadata Thread (Port 9998)
        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    metaSocket = new DatagramSocket(null);
                    metaSocket.setReuseAddress(true);
                    metaSocket.bind(new java.net.InetSocketAddress(9998));
                    byte[] buffer = new byte[1024];
                    while (isRunning) {
                        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                        metaSocket.receive(packet);
                        String senderIp = normalizeIp(packet.getAddress().getHostAddress());
                        String msg = new String(buffer, 0, packet.getLength(), StandardCharsets.UTF_8);
                        
                        if (msg.startsWith("MSG:NAME:")) {
                            // Extract name and strip any null bytes or trailing spaces that cause comparison failures
                            String rawName = msg.substring(9).replace("\0", "").trim();
                            if (!rawName.isEmpty()) {
                                deviceNames.put(senderIp, rawName);
                                lastActivity.put(senderIp, System.currentTimeMillis());
                                emitSources();
                                Log.d(TAG, "👤 Metadata: [" + rawName + "] from " + senderIp);
                            }
                        }
                    }
                } catch (Exception e) {
                    if (isRunning) Log.e(TAG, "❌ Meta Port Error: " + e.getMessage());
                }
            }
        }).start();
    }

    private synchronized AudioTrack getOrCreateTrack(String ip, int sampleRate) {
        if (playerMap.containsKey(ip)) {
            return playerMap.get(ip);
        }

        try {
            AudioAttributes attributes = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .setFlags(AudioAttributes.FLAG_LOW_LATENCY)
                    .build();

            // DEEP LATENCY: RESTORE NATIVE HARDWARE ALIGNMENT
            int nativeSampleRate = 48000;
            try {
                android.media.AudioManager am = (android.media.AudioManager) getReactApplicationContext().getSystemService(android.content.Context.AUDIO_SERVICE);
                String rate = am.getProperty(android.media.AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE);
                if (rate != null) nativeSampleRate = Integer.parseInt(rate);
                Log.d(TAG, "📱 Native Hardware Sample Rate: " + nativeSampleRate + " Hz");
            } catch (Exception e) {}

            AudioFormat format = new AudioFormat.Builder()
                    .setSampleRate(nativeSampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build();

            int minBufferSize = AudioTrack.getMinBufferSize(nativeSampleRate, 
                    AudioFormat.CHANNEL_OUT_STEREO, 
                    AudioFormat.ENCODING_PCM_16BIT);

            AudioTrack track = new AudioTrack.Builder()
                    .setAudioAttributes(attributes)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(minBufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .build();
            
            // DEEP LATENCY: Use 480 frames (~10ms) for ultimate speed.
            // This requires high-frequency packets from Mac to avoid starvation.
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.N) {
                int targetFrames = 480; 
                int actualFrames = track.setBufferSizeInFrames(targetFrames);
                Log.d(TAG, "⚡️ Deep Latency Tuned: Target " + targetFrames + " frames, Actual " + actualFrames + " frames");
            }
            
            track.play();
            playerMap.put(ip, track);
            emitSources(); // Notify UI about new source
            
            sendEvent("onAudioActive", true);
            return track;
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }
    
    private void sendEvent(String eventName, Object data) {
        try {
            getReactApplicationContext()
                .getJSModule(com.facebook.react.modules.core.DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, data);
        } catch (Exception e) {}
    }

    private void sendEvent(String eventName, boolean isActive) {
        sendEvent(eventName, (Object)isActive);
    }

    @ReactMethod
    public void stopServer() {
        isRunning = false;
        if (socket != null) {
            socket.close();
        }
        if (nsdManager != null && registrationListener != null) {
            try {
                nsdManager.unregisterService(registrationListener);
            } catch (Exception e) {}
        }
        if (multicastLock != null && multicastLock.isHeld()) {
            try {
                multicastLock.release();
                Log.d(TAG, "🔒 Multicast Lock Released");
            } catch (Exception e) {}
        }
    }

    private synchronized void stopServerInternal() {
        isRunning = false;
        try {
            if (socket != null) {
                socket.close();
                socket = null;
            }
            if (metaSocket != null) {
                metaSocket.close();
                metaSocket = null;
            }
        } catch (Exception e) {}

        for (AudioTrack track : playerMap.values()) {
            try {
                track.pause();
                track.flush();
                track.release();
            } catch (Exception e) {}
        }
        playerMap.clear();
        
        sendEvent("onAudioActive", false);
    }

    @ReactMethod
    public void getIPAddress(Promise promise) {
        try {
            List<NetworkInterface> interfaces = Collections.list(NetworkInterface.getNetworkInterfaces());
            for (NetworkInterface intf : interfaces) {
                List<InetAddress> addrs = Collections.list(intf.getInetAddresses());
                for (InetAddress addr : addrs) {
                    if (!addr.isLoopbackAddress()) {
                        String sAddr = addr.getHostAddress();
                        boolean isIPv4 = sAddr.indexOf(':') < 0;
                        if (isIPv4) {
                            promise.resolve(sAddr);
                            return;
                        }
                    }
                }
            }
            promise.reject("Error", "No IP address found");
        } catch (Exception ex) {
            promise.reject("Error", ex.getMessage());
        }
    }
}
