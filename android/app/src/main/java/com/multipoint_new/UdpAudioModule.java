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
                try {
                    socket = new DatagramSocket(9999);
                    socket.setReceiveBufferSize(256 * 1024);
                    
                    final int sampleRate = 48000;
                    
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

                    audioTrack = new AudioTrack.Builder()
                            .setAudioAttributes(attributes)
                            .setAudioFormat(format)
                            .setBufferSizeInBytes(minBufferSize)
                            .setTransferMode(AudioTrack.MODE_STREAM)
                            .build();
                    
                    audioTrack.play();

                    byte[] pktBuffer = new byte[8192];
                    while (isRunning) {
                        DatagramPacket packet = new DatagramPacket(pktBuffer, pktBuffer.length);
                        socket.receive(packet);
                        
                        if (audioTrack != null) {
                            // DRIFT PROTECTION:
                            // Try to write to the buffer. If it's full, write() will return 0 or less than length.
                            // We use WRITE_NON_BLOCKING to ensure we never wait (which would grow the delay).
                            int written = audioTrack.write(packet.getData(), 0, packet.getLength(), AudioTrack.WRITE_NON_BLOCKING);
                            
                            // If we couldn't write the full packet, it means the buffer is full.
                            // We don't retry - we just drop it to stay at the head of the stream.
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
