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
    
    // VAD settings
    private let silenceThreshold: Float = 0.0001 // More sensitive (-80dB)
    private var silenceCounter: Int = 0
    private let silenceHangoverFrames: Int = 50 // Approx 500ms at 10ms chunks

    func setTarget(ip: String, port: Int) {
        if udpSocket >= 0 { close(udpSocket) }
        udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(ip)
        targetAddress = addr
        print("📡 UDP Target Set: \(ip):\(port)")
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
        
        print("🖥️ Found Display: \(display.width)x\(display.height) (ID: \(display.displayID))")
        
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        
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
            
            var blockBuffer: CMBlockBuffer?
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer)
            guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription!)?.pointee else { return }
            
            let channelCount = Int(asbd.mChannelsPerFrame)
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            
            // Allocate space for the buffer list based on channel count
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
            
            var interleavedInt16 = [Int16]()
            interleavedInt16.reserveCapacity(frameCount * 2)
            var maxAmp: Float = 0
            
            if channelCount == 2 {
                let ptrL = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                let ptrR = bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self)
                
                if let l = ptrL, let r = ptrR {
                    for i in 0..<frameCount {
                        let sL = l[i]
                        let sR = r[i]
                        maxAmp = max(maxAmp, abs(sL), abs(sR))
                        
                        interleavedInt16.append(Int16(max(-1.0, min(1.0, sL)) * 32767.0))
                        interleavedInt16.append(Int16(max(-1.0, min(1.0, sR)) * 32767.0))
                    }
                }
            } else {
                let ptr = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                if let p = ptr {
                    for i in 0..<frameCount {
                        let sample = p[i]
                        maxAmp = max(maxAmp, abs(sample))
                        let val = Int16(max(-1.0, min(1.0, sample)) * 32767.0)
                        interleavedInt16.append(val)
                        interleavedInt16.append(val)
                    }
                }
            }
            
            // Silence Suppression
            if maxAmp < silenceThreshold {
                silenceCounter += 1
            } else {
                silenceCounter = 0
            }
            
            if silenceCounter > silenceHangoverFrames {
                return
            }
            
            let data = Data(bytes: interleavedInt16, count: interleavedInt16.count * 2)
            
            if var addr = targetAddress {
                let bytes = data.withUnsafeBytes { $0.baseAddress }
                if let bytes = bytes {
                    sendto(udpSocket, bytes, data.count, 0, 
                           withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, 
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
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
