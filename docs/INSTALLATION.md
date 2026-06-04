> **Status: PAUSED** — This describes the MeetCapture.app menu bar app.
> For the ACTIVE transcription pipeline, see [TRANSCRIPTION-PIPELINE.md](TRANSCRIPTION-PIPELINE.md).

# Installation Guide

## Prerequisites

### macOS Version
- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3/M4) required for ScreenCaptureKit

### Hardware
- 8GB RAM minimum (Whisper base model uses ~400MB during transcription)
- ~2GB disk space (Whisper model + app)
- Microphone access permission (for ScreenCaptureKit audio capture)

### Development Tools
- Xcode Command Line Tools 26.5+
- Swift 6.3.2+

---

## Step 1: Install Xcode Command Line Tools

```bash
# Install if not already installed
xcode-select --install

# Or update to latest version
softwareupdate --install "Command Line Tools for Xcode 26.5-26.5"
```

Verify installation:
```bash
swift --version
# Should show: Apple Swift version 6.3.2 or later
```

---

## Step 2: Clone the Repository

```bash
git clone https://github.com/Gigisanta/MeetCapture.git
cd MeetCapture
```

---

## Step 3: Build the App

### Option A: Use the build script

```bash
./build.sh
```

### Option B: Manual build

```bash
# Find all Swift sources
SOURCES=$(find Sources/MeetCapture -name "*.swift" | sort | tr '\n' ' ')

# Compile
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

# Sign the app (required for permissions)
codesign --force --deep --sign - ~/meetings/MeetCapture.app
```

---

## Step 4: Grant Permissions

### Screen Recording Permission

1. Launch MeetCapture:
   ```bash
   open ~/meetings/MeetCapture.app
   ```

2. Click the menu bar icon → "Grant Permission"

3. System Settings will open → Enable MeetCapture in **Privacy & Security → Screen Recording**

4. **Restart the app** after granting permission:
   ```bash
   # Quit and relaunch
   pkill -f "meetings/MeetCapture.app"
   open ~/meetings/MeetCapture.app
   ```

### Calendar Access Permission

1. When prompted by macOS, click "Allow" to grant calendar access

2. If you missed the prompt, go to **System Settings → Privacy & Security → Calendars** and enable MeetCapture

---

## Step 5: Configure Whisper Model

MeetCapture automatically downloads the appropriate Whisper model on first use. The model is stored in:

```
~/Library/Application Support/MeetCapture/Models/
```

### Manual Model Download (Optional)

If you want to pre-download a model:

```bash
# Create models directory
mkdir -p ~/Library/Application\ Support/MeetCapture/Models

# Download base model (141MB, good for most meetings)
curl -L -o ~/Library/Application\ Support/MeetCapture/Models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin

# Or download small model (466MB, better quality)
curl -L -o ~/Library/Application\ Support/MeetCapture/Models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

### Model Selection

MeetCapture selects the best model based on available RAM:

| RAM Available | Model Selected | Size | Quality |
|---------------|----------------|------|---------|
| < 8GB | base | 141MB | Good |
| 8-16GB | small | 466MB | Better |
| > 16GB | medium | 1.5GB | Great |

---

## Step 6: Verify Installation

### Check App Status

```bash
# Verify app is running
ps aux | grep MeetCapture | grep -v grep

# Check menu bar icon
# Should appear as a microphone icon in the top-right
```

### Test Calendar Integration

1. Create a test Google Meet event in your calendar
2. Wait for MeetCapture to detect it (should appear in menu bar dropdown)
3. Verify meeting details are shown

### Test Audio Capture

1. Join a Google Meet call
2. Click "Start Recording" in MeetCapture menu
3. Verify recording indicator appears
4. Click "Stop Recording"
5. Check transcript in your configured directory

---

## Troubleshooting

### App doesn't launch

```bash
# Check if binary exists
ls -la ~/meetings/MeetCapture.app/Contents/MacOS/MeetCapture

# Rebuild
cd ~/meetings-repo && ./build.sh

# Re-sign
codesign --force --deep --sign - ~/meetings/MeetCapture.app
```

### Screen Recording permission not detected

```bash
# Reset TCC database for our app
tccutil reset ScreenCapture com.maatwork.meetcapture

# Relaunch and grant permission again
pkill -f "meetings/MeetCapture.app"
open ~/meetings/MeetCapture.app
```

### No audio captured

1. Ensure Screen Recording permission is granted
2. Check System Settings → Privacy & Security → Screen Recording
3. Restart the app after granting permission
4. Verify you're in a Google Meet call (not just a regular call)

### Transcription fails

```bash
# Check daemon logs
log show --predicate 'subsystem == "com.maatwork.meetcapture"' --last 5m

# Verify Whisper model exists
ls -lh ~/Library/Application\ Support/MeetCapture/Models/

# Check available RAM
vm_stat | head -5
```

### App crashes on startup

```bash
# Check crash logs
ls -lt ~/Library/Logs/DiagnosticReports/MeetCapture* | head -5

# View latest crash log
cat ~/Library/Logs/DiagnosticReports/MeetCapture*.crash | head -50
```

---

## Uninstallation

### Remove App

```bash
# Quit the app
pkill -f "meetings/MeetCapture.app"

# Remove app
rm -rf ~/meetings/MeetCapture.app

# Remove app support files
rm -rf ~/Library/Application\ Support/MeetCapture

# Remove logs
rm -rf ~/Library/Logs/MeetCapture

# Remove transcripts (optional)
rm -rf ~/Documents/MeetCapture
```

### Reset Permissions

```bash
# Reset Screen Recording permission
tccutil reset ScreenCapture com.maatwork.meetcapture

# Reset Calendar permission
tccutil reset Calendar com.maatwork.meetcapture
```

---

## Advanced Configuration

### Custom Transcript Directory

By default, transcripts are saved to `~/Documents/MeetCapture/`. To change:

1. Open MeetCapture → Settings
2. Set "Transcript Directory" to your preferred path
3. Click "Save"

### Auto-Start on Login

MeetCapture can automatically start when you log in:

1. Open MeetCapture → Settings
2. Enable "Launch at Login"
3. The app registers with SMAppService

### Debug Logging

To enable detailed logging:

```bash
# View app logs in real-time
log show --predicate 'subsystem == "com.maatwork.meetcapture"' --last 5m --info --debug

# View debug output file
cat /tmp/meetcapture_debug.log
```

---

## Build from Source (Development)

### Setup Development Environment

```bash
# Clone repository
git clone https://github.com/Gigisanta/MeetCapture.git
cd MeetCapture

# Create build directory
mkdir -p build

# Build for development (with debug symbols)
swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -g \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework EventKit \
    -framework ScreenCaptureKit \
    -framework Combine \
    -framework UserNotifications \
    -framework AppKit \
    -parse-as-library \
    $(find Sources/MeetCapture -name "*.swift" | sort | tr '\n' ' ') \
    -o build/MeetCapture

# Run from build directory
./build/MeetCapture
```

### Code Signing for Distribution

For distribution outside the App Store:

```bash
# Sign with Developer ID
codesign --force --deep \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --options runtime \
    --entitlements entitlements.plist \
    ~/meetings/MeetCapture.app

# Verify signature
codesign -vvv ~/meetings/MeetCapture.app

# Notarize (required for macOS 10.15+)
xcrun notarytool submit ~/meetings/MeetCapture.app \
    --apple-id your@email.com \
    --password your-app-specific-password \
    --team-id TEAMID
```

---

## System Requirements

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| macOS | 14.0 (Sonoma) | 14.0+ |
| Architecture | Apple Silicon | M1/M2/M3/M4 |
| RAM | 8GB | 16GB+ |
| Disk | 2GB | 5GB+ |
| Xcode CLI Tools | 26.5+ | Latest |

---

*Last updated: 2026-05-28*
*Version: 4.0.0*
