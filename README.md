# MeetCapture

**Automatic Google Meet transcription for macOS.** 100% local, zero cloud, no bots joining your calls.

MeetCapture captures system audio during Google Meet calls, transcribes it with Whisper, and generates structured summaries — all without anyone knowing you're recording.

Built by [MaatWork](https://maat.work) as an open-source tool for teams that need detailed meeting records without the privacy concerns of cloud-based transcription services.

---

## How It Works

```
Google Calendar → Detect meeting with external attendees
       ↓
BlackHole (system audio loopback) → ffmpeg captures audio
       ↓
Meeting ends → Whisper.cpp transcribes (Apple Silicon GPU)
       ↓
Post-process → Clean artifacts, remove repetitions
       ↓
Structured summary → Markdown + HTML report
```

**Privacy:** Audio never leaves your machine. No third-party SaaS. No bot in the meeting. No one knows you're recording.

---

## Quick Start

### 1. Install dependencies

```bash
# Audio loopback (requires reboot)
brew install blackhole-16ch

# Whisper (local STT)
brew install whisper-cpp
mkdir -p ~/.whisper/models
curl -L -o ~/.whisper/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

# FFmpeg
brew install ffmpeg

# Google Workspace CLI
brew install googleworkspace-cli
gws auth login --services calendar
```

### 2. Install MeetCapture

```bash
git clone https://github.com/Gigisanta/MeetCapture.git
cd MeetCapture

# Create Python venv
python3 -m venv .app-venv
.app-venv/bin/pip install rumps

# Compile native launcher
clang -target arm64-apple-macosx13.0 \
    -framework Cocoa -framework Foundation \
    -o MeetCapture.app/Contents/MacOS/MeetCapture \
    MeetCaptureLauncher.m

# Copy Python files
cp daemon.py MeetCapture.app/Contents/Resources/meet-daemon.py
cp transcribe_worker.py MeetCapture.app/Contents/Resources/
cp MeetCaptureApp.py MeetCapture.app/Contents/Resources/

# Run
open MeetCapture.app
```

### 3. Configure

Click the microphone icon in the menu bar → **Settings** → Set your transcript directory.

---

## Menu Bar

The app shows a **microphone icon** in your menu bar:

| Icon | State |
|------|-------|
| 🎤 (black) | Waiting for meeting |
| 🎤 (red dot) | Recording in progress |
| 🎤 (orange) | Daemon stopped |

Click to see:
- Current status and meeting name
- Stop Recording
- Open Transcripts Folder
- View Log
- Settings
- Quit

---

## What Gets Recorded

- ✅ Meetings with a **Google Meet link** + **external attendees**
- ❌ Personal events, solo calls, meetings without Meet link

---

## Architecture

```
MeetCapture.app (native Objective-C, ~40MB RAM)
  └── daemon.py (background, ~20MB RAM, 0% CPU idle)
        ├── Calendar polling (smart intervals)
        ├── ffmpeg capture (BlackHole → FLAC)
        ├── transcribe_worker.py (async, chunked)
        │     ├── Whisper.cpp (Apple Silicon GPU)
        │     └── Streaming post-processing
        └── Hermes integration (.pending signal)
```

---

## Project Structure

```
MeetCapture/
├── README.md
├── LICENSE (MIT)
├── MeetCaptureLauncher.m    ← Native Objective-C menu bar app
├── MeetCaptureApp.py        ← Python fallback (rumps)
├── daemon.py                ← Background daemon
├── transcribe_worker.py     ← Async transcription worker
├── MeetCapture.app/         ← macOS app bundle
├── com.maatwork.meetcapture.plist ← LaunchAgent
└── docs/
    ├── INSTALLATION.md
    ├── ARCHITECTURE.md
    └── TROUBLESHOOTING.md
```

---

## Contributing

1. Fork → Branch → Commit → Push → PR

---

## License

MIT License. See [LICENSE](LICENSE).

---

## Credits

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Local STT
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) — Audio loopback
- [gws CLI](https://github.com/nicholasgasior/gws) — Google Calendar API

Built by [MaatWork](https://maat.work)
