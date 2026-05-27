# Installation Guide

## Prerequisites

### macOS Version
- macOS 13 (Ventura) or later
- Apple Silicon (M1/M2/M3) recommended for Whisper GPU acceleration

### Hardware
- 8GB RAM minimum (Whisper base model uses ~400MB during transcription)
- ~500MB disk space for Whisper model
- Microphone access permission (for BlackHole audio capture)

---

## Step 1: Install System Dependencies

### BlackHole (Audio Loopback)

BlackHole creates a virtual audio device that captures system audio. This is how MeetCapture records Google Meet calls without anyone knowing.

```bash
brew install blackhole-16ch
```

**Important:** You must **restart your Mac** after installing BlackHole. The kernel extension only loads on boot.

After restart, verify BlackHole is available:
```bash
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep BlackHole
```

### Whisper.cpp (Speech-to-Text)

```bash
brew install whisper-cpp
```

Download the base model (141MB, good for most meetings):
```bash
mkdir -p ~/.whisper/models
curl -L -o ~/.whisper/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

Verify Whisper works with Apple Silicon GPU:
```bash
whisper-cli --help 2>&1 | grep -i metal
# Should show: "ggml_metal_device_init: GPU name: ..."
```

### FFmpeg

```bash
brew install ffmpeg
```

### Google Workspace CLI

```bash
brew install googleworkspace-cli
```

Authenticate with Google Calendar:
```bash
gws auth login --services calendar
```

This will open a browser for OAuth. Grant calendar read access.

---

## Step 2: Install MeetCapture

### Option A: Build from source

```bash
git clone https://github.com/Gigisanta/MeetCapture.git
cd MeetCapture

# Create Python venv
python3 -m venv .app-venv
.app-venv/bin/pip install rumps

# Compile launcher
cc -o MeetCapture.app/Contents/MacOS/MeetCapture launcher.c -framework CoreFoundation

# Copy Python files to app bundle
cp daemon.py MeetCapture.app/Contents/Resources/meet-daemon.py
cp transcribe_worker.py MeetCapture.app/Contents/Resources/
cp MeetCaptureApp.py MeetCapture.app/Contents/Resources/

# Run
open MeetCapture.app
```

### Option B: Pre-built release (coming soon)

Download the latest `.dmg` from [Releases](https://github.com/Gigisanta/MeetCapture/releases) and drag to Applications.

---

## Step 3: Configure

### Menu Bar Settings

1. Click the MeetCapture icon in your menu bar (●)
2. Click **Settings...**
3. Set your transcript directory (where `.txt` files are saved)
4. Click **Save**

### Config File

Edit `~/.meetcapture.json`:

```json
{
  "transcript_dir": "~/Documents/MeetingTranscripts",
  "auto_start": true
}
```

### Edit Your Emails

In `daemon.py`, find the `MY_EMAILS` set and add your email addresses:

```python
MY_EMAILS = {"your.email@gmail.com", "your.alt@gmail.com"}
```

MeetCapture will only record meetings with external attendees (not just your own emails).

---

## Step 4: Auto-Start (Optional)

To launch MeetCapture automatically on login:

```bash
# Copy LaunchAgent
cp com.maatwork.meetcapture.plist ~/Library/LaunchAgents/

# Load it
launchctl load ~/Library/LaunchAgents/com.maatwork.meetcapture.plist
```

To disable auto-start:
```bash
launchctl unload ~/Library/LaunchAgents/com.maatwork.meetcapture.plist
rm ~/Library/LaunchAgents/com.maatwork.meetcapture.plist
```

---

## Step 5: Test

### Verify everything works

```bash
# Health check
python3 daemon.py --health

# Simulate a meeting
python3 daemon.py --simulate

# Test audio capture (3 seconds)
ffmpeg -f avfoundation -i ":BlackHole 16ch" -ar 16000 -ac 1 -acodec flac -t 3 -y /tmp/test.flac

# Test transcription
whisper-cli -m ~/.whisper/models/ggml-base.bin -f /tmp/test.flac -otxt -of /tmp/test --language es --no-timestamps -np
cat /tmp/test.txt

# Cleanup
rm /tmp/test.flac /tmp/test.txt
```

### Schedule a test meeting

1. Create a Google Calendar event with a Meet link
2. Add an external attendee (any email not in your `MY_EMAILS`)
3. Join the meeting
4. Verify the menu bar icon changes to ◉ (recording)
5. Leave the meeting
6. Check your transcript directory for the `.txt` file

---

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues and fixes.
