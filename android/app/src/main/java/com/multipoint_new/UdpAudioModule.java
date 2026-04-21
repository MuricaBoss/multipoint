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

public class UdpAudioModule extends ReactContextBaseJavaModule {
    private AudioTrack audioTrack;
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
                final int sampleRate = 48000;
                try {
                    socket = new DatagramSocket(9999);
                    socket.setReceiveBufferSize(256 * 1024);
                    
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
                    
                    audioTrack = new AudioTrack(attributes, format, minBufferSize * 2, 
                            AudioTrack.MODE_STREAM, AudioManager.AUDIO_SESSION_ID_GENERATE);
                    
                    audioTrack.play();

                    byte[] buffer = new byte[8192];

                    while (isRunning) {
                        DatagramPacket packet = new DatagramPacket(buffer, buffer.length);
                        socket.receive(packet);
                        
                        if (audioTrack != null) {
                            audioTrack.write(packet.getData(), 0, packet.getLength());
                        }
                    }
                } catch (Exception e) {
                    e.printStackTrace();
                } finally {
                    stopServerInternal();
                }
            }
        }).start();
    }

    @ReactMethod
    public void stopServer() {
        isRunning = false;
        stopServerInternal();
    }

    private void stopServerInternal() {
        if (socket != null) {
            socket.close();
            socket = null;
        }
        if (audioTrack != null) {
            audioTrack.stop();
            audioTrack.release();
            audioTrack = null;
        }
    }
}
