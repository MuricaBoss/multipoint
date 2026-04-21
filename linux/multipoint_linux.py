import socket
import time
import subprocess
from zeroconf import ServiceBrowser, Zeroconf

class MultipointDiscovery:
    def __init__(self):
        self.target_ip = None

    def update_service(self, zeroconf, z_type, name):
        info = zeroconf.get_service_info(z_type, name)
        if info:
            self.target_ip = socket.inet_ntoa(info.addresses[0])
            print(f"✨ Found Multipoint Receiver: {self.target_ip}")

    def remove_service(self, zeroconf, z_type, name):
        pass

    def add_service(self, zeroconf, z_type, name):
        self.update_service(zeroconf, z_type, name)

def main():
    print("🚀 Multipoint Bridge Linux Client Starting...")
    
    # 1. Discover Receiver
    zeroconf = Zeroconf()
    listener = MultipointDiscovery()
    browser = ServiceBrowser(zeroconf, "_multipoint._udp.local.", listener)
    
    print("📡 Scanning for receivers (mDNS)...")
    timeout = 10
    start = time.time()
    while listener.target_ip is None and (time.time() - start) < timeout:
        time.sleep(0.1)
    
    # 2. Identify ourselves to the receiver periodically
    import threading
    import platform
    
    def identity_heartbeat(ip, stop_event):
        device_name = platform.node()
        msg = f"MSG:NAME:{device_name}".encode('utf-8')
        print(f"👤 Starting Identity Heartbeat: {device_name}")
        while not stop_event.is_set():
            try:
                with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                    s.sendto(msg, (ip, 9999))
            except:
                pass
            time.sleep(3)

    if listener.target_ip is None:
        print("❌ Error: No receiver found.")
        return
    
    target_ip = listener.target_ip

    stop_heartbeat = threading.Event()
    heartbeat_thread = threading.Thread(target=identity_heartbeat, args=(target_ip, stop_heartbeat))
    heartbeat_thread.daemon = True
    heartbeat_thread.start()

    # 3. Start GStreamer Pipeline
    # This captures the default PulseAudio monitor source (what you hear)
    # and streams it as raw S16LE PCM over UDP.
    print(f"✅ Streaming to {target_ip}:9999 via GStreamer...")
    
    # Simple PulseAudio/PipeWire monitor capture pipeline
    cmd = [
        "gst-launch-1.0",
        "pulsesrc", "device=auto_null.monitor", # Try default monitor
        "!", "audioconvert",
        "!", "audioresample",
        "!", "audio/x-raw,format=S16LE,rate=48000,channels=2",
        "!", "udpsink", f"host={target_ip}", "port=9999"
    ]
    
    # Note: On many systems, 'pulsesrc' will pick the default output monitor automatically.
    # If using PipeWire, it also supports 'pulsesrc' via pipewire-pulse.
    
    try:
        subprocess.run(cmd)
    except KeyboardInterrupt:
        print("\n🛑 Stopped.")
    except FileNotFoundError:
        print("❌ Error: 'gst-launch-1.0' not found. Please install GStreamer.")

if __name__ == "__main__":
    main()
