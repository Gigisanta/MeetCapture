# MeetCapture v4 — Architecture & Implementation Plan

## Vision

Production-ready macOS menu bar app that automatically records and transcribes
Google Meet calls. Zero-config, native macOS integration, <50MB RAM idle.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                    MeetCapture.app (Swift/SwiftUI)              │
│                                                                 │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────────┐ │
│  │  MenuBarExtra │  │ CalendarMgr   │  │ AudioCapture         │ │
│  │  SwiftUI      │  │ EventKit +    │  │ ScreenCaptureKit     │ │
│  │  SF Symbols   │  │ Google API    │  │ (system audio)       │ │
│  │  ~5MB RAM     │  │ ~2MB RAM      │  │ ~3MB RAM             │ │
│  └──────────────┘  └───────────────┘  └──────────┬───────────┘ │
│                                                   │             │
│  ┌──────────────┐  ┌───────────────┐              │             │
│  │ SMAppService │  │ StateMachine  │              │             │
│  │ Daemon mgmt  │  │ Idle→Approach │              │             │
│  │              │  │ →Record→Done  │              │             │
│  └──────────────┘  └───────────────┘              │             │
└───────────────────────────────────────────────────┼─────────────┘
                                                    │ PCM pipe
┌───────────────────────────────────────────────────▼─────────────┐
│              meet-daemon (Python, background)                   │
│                                                                 │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────────┐ │
│  │ Whisper.cpp  │  │ ChunkedProc   │  │ TranscriptWriter     │ │
│  │ large-v3-    │  │ 5s chunks     │  │ Markdown + Hermes    │ │
│  │ turbo (1.6GB)│  │ VAD filter    │  │ notification         │ │
│  │ ~4x RT M2   │  │ ~50MB peak    │  │                      │ │
│  └──────────────┘  └───────────────┘  └──────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

IPC: Unix Domain Socket (/tmp/meetcapture.sock)
```

---

## Technology Stack

| Component | Current | v4 Target | Why |
|-----------|---------|-----------|-----|
| UI | Objective-C + NSStatusItem | Swift + SwiftUI MenuBarExtra | Modern, less code, native dark mode |
| Audio capture | BlackHole 16ch + ffmpeg | ScreenCaptureKit (native) | No virtual driver, lower CPU, Apple recommended |
| Calendar | gws CLI polling (120s) | EventKit + Google API push | Zero polling, instant detection |
| Daemon mgmt | Manual LaunchAgent plist | SMAppService (macOS 13+) | No macOS 26 warnings, System Settings integration |
| Transcription | whisper-cli subprocess | whisper.cpp C API via Swift | No subprocess overhead, streaming |
| Model | base (141MB) | large-v3-turbo Q5_0 (1.6GB) | 2.6% WER, fits 8GB RAM, 4x real-time |
| IPC | File-based (.daemon_state.json) | Unix Domain Socket | Real-time bidirectional |
| Distribution | Manual .app | DMG + Sparkle auto-update | Professional, auto-updates |

---

## Implementation Phases

### Phase 1: Swift/SwiftUI Foundation (Day 1-2)

**Goal:** Rewrite menu bar app in Swift with proper architecture.

```
MeetCapture/
├── MeetCaptureApp.swift          # @main, MenuBarExtra scene
├── StateMachine.swift            # App state: idle → approaching → recording → transcribing → done
├── Views/
│   ├── StatusView.swift          # Menu content
│   ├── RecordingView.swift       # Active recording indicator
│   └── SettingsView.swift        # Preferences window
├── Services/
│   ├── CalendarService.swift     # EventKit + Google Calendar API
│   ├── AudioCaptureService.swift # ScreenCaptureKit audio capture
│   ├── DaemonManager.swift       # SMAppService + daemon lifecycle
│   └── WhisperService.swift      # whisper.cpp C API integration
├── Models/
│   ├── Meeting.swift             # Calendar event model (struct)
│   ├── Transcript.swift          # Transcript model
│   └── AppState.swift            # Observable state
├── Info.plist                    # LSUIElement, privacy descriptions
└── MeetCapture.entitlements      # Audio, network, file access
```

Key implementation details:

```swift
// MeetCaptureApp.swift
import SwiftUI
import ServiceManagement

@main
struct MeetCaptureApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var state = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            StatusView(state: state)
        } label: {
            Label(state.menuBarTitle, systemImage: state.menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

// State machine
enum AppPhase {
    case idle           // Polling calendar, no meeting
    case approaching    // Meeting in <5 min, preparing
    case recording      // Actively capturing audio
    case transcribing   // Meeting ended, processing
    case done           // Transcript ready, notifying
}
```

**Files to create:** 12 Swift files, 1 Info.plist, 1 entitlements
**Dependencies:** None (all Apple frameworks)

---

### Phase 2: ScreenCaptureKit Audio Capture (Day 2-3)

**Goal:** Replace BlackHole + ffmpeg with native ScreenCaptureKit.

```swift
// AudioCaptureService.swift
import ScreenCaptureKit
import CoreMedia

class AudioCaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.meetcapture.audio", qos: .userInitiated)
    private var audioFileHandle: FileHandle?
    
    func startCapture(outputPath: String, excludeApps: [SCRunningApplication] = []) async throws {
        // 1. Get shareable content
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        
        // 2. Filter: exclude MeetCapture itself
        let excludedApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludeApps.isEmpty ? excludedApps : excludeApps,
            exceptingWindows: []
        )
        
        // 3. Configure for audio-only (minimize video overhead)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000        // Whisper expects 16kHz
        config.channelCount = 1          // Mono for speech
        config.excludesCurrentProcessAudio = true
        
        // Minimize video overhead (required even for audio-only)
        config.minimumFrameInterval = CMTime(value: 10, timescale: 1)  // 0.1fps
        config.width = 2
        config.height = 2
        config.queueDepth = 3
        
        // 4. Create stream
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        
        // 5. Open output file (raw PCM, will be piped to Whisper)
        FileManager.default.createFile(atPath: outputPath, contents: nil)
        audioFileHandle = FileHandle(forWritingAtPath: outputPath)
        
        // 6. Start
        try await stream?.startCapture()
    }
    
    func stopCapture() async {
        try? await stream?.stopCapture()
        audioFileHandle?.closeFile()
        audioFileHandle = nil
        stream = nil
    }
    
    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                     totalLengthOut: &totalLength, dataPointerOut: &dataPointer)
        
        guard let dataPointer = dataPointer else { return }
        let pcmData = Data(bytesNoCopy: dataPointer, count: totalLength, deallocator: .none)
        audioFileHandle?.write(pcmData)
    }
    
    // MARK: - SCStreamDelegate
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Handle stream errors, restart if needed
    }
}
```

**Key decisions:**
- 16kHz mono PCM (matches Whisper input format)
- ScreenCaptureKit requires "Screen & System Audio Recording" permission
- Purple recording indicator appears (macOS privacy feature, unavoidable)
- Audio comes as Float32 CMSampleBuffer → write raw PCM → pipe to Whisper

**Permission handling:**
```swift
// Check permission before starting
import ScreenCaptureKit

func checkPermission() -> Bool {
    return CGPreflightScreenCaptureAccess()
}

func requestPermission() {
    CGRequestScreenCaptureAccess()
    // Opens System Settings > Privacy & Security > Screen & System Audio Recording
}
```

---

### Phase 3: EventKit + Calendar Detection (Day 3-4)

**Goal:** Replace gws CLI polling with native EventKit notifications.

```swift
// CalendarService.swift
import EventKit
import Foundation

class CalendarService: ObservableObject {
    private let store = EKEventStore()
    @Published var upcomingMeetings: [Meeting] = []
    
    func requestAccess() async throws {
        try await store.requestFullAccessToEvents()
    }
    
    func startObserving() {
        // React to ANY calendar change (no polling!)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
        loadUpcomingMeetings()
    }
    
    @objc private func calendarChanged() {
        loadUpcomingMeetings()
    }
    
    private func loadUpcomingMeetings() {
        let now = Date()
        let endOfDay = Calendar.current.date(byAdding: .hour, value: 8, to: now)!
        
        let predicate = store.predicateForEvents(withStart: now, end: endOfDay, calendars: nil)
        let events = store.events(matching: predicate)
        
        upcomingMeetings = events.compactMap { event -> Meeting? in
            // Filter: must have video conference link
            guard let url = event.url?.absoluteString,
                  url.contains("meet.google.com") else { return nil }
            
            // Filter: must have external attendees
            let attendees = event.attendees ?? []
            let external = attendees.filter { attendee in
                guard let email = attendee.url.absoluteString
                    .replacingOccurrences(of: "mailto:", with: "")
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return false }
                return !Self.whitelistedEmails.contains(email.lowercased())
            }
            
            guard !external.isEmpty else { return nil }
            
            return Meeting(
                id: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                meetURL: url,
                externalAttendees: external.map { $0.name ?? "Unknown" }
            )
        }
    }
    
    static let whitelistedEmails = [
        "giolivosantarelli@gmail.com",
        "giogametodraggg@gmail.com"
    ]
}
```

**Hybrid approach for Google Calendar (if EventKit doesn't have all events):**
- Primary: EventKit (instant, no network, no polling)
- Fallback: Google Calendar API with webhook push notifications
- Only poll if webhook subscription expires (>24h)

---

### Phase 4: whisper.cpp Native Integration (Day 4-5)

**Goal:** Replace subprocess whisper-cli with direct C API calls.

**Option A: SwiftWhisper (easiest)**
```swift
import SwiftWhisper

class WhisperService {
    private var whisper: Whisper?
    
    func loadModel() {
        let modelURL = Bundle.main.url(forResource: "ggml-large-v3-turbo", withExtension: "bin")!
        whisper = Whisper(fromFileURL: modelURL)
    }
    
    func transcribe(audioFile: URL) async throws -> String {
        let audioData = try loadAudioAsFloat(audioFile)
        let segments = try await whisper!.transcribe(audioFrames: audioData)
        return segments.map { $0.text }.joined(separator: "\n")
    }
}
```

**Option B: Direct C API (more control, streaming)**
```swift
// WhisperBridge.swift
import CWhisper  // Custom modulemap pointing to whisper.h

class WhisperBridge {
    private var ctx: OpaquePointer?
    
    func loadModel(path: String) {
        var params = whisper_context_default_params()
        params.use_gpu = true      // Metal acceleration
        params.flash_attn = true   // Memory optimization
        ctx = whisper_init_from_file_with_params(path, &params)
    }
    
    func transcribe(samples: [Float], language: String = "en") -> String {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_timestamps = false
        params.no_context = true
        params.n_threads = 4
        params.language = language
        
        whisper_full(ctx, params, samples, Int32(samples.count), nil, nil, nil)
        
        var result = ""
        let nSegments = whisper_full_n_segments(ctx)
        for i in 0..<nSegments {
            if let text = whisper_full_get_segment_text(ctx, Int32(i)) {
                result += String(cString: text)
            }
        }
        return result
    }
    
    func unloadModel() {
        if ctx != nil {
            whisper_free(ctx)
            ctx = nil
        }
    }
}
```

**Model selection for 8GB M2:**
- Primary: `large-v3-turbo` Q5_0 (1.6GB disk, ~2.6% WER, 4x real-time)
- Fallback: `small` (461MB disk, 3.4% WER, 6x real-time) if memory pressure
- Load model only when recording starts, unload when done
- Monitor memory pressure via `ProcessInfo.processInfo.physicalMemory`

---

### Phase 5: SMAppService Daemon Management (Day 5-6)

**Goal:** Proper daemon lifecycle via SMAppService.

```swift
// DaemonManager.swift
import ServiceManagement

class DaemonManager {
    private let agentService = SMAppService.agent(plistName: "com.gio.meetcapture.daemon.plist")
    
    var isRegistered: Bool { agentService.status == .enabled }
    
    func register() throws {
        try agentService.register()
    }
    
    func unregister() throws {
        try agentService.unregister()
    }
    
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
    
    var status: String {
        switch agentService.status {
        case .enabled: return "Running"
        case .notRegistered: return "Not registered"
        case .notFound: return "Daemon plist not found in bundle"
        case .requiresApproval: return "Needs user approval"
        case .permissionDenied: return "Permission denied"
        @unknown default: return "Unknown"
        }
    }
}
```

**App bundle structure for SMAppService:**
```
MeetCapture.app/
├── Contents/
│   ├── MacOS/
│   │   └── MeetCapture                    # Main binary
│   ├── Resources/
│   │   ├── meet-daemon.py                 # Python daemon
│   │   ├── ggml-large-v3-turbo-q5_0.bin   # Whisper model
│   │   └── meet-daemon-venv/              # Python venv
│   ├── Library/
│   │   └── LaunchAgents/
│   │       └── com.gio.meetcapture.daemon.plist  # Daemon config
│   └── Info.plist
```

**Daemon plist (bundled):**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.gio.meetcapture.daemon</string>
    <key>BundleProgram</key>
    <string>Contents/Resources/meet-daemon.py</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
```

---

### Phase 6: IPC — Unix Domain Socket (Day 6-7)

**Goal:** Replace file-based state with real-time bidirectional IPC.

```swift
// SocketServer.swift (in daemon)
import Foundation

class SocketServer {
    private var serverSocket: Int32 = -1
    private let socketPath = "/tmp/meetcapture.sock"
    
    func start() {
        unlink(socketPath)
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let pathBuf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = socketPath.withCString { strncpy(pathBuf, $0, 104) }
        }
        
        bind(serverSocket, sockaddr_cast(&addr), socklen_t(MemoryLayout<sockaddr_un>.size))
        listen(serverSocket, 5)
        
        // Accept connections on background thread
        DispatchQueue.global().async { [weak self] in
            while let self = self {
                let client = accept(self.serverSocket, nil, nil)
                if client >= 0 {
                    self.handleClient(client)
                }
            }
        }
    }
    
    private func handleClient(_ socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(socket, &buffer, buffer.count)
        if bytesRead > 0 {
            let data = Data(bytes: buffer, count: bytesRead)
            let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            
            // Handle commands: start_recording, stop_recording, get_status, ...
            if let command = message?["command"] as? String {
                let response = handleCommand(command, params: message)
                let responseData = try! JSONSerialization.data(withJSONObject: response)
                write(socket, (responseData as NSData).bytes, responseData.count)
            }
        }
        close(socket)
    }
}
```

**Socket protocol (JSON over Unix socket):**
```json
// App → Daemon: start recording
{"command": "start_recording", "meeting_id": "abc123", "output_path": "/path/to/output.pcm"}

// App → Daemon: stop recording
{"command": "stop_recording"}

// App → Daemon: get status
{"command": "get_status"}

// Daemon → App: status response
{"status": "recording", "duration_seconds": 120, "chunks_processed": 24}

// Daemon → App: transcription complete
{"event": "transcription_complete", "meeting_id": "abc123", "transcript_path": "/path/to/transcript.md"}
```

---

### Phase 7: Energy Optimization (Day 7)

**Goal:** <1% battery impact when idle, proper App Nap handling.

```swift
// EnergyManager.swift
import Foundation

class EnergyManager {
    private var activity: NSObjectProtocol?
    
    func beginRecordingActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording Google Meet audio"
        )
    }
    
    func endRecordingActivity() {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
    
    func checkMemoryPressure() -> MemoryLevel {
        let totalGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        let usedGB = totalGB - getAvailableMemoryGB()
        
        if usedGB > totalGB * 0.85 {
            return .critical    // Unload Whisper, stop transcription
        } else if usedGB > totalGB * 0.70 {
            return .warning     // Use smaller model
        }
        return .normal
    }
    
    private func getAvailableMemoryGB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_073_741_824 : 0
    }
    
    enum MemoryLevel {
        case normal, warning, critical
    }
}
```

**Idle behavior:**
- Calendar check: EventKit notification (zero CPU when no changes)
- Socket server: blocking accept() (zero CPU when no connections)
- Whisper model: NOT loaded until recording starts
- Total idle: ~5MB RAM, 0% CPU

---

### Phase 8: Code Signing & Distribution (Day 8)

**Goal:** Notarized DMG with Sparkle auto-update.

```bash
#!/bin/bash
# build-and-sign.sh

APP="MeetCapture.app"
IDENTITY="Developer ID Application: Gio Livio Santarelli (TEAMID)"

# 1. Build
xcodebuild -scheme MeetCapture -configuration Release -derivedDataPath build/

# 2. Sign (innermost first, NO --deep)
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    "$APP/Contents/Resources/meet-daemon-venv/bin/python3"

codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" \
    "$APP/Contents/Resources/meet-daemon.py"

codesign --force --options runtime --timestamp \
    --entitlements MeetCapture.entitlements \
    --sign "$IDENTITY" \
    "$APP"

# 3. Verify
codesign --verify --deep --strict --verbose=2 "$APP"

# 4. Notarize
ditto -c -k --keepParent "$APP" MeetCapture.zip
xcrun notarytool submit MeetCapture.zip --keychain-profile "MeetCapture" --wait
xcrun stapler staple "$APP"

# 5. DMG
create-dmg \
    --volname "MeetCapture" \
    --window-size 600 400 \
    --icon "MeetCapture.app" 150 200 \
    --app-drop-link 450 200 \
    "MeetCapture-1.0.dmg" \
    "$APP"

# 6. Notarize DMG
xcrun notarytool submit MeetCapture-1.0.dmg --keychain-profile "MeetCapture" --wait
xcrun stapler staple MeetCapture-1.0.dmg
```

**Entitlements:**
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.microphone</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
```

**Info.plist privacy descriptions:**
```xml
<key>LSUIElement</key>
<true/>
<key>NSMicrophoneUsageDescription</key>
<string>MeetCapture captures system audio from Google Meet calls for transcription.</string>
<key>NSScreenCaptureUsageDescription</key>
<string>MeetCapture captures system audio to include in meeting transcripts.</string>
<key>NSCalendarsUsageDescription</key>
<string>MeetCapture reads your calendar to detect Google Meet meetings.</string>
<key>NSCalendarsFullAccessUsageDescription</key>
<string>MeetCapture needs calendar access to detect upcoming meetings with external attendees.</string>
```

---

### Phase 9: Sparkle Auto-Update (Day 8)

```swift
// UpdaterManager.swift
import Sparkle

class UpdaterManager: ObservableObject {
    private let updaterController: SPUStandardUpdaterController
    
    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }
    
    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
    
    var canCheckForUpdates: Bool {
        updaterController.updater.canCheckForUpdates
    }
}
```

**Appcast.xml (hosted on GitHub Pages or own server):**
```xml
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>MeetCapture</title>
        <item>
            <title>Version 1.0.0</title>
            <pubDate>Mon, 01 Jun 2026 12:00:00 +0000</pubDate>
            <sparkle:version>1</sparkle:version>
            <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/Gigisanta/MeetCapture/releases/download/v1.0.0/MeetCapture-1.0.0.dmg"
                       length="200000000"
                       type="application/octet-stream"
                       sparkle:edSignature="SIGNATURE_HERE"/>
        </item>
    </channel>
</rss>
```

---

## State Machine

```
                    ┌──────────┐
                    │   IDLE   │◄──────────────────────┐
                    │ Polling  │                        │
                    │ Calendar │                        │
                    └────┬─────┘                        │
                         │ Meeting detected             │
                         │ (Meet link + external)       │
                         ▼                              │
                    ┌──────────┐                        │
                    │APPROACHING│                       │
                    │ <5 min   │                        │
                    │ Prepare  │                        │
                    └────┬─────┘                        │
                         │ Meeting starts               │
                         ▼                              │
                    ┌──────────┐                        │
                    │RECORDING │                        │
                    │ SCK audio│                        │
                    │ → PCM    │                        │
                    └────┬─────┘                        │
                         │ Meeting ends                 │
                         │ (Calendar event end time)    │
                         ▼                              │
                    ┌──────────┐                        │
                    │TRANSCRIBING                       │
                    │ Whisper  │                        │
                    │ chunks   │                        │
                    └────┬─────┘                        │
                         │ Transcript ready             │
                         ▼                              │
                    ┌──────────┐                        │
                    │   DONE   │                        │
                    │ Notify   │────────────────────────┘
                    │ Hermes   │
                    └──────────┘
```

---

## Model Strategy

| Scenario | Model | RAM | Speed | When |
|----------|-------|-----|-------|------|
| Default | large-v3-turbo Q5_0 | ~2GB | 4x RT | Normal operation |
| Memory pressure | small | ~1GB | 6x RT | >70% RAM used |
| Critical memory | base | ~500MB | 16x RT | >85% RAM used |
| No meeting | None | 0 | - | Idle (model not loaded) |

Dynamic model switching based on `ProcessInfo.physicalMemory` pressure.

---

## Testing Strategy

### Unit Tests
- StateMachine transitions
- Calendar event filtering (Meet link detection, external attendee detection)
- Audio format conversion (Float32 → Int16)
- Whisper segment parsing

### Integration Tests
- ScreenCaptureKit → PCM file → Whisper → transcript
- Calendar change → state transition → recording start
- SMAppService register/unregister lifecycle
- Socket IPC round-trip

### Real-World Tests
- Full meeting recording (30+ min)
- Multiple meetings in sequence
- Memory pressure during long meeting
- Network interruption during calendar sync
- macOS sleep/wake during recording

---

## Resource Budget

| State | RAM | CPU | Disk |
|-------|-----|-----|------|
| Idle (no model) | ~8MB | 0% | 0 |
| Idle (model loaded) | ~2.1GB | 0% | 0 |
| Recording | ~2.1GB | 2-3% | ~1MB/min PCM |
| Transcribing | ~2.2GB | 80-100% (burst) | ~1MB/min + transcript |
| Done | ~2.1GB | 0% | transcript |

**Target:** <50MB RAM when idle (model unloaded), <2.5GB when transcribing.

---

## Migration Path

**Phase 1-2:** Swift app + ScreenCaptureKit audio (replaces ObjC + BlackHole)
**Phase 3:** EventKit calendar (replaces gws CLI)
**Phase 4-5:** Native Whisper + SMAppService (replaces subprocess daemon)
**Phase 6:** Socket IPC (replaces file-based state)
**Phase 7:** Energy optimization
**Phase 8-9:** Signing, notarization, Sparkle

Each phase is independently deployable. Can ship v3.1 with Phase 1-2 while
continuing development on Phase 3+.

---

## Risk Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| ScreenCaptureKit requires Screen Recording permission | High | Clear onboarding, permission check before first use |
| large-v3-turbo too large for 8GB | Medium | Dynamic model switching, unload when idle |
| macOS 26 breaks something | Medium | Target macOS 14+ (Sonoma), test on 26.5 |
| EventKit missing Google Calendar events | Low | Hybrid: EventKit primary, Google API fallback |
| Core Audio taps unreliable | Low | Using ScreenCaptureKit instead (production-proven) |
| Sparkle CVE-2025-10016 | Low | Use Sparkle 2.x+ (patched) |

---

## Success Criteria

- [ ] Menu bar icon visible in macOS 26 (SF Symbols, template mode)
- [ ] Calendar detection without polling (EventKit notifications)
- [ ] System audio capture via ScreenCaptureKit (no BlackHole)
- [ ] Whisper transcription <2x real-time latency
- [ ] <50MB RAM when idle
- [ ] <1% battery impact when idle
- [ ] Auto-start via SMAppService (no macOS 26 warnings)
- [ ] Notarized DMG distribution
- [ ] Sparkle auto-updates working
- [ ] Full 30-min meeting recorded and transcribed end-to-end
