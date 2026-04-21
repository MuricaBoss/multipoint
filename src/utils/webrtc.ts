import {
  RTCPeerConnection,
  RTCSessionDescription,
  RTCIceCandidate,
} from 'react-native-webrtc';

export const createPeerConnection = (onIceCandidate: (candidate: any) => void) => {
  const pc = new RTCPeerConnection({
    iceServers: [
      {urls: 'stun:stun.l.google.com:19302'},
    ],
  });

  pc.onicecandidate = (event) => {
    if (event.candidate) {
      onIceCandidate(event.candidate);
    }
  };

  return pc;
};
