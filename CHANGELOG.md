# Changelog

All notable changes to MeetCapture. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
semantic versioning. The single source of the current version is
`Resources/Info.plist` (`scripts/version.sh`).

## [Unreleased]

Planned as 7.0.0 (`scripts/version.sh` bumps it at release).

### Removed
- Whisper: `whisper-cli`, the ggml models in `~/.whisper/models`,
  `scripts/fetch-models.sh`, `WhisperModels`, `SegmentJSON`, the Homebrew
  `whisper-cpp` requirement and its bundling (`tools/packaging/bundle_macho.py`).
- The Python diarizer: `scripts/speaker_diarize.py` (sherpa-onnx),
  `scripts/setup-venv.sh`, `requirements.txt` and `~/.meetcapture/venv`. The
  app runs no Python; the summary dispatcher is unchanged.
- Live transcription.
- `ToolchainResolver`, the `domainPrompt`, `python` and `scriptsDir` keys of
  `config.json`, the `asrModel` setting, and the proportional timeout helper
  in `ProcessRunner`, which now only runs `afconvert` and `afplay`.

### Added
- NVIDIA Parakeet TDT 0.6B "ultra" through the FluidAudio Swift package
  (pinned revision), on the Neural Engine so it does not compete with a local
  LLM for the GPU. Each channel is transcribed separately; the models
  download once to `~/Library/Application Support/FluidAudio`. Licenses and
  attribution in `docs/THIRD_PARTY.md` and Settings › Acerca de.
- Bleed gate: 0.5 s microphone windows that only repeat the call audio coming
  out of the speakers are muted before transcription; double talk is kept.
- FluidAudio offline diarization (pyannote community-1, VBx) on the call
  channel on macOS 15 and newer: `Participante 1..N` by order of appearance,
  `Gio` for the microphone, one `Participante` without diarization.
- `aliases` in `config.json`: canonical spelling → variants, applied whole-word
  and case-insensitively to the merged transcript.
- Per-channel checkpoints in `<audio>.work/remote/` and `<audio>.work/mic/`
  (manifest version 2) plus a cached `diarization.json`; a chunk failing twice
  becomes `[fragmento sin transcribir …]` and the audio is kept.
- `install.sh` downloads and compiles the models (`MEETCAPTURE_PREFETCH_MODELS=1`)
  and refuses to swap the bundle while a `recording-*.pcm` is being written.
  Parakeet loads when a recording starts and is freed after 10 idle minutes.
- Default retention is now 24 h instead of deleting the audio right after the
  handoff, so a failed or partial transcript can still be redone.
- `.pending` lists the transcript `speakers`; the summary dispatcher names
  them and summarizes long transcripts in parts before merging them.

### Fixed
- Run as a menu-bar-only app (`LSUIElement`) with a square template-icon
  status item that reflects the phase. Detect when macOS does not host the
  item (switched off in System Settings › Menu Bar › "Allow in the Menu Bar")
  or leaves it behind the notch, and show the same controls in a floating
  panel with the fix instead of an invisible menu. Clicking the icon toggles
  the popover, and a minimal main menu makes ⌘C/⌘V work in text fields.
- Check the microphone permission first and independently of Calendar,
  re-check it whenever the app becomes active, and keep Record enabled: it
  requests the permission, or opens Privacy settings once macOS no longer
  asks. Warn during a recording when the system channel never carries audio
  (missing System Audio Recording permission) or the microphone delivers
  pure silence.
- Recover recordings that never reached a transcript (quit, crash or failed
  transcription). Captures from the last 48 hours are transcribed in the
  background at launch, at most three attempts each; older ones are listed
  with a "Transcribir" button. Quitting mid-recording stops and flushes the
  capture so it can be recovered, and retention never deletes unprocessed
  audio.
- Always capture system audio through the global tap, because the targeted
  tap missed browser GPU helpers (Safari `WebKit.GPU`) and Teams 2. Recognise
  those processes as call apps.
- Serialize recording start/stop, preserve actionable errors, and run history
  searches outside the main actor.
- Give each job and recording a unique identity, and publish summary
  handoffs only after transcript, history and processing metadata are durable.
- Reject empty transcripts and malformed audio instead of marking them complete.
- Terminate descendant process groups on cancellation and timeout, including
  children still holding output pipes after their parent exits.
- Preserve microphone-only levels and allocate enough resampler output for
  upsampling; clean up failed and cancelled capture starts.
- Reject empty summaries, roll back failed artifact publication, preserve
  colliding handoffs, and restart retry backoff from the latest failure.
- Confine summary input paths to the meetings directory, and preserve imported
  transcripts when their audio was already deleted after handoff. Keep each
  retranscription in its own artifact so earlier history remains intact.
- Verify the selected app bundle through a decoded UI snapshot and provide an
  isolated window for interactive regression checks.
- Clear a prior operation error when a new operation is accepted and cancel
  its dismissal task, so a successful voice retry does not retain stale error
  text in the UI.
- Show `Iniciando audio…` while recording startup is pending, and show
  `Grabando` only after the recording driver has actually started.
- Surface PCM write, flush and close failures to the recording state, retain
  the partial audio, and skip transcription and handoff for incomplete audio
  in that session (the partial capture is offered again by recording recovery).
  Bound the pending PCM buffer after a write failure, stop capture as soon as
  the consumer reports it, and show the error. A failed device-change rebuild
  also makes stop fail, so interrupted audio cannot be published as complete.
- Convert imported audio in a temporary sibling file; cancellation or process
  failure removes the partial output, and only a completed conversion is moved
  into the durable imports directory.

### Changed
- Transcription splits the stereo capture into a system and a microphone
  WAV instead of mixing it to mono. Mic-only captures, imports and meetings
  whose system channel stayed silent use a single channel.
- CI no longer installs `whisper-cpp` or runs the packaging tests.
- Keep installer backups as zipped bundles in `~/meetings/.backups`, so
  LaunchServices no longer registers old copies under the same bundle id.
- Sign with `MEETCAPTURE_SIGN_IDENTITY` and the hardened runtime when set
  (permissions then survive rebuilds); ad-hoc signing still works and warns
  that macOS may ask for permissions again.
- `qa/visual-test.sh` refuses to run while MeetCapture is open instead of
  killing the user's instance.
- Compact the streaming PCM resampler by indexed windows instead of moving its
  pending array for each output sample. The converted WAV bytes and duration
  remain unchanged on the measured voice corpus.
- Measure WAV duration through `AVAudioFile` so padded RIFF chunks such as
  `FLLR` do not turn a multi-second recording into a false near-zero duration.
- Carry the measured audio duration and capture end time through the
  transcription outcome before post-processing, so history and handoff
  duration describe the audio instead of ASR wall-clock time.
- Remove unused record summary data and obsolete Whisper model metadata, and
  replace tautological assertions with behavior checks.

### Documentation
- Separate structural checks, synthetic UI fixtures, direct ASR fixtures, and
  the real import/capture/UI harness. Document the environment contract,
  the CUA boundary, and its exit meanings without turning local evidence into
  a global pass; keep `PopoverSnapshot` as appearance-only evidence.

### Verification and limits
- The final Swift suite passed `114/114`; the targeted import and AppState
  suites also passed `9/9` each, including a real
  `afconvert` conversion, cancellation after a partial output was written,
  and immediate stop after a reported write failure. The staged
  signed bundle passed `10/10` smoke checks, including normal launch liveness;
  the normal app also remained running for five seconds with test output and
  automatic recording disabled. A fresh `5.125063`-second spoken
  fixture passed the app's real import flow with three distinct history rows
  and WER `0`; microphone-only capture recorded `7.008` seconds, dropped zero
  callbacks, and produced the same text with WER `0`. These local tests do not
  validate the unresolved microphone-plus-system HAL path.
- On a fresh `91.414`-second local Spanish voice corpus, the PCM conversion
  measured `3.40` to `1.38` seconds for float32 mono and `3.67` to `1.55`
  seconds for Int16 stereo; both resulting WAVs retained the baseline SHA-256,
  size and duration. The test-process RSS rose from `76.2` to `90.5` MB in that
  run, so this evidence demonstrates CPU speedup, not a memory reduction.
- The same corpus with `ggml-medium-q5_0`, the production Whisper prompt,
  Silero VAD and CPU-only inference produced WER `2/244` (`0.82%`) at both 4
  and 8 threads. Four threads took `59.87` seconds; two 8-thread passes took
  `49.48` and `60.76` seconds, with about `1.6` GB peak CLI RSS. The 12-thread
  pass was stopped after `294.91` seconds without a final transcript; it
  overlapped a Swift link, so its cause is not established. This does not
  justify raising the existing 8-thread cap or promise a speedup on every Mac.
- A real capture baseline observed a zero-byte PCM output and a timeout;
  hardware behavior remains unresolved, so this entry does not claim that the
  capture path is repaired.
- A later capture attempt reported the HAL hang
  `AudioDeviceCreateIOProcIDWithBlock` before `AudioDeviceStart`. The host/TCC
  responsibility remains undetermined; no permission reset or service change
  was performed. The capture contract still requires microphone plus system
  audio, and this observation does not claim capture is fixed.
- A real opt-in microphone-only capture with
  `MEETCAPTURE_CHECK_MIC_ONLY=1` played the `5.639875`-second known microphone
  fixture through `afplay`, produced a `7.562`-second capture with zero dropped
  callbacks, and yielded the expected Whisper text with `micOnly:true`.
  This validates only the microphone-only branch; it does not
  validate dual microphone-plus-system capture.
- Dual capture still fails under normal LaunchServices even with Audio Capture
  permission visibly enabled in the UI; the failure reaches the HAL call
  `AudioDeviceCreateIOProcIDWithBlock` before `AudioDeviceStart`, while the
  deeper cause remains unknown. A proposed `coreaudiod` restart was not
  approved and was not performed.
- Independent review accepted the bounded capture failure behavior: a 15-second
  productive timeout rejects new starts with an actionable error, defers cleanup
  until HAL returns without a concurrent stop, and releases stop waiters. Seven
  `CaptureRegressionTests` passed. This validates timeout and cleanup behavior;
  it does not repair the HAL path or provide new real-capture evidence.
- The full Swift suite completed 105 tests with zero failures in `12.507` seconds.
  This is suite
  evidence only; no new CUA evidence is claimed.
- A separate three-second silence input produced no transcription segments,
  published no handoffs, and retained its imported audio. That is the expected
  negative result for silence, not evidence of a successful speech path.
- Before the duration correction, a valid-WAV import produced correct
  transcripts across three ASR jobs while history reported the wrong duration.
  A subsequent real session confirmed three distinct handoffs consumed once by
  the canonical dispatcher with model `maat/smart` through `127.0.0.1:8080`,
  with `dry_run=false`, `keep_audio=true`, no hooks, and a temporary config.
  It produced three JSON+HTML summary pairs containing “revisar proyecto” and
  “preparar informe mañana”, without invented attendees; a second dispatcher
  run was idempotent.
- A separate CUA session opened the real UI with `NSOpenPanel`, imported the
  known Spanish WAV, re-transcribed it, and exercised matching and non-matching
  history search. SQLite contained two exact transcripts with distinct paths
  and the corrected `5.639875` second duration. This is local manual evidence,
  not a CI PASS; the disposable evidence JSON is outside the repository.
- The real rich-summary check made strong assertions against `maat/smart` and
  passed with `--delete-audio`: Lucía's budget was dated 30 September, Bruno's
  demo 2 October, and API v2 release 5 October. The idempotent second run kept
  the published artifacts unchanged after the first execution deleted the
  audio fixture while preserving the transcript.
- A recovery audit confirmed that silence → visible error → valid voice clears
  the stale error during and after the retry. The run preserved one SQLite row,
  one `.pending` handoff, and two audio files; five focused AppState tests also
  passed. The manual evidence is disposable and does not make the app emit an
  automatic PASS.
- The real capture wrapper now compares every report record with the original
  reference text, checks capture duration from the captured PCM and format
  sidecar independently of the input WAV, and keeps its disposable artifacts.
  The ASR benchmark defaults to `ENGINE=both` and `MAX_WER=0.15`, and fails if
  a requested engine is missing. Its wrapper revalidation accepted three
  records against an independent original TTS reference and rejected an old
  corrupt record.
- The real sherpa report used the complete corpus
  with the strict gate `WER <= 0.20` and essential coverage `>= 0.80`.
  Spanish offline measured WER `0.196`/coverage `0.750` and failed; Spanish
  streaming measured `0.109`/`0.857` and met that gate. English offline
  measured `0.378`/`0.607` and failed; English streaming measured
  `0.400`/`0.607` and failed. Diarization produced speakers A/B and preserved
  the mapping/text in its targeted check, without proving DER or identity.
  The corpus was not truncated; these results identify a real sherpa model
  quality limitation rather than a fixture-shortening artifact.
- On that same corpus, the Whisper CPU gold report covered all four
  phrases: Spanish WER `0%`/coverage `100%`, English WER `4.4%`/coverage
  `96.4%`. Whisper remains the default engine. These are engine-level results;
  they do not establish app capture or a global pipeline result.
- The real Whisper benchmark over 12 Spanish TTS phrases measured WER
  `2.46%` and RTF `0.53` over `91.413813` seconds, under the `0.15` WER gate,
  using `ggml-medium-q5_0`, four CPU threads, and the original reference text.
  This is direct Whisper evidence,
  not app capture or a global pipeline result; app capture remains pending. An
  earlier unretained run is excluded from the evidence.
- The disposable `/tmp` logs and reports from 22 September were removed by
  the host's cleanup. The measurements above are historical; regenerate
  inspectable evidence with the commands in `qa/README.md`.

## [6.3.0] - 2026-09-11

### Added
- SwiftPM `Package.swift` with a `MeetCaptureCore` library, an executable
  shim and an XCTest target; `build.sh` now bundles an optimized
  `swift build -c release` binary.
- `~/.meetcapture/config.json` for per-machine data (attendee whitelist,
  domain prompt, python, scripts dir) with `Resources/config.example.json`.
- `ToolchainResolver`: python and scripts are found through Settings,
  `config.json`, environment, `~/.meetcapture/venv`, the app bundle and
  `PATH`, with a cached `import sherpa_onnx` check.
- Live transcription warm policy: the streaming recognizer unloads after
  N idle minutes (Settings › ASR, default 10) and warms again for calls,
  imminent meetings and manual recordings.
- Settings › Resumen edits `~/.meetcapture/summary.json`; Settings ›
  Calendario shows the whitelist.
- FTS5 index over meeting transcripts with debounced search.
- `tools/summary/`: the summary dispatcher lives in the repo with retry
  backoff (5 min doubling to 6 h, 8 attempts), `--retry-failed`, a launchd
  plist template, installer and unit tests.
- `scripts/setup-venv.sh`, `scripts/fetch-models.sh`, `scripts/version.sh`,
  `requirements.txt`, `qa/` for machine-bound checks, CI on macOS 14 and 15
  plus a Linux checks job, and the landing page at meetcapture.maat.work.

### Changed
- Sources split into layers (App, Capture, Detection, ASR, Pipeline, Store,
  Settings, Support, UI); `AppState` shrank from 1027 to about 350 lines.
- Audio path: preallocated ring buffer in the IOProc (no allocations per
  callback), dedicated consumer thread, 64 KB buffered PCM writer.
- Call detection listens to Core Audio process events with a 30 s
  reconciliation poll instead of polling every 4 s.
- All post-processing (transcript, `.pending`, marker, retention, SQLite)
  runs off the main actor.
- External processes run through one `ProcessRunner` with drained pipes,
  audio-proportional timeouts and SIGTERM then SIGKILL.
- Popover reordered: status card with the live text, primary button under
  it, next meeting, transcript card, history with import. UI strings in
  Spanish. Settings tabs: General, Audio, ASR, Resumen, Calendario, Acerca de.
- Version shown from the bundle; no hardcoded version strings.

- Headless popover render (`MEETCAPTURE_SNAPSHOT_PATH`, `qa/visual-test.sh
  --headless`): the real view with synthetic data, used for the landing
  screenshot without Accessibility permissions.
- Landing page in `site/` (static, no JavaScript, self-hosted fonts) with
  `scripts/deploy-site.sh`.

### Fixed
- The capture consumer thread ran with Foundation's 512 KB default stack and
  overflowed during real calls (SIGBUS in the live feed path); capture and
  ASR worker threads now get 8 MB.
- The app trapped (`dispatch_sync` on its own queue) when Core Audio
  reported a process-list change while the call detector was reconciling
  its listeners; found by the self-test recording.
- Speaker labels never applied: the diarizer received a bare array instead
  of `{"segments": [...]}`.
- Live transcription only worked for the first recording per launch.
- Importing or re-transcribing overwrote the previous meeting's `.pending`
  and SQLite row (session identity is now created once per job).
- Temporary WAV path was a literal `\(UUID)`.
- Calendar-based scheduling never fired (`tick()` had no caller).
- Whisper timeout sent SIGINT and checked the wrong exit codes.

### Removed
- Hardcoded personal paths, emails and prompt text.
- Legacy docs (`INSTALLATION`, `TROUBLESHOOTING`, `TRANSCRIPTION-PIPELINE`,
  `FORENSIC-AUDIT`), `.omh/`, `scripts/e2e-test.sh`,
  `qa/test-asr-pipeline.sh` (ported to XCTest), model downloads in `build.sh`.

## [6.2.0] - 2026-08-14

### Added
- Conversation mode (microphone only) and input device selector
  (iPhone Continuity).

## [6.1.0] - 2026-08-14

### Added
- Live in-call transcription with a sherpa-onnx streaming recognizer;
  partial and final sentences shown in the popover while recording.

## [6.0.1] - 2026-08-10

### Fixed
- `.pending` handoff written to the canonical `~/meetings` path, one file
  per meeting (`meet-<epoch>.pending`).

## [6.0.0] - 2026-08-09

### Added
- sherpa-onnx engine, speaker diarization, summary dispatcher, SQLite
  history with search, audio import and re-transcription, GitHub Actions CI.

## [5.0.0] - 2026-07-14

### Changed
- Standalone app: the Python daemon, socket IPC and launch agent were
  removed. Atomic handoff contract, configurable retention, verified
  installer with rollback.

## [4.4.0] - 2026-07-14

### Fixed
- Lifecycle, handoff, retention and build corrections.

## [4.3.0] - 2026-06-16

### Changed
- Security hardening of the daemon and build, robust linking.

## [4.2.0] - 2026-06-15

### Added
- Microphone plus system audio capture, VAD, device-change resilience,
  automatic recording of live calls.

## [4.0.0] - 2026-06-04

### Changed
- Native Swift/SwiftUI menu-bar app with bundled `whisper-cli`, code
  signing and a flat architecture.

## [3.0.0] - 2026-05-27

### Added
- First release: automatic Google Meet transcription.
