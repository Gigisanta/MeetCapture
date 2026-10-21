# Changelog

All notable changes to MeetCapture. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project uses
semantic versioning. The single source of the current version is
`Resources/Info.plist` (`scripts/version.sh`).

## [Unreleased]

## [7.0.2] - 2026-10-21

### Fixed
- Capture keeps bounded pending frames from unequal converter batches and drains
  both converters before the final writer flush. Overflow, channel imbalance,
  conversion and drain errors are surfaced; the realtime callback is unchanged.
- Removed lexical microphone-word deletion. Identical answers and negations from
  different speakers are retained; the acoustic bleed gate remains unchanged.
- Checkpoint manifest v4 binds audio/reference content, actual model artifacts,
  SDK revision and effective recognition configuration. Stale or corrupt derived
  checkpoints rebuild without deleting source audio; diarization is content-bound.
- Nonempty SDK text without valid word timings fails explicitly instead of
  silently losing speech or inventing timestamps.
- Cancellation reaches the detached transcription worker, and model leases are
  balanced on completion, failure and cancellation. The final user cleans up
  models without interrupting another active job.
- A failed signature verification now aborts `build.sh`; it cannot print READY.
  Injected verifier exit 42 was incorrectly accepted by the previous script and
  is now propagated as exit 42. Actual signed production and QA bundles verified.

### Changed
- Parakeet loads for transcription, not capture. The final job drops app-held model
  references and invokes SDK cleanup instead of retaining them for ten idle
  minutes. The disk cache is kept; immediate process-RSS recovery is not guaranteed.
- Production remains Parakeet-only. Experimental WhisperKit dependencies and
  controls are not included. The tested FluidAudio revision is retained: the
  inspected newer commits do not change Ultra recognition, and tag v0.17.7 is older.
- Documentation no longer guarantees Neural Engine placement or zero GPU
  contention, and describes the actual silent-left/right-mic capture layout.

### Verification and limits
- Swift tests passed 145/145, installer regressions 13/13, dispatcher 31/31,
  real-summary checks 15/15 and legacy migration 4/4; version, signature and
  shellcheck checks passed.
- The strict hosted-icon smoke passed 10/10 with local speech models required.
  An initial notHosted failure is retained as a failure; a later same-source
  native probe and screenshot established visible hosting before the successful
  retry. The Menu Bar switch was already on and no OS preference was changed.
  The transition's cause is unproven; visibility on every display/Space is not certified.
- Network-denied real import completed two imports and one re-transcription with
  three distinct history records. Network-denied dual system/microphone capture
  completed with diarization on, two participant labels, zero dropped callbacks
  and 92.907 s of captured audio from the unchanged 91.414 s public TTS corpus.
- The real isolated QA UI completed manual NSOpenPanel import, re-transcription,
  matching/non-matching search, a real invalid-WAV error and successful recovery.
  Its three distinct history rows, markers, handoffs and transcript checksums
  agreed, and Quit exited only the QA process.
- The original acceptance wrappers remain **FAIL**: all three import records
  score 1/244 word errors (WER 0.004); capture scores 2/244 (WER 0.008).
  Each misses the essential word `pongo` because the model writes `puego`.
  The maintainer explicitly accepted this known exact-word exception for this
  maintenance release on 2026-10-21. No reference, essential word, alias,
  threshold or wrapper was changed. This is not a general accuracy improvement.
- Live UI-process RSS remained elevated after completed jobs. Return to the
  pre-ASR level was not demonstrated, and neither a leak nor a cache cause is
  established. These observations do not demonstrate a RAM improvement:

  | Live QA process observation | RSS (MiB) |
  | --- | ---: |
  | Before the first import | 108.6 |
  | After the first import | 771.3 |
  | After re-transcription | 834.4 |
  | After the invalid-WAV error | 826.5 |
  | After successful recovery import | 948.3 |

  Separate BSD `time -l` command peaks, not live idle or whole-PC usage:

  | Command | Maximum RSS (MiB, rounded) |
  | --- | ---: |
  | Real import | 1001 |
  | Real capture | 1041 |

## [7.0.1] - 2026-10-19

### Fixed
- The installer uses the portable `find -mmin -1` predicate on macOS and
  Homebrew/GNU find. A failed inspection is no longer silently treated as
  "no recording"; installation aborts without replacing the bundle. The same
  capture/file-use guard runs again immediately before the swap, catching a
  recording that started during the build or backup.

### Added
- `build.sh --staging-dir <path> --qa --sign -` builds a separate
  `MeetCapture QA.app` with identifier `com.maatwork.meetcapture.qa` and a
  matching ad-hoc designated requirement. Production identity is unchanged;
  the installer rejects the QA identifier. Existing QA and release docs now
  describe launching the real UI with isolated data and preferences.

### Verification and limits
- The real QA UI imported the unchanged Spanish corpus through NSOpenPanel,
  re-transcribed it, found matching text, showed an empty result for a
  non-match, surfaced an invalid-WAV conversion error, and recovered on a new
  valid import. Three distinct history rows, transcripts, processed markers
  and handoff checksums agreed. Quit exited the QA process without stopping
  the installed app or changing its 29-row database (`quick_check`: `ok`).
- The installer regression suite passed all 13 cases, including a recording
  started during the build and an inspection failure. Its recording guard
  regression failed before the fix under GNU-compatible find behavior.
- Swift tests passed `139/139`, dispatcher `31/31`, real-summary checks
  `15/15`, and legacy migration `4/4`; shellcheck passed. The signed production
  bundle passed the strict hosted-icon smoke `10/10`. Real dual-channel
  capture with diarization enabled passed with WER `0.004`, two participant
  labels, zero dropped callbacks and `92.778` s of audio from the unchanged
  `91.414` s corpus. CI now runs the installer regressions and verifies the
  separate QA bundle identity on both macOS runners.
- The known 7.0.0 exact-word import gate failure remains: Parakeet hears
  "me pongo" as "me puego" in the 91.414-second TTS corpus (WER 1/244).
  FluidAudio's opt-in dual-decode arbitration did not fix it and was rejected;
  neither the corpus, word aliases nor the acceptance gate were changed.

## [7.0.0] - 2026-10-19

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
  (manifest version 3, which records the recognition language; changing the
  language redoes the chunks) plus a cached `diarization.json`; a chunk failing
  twice becomes `[fragmento sin transcribir …]` and the audio is kept.
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
- A transcript with gaps is retried automatically (three attempts within 48 h
  of the capture) and only its failed chunks run again. Recovery and
  Re-transcribir of a capture replace its transcript, history row and
  `.pending`, keeping the meeting id and title, instead of adding a meeting. A
  gapped handoff carries `audioPath` null and skips retention, so the audio
  stays until no gap is left. Re-transcribir refuses while background recovery
  works on the same capture.
- Summary dispatcher: a `.pending` whose checksum differs from its `.done` is a
  revision and replaces the summary; a handoff rewritten while it is read,
  summarized or acknowledged is left for the next pass instead of being
  acknowledged with the old summary, and a stale `.pending.retry` that a
  revision superseded moves to `.pending.superseded`.
- Retry times are saved in `<audio>.recovery.json` (`next_attempt_at`), so the
  5 and 20 min backoff survives a relaunch or crash, and each capture keeps its
  own time; a capture that comes due during another recovery runs right after
  it, and a queued capture is checked again before its turn.
- A capture that used up its automatic attempts shows a warning under the
  pending count in the popover and posts one notification; its audio is kept
  until it is transcribed by hand. A failed Re-transcribir of a complete
  capture keeps its transcript and does not count as an attempt.
- Chunk checkpoints record the recognition language; after a language change
  the chunks are transcribed again instead of reusing the old language.

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
- 7.0.0 release gate, run locally on the staged bundle: `swift test` passed
  `139/139`; the summary dispatcher tests passed `31/31` and the real-summary
  check passed; `codesign --verify --deep --strict` and the installer fixture
  test passed; the smoke test passed `10/10`. On the `91.414`-second Spanish
  TTS corpus, `capture` passed with WER `0.004`, `93.376` s of recorded audio
  and zero dropped callbacks. `import` measured WER `0.004` (1/244, under the
  `0.15` limit) but exited 1: its essential-word check requires every
  reference word of four letters or more, and Parakeet heard "me pongo" as
  "me puego" on both runs. The `ui` mode of RELEASING was not run, because the
  repo has no way to build the QA bundle with a separate identifier.
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
