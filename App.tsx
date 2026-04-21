import React, {useState, useEffect, useCallback, useRef} from 'react';
import {
  SafeAreaView,
  StatusBar,
  StyleSheet,
  Text,
  useColorScheme,
  View,
  TouchableOpacity,
  NativeModules,
  NativeEventEmitter,
  Dimensions,
  ScrollView,
} from 'react-native';
import Slider from '@react-native-community/slider';
import {NetworkInfo} from 'react-native-network-info';
import { RTCPeerConnection, RTCSessionDescription, RTCIceCandidate, MediaStream } from 'react-native-webrtc';
import { createPeerConnection } from './src/utils/webrtc';
import { SignalingServer, SignalingDelegate } from './src/native/SignalingServer';

const { UdpAudio, PcmPlayer } = NativeModules;
const udpEventEmitter = new NativeEventEmitter(UdpAudio);

const MixerControl = ({ ip, name, initialValue, onVolumeChange }: { ip: string, name: string, initialValue: number, onVolumeChange: (ip: string, val: number) => void }) => {
  const [localVal, setLocalVal] = useState(initialValue);

  const adjustVolume = (delta: number) => {
    const newVal = Math.min(1.0, Math.max(0.0, localVal + delta));
    setLocalVal(newVal);
    onVolumeChange(ip, newVal);
  };

  return (
    <View style={styles.sourceCard}>
      <Text style={styles.hugeName} numberOfLines={1}>
        {name || "IDENTIFIED DEVICE"}
      </Text>
      
      <View style={styles.controlRow}>
        <TouchableOpacity 
          style={styles.volBtn} 
          onPress={() => adjustVolume(-0.1)}
        >
          <Text style={styles.volBtnText}>-</Text>
        </TouchableOpacity>

        <View style={styles.volDisplay}>
          <Text style={styles.volPercent}>{Math.round(localVal * 100)}%</Text>
          <Text style={styles.volLabel}>VOLUME</Text>
        </View>

        <TouchableOpacity 
          style={styles.volBtn} 
          onPress={() => adjustVolume(0.1)}
        >
          <Text style={styles.volBtnText}>+</Text>
        </TouchableOpacity>
      </View>
      
      <View style={styles.cardFooter}>
        <View style={styles.liveIndicator}>
          <View style={styles.dotActive} />
          <Text style={styles.liveText}>LIVE</Text>
        </View>
        <Text style={styles.ipBadge}>IP: {ip}</Text>
      </View>
    </View>
  );
};

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  const [ipAddress, setIpAddress] = useState<string | null>(null);
  const [status, setStatus] = useState<string>('Ready');
  const [isConnected, setIsConnected] = useState(false);
  const [isUdpActive, setIsUdpActive] = useState(false);
  const [isAudioLive, setIsAudioLive] = useState(false);
  const [sources, setSources] = useState<{ip: string, name: string}[]>([]);
  const [sourceVolumes, setSourceVolumes] = useState<{[key: string]: number}>({});
  
  const pcRef = useRef<RTCPeerConnection | null>(null);
  const signalingServerRef = useRef<SignalingServer | null>(null);

  useEffect(() => {
    const subActive = udpEventEmitter.addListener('onAudioActive', (isActive) => {
      setIsAudioLive(isActive);
    });

    const subSources = udpEventEmitter.addListener('onSourcesChanged', (newSources: {ip: string, name: string}[]) => {
      console.log('Sources Changed:', newSources);
      setSources(newSources);
      // Initialize volumes for new sources
      setSourceVolumes(prev => {
        const next = { ...prev };
        newSources.forEach(s => {
          if (next[s.ip] === undefined) next[s.ip] = 1.0;
        });
        return next;
      });
    });

    return () => {
      subActive.remove();
      subSources.remove();
    };
  }, []);

  const handleVolumeChange = (ip: string, val: number) => {
    setSourceVolumes(prev => ({ ...prev, [ip]: val }));
    UdpAudio.setSourceVolume(ip, val);
  };

  const cleanup = useCallback(() => {
    if (pcRef.current) {
      pcRef.current.close();
      pcRef.current = null;
    }
    if (signalingServerRef.current) {
      signalingServerRef.current.stop();
      signalingServerRef.current = null;
    }
    UdpAudio.stopServer();
    setIsUdpActive(false);
    setIsConnected(false);
    setIsAudioLive(false);
    setSources([]);
    setStatus('Ready');
  }, []);

  const toggleUdp = async () => {
    if (isUdpActive) {
      cleanup();
    } else {
      cleanup();
      UdpAudio.startServer();
      setIsUdpActive(true);
      setStatus('UDP Receiving');
      
      try {
        const ip = await UdpAudio.getIPAddress();
        setIpAddress(ip);
      } catch (e) {
        console.log('Native IP fetch failed, using fallback');
      }
    }
  };

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
          PcmPlayer.start();
          
          channel.onmessage = (msg: any) => {
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
      <ScrollView 
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >
        <View style={styles.content}>
          <Text style={styles.title}>🎧 Multipoint Mixer</Text>
          <Text style={styles.versionLabel}>v1.2.0</Text>

          <View style={styles.card}>
            <Text style={styles.label}>Your IP Address</Text>
            <Text style={styles.ip}>{ipAddress || 'Detecting...'}</Text>
          </View>

          <View style={styles.infoRow}>
            <View style={[styles.dot, isConnected && styles.dotActive]} />
            <Text style={styles.status}>Status: {status}</Text>
          </View>

          {isUdpActive && (
            <View style={styles.mixerSection}>
              <Text style={styles.mixerTitle}>Connected Sources ({sources.length})</Text>
              {sources.length === 0 ? (
                <Text style={styles.emptyMixer}>Waiting for audio streams...</Text>
              ) : (
                sources.map(s => (
                  <MixerControl 
                    key={s.ip} 
                    ip={s.ip} 
                    name={s.name} 
                    initialValue={sourceVolumes[s.ip] || 1.0}
                    onVolumeChange={handleVolumeChange}
                  />
                ))
               )}
            </View>
          )}

          {isUdpActive && !sources.length && (
            <View style={[styles.activityRow, { marginBottom: 20 }]}>
              <View style={[styles.dot, isAudioLive && { backgroundColor: '#4caf50', shadowColor: '#4caf50', shadowRadius: 10, elevation: 5 }]} />
              <Text style={[styles.status, { color: isAudioLive ? '#4caf50' : '#757575' }]}>
                {isAudioLive ? 'Audio Signal: Active' : 'Audio Signal: Idling'}
              </Text>
            </View>
          )}

          <TouchableOpacity 
            style={[styles.button, isUdpActive && {backgroundColor: '#ff9500'}]} 
            onPress={toggleUdp}
          >
            <Text style={styles.buttonText}>
              {isUdpActive ? 'Stop Mixer Service' : 'Start Multipoint Mixer'}
            </Text>
          </TouchableOpacity>
          
          {isUdpActive && (
              <Text style={styles.hint}>
                Listening for audio from identified network sources.
              </Text>
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#0a0a0a',
  },
  scrollContent: {
    paddingBottom: 50,
  },
  content: {
    padding: 24,
    alignItems: 'stretch',
  },
  title: {
    fontSize: 32,
    fontWeight: '900',
    color: '#ffffff',
    marginTop: 20,
    marginBottom: 8,
    textAlign: 'center',
  },
  versionLabel: {
    fontSize: 14,
    color: '#00ccff',
    fontWeight: 'bold',
    textAlign: 'center',
    marginBottom: 40,
    opacity: 0.8,
  },
  card: {
    backgroundColor: '#161616',
    borderRadius: 24,
    padding: 24,
    alignItems: 'center',
    marginBottom: 32,
    borderWidth: 1,
    borderColor: '#222',
  },
  label: {
    color: '#666',
    fontSize: 10,
    fontWeight: '900',
    letterSpacing: 2,
    marginBottom: 8,
    textTransform: 'uppercase',
  },
  ip: {
    color: '#00ccff',
    fontSize: 24,
    fontWeight: 'bold',
    fontFamily: 'monospace',
  },
  infoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 40,
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
    elevation: 8,
  },
  status: {
    color: '#eee',
    fontSize: 16,
    fontWeight: '600',
  },
  mixerSection: {
    marginBottom: 40,
  },
  mixerTitle: {
    color: '#fff',
    fontSize: 18,
    fontWeight: 'bold',
    marginBottom: 20,
    opacity: 0.9,
  },
  sourceCard: {
    backgroundColor: '#1c1c1e',
    borderRadius: 24,
    padding: 24,
    marginBottom: 24,
    borderWidth: 1,
    borderColor: '#333',
    elevation: 4,
  },
  hugeName: {
    color: '#00ccff',
    fontSize: 28,
    fontWeight: '900',
    marginBottom: 24,
    textAlign: 'center',
  },
  controlRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 24,
  },
  volBtn: {
    width: 70,
    height: 70,
    borderRadius: 35,
    backgroundColor: '#2c2c2e',
    justifyContent: 'center',
    alignItems: 'center',
    borderWidth: 1,
    borderColor: '#444',
  },
  volBtnText: {
    color: '#fff',
    fontSize: 36,
    fontWeight: '300',
  },
  volDisplay: {
    alignItems: 'center',
    flex: 1,
  },
  volPercent: {
    color: '#fff',
    fontSize: 36,
    fontWeight: 'bold',
  },
  volLabel: {
    color: '#666',
    fontSize: 10,
    fontWeight: 'bold',
    marginTop: 4,
    letterSpacing: 1,
  },
  cardFooter: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    borderTopWidth: 1,
    borderTopColor: '#333',
    paddingTop: 16,
  },
  liveIndicator: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#4caf5020',
    paddingHorizontal: 8,
    paddingVertical: 4,
    borderRadius: 12,
  },
  liveText: {
    color: '#4caf50',
    fontSize: 10,
    fontWeight: '900',
    marginLeft: 6,
  },
  ipBadge: {
    color: '#555',
    fontSize: 11,
    fontFamily: 'monospace',
  },
  activityRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 32,
  },
  button: {
    backgroundColor: '#00ccff',
    paddingVertical: 20,
    borderRadius: 40,
    alignItems: 'center',
    shadowColor: '#00ccff',
    shadowOffset: { width: 0, height: 8 },
    shadowOpacity: 0.4,
    shadowRadius: 16,
    elevation: 8,
    marginBottom: 16,
  },
  buttonActive: {
    backgroundColor: '#ff3b30',
    shadowColor: '#ff3b30',
  },
  buttonText: {
    color: '#000',
    fontSize: 18,
    fontWeight: '900',
    letterSpacing: 1,
  },
  hint: {
    color: '#444',
    fontSize: 12,
    textAlign: 'center',
    marginTop: 8,
    fontStyle: 'italic',
  },
  emptyMixer: {
    color: '#444',
    textAlign: 'center',
    paddingVertical: 40,
    fontSize: 15,
  },
});

export default App;
