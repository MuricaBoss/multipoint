package com.multipoint_new;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.content.Context;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import com.facebook.react.bridge.Promise;

import android.net.wifi.WifiManager;
import android.util.Log;

public class UdpAudioModule extends ReactContextBaseJavaModule {
    private Map<String, AudioTrack> playerMap = new HashMap<>();
    private DatagramSocket socket;
    private boolean isRunning = false;
    private int port = 9999;
    private NsdManager nsdManager;
    private NsdManager.RegistrationListener registrationListener;
    private WifiManager.MulticastLock multicastLock;
    private static final String TAG = "MultipointUDP";

    public UdpAudioModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "UdpAudio";
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

        new Thread(new Runnable() {
            @Override
            public void run() {
                try {
                    socket = new DatagramSocket(9999);
                    socket.setReceiveBufferSize(512 * 1024);
                    
                    final int sampleRate = 48000;
                    byte[] pktBuffer = new byte[8192];
                    
                    while (isRunning) {
                        DatagramPacket packet = new DatagramPacket(pktBuffer, pktBuffer.length);
                        socket.receive(packet);
                        
                        String senderIp = packet.getAddress().getHostAddress();
                        AudioTrack track = getOrCreateTrack(senderIp, sampleRate);
                        
                        if (track != null && isRunning) {
                            track.write(packet.getData(), 0, packet.getLength());
                        }
                    }
                } catch (Exception e) {
                    if (isRunning) e.printStackTrace();
                } finally {
                    stopServerInternal();
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

            AudioFormat format = new AudioFormat.Builder()
                    .setSampleRate(sampleRate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build();

            int minBufferSize = AudioTrack.getMinBufferSize(sampleRate, 
                    AudioFormat.CHANNEL_OUT_STEREO, 
                    AudioFormat.ENCODING_PCM_16BIT);

            AudioTrack track = new AudioTrack.Builder()
                    .setAudioAttributes(attributes)
                    .setAudioFormat(format)
                    .setBufferSizeInBytes(minBufferSize)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            
            track.play();
            playerMap.put(ip, track);
            sendEvent("onAudioActive", true);
            return track;
        } catch (Exception e) {
            e.printStackTrace();
            return null;
        }
    }
    
    private void sendEvent(String eventName, boolean isActive) {
        try {
            getReactApplicationContext()
                .getJSModule(com.facebook.react.modules.core.DeviceEventManagerModule.RCTDeviceEventEmitter.class)
                .emit(eventName, isActive);
        } catch (Exception e) {}
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
