package com.multipoint_new;

import android.media.AudioFormat;
import android.media.AudioManager;
import android.media.AudioTrack;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.ReadableArray;
import android.util.Base64;

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
        int bufferSize = AudioTrack.getMinBufferSize(sampleRate, 
                AudioFormat.CHANNEL_OUT_MONO, 
                AudioFormat.ENCODING_PCM_16BIT);
        
        audioTrack = new AudioTrack(AudioManager.STREAM_MUSIC,
                sampleRate,
                AudioFormat.CHANNEL_OUT_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                bufferSize,
                AudioTrack.MODE_STREAM);
        
        audioTrack.play();
    }

    @ReactMethod
    public void stop() {
        if (audioTrack != null) {
            audioTrack.stop();
            audioTrack.release();
            audioTrack = null;
        }
    }

    @ReactMethod
    public void play(String base64Data) {
        if (audioTrack != null) {
            byte[] data = Base64.decode(base64Data, Base64.DEFAULT);
            audioTrack.write(data, 0, data.length, AudioTrack.WRITE_NON_BLOCKING);
        }
    }
}
