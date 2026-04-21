import Foundation
import AppKit
import ScreenCaptureKit

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
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Multipoint Mixer: Transmitter"
        window.isReleasedWhenClosed = false
        
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView
        
        // Device Name Label
        let nameLabel = NSTextField(labelWithString: "DEVICE NAME:")
        nameLabel.frame = NSRect(x: 20, y: 170, width: 100, height: 20)
        nameLabel.font = .systemFont(ofSize: 12, weight: .bold)
        contentView.addSubview(nameLabel)
        
        // Name Input field
        let field = NSTextField(frame: NSRect(x: 20, y: 140, width: 230, height: 24))
        field.stringValue = customDeviceName
        field.font = .systemFont(ofSize: 14)
        contentView.addSubview(field)
        self.nameField = field
        
        // Save Button
        let saveBtn = NSButton(title: "Save & Identity", target: self, action: #selector(saveNameFromWindow))
        saveBtn.frame = NSRect(x: 255, y: 136, width: 80, height: 32)
        contentView.addSubview(saveBtn)
        
        // Status Row
        let statusTitle = NSTextField(labelWithString: "STATUS:")
        statusTitle.frame = NSRect(x: 20, y: 100, width: 100, height: 20)
        statusTitle.font = .systemFont(ofSize: 12, weight: .bold)
        contentView.addSubview(statusTitle)
        
        let statusText = NSTextField(labelWithString: "Searching for Android...")
        statusText.frame = NSRect(x: 20, y: 80, width: 300, height: 20)
        statusText.tag = 500
        contentView.addSubview(statusText)
        
        // IP Manual Connect
        let manualBtn = NSButton(title: "Manual IP Connect...", target: self, action: #selector(promptForIP))
        manualBtn.frame = NSRect(x: 20, y: 40, width: 150, height: 32)
        contentView.addSubview(manualBtn)
        
        self.mainWindow = window
        window.makeKeyAndOrderFront(nil)
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
