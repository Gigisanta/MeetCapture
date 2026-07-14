# MeetCapture v5

Native macOS menu-bar app for private, local meeting capture and Spanish transcription.

## Production architecture

- SwiftUI/AppKit app; no Python daemon, socket IPC, LaunchAgent, or cloud audio service.
- Core Audio process tap targets active call processes and falls back to a global tap only when needed.
- Audio is written as 16 kHz signed Int16 stereo PCM: left = system, right = microphone.
- Every recording has an explicit `<recording>.pcm.format.json` sidecar; byte heuristics are forbidden.
- `whisper.cpp` runs locally with the quantized `medium Q5_0` model by default.
- Long recordings are converted and transcribed as bounded sequential chunks with persistent context.
- A single atomic `.pending` handoff wakes the deterministic HerMaat summary dispatcher.
- Raw audio is deleted only after transcript creation and durable handoff; retention is configurable.

No meeting audio or transcript is sent over the network by MeetCapture.

## Requirements

- Apple Silicon Mac, macOS 14.4+
- Microphone, Screen & System Audio, Calendar, and Notification permissions as desired
- `whisper-cli` from `brew install whisper-cpp`
- local model: `~/.whisper/models/ggml-medium-q5_0.bin`

## Install or update

```bash
./install.sh
```

The installer:

1. builds in an isolated staging directory;
2. verifies plist and code signature;
3. backs up the current app;
4. replaces and launches `~/meetings/MeetCapture.app`;
5. runs production smoke checks;
6. automatically restores the prior build if verification fails.

Only the three newest backups are kept under `~/meetings/.backups/`.

## Build without installing

```bash
./build.sh --staging-dir /tmp/meetcapture-stage
codesign --verify --deep --strict /tmp/meetcapture-stage/MeetCapture.app
```

Local builds use ad-hoc signing. Developer ID signing and notarization are required only for distribution to other Macs.

## Tests

```bash
bash scripts/lifecycle-test.sh
bash tests/test-asr-pipeline.sh
python3 scripts/test_legacy_privacy_migration.py

swiftc \
  -framework AppKit -framework CoreAudio -framework AudioToolbox \
  -framework AVFoundation -framework Combine \
  Sources/AudioCapture.swift Sources/CallDetector.swift \
  Tests/AudioResamplerIntegrationTests.swift \
  -o /tmp/audio-resampler-tests
/tmp/audio-resampler-tests

swiftc Tests/CallDetectorTests.swift -o /tmp/call-detector-tests
/tmp/call-detector-tests
```

Full strict-concurrency typecheck:

```bash
swiftc -typecheck -strict-concurrency=complete -warn-concurrency \
  -framework AppKit -framework SwiftUI -framework CoreAudio \
  -framework AudioToolbox -framework AVFoundation -framework EventKit \
  -framework UserNotifications Sources/*.swift
```

Expected result: zero errors and zero warnings.

## Runtime data

```text
~/meetings/MeetCapture.app
~/.whisper/models/ggml-medium-q5_0.bin
~/.hermes/TechPartners/MaatWork/meetings/transcripts/
~/.hermes/TechPartners/MaatWork/meetings/.pending
```

Directories and meeting artifacts use owner-only permissions. The legacy migration tool defaults to dry-run and never deletes recordings.

## Recovery

```bash
./build.sh --rollback
```

If a production install fails its smoke checks, `install.sh` performs this rollback automatically.
