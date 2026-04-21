import React, {useState, useEffect, useCallback, useRef} from 'react';
import {
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
  TouchableOpacity,
} from 'react-native';
import {NetworkInfo} from 'react-native-network-info';
import { RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, MediaStream } from 'react-native-webrtc';
import { createPeerConnection } from './src/utils/webrtc';
import { SignalingServer, SignalingDelegate } from './src/native/SignalingServer';

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  const [ipAddress, setIpAddress] = useState<string | null>(null);
  const [status, setStatus] = useState<string>('Ready');
  const [isConnected, setIsConnected] = useState(false);
  
  const pcRef = useRef<RTCPeerConnection | null>(null);
  const signalingServerRef = useRef<SignalingServer | null>(null);

  const cleanup = useCallback(() => {
    if (pcRef.current) {
      pcRef.current.close();
      pcRef.current = null;
    }
    if (signalingServerRef.current) {
      signalingServerRef.current.stop();
      signalingServerRef.current = null;
    }
    setIsConnected(false);
    setStatus('Ready');
  }, []);

  const handleCandidate = useCallback((candidate: RTCIceCandidate) => {
    if (pcRef.current) {
      pcRef.current.addIceCandidate(candidate).catch(e => console.error('Add candidate error', e));
    }
  }, []);

  const handleOffer = useCallback(async (offer: RTCSessionDescription): Promise<RTCSessionDescription> => {
    setStatus('Negotiating...');
    
    // Create connection if not exists
    if (!pcRef.current) {
      pcRef.current = createPeerConnection((candidate) => {
        console.log('Android ICE Candidate generated', candidate);
      });

      pcRef.current.ondatachannel = (event) => {
        const channel = event.channel;
        if (channel.label === 'audio-stream') {
          console.log('Audio Data Channel opened!');
          const { NativeModules } = require('react-native');
          const { PcmPlayer } = NativeModules;
          
          PcmPlayer.start();
          
          channel.onmessage = (msg: any) => {
            // msg.data is base64 from current react-native-webrtc versions for binary
            PcmPlayer.play(msg.data);
          };
          
          channel.onclose = () => {
             PcmPlayer.stop();
          };
        }
      };

      pcRef.current.onconnectionstatechange = () => {
        const state = pcRef.current?.connectionState;
        console.log('Connection state change:', state);
        if (state === 'connected') {
          setIsConnected(true);
          setStatus('Connected');
        } else if (state === 'failed' || state === 'closed') {
          setIsConnected(false);
          setStatus('Ready');
        }
      };

      pcRef.current.ontrack = (event) => {
        console.log('Remote track received!', event.streams[0]);
        setStatus('Receiving Audio');
      };
    }

    await pcRef.current.setRemoteDescription(offer);
    const answer = await pcRef.current.createAnswer();
    await pcRef.current.setLocalDescription(answer);
    
    return answer as RTCSessionDescription;
  }, []);

  const startListening = useCallback(() => {
    setStatus('Waiting for Mac...');
    
    const delegate: SignalingDelegate = {
      onOfferReceived: handleOffer,
      onCandidateReceived: handleCandidate,
    };

    signalingServerRef.current = new SignalingServer(delegate);
    signalingServerRef.current.start();
  }, [handleOffer, handleCandidate]);

  useEffect(() => {
    NetworkInfo.getIPAddress().then(ip => {
      setIpAddress(ip);
    });
    return cleanup;
  }, [cleanup]);

  const toggleConnection = () => {
    if (status === 'Ready') {
      startListening();
    } else {
      cleanup();
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <View style={styles.content}>
        <Text style={styles.title}>🎧 Multipoint Bridge</Text>
        
        <View style={styles.card}>
          <Text style={styles.label}>Your IP Address</Text>
          <Text style={styles.ip}>{ipAddress || 'Detecting...'}</Text>
        </View>

        <View style={styles.infoRow}>
          <View style={[styles.dot, isConnected && styles.dotActive]} />
          <Text style={styles.status}>Status: {status}</Text>
        </View>

        <TouchableOpacity 
          style={[styles.button, status !== 'Ready' && styles.buttonActive]} 
          onPress={toggleConnection}
        >
          <Text style={styles.buttonText}>
            {status === 'Ready' ? 'Start Listening' : 'Stop'}
          </Text>
        </TouchableOpacity>
        
        {isConnected && (
            <Text style={styles.hint}>Streaming from Mac...</Text>
        )}
      </View>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0a0a0a',
  },
  content: {
    flex: 1,
    padding: 32,
    justifyContent: 'center',
    alignItems: 'center',
  },
  title: {
    fontSize: 32,
    fontWeight: '900',
    color: '#ffffff',
    marginBottom: 64,
    letterSpacing: -0.5,
  },
  card: {
    backgroundColor: '#161616',
    borderRadius: 24,
    padding: 32,
    width: '100%',
    alignItems: 'center',
    marginBottom: 48,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 10 },
    shadowOpacity: 0.5,
    shadowRadius: 20,
    elevation: 10,
    borderWidth: 1,
    borderColor: '#222',
  },
  label: {
    color: '#666',
    fontSize: 12,
    fontWeight: '700',
    marginBottom: 12,
    textTransform: 'uppercase',
    letterSpacing: 2,
  },
  ip: {
    color: '#00ccff',
    fontSize: 28,
    fontWeight: '700',
    fontFamily: 'monospace',
  },
  infoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 48,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#333',
    marginRight: 10,
  },
  dotActive: {
    backgroundColor: '#00ffaa',
    shadowColor: '#00ffaa',
    shadowRadius: 10,
    elevation: 5,
  },
  button: {
    backgroundColor: '#00ccff',
    paddingVertical: 18,
    paddingHorizontal: 54,
    borderRadius: 40,
    shadowColor: '#00ccff',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.3,
    shadowRadius: 12,
    elevation: 8,
  },
  buttonActive: {
    backgroundColor: '#ff3b30',
    shadowColor: '#ff3b30',
  },
  buttonText: {
    color: '#000',
    fontSize: 20,
    fontWeight: '800',
  },
  status: {
    fontSize: 18,
    color: '#ddd',
    fontWeight: '500',
  },
  hint: {
    marginTop: 20,
    color: '#00ffaa',
    fontSize: 14,
    fontWeight: '600',
  }
});

export default App;
