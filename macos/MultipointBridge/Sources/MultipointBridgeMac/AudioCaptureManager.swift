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
        config.channelCount = 2 // Stereo
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
        if type == .audio {
            guard dataChannel.readyState == .open else { return }
            
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
            
            if channelCount == 2 {
                let ptrL = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                let ptrR = bufferListPtr[1].mData?.assumingMemoryBound(to: Float.self)
                
                if let l = ptrL, let r = ptrR {
                    for i in 0..<frameCount {
                        let sL = max(-1.0, min(1.0, l[i]))
                        interleavedInt16.append(Int16(sL * 32767.0))
                        let sR = max(-1.0, min(1.0, r[i]))
                        interleavedInt16.append(Int16(sR * 32767.0))
                    }
                }
            } else {
                // Fallback to Mono if needed, but still output 2 channels for Android
                let ptr = bufferListPtr[0].mData?.assumingMemoryBound(to: Float.self)
                if let p = ptr {
                    for i in 0..<frameCount {
                        let sample = max(-1.0, min(1.0, p[i]))
                        let val = Int16(sample * 32767.0)
                        interleavedInt16.append(val)
                        interleavedInt16.append(val)
                    }
                }
            }
            
            let data = Data(bytes: interleavedInt16, count: interleavedInt16.count * 2)
            let base64String = data.base64EncodedString()
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
