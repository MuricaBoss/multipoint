package com.multipoint_new;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.util.HashMap;
import java.util.Map;

public class UdpAudioModule extends ReactContextBaseJavaModule {
    private Map<String, AudioTrack> playerMap = new HashMap<>();
    private DatagramSocket socket;
    private boolean isRunning = false;
    private int port = 9999;
    private int sampleRate = 48000;

    public UdpAudioModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "UdpAudio";
    }

    @ReactMethod
    public void startServer() {
        if (isRunning) return;
        isRunning = true;

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
}
