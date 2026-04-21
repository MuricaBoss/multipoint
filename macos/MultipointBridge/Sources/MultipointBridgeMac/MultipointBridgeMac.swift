import Foundation
import WebRTC

@main
struct MultipointBridgeMac {
    static func main() async {
        print("🚀 Multipoint Bridge Mac Client Starting...")
        
        // 1. Get Android IP from arguments or default
        let arguments = CommandLine.arguments
        let androidIP = arguments.count > 1 ? arguments[1] : "192.168.0.100" // Default for dev
        
        let client = SignalingClient(androidIP: androidIP)
        let webRTCManager = WebRTCManager()
        
        if CommandLine.arguments.count > 1 {
            let targetIP = CommandLine.arguments[1]
            webRTCManager.audioCaptureManager.setTargetIP(targetIP)
            print("🚀 UDP Mode Enabled: Direct streaming to \(targetIP)")
            Task {
                try? await webRTCManager.audioCaptureManager.startCapture()
            }
            
            // In UDP mode, we don't need WebRTC signaling
            RunLoop.main.run()
            return
        }
        
        print("📡 Creating WebRTC Offer...")
        do {
            let sdp = try await webRTCManager.createOffer()

            // Wait for ICE Gathering to complete (to include candidates in SDP)
            print("⏳ Gathering ICE candidates...")
            var gatheringAttempts = 0
            while webRTCManager.peerConnection?.iceGatheringState != .complete && gatheringAttempts < 50 {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                gatheringAttempts += 1
            }
            
            // Get the updated SDP with candidates
            guard let finalOffer = webRTCManager.peerConnection?.localDescription else {
                throw NSError(domain: "WebRTC", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to get local description"])
            }

            print("📤 Sending Offer to \(androidIP)...")
            let answer = try await client.sendOffer(sdp: finalOffer.sdp)
            print("✅ Received Answer, establishing connection...")
            
            await webRTCManager.setAnswer(sdp: answer)
            print("🎉 WebRTC Connection State: Negotiated")
            
            // 2. Wait for Data Channel to OPEN
            if let dataChannel = webRTCManager.dataChannel {
                print("⏳ Waiting for Data Channel to open...")
                var attempts = 0
                while dataChannel.readyState != .open && attempts < 100 {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    attempts += 1
                }
                
                if dataChannel.readyState == .open {
                    print("✅ Data Channel is OPEN!")
                } else {
                    print("⚠️ Data Channel is still \(dataChannel.readyState.rawValue), proceedings anyway...")
                }
            }

            // 3. Start Audio Capture
            if let dataChannel = webRTCManager.dataChannel {
                print("🎙️ Initializing Audio Capture...")
                webRTCManager.audioCaptureManager.setDataChannel(dataChannel)
                do {
                    try await webRTCManager.audioCaptureManager.startCapture()
                    print("🟢 Streaming started via RTC. Press Ctrl+C to stop.")
                } catch {
                    print("❌ Capture Error: \(error)")
                }
            }
            
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            print("❌ Error: \(error)")
        }
        
        // Run loop to prevent exit
        RunLoop.main.run()
    }
}

class WebRTCManager: NSObject, RTCPeerConnectionDelegate {
    var peerConnection: RTCPeerConnection?
    var audioSource: RTCAudioSource?
    var dataChannel: RTCDataChannel?
    let factory: RTCPeerConnectionFactory
    let audioCaptureManager = AudioCaptureManager()
    
    override init() {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        factory = RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
        super.init()
    }
    
    func createOffer() async throws -> String {
        let config = RTCConfiguration()
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]
        
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)
        peerConnection = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        
        // Create Data Channel for Audio Streaming
        let dataChannelConfig = RTCDataChannelConfiguration()
        dataChannelConfig.isOrdered = false // Best for streaming
        dataChannelConfig.maxRetransmits = 0 // Best for low latency
        dataChannel = peerConnection?.dataChannel(forLabel: "audio-stream", configuration: dataChannelConfig)
        dataChannel?.delegate = self
        
        // We don't add a microphone track, only the data channel for system audio
        
        let sdp = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            peerConnection?.offer(for: constraints) { sdp, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let sdp = sdp {
                    self.peerConnection?.setLocalDescription(sdp) { error in
                        if let error = error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: sdp.sdp)
                        }
                    }
                }
            }
        }
        return sdp as! String
    }
    
    func setAnswer(sdp: String) async {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        _ = await withCheckedContinuation { continuation in
            peerConnection?.setRemoteDescription(answer) { error in
                if let error = error {
                    print("❌ Error setting answer: \(error)")
                }
                continuation.resume(returning: ())
            }
        }
    }
    
    // PeerConnection Delegates
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("🧊 ICE Connection State: \(newState.rawValue)")
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        print("📺 DataChannel State: \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            print("🚀 Starting Audio Capture...")
            self.audioCaptureManager.setDataChannel(dataChannel)
            Task {
                try? await self.audioCaptureManager.startCapture()
            }
        }
    }
    
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {}
}
