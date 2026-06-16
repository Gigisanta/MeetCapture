> **Status: ACTIVE (v4.3.0).** Source of truth: [../README.md](../README.md).
>
> This document describes the MeetCapture.app menu bar app, which is in active
> production use. Key architectural facts:
>
> 1. **Audio capture uses a Core Audio process tap + aggregate device**
>    (`CATapDescription` + private aggregate device, macOS 14.4+). It captures
>    the system audio (other call participants) **plus the microphone** (your own
>    voice), mixed to mono Float32 in the IOProc. It does NOT use
>    ScreenCaptureKit / `SCStream`: on macOS 15+/26 `SCStream.startCapture()`
>    succeeds but never delivers any sample-buffer callbacks — a confirmed OS
>    regression, reproducible with minimal textbook code under the granted
>    identity — which is why capture was migrated. See `Sources/AudioCapture.swift`.
> 2. **The required permission is Microphone, not Screen Recording.** Core Audio
>    process taps are gated by the Microphone (audio input) TCC permission. The
>    app requests it at launch and gates the Record button on it.
>
> The transcription pipeline (`Sources/WhisperTranscriber.swift`) shells out to
> the `whisper-cli` binary via `Process`; it resamples the captured audio to
> 16kHz mono (from the device's real rate, read at runtime) before transcribing.
> The standalone CLI pipeline ([TRANSCRIPTION-PIPELINE.md](TRANSCRIPTION-PIPELINE.md))
> remains available for transcribing arbitrary audio files.

# Architecture

## System Overview

MeetCapture is a native macOS menu bar application built with Swift/SwiftUI that automatically captures and transcribes Google Meet calls. It operates entirely locally — no audio leaves the machine, no bots join meetings, no cloud services are required.

```
┌─────────────────────────────────────────────────────────┐
│  MeetCapture.app (Swift/SwiftUI, ~30MB RAM idle)        │
│  ├── MenuBarExtra (SwiftUI)                             │
│  │   └── StatusView + SettingsView                      │
│  ├── CalendarService (EventKit)                         │
│  │   └── EKEventStore + change notifications            │
│  ├── AudioCaptureService (Core Audio process tap)      │
│  │   └── CATapDescription + aggregate device + mic      │
│  ├── DaemonManager (SMAppService)                       │
│  │   └── LaunchAgent lifecycle                          │
│  ├── WhisperTranscriber (shells out to whisper-cli)     │
│  │   └── Process/exec → whisper-cli binary              │
│  └── SocketClient (Unix Domain Socket)                  │
│       └── IPC to meet-daemon                            │
└─────────────────────────────────────────────────────────┘
                     │ IPC: /tmp/meetcapture.sock
                     ▼
┌─────────────────────────────────────────────────────────┐
│  meet-daemon (Python, background)                       │
│  ├── Whisper transcription engine                       │
│  ├── Audio chunking (5s segments)                       │
│  ├── Post-processing (cleanup, dedup)                   │
│  └── Transcript writing (Markdown)                      │
└─────────────────────────────────────────────────────────┘
```

---

## Components

### 1. MeetCaptureApp.swift — App Entry Point

**Technology:** Swift + SwiftUI

**Responsibilities:**
- App lifecycle management (`@main`)
- Menu bar icon via `MenuBarExtra`
- State coordination via `AppState`
- Window management (settings, status)

**Key Code:**
```swift
@main
struct MeetCaptureApp: App {
    @StateObject private var appState = AppState()
    
    var body: some Scene {
        MenuBarExtra {
            StatusView(appState: appState)
        } label: {
            Image(systemName: appState.menuBarIcon)
        }
    }
}
```

### 2. AppState.swift — State Machine

**Technology:** Swift + Combine

**Responsibilities:**
- State management (IDLE → APPROACHING → RECORDING → TRANSCRIBING → DONE)
- Service coordination
- Error handling
- UI state updates

**State Transitions:**
```
IDLE → APPROACHING: Calendar detects meeting with Google Meet link
APPROACHING → RECORDING: T-5min or manual start
RECORDING → TRANSCRIBING: Meeting ends or manual stop
TRANSCRIBING → DONE: Whisper completes
DONE → IDLE: 30s timeout or manual dismiss
```

### 3. AudioCaptureService.swift — Core Audio Process Tap Capture

**Technology:** Core Audio (process tap + aggregate device, macOS 14.4+)

**Responsibilities:**
- Capture system audio (other participants) **+ the microphone** (your voice)
  via a `CATapDescription` process tap aggregated with the default input
- Mix both sources to mono Float32 in the IOProc; write samples to file
- Permission management (Microphone / `AVCaptureDevice` audio authorization)
- Tap/aggregate lifecycle management, including rebuild on device change

**Key Features:**
- Captures the full call (system audio + mic), not just the remote side
- Rate-agnostic: reads the device's real sample rate at runtime (48kHz tap-only,
  44.1kHz when the internal mic drives the clock) — nothing hardcoded
- Device-change resilience: if you switch headphones/output mid-call, the tap
  silently stops delivering audio with no error, so the service listens for
  device changes and **rebuilds the tap + aggregate** into the same file
- Low CPU usage (~5% during recording)

**Permission Flow:**
```swift
func checkPermission() -> Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
}

func requestPermission() {
    AVCaptureDevice.requestAccess(for: .audio) { _ in }
}

func startCapture(outputPath: String) async throws {
    // Build a CATapDescription process tap, aggregate it with the default
    // input (mic), install an IOProc that mixes to mono Float32, and write.
}
```

### 4. CalendarService.swift — EventKit Integration

**Technology:** EventKit + Combine

**Responsibilities:**
- Calendar monitoring via `EKEventStore`
- Meeting detection with Google Meet links
- Attendee analysis (external vs internal)
- Real-time change notifications

**Key Features:**
- Native macOS calendar access
- Instant change detection via `EKEventStoreChanged`
- Smart meeting filtering (only Google Meet)
- External attendee detection

**Meeting Detection Logic:**
```swift
func findUpcomingMeetings() -> [Meeting] {
    let predicate = eventStore.predicateForEvents(
        withStart: now,
        end: now.addingTimeInterval(3600),
        calendars: nil
    )
    return eventStore.events(matching: predicate)
        .filter { $0.hasGoogleMeetLink }
        .filter { $0.hasExternalAttendees }
}
```

### 5. DaemonManager.swift — SMAppService Lifecycle

**Technology:** ServiceManagement (macOS 13+)

**Responsibilities:**
- LaunchAgent registration via `SMAppService`
- Daemon start/stop/restart
- Status monitoring
- System Settings integration

**Key Features:**
- Proper lifecycle management (no manual plist editing)
- Status tracking (enabled, notRegistered, notFound, requiresApproval)
- Toggle registration
- Open System Settings for approval

### 6. WhisperTranscriber.swift — shells out to the whisper-cli binary

**Technology:** Swift `Process` (exec of the `whisper-cli` binary)

**Responsibilities:**
- Resample/downmix captured audio to 16kHz mono WAV
- Spawn `whisper-cli` per chunk with the model + domain initial prompt
- Read transcription text from whisper-cli output
- Apply post-processing (dedup, garbage removal)

**Key Features:**
- Shells out to the `whisper-cli` binary via `Process` (no linked
  whisper.cpp library / C-FFI)
- Default model is **medium**; uses Silero VAD, a domain initial prompt,
  carry-initial-prompt across chunks, dedup, and per-chunk gain normalization
- Memory-efficient chunk processing; the model is released when done (idle ~15MB)
- Apple Silicon GPU acceleration (via whisper-cli)

### 7. SocketClient.swift — Unix Domain Socket IPC

**Technology:** Swift + POSIX sockets

**Responsibilities:**
- Connect to meet-daemon socket (`/tmp/meetcapture.sock`)
- Send commands (start_recording, stop_recording, status)
- Receive responses
- Connection lifecycle management

**Protocol:**
```json
// Request
{"command": "start_recording", "payload": {"title": "Team Meeting"}}

// Response
{"status": "ok", "data": {"recording_id": "123"}}
```

---

## Data Flow

### Recording Flow

```
1. CalendarService detects meeting
   ↓
2. AppState transitions to APPROACHING
   ↓
3. AudioCaptureService.startCapture()
   ↓
4. Core Audio process tap + aggregate device captures system audio + mic
   ↓
5. Mono Float32 samples written to file
   ↓
6. Meeting ends → AppState transitions to TRANSCRIBING
   ↓
7. WhisperTranscriber shells out to whisper-cli per chunk
   ↓
8. Transcript written to Markdown file
   ↓
9. AppState transitions to DONE
   ↓
10. User notified, transcript available
```

### Permission Flow

```
1. App launches
   ↓
2. AudioCaptureService.checkPermission()  (Microphone authorization)
   ↓
3. If not granted → show "Grant Permission" button
   ↓
4. User clicks → AVCaptureDevice.requestAccess(for: .audio)
   ↓
5. System Settings opens (Privacy & Security → Microphone)
   ↓
6. User enables MeetCapture
   ↓
7. App restarts → permission detected
   ↓
8. Start Recording button enabled
```

---

## Performance Characteristics

### Memory Usage

| State | RAM | CPU |
|-------|-----|-----|
| Idle (menu bar) | ~30MB | 0% |
| Recording | ~60MB | ~5% |
| Transcribing | ~400MB-2GB | 80-100% |
| Post-processing | ~50MB | 20% |

### Battery Impact

- **Idle:** Negligible (0% CPU)
- **Recording:** Low (~5% CPU, EnergyManager active)
- **Transcribing:** High (CPU-bound, GPU-accelerated)
- **Overall:** Minimal battery drain for typical meetings

### Disk Usage

- **App binary:** ~1MB
- **Whisper model:** 141MB-1.6GB (depending on model)
- **Transcripts:** ~1KB per minute of meeting
- **Audio (temporary):** ~10MB per minute (PCM, deleted after transcription)

---

## Security Model

### Permissions

1. **Microphone** — For the Core Audio process tap audio capture
   - Required for system audio + mic capture (process taps are gated by the
     Microphone TCC permission)
   - Granted in System Settings → Privacy & Security → Microphone
   - App must be code-signed for TCC to work

2. **Calendar Access** — For EventKit calendar monitoring
   - Required for meeting detection
   - Granted via macOS permission dialog
   - Read-only access to calendar events

3. **Accessibility** — For window management (optional)
   - Not required for core functionality
   - Used for advanced window detection

### Code Signing

- **Development:** Ad-hoc signed (`codesign --force --deep --sign -`)
- **Distribution:** Developer ID signed + notarized
- **Requirements:** Valid code signature for TCC permissions

### Data Protection

- All processing is local
- No network requests (except optional auto-update)
- Transcripts stored in user-specified directory
- Temporary audio files deleted after transcription

---

## Build System

### Dependencies

- **Xcode Command Line Tools** 26.5+
- **Swift** 6.3.2+
- **macOS SDK** 14.0+
- **Frameworks:** SwiftUI, ServiceManagement, EventKit, CoreAudio, AudioToolbox, AVFoundation, Combine, UserNotifications, AppKit

### Build Command

```bash
./build.sh
```

### Manual Build

```bash
swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework EventKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Combine \
    -framework UserNotifications \
    -framework AppKit \
    -parse-as-library \
    $(find Sources/MeetCapture -name "*.swift" | sort | tr '\n' ' ') \
    -o ~/meetings/MeetCapture.app/Contents/MacOS/MeetCapture

codesign --force --deep --sign - ~/meetings/MeetCapture.app
```

---

## Testing

### Unit Tests

```bash
# Run unit tests
swift test
```

### Integration Tests

```bash
# Test calendar integration
swift test --filter CalendarServiceTests

# Test audio capture
swift test --filter AudioCaptureServiceTests
```

### Manual Testing

1. Launch app → verify menu bar icon
2. Grant permissions → verify detection
3. Create test meeting → verify calendar detection
4. Start recording → verify audio capture
5. Stop recording → verify transcription
6. Check transcript → verify output quality

---

## Future Architecture

### Phase 2: Enhanced Transcription

- Whisper model auto-download
- Multiple language support
- Speaker diarization
- Custom vocabulary

### Phase 3: Integration

- Note-taking app integration
- Calendar event enrichment
- Action item extraction
- Meeting summary generation

### Phase 4: Distribution

- App Store submission
- Notarization
- Auto-update via Sparkle
- Usage analytics (opt-in)

---

*Last updated: 2026-06-16*
*Version: 4.3.0*
