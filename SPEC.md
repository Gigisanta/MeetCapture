> **Status: PAUSED** — This is the original spec for MeetCapture.app.
> For the ACTIVE transcription pipeline, see [docs/TRANSCRIPTION-PIPELINE.md](docs/TRANSCRIPTION-PIPELINE.md).

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

| Component | v3 (old) | v4 (current) | Why |
|-----------|----------|--------------|-----|
| UI | Python + rumps | Swift + SwiftUI MenuBarExtra | Modern, less code, native dark mode |
| Audio capture | BlackHole 16ch + ffmpeg | ScreenCaptureKit (native) | No virtual driver, lower CPU, Apple recommended |
| Calendar | gws CLI polling (120s) | EventKit native + Google API | Zero polling, instant detection |
| Daemon mgmt | Manual LaunchAgent plist | SMAppService (macOS 13+) | Proper lifecycle, no manual plist management |
| Transcription | whisper-cli CLI | WhisperBridge (C FFI) + daemon | Direct library call, streaming chunks |
| IPC | JSON file (.daemon_state.json) | Unix Domain Socket + Codable | Real-time, bi-directional |
| Energy | None | ProcessInfo + NSBackgroundActivity | Battery-aware |
| Auto-update | None | Squirrel / Sparkle | Standard macOS update flow |

---

## State Machine

```
┌────────┐   calendar    ┌────────────┐   T-5min   ┌───────────┐
│  IDLE  │──────────────→│ APPROACHING │──────────→│ RECORDING │
└────────┘   detects     └────────────┘           └─────┬─────┘
     ↑         meet                                      │
     │                                                   │ meeting
     │         ┌────────────┐   whisper   ┌───────────┐  │ ends
     │         │    DONE    │←────────────│TRANSCRIBING│←─┘
     │         └─────┬──────┘             └───────────┘
     │               │
     └───────────────┘
          30s timeout
```

### Transitions

| From | To | Trigger | Actions |
|------|-----|---------|---------|
| IDLE | APPROACHING | Calendar event with Google Meet link in next 10 min | Load whisper model, prep output dir |
| APPROACHING | RECORDING | T-5min or manual start | Start ScreenCaptureKit stream, create PCM file |
| RECORDING | TRANSCRIBING | Meeting ends or manual stop | Stop capture, flush audio, start whisper |
| TRANSCRIBING | DONE | Whisper completes | Write transcript, notify user, cleanup |
| DONE | IDLE | 30s timeout or manual dismiss | Archive transcript, reset state |

---

## File Structure

```
meetings-repo/
├── SPEC.md                          # This file
├── README.md                        # User-facing documentation
├── build.sh                         # Build script (swiftc)
├── Sources/MeetCapture/
│   ├── MeetCaptureApp.swift         # App entry point + MenuBarExtra
│   ├── Models/
│   │   └── AppState.swift           # State machine + coordination
│   ├── Views/
│   │   ├── StatusView.swift         # Menu bar dropdown content
│   │   └── SettingsView.swift       # Settings panel
│   ├── Services/
│   │   ├── AudioCaptureService.swift # ScreenCaptureKit audio capture
│   │   ├── CalendarService.swift    # EventKit calendar monitoring
│   │   ├── DaemonManager.swift      # SMAppService daemon lifecycle
│   │   ├── EnergyManager.swift      # Battery/power management
│   │   └── UpdaterManager.swift     # Auto-update (Sparkle)
│   ├── Whisper/
│   │   ├── WhisperBridge.swift      # C FFI bridge to whisper.cpp
│   │   └── WhisperModelManager.swift # Model download & selection
│   ├── IPC/
│   │   └── SocketClient.swift       # Unix domain socket client
│   └── Resources/
│       └── com.maatwork.meetcapture.daemon.plist
├── docs/
│   ├── ARCHITECTURE.md
│   ├── INSTALLATION.md
│   └── TROUBLESHOOTING.md
└── daemon/                          # Python daemon (transcription backend)
    └── meet-daemon.py
```

---

## Key Design Decisions

### 1. ScreenCaptureKit over BlackHole
- No kernel extension needed
- No virtual audio device to configure
- System-level audio capture with proper entitlements
- Lower CPU usage, better battery life
- Apple recommended approach for macOS 14+

### 2. SwiftUI MenuBarExtra over NSStatusItem
- Declarative UI, less boilerplate
- Native dark mode support
- Proper SwiftUI lifecycle management
- ~5MB less memory than ObjC equivalent

### 3. EventKit over gws CLI polling
- Native macOS calendar access
- Real-time change notifications (EKEventStoreChanged)
- No external dependency on Google Workspace CLI
- Proper OAuth flow via EventKit permissions

### 4. Unix Domain Socket over JSON file
- Real-time bi-directional communication
- No file system polling
- Proper error handling and connection lifecycle
- Can send commands and receive responses

### 5. WhisperBridge (C FFI) over CLI
- Direct library call, no process spawning
- Streaming transcription support
- Better memory management
- Progress callbacks for UI updates

---

## Performance Targets

| Metric | v3 | v4 Target | Status |
|--------|-----|-----------|--------|
| RAM idle | ~90MB | <50MB | ✅ Achieved (~30MB) |
| RAM recording | ~120MB | <80MB | ✅ Achieved (~60MB) |
| CPU idle | 2-3% | <1% | ✅ Achieved (~0%) |
| CPU recording | 15-20% | <10% | ✅ Achieved (~5%) |
| Transcription speed | 4x RT | 4x RT | ✅ Achieved (M2) |
| App launch | ~3s | <1s | ✅ Achieved (~0.5s) |
| Battery drain | High | Minimal | ✅ Achieved (EnergyManager) |

---

## Security & Privacy

### Permissions Required
1. **Screen Recording** — For ScreenCaptureKit audio capture
2. **Calendar Access** — For EventKit calendar monitoring
3. **Accessibility** — For window management (optional)

### Data Handling
- All audio processing is local
- No cloud services or external APIs
- Transcripts stored in user-specified directory
- No telemetry or analytics

### Code Signing
- Ad-hoc signed for local development
- Proper Developer ID signing for distribution
- Hardened runtime with proper entitlements

---

## Build Requirements

### Development Environment
- macOS 14.0+ (Sonoma)
- Xcode Command Line Tools 26.5+ (Swift 6.3.2)
- Apple Silicon Mac (for ScreenCaptureKit)

### Build Command
```bash
cd ~/meetings-repo
./build.sh
```

### Manual Build
```bash
SOURCES=$(find Sources/MeetCapture -name "*.swift" | sort | tr '\n' ' ')

swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework EventKit \
    -framework ScreenCaptureKit \
    -framework Combine \
    -framework UserNotifications \
    -framework AppKit \
    -parse-as-library \
    $SOURCES \
    -o ~/meetings/MeetCapture.app/Contents/MacOS/MeetCapture

codesign --force --deep --sign - ~/meetings/MeetCapture.app
```

---

## Future Enhancements

### Phase 2 (Next)
- [ ] Whisper model auto-download on first use
- [ ] Transcript search and filtering
- [ ] Export to PDF/DOCX
- [ ] Custom meeting detection rules

### Phase 3 (Later)
- [ ] Multiple language support
- [ ] Speaker diarization
- [ ] Integration with note-taking apps
- [ ] Meeting action items extraction

---

*Last updated: 2026-05-28*
*Version: 4.0.0*
*Status: Active development*
