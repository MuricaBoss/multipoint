package com.multipoint_new;

import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import android.util.Base64;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;

public class PcmPlayerModule extends ReactContextBaseJavaModule {
    private AudioTrack audioTrack;
    private int sampleRate = 48000;

    public PcmPlayerModule(ReactApplicationContext reactContext) {
        super(reactContext);
    }

    @Override
    public String getName() {
        return "PcmPlayer";
    }

    @ReactMethod
    public void start() {
        AudioAttributes attributes = new AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setFlags(AudioAttributes.FLAG_LOW_LATENCY)
                .build();
        
        AudioFormat format = new AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                .build();

        int bufferSize = AudioTrack.getMinBufferSize(sampleRate, 
                AudioFormat.CHANNEL_OUT_STEREO, 
                AudioFormat.ENCODING_PCM_16BIT);
        
        audioTrack = new AudioTrack(attributes,
                format,
                bufferSize,
                AudioTrack.MODE_STREAM,
                AudioManager.AUDIO_SESSION_ID_GENERATE);
        
        audioTrack.play();
    }

    @ReactMethod
    public void play(String base64Data) {
        if (audioTrack != null) {
            byte[] data = Base64.decode(base64Data, Base64.DEFAULT);
            audioTrack.write(data, 0, data.length, AudioTrack.WRITE_NON_BLOCKING);
        }
    }

    @ReactMethod
    public void stop() {
        if (audioTrack != null) {
            audioTrack.stop();
            audioTrack.release();
            audioTrack = null;
        }
    }
}
