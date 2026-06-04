> **Status: PAUSED** — This describes the MeetCapture.app menu bar app.
> For the ACTIVE transcription pipeline troubleshooting, see [TRANSCRIPTION-PIPELINE.md](TRANSCRIPTION-PIPELINE.md#troubleshooting).

# Troubleshooting

## Common Issues

### App doesn't launch on double-click

**Cause:** The binary isn't compiled, isn't signed, or the app bundle is corrupted.

**Fix:**
```bash
# Rebuild the app
cd ~/meetings-repo && ./build.sh

# Re-sign the app
codesign --force --deep --sign - ~/meetings/MeetCapture.app

# Try launching from terminal to see errors
~/meetings/MeetCapture.app/Contents/MacOS/MeetCapture
```

---

### Screen Recording permission not detected

**Cause:** The app isn't code-signed properly, or the TCC database is stale.

**Fix:**
```bash
# Reset TCC database for our app
tccutil reset ScreenCapture com.maatwork.meetcapture

# Re-sign the app
codesign --force --deep --sign - ~/meetings/MeetCapture.app

# Relaunch
pkill -f "meetings/MeetCapture.app"
open ~/meetings/MeetCapture.app

# Grant permission again in the app
```

**Note:** macOS requires a valid code signature for TCC permissions to work. Ad-hoc signing is sufficient for local development.

---

### "Start Recording" button does nothing

**Cause:** Screen Recording permission not granted, or permission not detected after granting.

**Fix:**
1. Click "Grant Permission" in the app
2. Enable MeetCapture in System Settings → Privacy & Security → Screen Recording
3. **Restart the app** after granting permission:
   ```bash
   pkill -f "meetings/MeetCapture.app"
   open ~/meetings/MeetCapture.app
   ```
4. The button should now be enabled

**Debug:**
```bash
# Check if permission is detected
log show --predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS "MeetCapture"' --last 1m

# Check debug output
cat /tmp/meetcapture_debug.log
```

---

### No audio captured (0-byte recordings)

**Cause:** Screen Recording permission not granted, or ScreenCaptureKit not capturing audio.

**Fix:**
1. Verify Screen Recording permission:
   - System Settings → Privacy & Security → Screen Recording
   - MeetCapture should be listed and enabled

2. Restart the app after granting permission

3. Verify you're in a Google Meet call (not just a regular call)

**Debug:**
```bash
# Check if audio capture is working
log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "capture"' --last 5m

# Check PCM file size
ls -lh ~/Documents/MeetCapture/recording-*.pcm
```

---

### Calendar events not detected

**Cause:** Calendar permission not granted, or no Google Meet links in events.

**Fix:**
1. Grant Calendar permission:
   - System Settings → Privacy & Security → Calendars
   - Enable MeetCapture

2. Verify events have Google Meet links:
   - Open Calendar app
   - Check event details for Google Meet URL

3. Check calendar service logs:
   ```bash
   log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "calendar"' --last 5m
   ```

---

### Transcription fails or is empty

**Cause:** Whisper model not found, or audio file is corrupted/empty.

**Fix:**
1. Check Whisper model exists:
   ```bash
   ls -lh ~/Library/Application\ Support/MeetCapture/Models/
   ```

2. If model is missing, MeetCapture will auto-download on next use

3. Check audio file:
   ```bash
   # Verify PCM file exists and has content
   ls -lh ~/Documents/MeetCapture/recording-*.pcm
   
   # Check file format (should be 16-bit PCM, 44.1kHz)
   file ~/Documents/MeetCapture/recording-*.pcm
   ```

4. Check daemon logs:
   ```bash
   log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "whisper"' --last 5m
   ```

---

### App crashes on startup

**Cause:** Missing frameworks, incompatible macOS version, or corrupted binary.

**Fix:**
1. Check crash logs:
   ```bash
   ls -lt ~/Library/Logs/DiagnosticReports/MeetCapture* | head -5
   ```

2. Verify macOS version:
   ```bash
   sw_vers
   # Should show: ProductVersion: 14.0 or later
   ```

3. Rebuild from source:
   ```bash
   cd ~/meetings-repo && ./build.sh
   ```

---

### High CPU usage

**Cause:** Whisper transcription running (expected during transcription), or stuck in a loop.

**Fix:**
1. Check if transcription is running:
   - Menu bar should show "Transcribing..." state
   - This is expected behavior during transcription

2. If CPU stays high after transcription:
   ```bash
   # Check for stuck processes
   ps aux | grep MeetCapture | grep -v grep
   
   # Restart if needed
   pkill -f "meetings/MeetCapture.app"
   open ~/meetings/MeetCapture.app
   ```

---

### Memory usage is high

**Cause:** Whisper model loaded in memory (expected during transcription).

**Fix:**
1. Check current memory usage:
   ```bash
   ps -p $(pgrep -f "meetings/MeetCapture.app") -o pid,rss,vsz
   ```

2. Expected memory usage:
   - Idle: ~30MB
   - Recording: ~60MB
   - Transcribing: ~400MB-2GB (depending on model)

3. If memory stays high after transcription:
   ```bash
   # Restart the app
   pkill -f "meetings/MeetCapture.app"
   open ~/meetings/MeetCapture.app
   ```

---

### Socket connection fails

**Cause:** meet-daemon not running, or socket file missing.

**Fix:**
1. Check if daemon is running:
   ```bash
   ps aux | grep meet-daemon | grep -v grep
   ```

2. Check socket file:
   ```bash
   ls -la /tmp/meetcapture.sock
   ```

3. Restart daemon:
   ```bash
   pkill -f "meet-daemon"
   # Daemon will restart automatically
   ```

---

### Auto-update fails

**Cause:** Network issues, or update server unavailable.

**Fix:**
1. Check network connection:
   ```bash
   curl -I https://maat.work
   ```

2. Check update logs:
   ```bash
   log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "update"' --last 5m
   ```

3. Manual update:
   ```bash
   cd ~/meetings-repo && git pull && ./build.sh
   ```

---

## Debug Commands

### View App Logs

```bash
# View all app logs
log show --predicate 'subsystem == "com.maatwork.meetcapture"' --last 5m

# View only errors
log show --predicate 'subsystem == "com.maatwork.meetcapture" AND messageType == error' --last 5m

# View specific component logs
log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "calendar"' --last 5m
log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "capture"' --last 5m
log show --predicate 'subsystem == "com.maatwork.meetcapture" AND eventMessage CONTAINS "whisper"' --last 5m
```

### View Debug Output

```bash
# Debug output file (if enabled)
cat /tmp/meetcapture_debug.log

# Check file permissions
ls -la /tmp/meetcapture_debug.log
```

### Check System State

```bash
# Check TCC permissions
sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db \
  "SELECT service, auth_value FROM access WHERE client LIKE '%MeetCapture%';"

# Check running processes
ps aux | grep MeetCapture | grep -v grep

# Check open files
lsof -p $(pgrep -f "meetings/MeetCapture.app") | head -20

# Check network connections
lsof -p $(pgrep -f "meetings/MeetCapture.app") -i
```

### Reset App State

```bash
# Quit the app
pkill -f "meetings/MeetCapture.app"

# Remove app support files
rm -rf ~/Library/Application\ Support/MeetCapture

# Remove logs
rm -rf ~/Library/Logs/MeetCapture

# Remove debug files
rm -f /tmp/meetcapture_debug.log

# Reset TCC permissions
tccutil reset ScreenCapture com.maatwork.meetcapture
tccutil reset Calendar com.maatwork.meetcapture

# Relaunch
open ~/meetings/MeetCapture.app
```

---

## Performance Tuning

### Reduce Memory Usage

1. Use smaller Whisper model:
   - base (141MB) instead of medium (1.5GB)
   - Quality trade-off: slightly lower accuracy

2. Close other applications during transcription:
   - Whisper uses significant RAM
   - Close browser tabs, large files, etc.

### Reduce CPU Usage

1. Disable auto-transcription:
   - Settings → Auto-transcribe → Disabled
   - Manually trigger transcription when needed

2. Use faster Whisper model:
   - base model is faster than medium
   - Quality trade-off: slightly lower accuracy

### Improve Battery Life

1. Disable auto-start on login:
   - Settings → Launch at Login → Disabled
   - Manually start when needed

2. Use Energy Saver settings:
   - System Settings → Battery → Low Power Mode
   - Reduces CPU performance but extends battery

---

## Getting Help

### Collect Debug Information

Before reporting an issue, collect:

```bash
# System info
sw_vers
uname -a

# App version
strings ~/meetings/MeetCapture.app/Contents/MacOS/MeetCapture | grep -i version

# Recent logs
log show --predicate 'subsystem == "com.maatwork.meetcapture"' --last 10m > /tmp/meetcapture_logs.txt

# Crash logs
ls -lt ~/Library/Logs/DiagnosticReports/MeetCapture* | head -5

# System state
ps aux | grep MeetCapture > /tmp/meetcapture_processes.txt
```

### Report Issues

1. Check existing issues: https://github.com/Gigisanta/MeetCapture/issues
2. Create new issue with:
   - macOS version
   - App version
   - Steps to reproduce
   - Debug logs (see above)
   - Expected vs actual behavior

---

*Last updated: 2026-05-28*
*Version: 4.0.0*
