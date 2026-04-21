import Foundation
import ScreenCaptureKit
import AVFoundation
import WebRTC

class AudioCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let dataChannel: RTCDataChannel
    
    init(dataChannel: RTCDataChannel) {
        self.dataChannel = dataChannel
        super.init()
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
        config.channelCount = 1
        config.width = 100
        config.height = 100
        config.queueDepth = 10
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        let captureQueue = DispatchQueue(label: "com.antigravity.audioCapture", qos: .userInteractive)
        
        print("🎙️ Adding stream outputs...")
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        
        try await stream?.startCapture()
        print("🎙️ SCStream.startCapture() completed.")
    }
    
    // SCStreamOutput Delegate
    @objc func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // print("📈 Delegate poke: \(type == .audio ? "AUDIO" : "VIDEO")")
        
        if type == .audio {
            guard dataChannel.readyState == .open else { 
                // print("⏳ DataChannel not open, skipping buffer")
                return 
            }
            
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { 
                // print("📭 Empty audio buffer")
                return 
            }
            
            let length = CMBlockBufferGetDataLength(blockBuffer)
            // print("📤 Sending \(length) bytes")
            
            var data = Data(count: length)
            data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                if let baseAddress = buffer.baseAddress {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
                }
            }
            // Convert Float32 to Int16
            let count = length / MemoryLayout<Float>.size
            var int16Data = Data(count: count * MemoryLayout<Int16>.size)
            
            data.withUnsafeBytes { (floatPtr: UnsafeRawBufferPointer) in
                let floats = floatPtr.bindMemory(to: Float.self)
                int16Data.withUnsafeMutableBytes { (int16Ptr: UnsafeMutableRawBufferPointer) in
                    let ints = int16Ptr.bindMemory(to: Int16.self)
                    for i in 0..<count {
                        // Clamp and convert
                        let sample = floats[i]
                        let clamped = max(-1.0, min(1.0, sample))
                        ints[i] = Int16(clamped * 32767.0)
                    }
                }
            }
            
            let base64String = int16Data.base64EncodedString()
            // print("📤 Sending \(count) samples as Base64 (\(base64String.count) chars)")
            let buffer = RTCDataBuffer(data: base64String.data(using: .utf8)!, isBinary: false)
            dataChannel.sendData(buffer)
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
