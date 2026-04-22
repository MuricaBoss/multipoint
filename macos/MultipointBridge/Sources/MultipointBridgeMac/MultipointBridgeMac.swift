import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation
import CoreAudio

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
    
    private var cachedBlackHoleID: AudioObjectID?
    private var lastUpdateTimestamp: TimeInterval = 0
    private var minUpdateInterval: TimeInterval = 0.05
    private var cachedSampleRate: Double = 48000.0
    
    private var isCalibrationEnabled = false
    private var localSinePlayer: AVAudioPlayerNode?
    private var audioEngine: AVAudioEngine?
    private var sonarBuffer = [Float]()
    private var isRecordingSonar = false
    private weak var levelBar: NSProgressIndicator?
    
    private var permissionCheckTimer: Timer?
    private var hasGrantedPermission = false
    
    // v27.0: Manual Approval State
    private var pendingLatency: Int?

    static func main() {
        let app = NSApplication.shared
        let delegate = MultipointBridgeApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if #available(macOS 10.15, *) {
            CGRequestScreenCaptureAccess()
        }

        if let savedName = UserDefaults.standard.string(forKey: "MultipointDeviceName") {
            customDeviceName = savedName
        }
        
        setupStatusBar()
        createMainWindow()
        startIdentityHeartbeat()

        serviceBrowser.delegate = self
        serviceBrowser.searchForServices(ofType: "_multipoint._udp", inDomain: "local.")
        NSApp.activate(ignoringOtherApps: true)

        startPermissionCheckLoop()
    }

    private func startPermissionCheckLoop() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    private func checkPermissions() {
        let status = CGPreflightScreenCaptureAccess()
        if status && !hasGrantedPermission {
            hasGrantedPermission = true
            DispatchQueue.main.async {
                self.createMainWindow() 
            }
        }
    }

    private func startIdentityHeartbeat() {
        nameHeartbeatTask?.cancel()
        nameHeartbeatTask = Task {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(9998).bigEndian
            addr.sin_addr.s_addr = inet_addr("255.255.255.255")
            
            while !Task.isCancelled {
                let cleanName = customDeviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                var msg = "MSG:NAME:\(cleanName)"
                while msg.count < 48 { msg += " " }
                
                guard let data = msg.data(using: .utf8) else { break }
                let s = socket(AF_INET, SOCK_DGRAM, 0)
                if s >= 0 {
                    var broadcastEnable: Int32 = 1
                    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
                    let bytes = data.withUnsafeBytes { $0.baseAddress }
                    sendto(s, bytes, data.count, 0, withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 } }, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        hasGrantedPermission = CGPreflightScreenCaptureAccess()
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Multipoint Mixer"
        window.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        
        let mainTitle = NSTextField(labelWithString: "🎧 MULTIPOINT MIXER")
        mainTitle.frame = NSRect(x: 20, y: window.frame.height - 60, width: 310, height: 24)
        mainTitle.font = .systemFont(ofSize: 18, weight: .bold)
        mainTitle.alignment = .center
        contentView.addSubview(mainTitle)

        if !hasGrantedPermission {
            let infoBox = NSView(frame: NSRect(x: 30, y: 150, width: 310, height: 140))
            infoBox.wantsLayer = true
            infoBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.05).cgColor
            infoBox.layer?.cornerRadius = 12
            infoBox.layer?.borderWidth = 1.5
            infoBox.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
            contentView.addSubview(infoBox)

            let infoText = NSTextField(labelWithString: "⚠️ PERMISSION REQUIRED\n\nMultipoint needs Screen Recording permission to capture system audio.\n\nGrant it in: System Settings > Screen Recording.")
            infoText.frame = NSRect(x: 15, y: 15, width: 280, height: 110)
            infoText.font = .systemFont(ofSize: 13, weight: .medium)
            infoText.alignment = .center
            infoText.textColor = .labelColor
            infoText.cell?.isScrollable = false
            infoText.cell?.wraps = true
            infoText.lineBreakMode = .byWordWrapping
            infoBox.addSubview(infoText)
            
            let settingsBtn = NSButton(title: "1. Open Privacy Settings...", target: self, action: #selector(openPrivacySettings))
            settingsBtn.frame = NSRect(x: 10, y: 100, width: 350, height: 45)
            settingsBtn.bezelStyle = .rounded
            contentView.addSubview(settingsBtn)
            
            let manualStartBtn = NSButton(title: "2. Permission granted? QUIT & RESTART 🚀", target: self, action: #selector(relaunchApp))
            manualStartBtn.frame = NSRect(x: 10, y: 35, width: 350, height: 55)
            manualStartBtn.bezelStyle = .rounded
            manualStartBtn.highlight(true)
            contentView.addSubview(manualStartBtn)
            
        } else {
            let infoBox = NSView(frame: NSRect(x: 20, y: 190, width: 330, height: 240))
            infoBox.wantsLayer = true
            infoBox.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.03).cgColor
            infoBox.layer?.cornerRadius = 12
            infoBox.layer?.borderWidth = 1.5
            infoBox.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.3).cgColor
            contentView.addSubview(infoBox)

            let infoText = NSTextField(labelWithString: "🔍 SEARCHING FOR MIXER...\n\nConnect phone to same Wi-Fi and press 'Start Multipoint Mixer' on phone.")
            infoText.frame = NSRect(x: 10, y: 10, width: 310, height: 220)
            infoText.font = .systemFont(ofSize: 15, weight: .bold)
            infoText.alignment = .center
            infoText.textColor = .secondaryLabelColor
            infoText.tag = 900
            infoText.cell?.isScrollable = false
            infoText.cell?.wraps = true
            infoText.lineBreakMode = .byWordWrapping
            infoBox.addSubview(infoText)
            
            let testBtn = NSButton(title: "🚀 SYNC DELAY", target: self, action: #selector(startAutoCalibration))
            testBtn.frame = NSRect(x: 20, y: 120, width: 330, height: 60)
            testBtn.bezelStyle = .rounded
            testBtn.highlight(true)
            testBtn.tag = 800
            testBtn.isHidden = true
            contentView.addSubview(testBtn)
            
            // v27.0: ACCEPT & INSTALL Button (Tag 802)
            let acceptBtn = NSButton(title: "✅ ACCEPT & ADJUST DRIVER", target: self, action: #selector(confirmInstallation))
            acceptBtn.frame = NSRect(x: 20, y: 120, width: 330, height: 60) // Same spot as testBtn
            acceptBtn.bezelStyle = .rounded
            acceptBtn.highlight(true)
            acceptBtn.tag = 802
            acceptBtn.isHidden = true
            contentView.addSubview(acceptBtn)
            
            let levelBar = NSProgressIndicator(frame: NSRect(x: 35, y: 100, width: 300, height: 14))
            levelBar.isIndeterminate = false
            levelBar.minValue = 0
            levelBar.maxValue = 1
            levelBar.tag = 801
            levelBar.isHidden = true
            contentView.addSubview(levelBar)
            self.levelBar = levelBar
            
            let manualBtn = NSButton(title: "Manual IP Connect...", target: self, action: #selector(promptForIP))
            manualBtn.frame = NSRect(x: 110, y: 20, width: 150, height: 32)
            manualBtn.tag = 777
            contentView.addSubview(manualBtn)
        }
        
        let oldWindow = self.mainWindow
        self.mainWindow = window
        window.makeKeyAndOrderFront(self)
        oldWindow?.close()
    }

    @objc func relaunchApp() {
        NSApp.terminate(nil)
    }

    @objc func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func updateStatusMessage(_ message: String, isError: Bool = false) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button { button.title = "🎧 " + message }
            if let infoText = self.mainWindow?.contentView?.viewWithTag(900) as? NSTextField {
                if self.isStreaming {
                    infoText.stringValue = "⚡ SYNC DELAY\n\n1. Mute/Close all other audio sources.\n2. Place phone near Mac microphone.\n3. Click 'SYNC DELAY' below.\n\n(Mac sends a pulse, the mic listens,\n and the delay is auto-calculated.)"
                    infoText.textColor = .labelColor
                } else {
                    infoText.stringValue = "🔍 SEARCHING FOR MIXER...\n\nConnect phone to same Wi-Fi and press 'Start Multipoint Mixer' on phone."
                    infoText.textColor = .secondaryLabelColor
                }
            }
            if let testBtn = self.mainWindow?.contentView?.viewWithTag(800) as? NSButton {
                let showTest = self.isStreaming && self.pendingLatency == nil
                testBtn.isHidden = !showTest
            }
            self.levelBar?.isHidden = !self.isStreaming
            self.mainWindow?.contentView?.viewWithTag(777)?.isHidden = self.isStreaming
        }
    }

    @objc func promptForIP() {
        let alert = NSAlert()
        alert.messageText = "Connect to Bridge"
        alert.informativeText = "Enter IP:"
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let ip = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ip.isEmpty { startStreaming(to: ip) }
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        discoveredServices.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5.0)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addressData = sender.addresses?.first else { return }
        var hostname = [CChar](repeating: 0, count: NI_MAXHOST)
        addressData.withUnsafeBytes { pointer in
            let sockaddrPtr = pointer.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            getnameinfo(sockaddrPtr, socklen_t(addressData.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
        }
        let ip = String(cString: hostname)
        if !isStreaming { startStreaming(to: ip) }
    }

    func startStreaming(to ip: String) {
        self.targetIP = ip
        isStreaming = true
        updateStatusMessage("Connected to \(ip)")
        self.createMainWindow() 
        captureManager.setTarget(ip: ip, port: 9999)
        Task { try? await captureManager.startCapture() }
    }

    @objc func startAutoCalibration() {
        if let infoText = self.mainWindow?.contentView?.viewWithTag(900) as? NSTextField {
            infoText.stringValue = "⌛ MEASURING...\n\nKeep it quiet! 🤫"
            infoText.textColor = .systemBlue
        }
        setupAudioEngine()
        sonarBuffer.removeAll()
        isRecordingSonar = true
        captureManager.sendCalibrationPulse()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.isRecordingSonar = false
            self?.analyzeSonarBuffer()
        }
    }

    private func analyzeSonarBuffer() {
        guard let infoText = self.mainWindow?.contentView?.viewWithTag(900) as? NSTextField else { return }
        if sonarBuffer.isEmpty {
            infoText.stringValue = "❌ ERROR: NO AUDIO RECORDED!\n\nPlease check microphone permissions."
            infoText.textColor = .systemRed
            return
        }
        var maxVal: Float = 0
        var maxIndex = 0
        for (i, sample) in sonarBuffer.enumerated() {
            let absVal = abs(sample)
            if absVal > maxVal { maxVal = absVal; maxIndex = i }
        }
        if maxVal < 0.05 {
            infoText.stringValue = "⚠️ TOO QUIET! 🔊⬆️\n\nFind the mic hole on your Mac and hold the phone closer."
            infoText.textColor = .systemOrange
        } else {
            let timeOffsetMs = Double(maxIndex) / 48.0
            let closestLatencyMs = Int((timeOffsetMs / 50.0).rounded()) * 50
            self.pendingLatency = closestLatencyMs
            
            infoText.stringValue = "🎯 DELAY DETECTED: \(Int(timeOffsetMs)) ms\n\nWould you like to adjust the driver to \(closestLatencyMs) ms for perfect sync?"
            infoText.textColor = .systemBlue
            
            // Toggle buttons
            self.mainWindow?.contentView?.viewWithTag(800)?.isHidden = true // Hide Sync
            self.mainWindow?.contentView?.viewWithTag(802)?.isHidden = false // Show Accept
        }
    }

    @objc func confirmInstallation() {
        guard let ms = pendingLatency, let infoText = self.mainWindow?.contentView?.viewWithTag(900) as? NSTextField else { return }
        
        infoText.stringValue = "⚙️ ADJUNTING DRIVER... (\(ms) ms)\n\nPlease wait for the system prompt."
        infoText.textColor = .systemBlue
        self.mainWindow?.contentView?.viewWithTag(802)?.isHidden = true // Hide button during install
        
        installSpecificDriver(ms: ms)
    }

    private func installSpecificDriver(ms: Int) {
        let projectPath = "/Volumes/munapelilevy/_AntiGravity/Projektit/BlackHole-Delayed"
        let appleScript = "do shell script \"cd \(projectPath) && ./install_driver.sh \(ms)\" with administrator privileges"
        
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let script = NSAppleScript(source: appleScript) {
                script.executeAndReturnError(&error)
                DispatchQueue.main.async { [weak self] in
                    guard let infoText = self?.mainWindow?.contentView?.viewWithTag(900) as? NSTextField else { return }
                    if error != nil {
                        infoText.stringValue = "❌ INSTALLATION FAILED!\n\nPlease check permissions or manual install."
                        infoText.textColor = .systemRed
                    } else {
                        infoText.stringValue = "🎯 SYNC SUCCESS! ✅\n\nDriver: BlackHole (\(ms) ms)\n\nIMPORTANT: Set System Audio Output to 'BlackHole Delayed' if it didn't switch automatically."
                        infoText.textColor = .systemGreen
                        self?.pendingLatency = nil // Reset for next time if needed
                    }
                }
            }
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
            let inputNode = engine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                if let channelData = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    var peak: Float = 0
                    for i in 0..<frameCount { peak = max(peak, abs(channelData[0][i])) }
                    DispatchQueue.main.async { self.levelBar?.doubleValue = Double(peak) }
                    if self.isRecordingSonar {
                        let data = channelData[0]
                        for i in 0..<frameCount { self.sonarBuffer.append(data[i]) }
                    }
                }
            }
            try engine.start()
            self.audioEngine = engine
            self.localSinePlayer = player
        } catch { print("❌ Audio Engine Error") }
    }

    func setupMenu() {}
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {}
    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {}
}
