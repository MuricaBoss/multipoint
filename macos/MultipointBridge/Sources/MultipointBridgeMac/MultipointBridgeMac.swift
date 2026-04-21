import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

@main
class MultipointBridgeApp: NSObject, NSApplicationDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    var statusItem: NSStatusItem?
    var mainWindow: NSWindow?
    var nameField: NSTextField?
    
    let captureManager = AudioCaptureManager()
    let serviceBrowser = NetServiceBrowser()
    var discoveredServices = [NetService]()
    var isStreaming = false
    var targetIP: String?
    private var customDeviceName: String = "Multipoint-Host"
    private var nameHeartbeatTask: Task<Void, Never>?
    
    // v3.0.0 Calibration Mode
    private var isCalibrationEnabled = false
    private var calibrationThread: Thread? // v4.0.0: Atomic Sequencer
    private var syncOffsetMs: Double = 310.0
    private var localSinePlayer: AVAudioPlayerNode?
    private var audioEngine: AVAudioEngine?
    private var sonarBuffer = [Float]() // v5.0.0: Recording buffer
    private var isRecordingSonar = false
    private var sonarStartTime: Date?
    private var calibrationUIElements = [NSView]()

    static func main() {
        let app = NSApplication.shared
        let delegate = MultipointBridgeApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Load saved name
        if let savedName = UserDefaults.standard.string(forKey: "MultipointDeviceName") {
            customDeviceName = savedName
        }
        
        setupStatusBar()
        createMainWindow()
        
        // Start Global Identity Heartbeat immediately
        startIdentityHeartbeat()

        // Start Bonjour search
        serviceBrowser.delegate = self
        serviceBrowser.searchForServices(ofType: "_multipoint._udp", inDomain: "local.")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startIdentityHeartbeat() {
        nameHeartbeatTask?.cancel()
        nameHeartbeatTask = Task {
            print("👤 Starting Global Identity Heartbeat (\(customDeviceName)) on port 9998")
            
            // Setup Broadcast Address
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9998).bigEndian
            addr.sin_addr.s_addr = inet_addr("255.255.255.255")
            
            while !Task.isCancelled {
                // Ensure the name is trimmed and has no hidden characters before sending
                let cleanName = customDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                var msg = "MSG:NAME:\(cleanName)"
                
                // PAD message to ensure it's not too small for some network hardware (min 48 bytes)
                while msg.count < 48 {
                    msg += " "
                }
                
                guard let data = msg.data(using: .utf8) else { break }
                print("👤 Identity Broadcast (\(cleanName)) [\(data.count) bytes]")
                
                let s = socket(AF_INET, SOCK_DGRAM, 0)
                if s >= 0 {
                    var broadcastEnable: Int32 = 1
                    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
                    
                    let bytes = data.withUnsafeBytes { $0.baseAddress }
                    sendto(s, bytes, data.count, 0, 
                           withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, 
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                    close(s)
                }
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            }
        }
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🎧 Multipoint"
        }
        setupMenu()
    }

    func createMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 450),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Multipoint Mixer (v5.0.1 - SONAR+)"
        window.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        
        // --- TITLE SECTION ---
        let mainTitle = NSTextField(labelWithString: "🎧 MULTIPOINT MIXER (v5.0.0)")
        mainTitle.frame = NSRect(x: 20, y: 410, width: 310, height: 24)
        mainTitle.font = .systemFont(ofSize: 18, weight: .bold)
        mainTitle.alignment = .center
        contentView.addSubview(mainTitle)

        // --- DEVICE NAME SECTION ---
        let nameLabel = NSTextField(labelWithString: "DEVICE NAME:")
        nameLabel.frame = NSRect(x: 20, y: 370, width: 100, height: 20)
        nameLabel.font = .systemFont(ofSize: 11, weight: .bold)
        contentView.addSubview(nameLabel)
        
        let field = NSTextField(frame: NSRect(x: 20, y: 345, width: 230, height: 24))
        field.stringValue = customDeviceName
        field.font = .systemFont(ofSize: 14)
        contentView.addSubview(field)
        self.nameField = field
        
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(saveNameFromWindow))
        saveBtn.frame = NSRect(x: 255, y: 341, width: 80, height: 32)
        contentView.addSubview(saveBtn)
        
        // --- CALIBRATION SECTION (v4.0.0 / v5.0.0) ---
        let calTitle = NSTextField(labelWithString: "🔧 ATOMIC CALIBRATION")
        calTitle.frame = NSRect(x: 20, y: 300, width: 250, height: 20)
        calTitle.font = .systemFont(ofSize: 12, weight: .bold)
        calTitle.textColor = .systemRed
        contentView.addSubview(calTitle)
        
        let calSwitch = NSButton(checkboxWithTitle: "Enable Calibration Ticks", target: self, action: #selector(toggleCalibration))
        calSwitch.frame = NSRect(x: 20, y: 275, width: 200, height: 20)
        contentView.addSubview(calSwitch)
        
        let offsetLabel = NSTextField(labelWithString: "Sync Offset: 310 ms")
        offsetLabel.frame = NSRect(x: 20, y: 250, width: 200, height: 20)
        offsetLabel.tag = 601
        contentView.addSubview(offsetLabel)
        
        let slider = NSSlider(value: 310.0, minValue: 0.0, maxValue: 1000.0, target: self, action: #selector(onSliderMove))
        slider.frame = NSRect(x: 20, y: 225, width: 310, height: 24)
        slider.tag = 600
        contentView.addSubview(slider)
        
        // --- SONAR AUTO-CALIBRATE SECTION (v5.0.0) ---
        let sonarTitle = NSTextField(labelWithString: "📡 SONAR AUTO-SYNC")
        sonarTitle.frame = NSRect(x: 20, y: 190, width: 250, height: 20)
        sonarTitle.font = .systemFont(ofSize: 12, weight: .bold)
        sonarTitle.textColor = .systemGreen
        contentView.addSubview(sonarTitle)

        let autoBtn = NSButton(title: "🚀 RUN ACOUSTIC MEASUREMENT", target: self, action: #selector(startAutoCalibration))
        autoBtn.frame = NSRect(x: 20, y: 155, width: 310, height: 32)
        autoBtn.bezelStyle = .rounded
        contentView.addSubview(autoBtn)
        
        let sonarStatus = NSTextField(labelWithString: "Ready for Sonar... Hold headphones to Mic! 📡")
        sonarStatus.frame = NSRect(x: 20, y: 135, width: 310, height: 20)
        sonarStatus.font = .systemFont(ofSize: 11)
        sonarStatus.alignment = .center
        sonarStatus.tag = 700
        contentView.addSubview(sonarStatus)
        
        // --- MIC LEVEL METER (v5.0.1) ---
        let levelLabel = NSTextField(labelWithString: "Mic Input Level:")
        levelLabel.frame = NSRect(x: 20, y: 115, width: 100, height: 15)
        levelLabel.font = .systemFont(ofSize: 9)
        contentView.addSubview(levelLabel)
        
        let levelBar = NSProgressIndicator(frame: NSRect(x: 120, y: 116, width: 210, height: 12))
        levelBar.isIndeterminate = false
        levelBar.minValue = 0
        levelBar.maxValue = 1
        levelBar.tag = 701
        contentView.addSubview(levelBar)
        
        // --- STATUS SECTION ---
        let statusTitle = NSTextField(labelWithString: "STATUS:")
        statusTitle.frame = NSRect(x: 20, y: 100, width: 100, height: 20)
        statusTitle.font = .systemFont(ofSize: 11, weight: .bold)
        contentView.addSubview(statusTitle)
        
        let windowStatus = NSTextField(labelWithString: "Searching for receiver...")
        windowStatus.frame = NSRect(x: 20, y: 75, width: 310, height: 24)
        windowStatus.font = .systemFont(ofSize: 14)
        windowStatus.tag = 500
        contentView.addSubview(windowStatus)
        
        // IP Manual Connect
        let manualBtn = NSButton(title: "Manual IP Connect...", target: self, action: #selector(promptForIP))
        manualBtn.frame = NSRect(x: 20, y: 40, width: 150, height: 32)
        contentView.addSubview(manualBtn)
        
        self.mainWindow = window
        window.setFrame(NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: 350, height: 350), display: true)
        window.makeKeyAndOrderFront(self)
    }

    @objc func toggleCalibration(_ sender: NSButton) {
        isCalibrationEnabled = (sender.state == .on)
        captureManager.isMuted = isCalibrationEnabled
        
        if isCalibrationEnabled {
            print("🚀 Atomic Sequencer Started (v5.0.0)")
            setupAudioEngine()
            requestMicrophoneAccess()
            startAtomicSequencer()
        } else {
            print("🛑 Atomic Sequencer Stopped")
            audioEngine?.stop()
        }
    }

    private func requestMicrophoneAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print(granted ? "🎤 Mic Access Granted" : "❌ Mic Access Denied")
            }
        case .restricted, .denied:
            print("⚠️ Mic access denied. Auto-Calibration Won't work.")
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    @objc func startAutoCalibration() {
        print("📡 Sonar Calibration Initiated...")
        guard let status = mainWindow?.contentView?.viewWithTag(700) as? NSTextField else { return }
        status.stringValue = "Measuring... Stay quiet! 🤫"
        status.textColor = .systemGreen
        
        setupAudioEngine()
        
        // Start recording
        sonarBuffer.removeAll()
        sonarStartTime = Date()
        isRecordingSonar = true
        
        // Send the pulse to Android
        captureManager.sendCalibrationPulse()
        
        // Wait 1.5s for return, then analyze
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isRecordingSonar = false
            self?.analyzeSonarBuffer()
        }
    }

    private func analyzeSonarBuffer() {
        guard let status = mainWindow?.contentView?.viewWithTag(700) as? NSTextField else { return }
        
        if sonarBuffer.isEmpty {
            status.stringValue = "Error: No audio recorded! ❌"
            status.textColor = .systemRed
            return
        }
        
        // v5.0.0: Simple Peak Detection
        // Look for the highest absolute value in the buffer
        var maxVal: Float = 0
        var maxIndex = 0
        
        for (i, sample) in sonarBuffer.enumerated() {
            let absVal = abs(sample)
            if absVal > maxVal {
                maxVal = absVal
                maxIndex = i
            }
        }
        
        // 48000 samples per second
        let timeOffsetMs = Double(maxIndex) / 48.0
        
        // v5.0.1: Lowered threshold (0.05)
        if maxVal < 0.05 {
            status.stringValue = "Still too quiet! 🔊⬆️ Find the mic hole!"
            status.textColor = .systemOrange
        } else {
            print("🎯 Sonar detected peak at \(Int(timeOffsetMs))ms with magnitude \(maxVal)")
            
            // Update the slider and label
            syncOffsetMs = timeOffsetMs
            if let slider = mainWindow?.contentView?.viewWithTag(600) as? NSSlider {
                slider.doubleValue = syncOffsetMs
            }
            if let label = mainWindow?.contentView?.viewWithTag(601) as? NSTextField {
                label.stringValue = "Sync Offset: \(Int(syncOffsetMs)) ms"
            }
            
            status.stringValue = "Auto-Synced: \(Int(timeOffsetMs)) ms! ✅"
            status.textColor = .systemGreen
        }
    }

    private func startAtomicSequencer() {
        calibrationThread = Thread { [weak self] in
            guard let self = self else { return }
            
            var timebaseInfo = mach_timebase_info()
            mach_timebase_info(&timebaseInfo)
            
            let cycleLengthSeconds: Double = 1.5
            let cycleLengthTicks = UInt64(cycleLengthSeconds * 1_000_000_000 * Double(timebaseInfo.denom) / Double(timebaseInfo.numer))
            
            while self.isCalibrationEnabled {
                let startTicks = mach_absolute_time()
                
                // 1. Send Audio Pulse (Slow Path) to Android at T=0
                self.captureManager.sendCalibrationPulse()
                
                // 2. Wait for Slider Delay
                let offsetMs = self.syncOffsetMs
                let delayTicks = UInt64(offsetMs * 1_000_000 * Double(timebaseInfo.denom) / Double(timebaseInfo.numer))
                
                mach_wait_until(startTicks + delayTicks)
                
                // 3. Play Local Pulse (Mac Speaker) at T=Slider
                if self.isCalibrationEnabled {
                    self.playLocalTick()
                }
                
                // 4. Wait for next cycle
                mach_wait_until(startTicks + cycleLengthTicks)
            }
        }
        
        calibrationThread?.qualityOfService = .userInteractive
        calibrationThread?.start()
    }

    @objc func onSliderMove(_ sender: NSSlider) {
        syncOffsetMs = sender.doubleValue
        if let label = mainWindow?.contentView?.viewWithTag(601) as? NSTextField {
            label.stringValue = "Sync Offset: \(Int(syncOffsetMs)) ms"
        }
    }

    private func setupAudioEngine() {
        if audioEngine != nil { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        
        do {
            // Tap the input for Sonar
            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                
                // Update Mic Level (v5.0.1)
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    var peak: Float = 0
                    for i in 0..<frameCount {
                        peak = max(peak, abs(channelData[0][i]))
                    }
                    DispatchQueue.main.async {
                        if let bar = self.mainWindow?.contentView?.viewWithTag(701) as? NSProgressIndicator {
                            bar.doubleValue = Double(peak)
                        }
                    }
                    
                    if self.isRecordingSonar {
                        let data = channelData[0]
                        for i in 0..<frameCount {
                            self.sonarBuffer.append(data[i])
                        }
                    }
                }
            }

            try engine.start()
            self.audioEngine = engine
            self.localSinePlayer = player
        } catch {
            print("❌ Calibration Audio Engine failed")
        }
    }

    private func playLocalTick() {
        guard let player = localSinePlayer, let engine = audioEngine, engine.isRunning else { return }
        
        // Simple tick: 1kHz sine for 0.01s
        let sampleRate = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
        let frameCount = AVAudioFrameCount(sampleRate * 0.01)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.mainMixerNode.outputFormat(forBus: 0), frameCapacity: frameCount) else { return }
        
        buffer.frameLength = frameCount
        let channels = Int(buffer.format.channelCount)
        for c in 0..<channels {
            let data = buffer.floatChannelData![c]
            for i in 0..<Int(frameCount) {
                data[i] = sinf(Float(i) * 2.0 * Float.pi * 1200.0 / Float(sampleRate)) * 0.5
            }
        }
        
        player.play()
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    @objc func saveNameFromWindow() {
        if let newName = nameField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty {
            customDeviceName = newName
            UserDefaults.standard.set(newName, forKey: "MultipointDeviceName")
            updateMenuName()
            startIdentityHeartbeat() // Refresh heartbeat with new name
            print("👤 Name updated via window: \(newName)")
        }
    }

    func updateMenuName() {
        if let nameItem = statusItem?.menu?.item(withTag: 102) {
            nameItem.title = "Set Device Name (\(customDeviceName))..."
        }
    }

    func setupMenu() {
        let menu = NSMenu()
        
        let statusLabel = NSMenuItem(title: "Searching for receiver...", action: nil, keyEquivalent: "")
        statusLabel.tag = 100
        menu.addItem(statusLabel)
        
        menu.addItem(NSMenuItem.separator())
        
        let nameItem = NSMenuItem(title: "Set Device Name (\(customDeviceName))...", action: #selector(promptForName), keyEquivalent: "n")
        nameItem.tag = 102
        menu.addItem(nameItem)
        
        let startItem = NSMenuItem(title: "Connect Manually...", action: #selector(promptForIP), keyEquivalent: "c")
        menu.addItem(startItem)
        
        let stopItem = NSMenuItem(title: "Disconnect", action: #selector(stopStreaming), keyEquivalent: "d")
        stopItem.tag = 101
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Multipoint Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }

    @objc func promptForName() {
        let alert = NSAlert()
        alert.messageText = "Set Device Name"
        alert.informativeText = "This name will appear in the Android mixer:"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.stringValue = customDeviceName
        alert.accessoryView = input
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                customDeviceName = name
                UserDefaults.standard.set(name, forKey: "MultipointDeviceName")
                if let nameItem = statusItem?.menu?.item(withTag: 102) {
                    nameItem.title = "Set Device Name (\(name))..."
                }
                startIdentityHeartbeat() // Refresh heartbeat with new name
            }
        }
    }

    func updateStatusMessage(_ message: String, isError: Bool = false) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                button.title = isError ? "⚠️ " + message : "🎧 " + message
            }
            if let statusLabel = self.statusItem?.menu?.item(withTag: 100) {
                statusLabel.title = message
            }
            if let windowStatus = self.mainWindow?.contentView?.viewWithTag(500) as? NSTextField {
                windowStatus.stringValue = message
                windowStatus.textColor = isError ? .systemRed : .labelColor
            }
            if let stopItem = self.statusItem?.menu?.item(withTag: 101) {
                stopItem.isEnabled = self.isStreaming
            }
        }
    }

    @objc func promptForIP() {
        let alert = NSAlert()
        alert.messageText = "Connect to Bridge"
        alert.informativeText = "Enter the IP address of your Android device:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        input.placeholderString = "192.168.0.xxx"
        alert.accessoryView = input
        
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let ip = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty {
                startStreaming(to: ip)
            }
        }
    }

    // MARK: - NetServiceBrowserDelegate
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("✨ Found Service: \(service.name) (type: \(service.type))")
        discoveredServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        print("❌ Discovery failed to start: \(errorDict)")
        updateStatusMessage("Discovery Error", isError: true)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("❌ Failed to resolve service \(sender.name): \(errorDict)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addressData = sender.addresses?.first else { return }
        
        // Resolve IP address to string
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        addressData.withUnsafeBytes { pointer in
            let sockaddrPtr = pointer.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            getnameinfo(sockaddrPtr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        }
        
        let ip = String(cString: hostname)
        print("✅ Auto-Resolved \(sender.name) to \(ip)")
        
        if !isStreaming {
            startStreaming(to: ip)
        }
    }

    @objc func startStreaming(to ip: String) {
        self.targetIP = ip
        isStreaming = true
        
        updateStatusMessage("Streaming to \(ip)")
        
        Task {
            do {
                captureManager.setTarget(ip: ip, port: 9999)
                try await captureManager.startCapture()
            } catch {
                print("❌ Failed to start streaming: \(error)")
                stopStreaming()
                updateStatusMessage("Stream Error", isError: true)
            }
        }
    }

    @objc func stopStreaming() {
        isStreaming = false
        nameHeartbeatTask?.cancel()
        nameHeartbeatTask = nil
        captureManager.stopCapture()
        updateStatusMessage("Disconnected")
    }
}
