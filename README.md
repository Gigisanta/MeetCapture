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

## Requirements

| Dependency | Version | Purpose |
|-----------|---------|---------|
| macOS | 13+ (Ventura) | Menu bar app, LaunchAgent |
| Python | 3.10+ | Daemon, app, transcription |
| ffmpeg | 8+ | Audio capture |
| whisper-cpp | latest | Speech-to-text |
| BlackHole | 0.6+ | System audio loopback |
| gws CLI | latest | Google Calendar API |

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
# Clone the repo
git clone https://github.com/Gigisanta/MeetCapture.git
cd MeetCapture

# Create Python venv and install rumps (menu bar UI)
python3 -m venv .app-venv
.app-venv/bin/pip install rumps

# Compile the launcher
cc -o MeetCapture.app/Contents/MacOS/MeetCapture launcher.c -framework CoreFoundation

# Copy Python files to app bundle
cp daemon.py MeetCapture.app/Contents/Resources/meet-daemon.py
cp transcribe_worker.py MeetCapture.app/Contents/Resources/
cp MeetCaptureApp.py MeetCapture.app/Contents/Resources/

# Run
open MeetCapture.app
```

### 3. Configure

Click the menu bar icon → **Settings** → Set your transcript directory.

Or edit `~/.meetcapture.json`:

```json
{
  "transcript_dir": "~/Documents/MeetingTranscripts",
  "auto_start": true
}
```

### 4. Auto-start on login (optional)

```bash
# Copy the LaunchAgent
cp com.maatwork.meetcapture.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.maatwork.meetcapture.plist
```

---

## Usage

### Menu Bar

The app lives in your menu bar with three states:

| Icon | State |
|------|-------|
| ● (green) | Daemon running, waiting for meeting |
| ◉ (red) | Recording in progress |
| ⚠ (amber) | Daemon stopped or error |

Click the icon to see:
- Current status
- Active meeting name (when recording)
- Start/Stop daemon
- Open transcripts folder
- View log
- Settings

### What Gets Recorded

MeetCapture only records meetings that have:
1. A **Google Meet link** (not Zoom, not phone-only)
2. At least one **external attendee** (not just your own emails)

Personal events, solo calls, and meetings without a Meet link are automatically skipped.

### Transcription

After a meeting ends:
1. Audio is transcribed locally with Whisper (base model, ~141MB)
2. Post-processing removes hallucinations and artifacts
3. Transcript is saved to your configured directory
4. If Hermes Agent is configured, a `.pending` signal triggers automatic summary generation

---

## Architecture

```
MeetCapture.app (menu bar, ~90MB RAM)
  └── daemon.py (background, ~20MB RAM, 0% CPU idle)
        ├── Calendar polling (smart intervals: 120s idle / 30s approaching / 10s active)
        ├── ffmpeg capture (BlackHole → FLAC, lossless)
        ├── transcribe_worker.py (async, chunked for long meetings)
        │     ├── Whisper.cpp with Apple Silicon GPU
        │     ├── Chunked processing (10min segments, ~50MB RAM peak)
        │     └── Streaming post-processing (line-by-line)
        └── Hermes integration (.pending signal → cron summary)
```

### Resource Budget

| State | CPU | RAM | Disk |
|-------|-----|-----|------|
| Idle | 0% | ~110MB (app+daemon) | 0 |
| Recording | <2% | ~130MB | ~1MB/min (FLAC) |
| Transcribing | <40% | ~200MB peak | temporary chunks |

---

## Configuration

### `~/.meetcapture.json`

| Key | Default | Description |
|-----|---------|-------------|
| `transcript_dir` | `~/.hermes/TechPartners/MaatWork/meetings/transcripts` | Where transcripts are saved |
| `auto_start` | `true` | Start daemon when app launches |

### Daemon Constants (in `daemon.py`)

| Constant | Default | Description |
|----------|---------|-------------|
| `MY_EMAILS` | Your emails | Emails to exclude from external attendee check |
| `AUDIO_SAMPLE_RATE` | 16000 | Audio sample rate (Hz) |
| `AUDIO_CHANNELS` | 1 | Mono (sufficient for speech) |
| `AUDIO_FORMAT` | flac | Lossless, ~60% smaller than WAV |
| `POLL_IDLE` | 120s | Calendar poll interval when idle |
| `POLL_APPROACHING` | 30s | Poll interval when meeting starts within 5 min |
| `POLL_ACTIVE` | 10s | Poll interval during active recording |
| `MAX_RETRIES` | 3 | Transcription retry attempts |
| `CHUNK_DURATION_SEC` | 600 | Audio chunk size for long meetings (10 min) |

---

## CLI Commands

```bash
# Daemon management
python3 daemon.py --daemon      # Start as background daemon
python3 daemon.py --status      # Show current status
python3 daemon.py --stop        # Stop recording + transcribe
python3 daemon.py --check       # One-shot calendar check
python3 daemon.py --health      # Health check (exit 0=ok, 1=error)
python3 daemon.py --simulate    # Test detection logic
python3 daemon.py --transcribe  # Process pending transcription queue
```

---

## Project Structure

```
MeetCapture/
├── README.md                          # This file
├── LICENSE                            # MIT License
├── .gitignore                         # Git ignore rules
├── MeetCaptureApp.py                  # Menu bar app (rumps)
├── daemon.py                          # Background daemon
├── transcribe_worker.py              # Async transcription worker
├── launcher.c                         # Compiled binary launcher
├── MeetCapture.app/                   # macOS app bundle
│   └── Contents/
│       ├── Info.plist                 # App metadata
│       ├── MacOS/MeetCapture          # Binary launcher (compiled from launcher.c)
│       └── Resources/                 # Python files (copied during install)
├── com.maatwork.meetcapture.plist     # LaunchAgent for auto-start
└── docs/
    ├── INSTALLATION.md                # Detailed installation guide
    ├── ARCHITECTURE.md                # Technical architecture
    └── TROUBLESHOOTING.md             # Common issues and fixes
```

---

## How It Compares

| Feature | MeetCapture | Otter.ai | Fireflies | Recall.ai |
|---------|-------------|----------|-----------|-----------|
| **100% local** | ✅ | ❌ | ❌ | ❌ |
| **No bot in call** | ✅ | ❌ | ❌ | ❌ |
| **Free** | ✅ | ❌ | ❌ | ❌ |
| **Open source** | ✅ | ❌ | ❌ | ❌ |
| **Apple Silicon GPU** | ✅ | ❌ | ❌ | ❌ |
| **Speaker diarization** | ❌ | ✅ | ✅ | ✅ |
| **Cloud backup** | ❌ | ✅ | ✅ | ✅ |
| **Multi-platform** | ❌ | ✅ | ✅ | ✅ |

---

## Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

## Credits

Built by [MaatWork](https://maat.work) — SaaS tools for Argentine businesses.

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — Local speech-to-text
- [BlackHole](https://github.com/ExistentialAudio/BlackHole) — Audio loopback driver
- [rumps](https://github.com/jaredks/rumps) — macOS menu bar Python library
- [gws CLI](https://github.com/nicholasgasior/gws) — Google Workspace CLI
