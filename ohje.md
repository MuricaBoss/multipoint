🎧 Antigravity – Low Latency Audio Bridge (Production Plan)

🎯 Goal

Build a low-latency cross-device audio bridge:

Mac → (WebRTC / UDP) → Android (React Native) → Bluetooth headphones

Target:

* Latency: < 200 ms
* One-click UX
* Product-ready architecture

⸻

🧠 High-Level Architecture

Data flow

Mac (CoreAudio capture)
    ↓
WebRTC (UDP, low latency)
    ↓
Android (React Native + native audio engine)
    ↓
Bluetooth headphones

⸻

⚙️ CORE DESIGN DECISIONS

Why WebRTC?

* Uses UDP internally
* Built-in jitter buffer
* NAT traversal (future internet support)
* Designed for real-time audio

Why React Native?

* Fast UI development
* Cross-platform future (iOS later)
* Native modules handle audio + WebRTC

⸻

📱 ANDROID APP (React Native)

Responsibilities

1. Start receiver (WebRTC peer)
2. Handle signaling
3. Receive audio stream
4. Output audio → Bluetooth
5. Provide simple UX

⸻

🧩 Architecture

React Native Layer

* UI
* Connection state
* Device discovery (later)

Native Module (Android)

* WebRTC (libwebrtc)
* AudioTrack playback
* Low-level buffer control

⸻

📦 Tech Stack

React Native

* React Native CLI (not Expo)

WebRTC

* react-native-webrtc

Audio Output

* AudioTrack (native)

⸻

🔌 Connection Flow

1. App starts
2. Creates WebRTC offer
3. Shows QR code / connection code
4. Waits for Mac to connect
5. Receives audio stream
6. Plays audio

⸻

📱 UI (MVP)

[ Start Listening ]
Status: Waiting for Mac...
Connection Code: 834729
[ QR CODE ]
● Connected
● Receiving audio

⸻

💻 MACOS APP (Swift)

Responsibilities

1. Capture system audio (CoreAudio)
2. Encode audio (Opus)
3. Send via WebRTC
4. Handle signaling
5. Provide simple UI

⸻

🧩 Architecture

Audio Capture

* CoreAudio + virtual device (BlackHole initially)

Encoding

* Opus (via WebRTC stack)

Transport

* WebRTC PeerConnection

⸻

🖥 UI (Menu Bar App)

● Connected to Android
○ Not connected
[ Connect ]
[ Disconnect ]

⸻

🔁 SIGNALING (IMPORTANT)

MVP (simple)

Use:

* Local WebSocket server (Android)

Flow:

1. Android starts WS server
2. Mac connects
3. Exchange SDP (offer/answer)
4. Exchange ICE candidates

⸻

Future

* Replace with cloud signaling

⸻

⚡ LATENCY STRATEGY

Key optimizations

1. Use Opus codec

* Low bitrate
* Low delay

2. Small buffers

* Reduce AudioTrack buffer size

3. Disable unnecessary processing

* No echo cancellation
* No noise suppression

4. Direct audio pipeline

* Avoid JS thread for audio

⸻

🔊 AUDIO PIPELINE (IMPORTANT)

Mac

CoreAudio → WebRTC → UDP

Android

WebRTC → PCM → AudioTrack → Bluetooth

⸻

🚀 DEVELOPMENT PHASES

Phase 1 – Core connection

* WebRTC connection works
* No audio yet

⸻

Phase 2 – Audio streaming

* Mac sends audio
* Android receives
* Basic playback works

⸻

Phase 3 – Low latency tuning

* Buffer tuning
* Opus config
* Jitter tuning

⸻

Phase 4 – UX polish

* Auto connect
* Device discovery
* Error handling

⸻

🧪 MVP SUCCESS CRITERIA

* Connection stable
* Audio plays
* Latency < 300 ms

⸻

⚠️ RISKS

* Bluetooth latency adds ~100–200 ms
* Android device fragmentation
* WebRTC complexity

⸻

💡 PRODUCT EDGE

“Add multipoint to any headphones”

* Works with any Bluetooth headphones
* No hardware upgrade needed
* Cross-device audio routing

⸻

🔧 NEXT STEPS

1. Setup React Native project
2. Add react-native-webrtc
3. Build signaling server (Android)
4. Create Mac WebRTC sender
5. Connect peers
6. Add audio pipeline

⸻

✅ DONE WHEN

* User opens Android app
* Opens Mac app
* Clicks connect
* Hears Mac audio instantly 🎧