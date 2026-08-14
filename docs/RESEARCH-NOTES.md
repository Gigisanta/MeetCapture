# Research notes (2026-08-14)

Findings from deep internet research (subagents + direct verification) behind
the v6.1 live-transcription work. Kept for future engineering decisions.

## 1) Native sherpa-onnx embedding (Swift) — verified feasible

- sherpa-onnx v1.13.5 ships a **SwiftPM binary target** (XCFramework):
  - static: `https://github.com/k2-fsa/sherpa-onnx/releases/download/xcframework/sherpa-onnx-v1.13.5-macos-static.xcframework.zip` (11.6 MB)
  - shared: `.../sherpa-onnx-v1.13.5-macos-shared.xcframework.zip` (3.5 MB)
  - auto-pulls ONNX Runtime 1.27.1 (csukuangfj/onnxruntime-libs). macOS floor **10.15**.
  - Install: `.package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "1.13.5")`, product `"sherpa-onnx"`.
- Swift API: `SherpaOnnxRecognizer` (owns an OnlineStream), config via
  `sherpaOnnxOnlineRecognizerConfig` (featConfig/modelConfig, enableEndpoint,
  rule1/2/3 silence params, numThreads). Methods: `acceptWaveform([Float], 16000)`
  (Float32 normalized [-1,1]), `decode()`, `getResult()` → .text/.tokens/.timestamps,
  `isReady()`, `inputFinished()`, `isEndpoint()`, `reset()`.
  Canonical sample: `swift-api-examples/decode-file.swift`.
- Verdict: native embedding is the clean long-term path (drop the python
  subprocess); the python-subprocess design was chosen for v6.1 because it
  reuses the already-proven sherpa venv and keeps the app bundle small.
- Use the **int8 encoder** (68 MB vs 250 MB fp32) and 0.1 s chunked feeding.

## 2) Testing live capture without speaking — BlackHole loopback

The MeetCapture global process tap captures the system audio mix directly, so
**no virtual device is needed** for e2e tests (proven: 5 runs with afplay
playback). For mic-path testing or user demos, BlackHole is the standard tool:

1. `brew install blackhole-2ch` → **reboot** (HAL plugin).
2. Audio MIDI Setup → create **Multi-Output Device** = [MacBook Pro Speakers
   (top/clock) + BlackHole 2ch], Drift Correction ON for BlackHole; right-click
   → "Use This Device For Sound Output".
3. Play into it: `ffmpeg -re -i speech.wav -f audiotoolbox -audio_device_index N -`
   (ffmpeg 8.x output device is **audiotoolbox**, not coreaudio; list with
   `ffmpeg -f audiotoolbox -list_devices true -`).
4. Grab any YouTube audio: `yt-dlp -x --audio-format wav -o sample.wav <url>`.
5. Input routing on macOS follows the **system default input** (no AVAudioSession):
   select BlackHole as default input in System Settings > Sound.
6. Gotchas: BlackHole defaults to 48 kHz → resample to 16 kHz in Swift
   (AVAudioConverter) before ASR; Multi-Output has no master volume (set per
   device); avoid speaker+mic feedback during ASR tests.

## 3) Model licenses (shipping a commercial bundle)

- `zipformer-es` (kroko, live + sherpa engine): **CC-BY-SA** — do not bundle
  the weights commercially without share-alike. Downloaded by the user in
  `~/.whisper/models/sherpa/` — the app itself never ships models.
- `zipformer-en` (2023-06-26): **Apache-2.0**.
- `bookbot/sherpa-onnx-zipformer-streaming-robust-es-v0`: **Apache-2.0** but
  **phoneme-level** (IPA output; needs a gruut lexicon to produce words) — not
  a drop-in replacement for kroko. Verified: garbage word output without lexicon.
- whisper.cpp ggml models: MIT. Silero VAD: MIT. pyannote/eres2net: MIT.
