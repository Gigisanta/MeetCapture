# MeetCapture v6.1

Native macOS menu-bar app for private, local meeting capture, **live in-call
transcription** and Spanish/English transcription.

## Production architecture

- SwiftUI/AppKit app; no Python daemon, socket IPC, LaunchAgent, or cloud audio service.
- Core Audio process tap targets active call processes and falls back to a global tap only when needed.
- Audio is written as 16 kHz signed Int16 stereo PCM: left = system, right = microphone.
- Every recording has an explicit `<recording>.pcm.format.json` sidecar; byte heuristics are forbidden.
- **Two ASR engines** (Settings → ASR): `whisper.cpp` (default, `medium Q5_0`) or **sherpa-onnx streaming** (`zipformer-es-kroko`, RTF ~0.04 — ~25× realtime, ~3.5× faster than medium whisper) with Silero VAD segmentation.
- **Live in-call transcription (v6.1)**: while recording, the 16 kHz mono mix (system + mic) streams to a sherpa-onnx **online recognizer** (`scripts/meetcapture_stream_asr.py` — zipformer es-kroko, ~0.13 RTF ≈ 7.7× realtime) and the popover shows the meeting text **as it is spoken** (partial + endpoint-segmented sentences). The recognizer is pre-warmed at app startup so the preview starts instantly; the authoritative transcript still comes from the whole-file engine (more accurate + diarized). Toggle in Settings → ASR (live model: es / en).
- **Speaker diarization** (sherpa-onnx pyannote segmentation + eres2net embeddings): post-hoc labels A/B/C mapped onto transcript segments; transcripts get `[Speaker A]:` prefixes; speaker count goes into the handoff.
- **`.pending` v2 atomic handoff** (version, meetingId, segments with timestamps+speakers, engine, model, checksum) wakes the summary dispatcher.
- **Summary engine**: `HerMaatOS/bin/meetcapture_summary_dispatcher.py` (launchd `com.maatwork.meetcapture-summary`, WatchPaths) calls any OpenAI-compatible endpoint — default the local MLX gateway (`:8083`, qwen3.5-4b) — and writes `summary.json` + self-contained `summary.html` (resumen, action items, decisiones, asistentes), then acks `.pending → .done` and applies retention.
- **SQLite history** (`~/meetings/meetcapture.db`): meetings indexed (title, dates, engine, model, speakers, paths, full transcript) with search in the popover.
- **Import & Enhance**: import any audio file (wav/m4a/aiff/caf/pcm) to transcribe it, or re-transcribe an existing recording with a different engine/model.
- Raw audio is deleted only after transcript creation and durable handoff; retention is configurable.

No meeting audio or transcript is sent over the network by MeetCapture.

## Model licenses

Models are **downloaded by the user** (never bundled with the app):

- zipformer-es (live + sherpa engine, kroko): **CC-BY-SA** — share-alike if you redistribute the weights. Fine for personal/internal use; for a commercial bundle prefer an Apache-2.0 model (zipformer-en is Apache-2.0; bookbot es is Apache-2.0 but phoneme-level, needs a gruut lexicon).
- zipformer-en: **Apache-2.0**.
- whisper.cpp models (ggml-medium-q5_0, ...): **MIT**.
- Silero VAD: MIT; pyannote/eres2net (diarization): MIT.


## Requirements

- Apple Silicon Mac, macOS 14.4+
- Microphone, Screen & System Audio, Calendar, and Notification permissions as desired
- `whisper-cli` from `brew install whisper-cpp`
- local model: `~/.whisper/models/ggml-medium-q5_0.bin`
- sherpa-onnx engine (optional): venv `HerMaatOS/venvs/venv-meet` with `sherpa-onnx` + `numpy`, models under `~/.whisper/models/sherpa/` (see `scripts/README`), helper scripts in `scripts/` (`transcribe_sherpa.py`, `speaker_diarize.py`, `meetcapture_stream_asr.py`).

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
bash scripts/app-smoke-test.sh    # bundle + runtime checks (8/8)
bash scripts/e2e-test.sh          # lifecycle/retention/handoff/version checks (32/32)
bash scripts/lifecycle-test.sh    # architecture + contract checks
bash scripts/benchmark-asr.sh     # A/B whisper vs sherpa (WER/RTF) on generated corpus

# Live streaming ASR (standalone): feeds 16 kHz mono Int16 PCM on stdin,
# JSONL events on stdout
ffmpeg -i meeting.wav -ar 16000 -ac 1 -f s16le - |   "$HOME/HerMaatOS/venvs/venv-meet/bin/python3" -B scripts/meetcapture_stream_asr.py --model zipformer-es
bash scripts/gen_test_corpus.sh   # 2-speaker Spanish corpus via macOS `say`
```
