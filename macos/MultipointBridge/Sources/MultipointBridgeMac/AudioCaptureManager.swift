import Foundation
import ScreenCaptureKit
import AVFoundation

class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    
    override init() {
        super.init()
    }
    
    private var udpSocket: Int32 = -1
    private var targetAddress: sockaddr_in?
    var isMuted: Bool = false // v3.1.2: Support muting system audio
    
    // VAD settings
    private let silenceThreshold: Float = 0.0001 // More sensitive (-80dB)
    private var silenceCounter: Int = 0
    private let silenceHangoverFrames: Int = 50 
    private var audioAccumulator = [Int16]()
    private let sendChunkSize = 256 // frames

    func setTarget(ip: String, port: Int) {
        if udpSocket >= 0 { close(udpSocket) }
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        targetAddress = addr
        print("📡 UDP Target Set: \(ip):\(port)")
        
        // v2.1.0: Start the Pong Reflector listener
        startPongReflector()
    }
    
    private func startPongReflector() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while self.udpSocket >= 0 {
                var remoteAddr = sockaddr()
                var addrLen = socklen_t(MemoryLayout<sockaddr>.size)
                let bytesRead = recvfrom(self.udpSocket, &buffer, buffer.count, 0, &remoteAddr, &addrLen)
                
                if bytesRead > 5 {
                    let receivedData = Data(bytes: buffer, count: bytesRead)
                    if let msg = String(data: receivedData, encoding: .utf8), msg.hasPrefix("PING:") {
                        // Reflect as PONG
                        let pongMsg = msg.replacingOccurrences(of: "PING:", with: "PONG:")
                        let pongData = pongMsg.data(using: .utf8)
                        if let d = pongData {
                            d.withUnsafeBytes { ptr in
                                if let base = ptr.baseAddress {
                                    sendto(self.udpSocket, base, d.count, 0, &remoteAddr, addrLen)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func stopCapture() {
        stream?.stopCapture { _ in }
        stream = nil
        if udpSocket >= 0 {
            close(udpSocket)
            udpSocket = -1
        }
    }

    func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        
        guard let display = content.displays.first else {
            print("❌ No displays found!")
            return
        }
        
        // v3.1.3: Exclude THIS application from the capture to prevent feedback loops (like calibration pips)
        let runningApps = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false).applications
        let currentApp = runningApps.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        let excludedApps = currentApp != nil ? [currentApp!] : []
        
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2 // Stereo
        config.width = 2 // Minimal video
        config.height = 2
        config.queueDepth = 2 // Extremely low latency (minimum possible is 1-2)
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        let audioQueue = DispatchQueue(label: "com.antigravity.audioCapture", qos: .userInteractive)
        let screenQueue = DispatchQueue(label: "com.antigravity.screenCapture", qos: .background)
        
        print("🎙️ Adding stream outputs...")
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenQueue)
        
        try await stream?.startCapture()
        print("🎙️ SCStream.startCapture() completed.")
    }
    
    // SCStreamOutput Delegate
    @objc func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            guard udpSocket >= 0 else { return }
            
            // v3.1.2: If muted, skip system audio frames (only pulses will go through)
            if isMuted { return }
            
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription!)?.pointee else { return }
            
            let channelCount = Int(asbd.mChannelsPerFrame)
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            
            var blockBuffer: CMBlockBuffer?
            let bufferListPtr = AudioBufferList.allocate(maximumBuffers: channelCount)
            defer { free(bufferListPtr.unsafeMutablePointer) }
            
            CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                sampleBuffer,
                bufferListSizeNeededOut: nil,
                bufferListOut: bufferListPtr.unsafeMutablePointer,
                bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
                blockBufferAllocator: nil,
                blockBufferMemoryAllocator: nil,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                blockBufferOut: &blockBuffer
            )
            
            var pcmData = Data()
            var interleavedInt16 = [Int16]()
            interleavedInt16.reserveCapacity(frameCount * 2)
            
            if channelCount == 2 {
                let ptrL = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                let ptrR = bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self)
                
                if let l = ptrL, let r = ptrR {
                    for i in 0..<frameCount {
                        interleavedInt16.append(Int16(max(-1.0, min(1.0, l[i])) * 32767.0))
                        interleavedInt16.append(Int16(max(-1.0, min(1.0, r[i])) * 32767.0))
                    }
                    pcmData = Data(bytes: interleavedInt16, count: interleavedInt16.count * 2)
                }
            } else {
                let ptr = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                if let p = ptr {
                    for i in 0..<frameCount {
                        let val = Int16(max(-1.0, min(1.0, p[i])) * 32767.0)
                        interleavedInt16.append(val)
                        interleavedInt16.append(val)
                    }
                    pcmData = Data(bytes: interleavedInt16, count: interleavedInt16.count * 2)
                }
            }
            
            if !pcmData.isEmpty {
                // Inject Timestamp (Diagnostic Header)
                let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
                sendPacket(pcmData: pcmData, timestamp: timestamp)
            }
        }
    }

    func sendCalibrationPulse() {
        // v3.3.0: Standard Audio Pulse (Hido reitti)
        // Generate 10ms of 600Hz square wave at 48kHz
        let frameCount = 480 // 10ms
        var samples = [Int16]()
        samples.reserveCapacity(frameCount * 2)
        
        for i in 0..<frameCount {
            // v3.1.3/v3.3.0: Remote Audio Pulse = 600Hz (Low Pop)
            let val = (i % 80 < 40) ? Int16(12000) : Int16(-12000)
            samples.append(val)
            samples.append(val)
        }
        
        let pcmData = Data(bytes: samples, count: samples.count * 2)
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        sendPacket(pcmData: pcmData, timestamp: timestamp)
        print("🔊 Audio Pulse (Slow) Sent to Android")
    }

    func sendCommandPulse() {
        // v3.3.0: Fast-Path Command (Pikareitti)
        let msg = "CMD:BEEP"
        if let data = msg.data(using: .utf8), var addr = targetAddress {
            let bytes = data.withUnsafeBytes { $0.baseAddress }
            if let bytes = bytes {
                sendto(udpSocket, bytes, data.count, 0, 
                       withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, 
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            print("⚡️ Command Pulse (Fast) Sent to Android")
        }
    }

    private func sendPacket(pcmData: Data, timestamp: Int64) {
        var packetData = Data()
        withUnsafeBytes(of: timestamp.bigEndian) { packetData.append(contentsOf: $0) }
        packetData.append(pcmData)
        
        if var addr = targetAddress {
            let bytes = packetData.withUnsafeBytes { $0.baseAddress }
            if let bytes = bytes {
                sendto(udpSocket, bytes, packetData.count, 0, 
                       withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, 
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("❌ Stream stopped with error: \(error.localizedDescription)")
    }
    
    func streamDidBecomeActive(_ stream: SCStream) {
        print("✅ Stream is now ACTIVE")
    }
    
    func streamDidBecomeInactive(_ stream: SCStream) {
        print("⚠️ Stream became INACTIVE")
    }
}
