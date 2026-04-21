import Foundation
import AppKit
import ScreenCaptureKit

@main
class MultipointBridgeApp: NSObject, NSApplicationDelegate, NetServiceBrowserDelegate, NetServiceDelegate {
    var statusItem: NSStatusItem?
    let captureManager = AudioCaptureManager()
    let serviceBrowser = NetServiceBrowser()
    var discoveredServices = [NetService]()
    var isStreaming = false
    var targetIP: String?

    static func main() {
        let app = NSApplication.shared
        let delegate = MultipointBridgeApp()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up Status Item (Menubar)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "🎧 Multipoint: Scanning..."
        }
        
        setupMenu()
        
        // Start searching for Android receiver via Bonjour
        serviceBrowser.delegate = self
        // Use an empty domain to search everywhere or "local."
        serviceBrowser.searchForServices(ofType: "_multipoint._udp", inDomain: "local.")
        print("📡 Searching for Multipoint receivers (_multipoint._udp.local.)...")
    }

    func setupMenu() {
        let menu = NSMenu()
        
        let statusLabel = NSMenuItem(title: "Searching for receiver...", action: nil, keyEquivalent: "")
        statusLabel.tag = 100
        menu.addItem(statusLabel)
        
        menu.addItem(NSMenuItem.separator())
        
        let startItem = NSMenuItem(title: "Connect Manually...", action: #selector(promptForIP), keyEquivalent: "c")
        menu.addItem(startItem)
        
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Multipoint Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }

    func updateStatusMessage(_ message: String, isError: Bool = false) {
        DispatchQueue.main.async {
            if let button = self.statusItem?.button {
                button.title = isError ? "⚠️ " + message : "🎧 " + message
            }
            if let statusLabel = self.statusItem?.menu?.item(withTag: 100) {
                statusLabel.title = message
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

    func startStreaming(to ip: String) {
        self.targetIP = ip
        isStreaming = true
        updateStatusMessage("Connecting to \(ip)...")
        
        Task {
            do {
                captureManager.setTargetIP(ip)
                try await captureManager.startCapture()
                updateStatusMessage("Streaming Audio")
            } catch {
                print("❌ Failed to start streaming: \(error)")
                isStreaming = false
                updateStatusMessage("Auto-connect Failed", isError: true)
            }
        }
    }
}
