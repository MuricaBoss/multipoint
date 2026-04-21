import httpBridge from 'react-native-http-bridge-refurbished';
import { RTCSessionDescription, RTCIceCandidate } from 'react-native-webrtc';

export interface SignalingDelegate {
  onOfferReceived: (offer: RTCSessionDescription) => Promise<RTCSessionDescription>;
  onCandidateReceived: (candidate: RTCIceCandidate) => void;
}

export class SignalingServer {
  private delegate: SignalingDelegate;
  private port: number = 8888;

  constructor(delegate: SignalingDelegate) {
    this.delegate = delegate;
  }

  public start() {
    console.log('Starting signaling server on port', this.port);
    httpBridge.start(this.port, 'multipoint-bridge', (request) => {
      const { type, url, postData } = request;

      if (type === 'GET' && url === '/status') {
        httpBridge.respond(request.requestId, 200, 'application/json', JSON.stringify({ status: 'ok' }));
      } else if (type === 'POST' && url === '/offer') {
        console.log('SignalingServer: Received Offer from Mac');
        try {
          const body = JSON.parse(postData);
          console.log('SignalingServer: Offer type:', body.type);
          const offer = new RTCSessionDescription(body);
          this.delegate.onOfferReceived(offer).then(answer => {
            console.log('SignalingServer: Sending Answer back to Mac');
            httpBridge.respond(request.requestId, 200, 'application/json', JSON.stringify({
              type: answer.type,
              sdp: answer.sdp
            }));
          }).catch(err => {
            console.error('SignalingServer: onOfferReceived error:', err);
            httpBridge.respond(request.requestId, 500, 'application/json', JSON.stringify({ error: 'Internal Error' }));
          });
        } catch (e) {
          console.error('SignalingServer: Offer parsing error:', e);
          httpBridge.respond(request.requestId, 400, 'application/json', JSON.stringify({ error: 'Invalid offer' }));
        }
      } else if (type === 'POST' && url === '/candidate') {
        try {
          const candidate = new RTCIceCandidate(JSON.parse(postData));
          this.delegate.onCandidateReceived(candidate);
          httpBridge.respond(request.requestId, 200, 'application/json', JSON.stringify({ status: 'received' }));
        } catch (e) {
          httpBridge.respond(request.requestId, 400, 'application/json', JSON.stringify({ error: 'Invalid candidate' }));
        }
      } else {
        httpBridge.respond(request.requestId, 404, 'application/json', JSON.stringify({ error: 'Not found' }));
      }
    });
  }

  public stop() {
    httpBridge.stop();
  }
}
