# Architecture

## System Overview

MeetCapture is a macOS menu bar application that automatically captures and transcribes Google Meet calls. It operates entirely locally — no audio leaves the machine, no bots join meetings, no cloud services are required.

```
┌─────────────────────────────────────────────────────────┐
│  MeetCapture.app (menu bar, ~90MB RAM)                  │
│  ├── Menu bar UI (rumps + PyObjC)                       │
│  ├── Settings management                                │
│  └── Daemon lifecycle management                        │
└────────────────────┬────────────────────────────────────┘
                     │ spawns
                     ▼
┌─────────────────────────────────────────────────────────┐
│  daemon.py (background, ~20MB RAM, 0% CPU idle)         │
│  ├── Google Calendar polling (gws CLI)                  │
│  ├── Meeting detection logic                            │
│  ├── ffmpeg audio capture                               │
│  ├── Transcription orchestration                        │
│  └── Hermes integration                                 │
└────────────────────┬────────────────────────────────────┘
                     │ spawns (on meeting end)
                     ▼
┌─────────────────────────────────────────────────────────┐
│  transcribe_worker.py (detached process)                │
│  ├── Audio chunking (>10min meetings)                   │
│  ├── Whisper.cpp transcription                          │
│  ├── Streaming post-processing                          │
│  └── Hermes notification                                │
└─────────────────────────────────────────────────────────┘
```

---

## Components

### 1. MeetCaptureApp.py — Menu Bar App

**Technology:** Python 3 + rumps (Ridiculously Uncomplicated macOS Python Statusbar apps)

**Responsibilities:**
- Display menu bar icon with state (●/◉/⚠)
- Provide menu: status, start/stop, settings, open transcripts
- Manage daemon lifecycle (start, monitor, restart)
- Settings UI (transcript directory, auto-start)

**State polling:** Every 3 seconds, reads `~/.meetings/.daemon_state.json` to update the UI.

**Memory:** ~60MB (Python + rumps + PyObjC + Cocoa framework)

### 2. daemon.py — Background Daemon

**Technology:** Python 3, pure stdlib (no external dependencies)

**Responsibilities:**
- Poll Google Calendar via `gws` CLI
- Detect active meetings with external attendees
- Start/stop ffmpeg recording
- Trigger transcription worker
- Write state to `.daemon_state.json`
- Log to `.daemon.log`

**Smart polling intervals:**
| State | Interval | Reason |
|-------|----------|--------|
| Idle | 120s | Save API calls |
| Meeting approaching (within 5 min) | 30s | Quick detection |
| Recording active | 10s | Detect meeting end |

**External attendee detection:**
- Only records meetings with at least one attendee NOT in `MY_EMAILS`
- Prevents recording personal events, solo calls, etc.

### 3. transcribe_worker.py — Transcription Worker

**Technology:** Python 3 + Whisper.cpp CLI

**Responsibilities:**
- Split long audio into 10-minute chunks
- Transcribe each chunk with Whisper
- Post-process: remove hallucinations, repetitions, garbage
- Concatenate chunk transcripts
- Notify Hermes via `.pending` signal

**Memory optimization:**
- Chunks are processed sequentially and deleted immediately
- Peak RAM ~50MB per chunk (vs ~300MB for full 60min file)
- Post-processing is streaming (line-by-line, no full file load)

### 4. launcher.c — Binary Launcher

**Technology:** C, compiled to Mach-O arm64

**Responsibilities:**
- Resolve Python venv path relative to app bundle
- Find the correct Python executable (venv → system fallback)
- Launch MeetCaptureApp.py

**Why a compiled binary?**
- macOS executes binaries when double-clicking `.app` bundles
- Shell scripts are opened in editors instead of executed
- ~34KB, zero dependencies

---

## Data Flow

### Recording Flow

```
1. daemon.py polls Google Calendar (gws CLI)
2. Finds meeting with Meet link + external attendee
3. Checks if currently in meeting time window
4. Starts ffmpeg: BlackHole 16ch → FLAC (16kHz mono)
5. Polls every 10s to detect meeting end
6. Meeting ends → sends SIGTERM to ffmpeg
7. Spawns transcribe_worker.py (detached process)
8. Worker splits audio → Whisper → post-process → notify
```

### Transcription Flow

```
1. Check audio duration
2. If >10 min: split into chunks (ffmpeg segment)
3. For each chunk:
   a. Transcribe with Whisper (base model, 4 threads)
   b. Delete chunk immediately (progressive cleanup)
4. Concatenate all chunk transcripts
5. Post-process (streaming, line-by-line):
   - Remove [Music], [Applause], etc.
   - Remove whisper hallucination repetitions
   - Remove empty lines
6. Copy transcript to configured directory
7. Write .pending signal for Hermes
```

---

## File Locations

| File | Location | Purpose |
|------|----------|---------|
| App bundle | `~/meetings/MeetCapture.app` | macOS application |
| Daemon | `~/meetings/meet-daemon.py` | Background service |
| Worker | `~/meetings/.transcribe_worker.py` | Transcription process |
| Config | `~/.meetcapture.json` | User configuration |
| State | `~/meetings/.daemon_state.json` | Current daemon state |
| PID | `~/meetings/.daemon.pid` | Daemon process ID |
| Log | `~/meetings/.daemon.log` | Daemon log |
| Queue | `~/meetings/.transcribe_queue.json` | Pending transcriptions |
| LaunchAgent | `~/Library/LaunchAgents/com.maatwork.meetcapture.plist` | Auto-start |
| Whisper model | `~/.whisper/models/ggml-base.bin` | STT model (141MB) |
| Transcripts | Configurable via `transcript_dir` | Output directory |

---

## Resource Usage

| Component | RAM | CPU (idle) | CPU (active) |
|-----------|-----|------------|--------------|
| MeetCapture.app | ~60MB | 0% | <1% |
| daemon.py | ~20MB | 0% | <2% |
| transcribe_worker | ~50MB peak | N/A | <40% |
| ffmpeg | ~10MB | N/A | <2% |
| **Total idle** | **~80MB** | **0%** | — |
| **Total recording** | **~100MB** | — | **<5%** |
| **Total transcribing** | **~200MB peak** | — | **<40%** |

---

## Security Considerations

### Privacy

- **No cloud services:** All processing is local
- **No bot in meeting:** Audio is captured via system loopback, not by joining the call
- **No network transmission:** Audio never leaves the machine
- **Local storage only:** Transcripts are stored on local disk

### Authentication

- Google Calendar access via OAuth2 (gws CLI)
- Token stored at `~/.config/gws/credentials.json`
- Refresh token handles automatic renewal

### Audio Capture

- Uses BlackHole 16ch virtual audio device
- Captures all system audio (not just Meet)
- Other audio (music, notifications) may be captured
- Post-processing removes some artifacts

---

## Limitations

| Limitation | Impact | Workaround |
|-----------|--------|------------|
| macOS only | No Windows/Linux | Use cloud alternatives |
| No speaker diarization | Can't identify who said what | Manual review |
| BlackHole captures all audio | Music/notifications in transcript | Close other audio sources |
| No real-time transcription | Only after meeting ends | Wait for summary |
| Whisper hallucinations | May generate false text | Post-processing reduces but doesn't eliminate |
| No multi-language | Spanish optimized | Change `--language` flag |

---

## Future Improvements

- [ ] Speaker diarization (identify who is speaking)
- [ ] Real-time transcription during meeting
- [ ] Multiple language support
- [ ] Windows/Linux support
- [ ] Cloud backup option (encrypted)
- [ ] Meeting summary with AI (GPT-4, Claude)
- [ ] Integration with other calendar providers
- [ ] Audio level monitoring during recording
- [ ] Automatic gain control
