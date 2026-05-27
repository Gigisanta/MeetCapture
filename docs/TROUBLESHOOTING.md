# Troubleshooting

## Common Issues

### App doesn't launch on double-click

**Cause:** The launcher binary isn't compiled or the venv isn't set up.

**Fix:**
```bash
# Recompile launcher
cc -o MeetCapture.app/Contents/MacOS/MeetCapture launcher.c -framework CoreFoundation

# Recreate venv
python3 -m venv .app-venv
.app-venv/bin/pip install rumps
```

---

### Daemon not starting

**Cause:** Missing dependencies or Python version mismatch.

**Check:**
```bash
# Run daemon manually to see errors
python3 daemon.py --daemon 2>&1

# Check health
python3 daemon.py --health
```

**Common fixes:**
```bash
# Install missing dependencies
brew install ffmpeg whisper-cpp

# Verify gws auth
gws calendar events list --params '{"calendarId":"primary","maxResults":1}' --format json 2>&1 | grep -v keyring
```

---

### BlackHole not found

**Cause:** BlackHole requires a Mac restart after installation.

**Fix:**
```bash
# Verify installation
brew list blackhole-16ch

# Restart Mac, then verify
ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep BlackHole
```

---

### No audio captured (0-byte recordings)

**Cause:** BlackHole isn't set as the audio output device for Chrome/Meet.

**Fix:**
1. Open **System Settings** → **Sound** → **Output**
2. Select **BlackHole 16ch**
3. Or: In Google Meet → Settings → Audio → Speaker → BlackHole 16ch

**Note:** This routes ALL system audio through BlackHole. You may want to use a multi-output device (BlackHole + headphones) to hear audio while recording.

---

### Whisper transcription fails

**Cause:** Model not found or incompatible version.

**Check:**
```bash
# Verify model exists
ls -lh ~/.whisper/models/ggml-base.bin

# Test whisper directly
whisper-cli -m ~/.whisper/models/ggml-base.bin --help 2>&1 | head -5
```

**Fix:**
```bash
# Re-download model
curl -L -o ~/.whisper/models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

---

### Transcription produces garbage

**Cause:** Audio quality is poor or Whisper model is too small.

**Possible causes:**
- BlackHole capturing silence (no audio playing)
- Multiple audio sources mixed
- Very quiet meeting

**Fix:**
- Verify audio is actually playing through BlackHole
- Test with a known audio file:
  ```bash
  ffmpeg -f avfoundation -i ":BlackHole 16ch" -ar 16000 -ac 1 -acodec flac -t 10 -y /tmp/test.flac
  whisper-cli -m ~/.whisper/models/ggml-base.bin -f /tmp/test.flac -otxt -of /tmp/test --language es -np
  cat /tmp/test.txt
  ```

---

### Daemon crashes silently

**Cause:** Unhandled exception in the daemon loop.

**Check:**
```bash
# View daemon log
cat ~/meetings/.daemon.log

# View stderr
cat ~/meetings/.daemon.err

# Run manually to see errors
python3 daemon.py --daemon 2>&1
```

**Common causes:**
- `gws` not in PATH → daemon uses full path `/opt/homebrew/bin/gws`
- Token expired → `gws auth login --services calendar`
- Disk full → `df -h /`

---

### Menu bar icon doesn't appear

**Cause:** rumps not installed in the venv.

**Fix:**
```bash
.app-venv/bin/pip install rumps
open MeetCapture.app
```

---

### Personal events being recorded

**Cause:** Your email isn't in the `MY_EMAILS` set.

**Fix:**
In `daemon.py`, find:
```python
MY_EMAILS = {"giolivosantarelli@gmail.com", "giogametodraggg@gmail.com"}
```

Replace with your emails:
```python
MY_EMAILS = {"your.email@gmail.com", "your.alt@gmail.com"}
```

---

### gws token expired

**Cause:** OAuth token expired (usually after 1 hour).

**Fix:**
```bash
gws auth login --services calendar
```

The daemon uses the refresh token to auto-renew, but if the refresh token is also expired, you need to re-authenticate.

---

### Multiple daemon instances

**Cause:** Daemon didn't clean up PID file on exit.

**Fix:**
```bash
# Kill all daemon instances
pkill -f "meet-daemon"

# Remove stale PID file
rm -f ~/meetings/.daemon.pid

# Restart app
open MeetCapture.app
```

---

### Disk space issues

**Cause:** Old recordings and transcripts accumulate.

**Fix:**
```bash
# Check recordings size
du -sh ~/meetings/recordings/

# Delete old recordings
find ~/meetings/recordings/ -name "*.flac" -mtime +7 -delete

# Check transcripts
du -sh ~/.hermes/TechPartners/MaatWork/meetings/transcripts/
```

The daemon automatically cleans up recordings after transcription, but if transcription fails, recordings may accumulate.

---

## Getting Help

1. Check the [Issues](https://github.com/Gigisanta/MeetCapture/issues) page
2. Run `python3 daemon.py --health` to diagnose
3. Include the output of `cat ~/meetings/.daemon.log` in your bug report
4. Include your macOS version (`sw_vers`) and Python version (`python3 --version`)
