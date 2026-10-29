# Architecture

MeetCapture is a native macOS menu-bar app with no main window or Dock icon.
Clicking its AppKit `NSStatusItem` opens an `NSPopover` that hosts SwiftUI
`PopoverContent` through `NSHostingController`.
The app process has no persistent daemon or socket companion: it records from
the process tap, transcribes locally in a short-lived worker per job, and
publishes a JSON handoff. The canonical Python dispatcher in
`tools/summary/` consumes that handoff; an optional per-user launchd agent
only schedules the dispatcher. Nothing leaves the Mac unless the configured
summary endpoint is remote. The retired `com.maatwork.meetcapture.daemon`
service is not part of this architecture.

## Layout

```
Package.swift                      SwiftPM manifest (macOS 14.4, Swift 6 toolchain, language mode 5 + StrictConcurrency; FluidAudio pinned by revision)
Sources/MeetCapture/               executable shim: @main + AppDelegate
Sources/MeetCaptureCore/           everything else, one directory per layer
  App/        AppState, RecordingCoordinator, MeetingDetectionPolicy, Notifier
  Capture/    CoreAudioTap, AudioRingBuffer, AudioResampler, PCMFileWriter, AudioFormatSidecar, ChannelLevels, InputDevices, AudioCaptureService
  Detection/  CallDetector, CallActivityDebouncer, CalendarService, MeetingFilter
  ASR/        TranscriptionWorker, TranscriptionJob, RecognitionIdentity, ChannelReader, PCMToWAV, BleedGate, ChunkedTranscription, ParakeetEngine, TurnMerger, Aliases, Segment
  Pipeline/   MeetingSession, PendingContractV2, PostProcessor, Retention, AudioImporter, RecordingRecovery, MeetingNotesStore
  Store/      MeetingStore (sqlite3 + FTS5)
  Settings/   Settings, LocalConfig, SummaryDispatcherConfig, AppPaths
  Support/    ProcessRunner, ISO8601, AppInfo, Signposts
  UI/         PopoverContent, PopoverSnapshot, SettingsView, Strings, Brand, MeetCaptureApp
Tests/MeetCaptureCoreTests/        XCTest, pure logic and on-disk contracts
scripts/                           version check (no runtime scripts)
tools/summary/                      canonical summary dispatcher, optional launchd template, tests
qa/                                checks that need a built app, audio or a human eye
```

Dependencies point downward: `UI` and `App` know every layer; `Pipeline`
knows `ASR`, `Store` and `Settings`; `Capture`, `Detection`, `ASR`, `Store`
and `Settings` only know `Support`. Nothing below `App` touches SwiftUI.

## Runtime flow

1. **Detect.** `CallDetector` installs a Core Audio listener on the process
   object list and, per call app, on `kAudioProcessPropertyIsRunningInput`.
   A 30 s timer reconciles the listener (4 s polling only if the listener
   fails to install). A call is confirmed 4 s after the mic opens;
   `CallActivityDebouncer` ends it only after two consecutive inactive
   observations, so a device switch does not stop the recording. `CalendarService` reads EventKit
   and schedules one wake-up at `start - 5 min` and one at `start`;
   `MeetingFilter` accepts events with at least one whitelisted attendee.
   `MeetingDetectionPolicy` turns those signals into an `AppPhase`
   (`idle`, `approaching`, `recording`, `transcribing`, `done`) and a
   `RecordingOrigin` (`manual`, `liveCall`, `calendar`) that decides when a
   recording auto-stops.
2. **Capture.** `CoreAudioTap` creates a process tap on the call app (or a
   global tap as fallback) plus an aggregate device with the chosen input.
   The IOProc copies both tracks into a preallocated `AudioRingBuffer`
   (64 slots of 8192 frames, no allocation on the real-time thread). One
   consumer thread resamples to 16 kHz (`AudioResampler` wraps
   `AVAudioConverter` with reused output buffers). Bounded per-channel pending
   queues preserve unequal converter batches; only matched frames are written,
   without padding. Stop drains the ring, both converters to end-of-stream and
   the writer, in that order. Conversion, overflow, imbalance and drain errors
   are surfaced rather than silently truncating audio. `PCMFileWriter` appends
   Int16 stereo and flushes every 64 KB. Left is system, right is microphone;
   microphone-only mode leaves the left silent and records the microphone on the right.
   `AudioFormatSidecar` writes `<file>.pcm.format.json` with schema
   `meetcapture.audio.v1` so no consumer guesses the byte layout.
3. **Transcribe.** There is no live transcription. After capture stops,
   `TranscriptionWorkerClient` launches this app's executable in worker mode
   and runs `TranscriptionJob` there, never in the menu-bar process.
   - *Split.* `ChannelReader` writes one 16 kHz mono WAV per channel
     (`PCMToWAV`): L (system, the remote side) and R (the local mic). A
     microphone-only capture, an import, a legacy mono file, or a system
     channel that stayed silent the whole meeting gives a single channel.
   - *Bleed gate.* With Mac speakers the mic also hears the remote side.
     `BleedGate` mutes each 0.5 s mic window where the system level is above
     −55 dBFS, the mic is less than 10 dB above it, and the 200 Hz–4 kHz
     band-passed signals correlate above 0.4 at a delay from −50 ms (mic leads
     the tap) to +100 ms (mic lags). The reference includes 100 ms of history
     and 50 ms of future samples, zero-padded outside the file. Gate identity
     version 2 invalidates checkpoints made with the previous range. Double
     talk stays because the local speaker is then clearly louder.
   - *Chunks.* `ChunkedTranscription` cuts each channel into ~5 min chunks at
     the quietest 100 ms frame within ±10 s of each boundary and transcribes
     them with `ParakeetEngine` (FluidAudio, Parakeet TDT 0.6B "ultra"), which
     returns real timed words. Core ML CPU/Neural Engine placement is requested,
     not measured. The adapter rejects nonfinite or negative times, reversed
     intervals and nonempty SDK text without word timings; it preserves SDK order
     rather than inventing an alignment. Finished
     chunks are checkpointed in `<audio>.work/remote/` and `<audio>.work/mic/`
     (`manifest.json` version 4 + `chunk-NNN.json`). Audio SHA-256, gated reference
     content, recognizer/model artifact identity, SDK and effective configuration
     must match before reuse. Mismatches or corrupt checkpoints rebuild derived
     work without deleting source audio. A chunk failing twice becomes
     `[fragmento sin transcribir hh:mm:ss–hh:mm:ss]` and the audio is kept. If
     every chunk fails the job throws `emptyOutput` and recovery retries it; if
     every chunk decodes and none has words the job throws `noSpeech`, which is
     terminal: `RecordingRecovery.recordTerminal` uses up the automatic attempts
     (`terminal: "no_speech"`), the audio stays for a manual run, and no history
     row, handoff or "exhausted" notice is produced.
   - *Diarize.* With diarization on, FluidAudio's offline diarizer (pyannote
     community-1 segmentation and embeddings, VBx clustering) runs on the
     remote channel only; its spans are cached in `<audio>.work/diarization.json`
     against actual source content, not just file size. It requires macOS 15
     (macOS 14 crashes in BNNS) and is skipped there.
   - *Merge.* `TurnMerger` labels mic words `Yo` and remote words
     `Participante 1..N` by order of first appearance, or `Participante` when
     diarization is off or failed. Lexical matching never deletes a microphone
     word merely because the remote speaker said it too; the acoustic gate is
     the echo control. A new turn opens on a speaker change, a gap over 1.5 s,
     or a sentence end after 45 s. A word whose weakest token confidence is under
     `TurnMerger.doubtfulBelow` (0.50) is written with `[?]` before its trailing
     punctuation (`hola[?],`); checkpoints from before 7.1.0 carry no confidence
     and are never marked. `Aliases` applies configured spelling fixes to the
     merged turns; a match containing doubtful words keeps a marker on the
     canonical spelling, including variants with trailing punctuation.

   `install.sh` downloads the models to `~/Library/Application Support/FluidAudio/`
   (`MEETCAPTURE_PREFETCH_MODELS=1`), or the first worker does. Completion,
   error and cancellation release the worker's model lease and invoke SDK
   cleanup; process exit then releases its entire address space. Capture
   never warms models, the disk cache is retained, and no idle unload timer
   is needed. Hardware placement and GPU contention are not instrumented.
4. **Hand off.** `PostProcessor` is an actor: it rejects empty transcripts,
   writes the `.txt` transcript, commits `MeetingStore`, writes the
   `.processed.json` marker, and only then publishes the `.pending`
   contract. It applies `RetentionPolicy` after those writes succeed.
   `AppState` receives the `PostProcessResult` and updates published state
   on the main actor.
5. **Summarize.** The canonical
   `tools/summary/meetcapture_summary_dispatcher.py` turns each `.pending`
   into `.summary.json`, `.summary.html` and `.summary.md`, renames it to `.done`, and
   deletes the audio unless `keep_audio` is set. A transcript over 24k characters is
   summarized in parts and the part summaries merged; the `speakers` list
   names who appears. The optional launchd agent
   wakes it on changes to `~/meetings` and every 15 minutes; it does not start
   MeetCapture or capture audio. Transient failures move the file to
   `.pending.retry[.N]` with a backoff of 5 min doubling up to 6 h; after 8
   attempts it becomes `.pending.failed`, which `--retry-failed` requeues. A
   `.pending` whose checksum differs from its `.done` is a revision (the app
   filled the gaps) and replaces the summary. The acknowledgement hard-links the
   handoff first and checks that copy, so a revision published meanwhile stays
   queued; a stale `.pending.retry` that a revision superseded moves to
   `.pending.superseded`.

## Meeting identity

`MeetingSession` is created once per job (recording, import or
re-transcription) and carries `id = "meet-<epoch>-<uuid>"`, `startedAt` and the
display title. Every path derived from a session (`.pcm`, `.txt`,
`.pending`, the SQLite row) uses the same id, so jobs created in the same
second never overwrite each other. Live captures add a `recording-` prefix
to that id; existing recordings and history keep their original paths.

## On-disk contracts

| Path | Writer | Reader | Notes |
| --- | --- | --- | --- |
| `~/meetings/transcripts/recording-meet-<epoch>-<uuid>.pcm` + `.pcm.format.json` | Capture | ASR, retention | Int16 stereo 16 kHz; sidecar schema `meetcapture.audio.v1` (`sample_rate`, `sample_format`, `channels`, `layout`, `tap_strategy`, `tap_info`). |
| `<audio>.work/` (`remote/`, `mic/`, `diarization.json`, `gaps.json`) | ASR | ASR | Per-channel manifest version 4 binds audio/reference SHA-256, actual model artifacts, SDK and effective recognition configuration. Stale/corrupt derived checkpoints are rebuilt without deleting source audio; diarization is content-bound too. `gaps.json` remains while the handed-off transcript has gaps and is removed after a complete transcript is handed off. Older manifests are invalidated, not compatibility-shimmed. |
| `<audio>.recovery.json` | AppState | AppState | `attempts`, `last_error`, `updated_at` and `next_attempt_at` (ISO 8601 with milliseconds; absent once the automatic attempts are used up). Automatic recovery runs a capture only after `next_attempt_at`, at most three attempts within 48 h of the capture. Removed when a transcript without gaps is handed off. |
| `~/meetings/transcripts/[recording-]meet-<epoch>-<uuid>.txt` | PostProcessor | dispatcher, popover | Live recordings use the `recording-` prefix; retranscriptions use the job id directly. Imports keep a unique dated basename in `~/meetings/imports/`. One `[speaker]: text` line per turn, for example `[Yo]: …` or `[Participante 2]: …`. |
| `~/meetings/meet-<epoch>-<uuid>.pending` | PostProcessor | dispatcher | Version 2, 14 sorted keys: `audioPath` (null if deleted or if the transcript has gaps), `checksum` (SHA-256 of the transcript text), `durationSec`, `endedAt`, `engine`, `language`, `meetingId`, `model`, `segments` (`start`, `end`, `text`, optional `speaker`), `speakerCount`, `startedAt`, `title`, `transcriptPath`, `version`. Written to a temp file and renamed. |
| `<transcript basename>.processed.json` | PostProcessor | app | Schema `meetcapture.processed.v1`: `processed_at`, `transcript_path`, `meeting_title`, `retention`. Makes post-processing idempotent. |
| `~/meetings/meet-<epoch>-<uuid>.done`, `.summary.json`, `.summary.html` | dispatcher | popover | Acknowledged handoff and the summary. |
| `~/meetings/meetcapture.db` | MeetingStore | popover | `meetings` table plus `meetings_fts` (FTS5, external content, triggers). `PRAGMA user_version = 2`. Searches use `MATCH` with a prefix on the last token, `LIMIT 50`; `LIKE` is the fallback without FTS5. |
| `~/.meetcapture/config.json` (0600) | you | LocalConfig | `whitelistedEmails` and `aliases` (canonical spelling → variant string or array; whole-word, case-insensitive). Decoding is tolerant: unknown keys are ignored, missing keys keep defaults. Template in `Resources/config.example.json`. |
| `~/.meetcapture/summary.json` (0600) | Settings, you | dispatcher | `endpoint`, `api_key`, `model`, `max_tokens`, `keep_audio`, `dry_run`. The app merges its fields and preserves the rest. |
| `~/Library/Application Support/FluidAudio/` | FluidAudio | ParakeetEngine, FluidDiarizer | Parakeet and diarization Core ML models, downloaded from Hugging Face on first use. Licenses in `docs/THIRD_PARTY.md`. |

`MEETCAPTURE_TEST_OUTPUT_DIR` redirects every meeting path into one
directory, including SQLite. XCTest and fixture QA use it so tests do not
touch `~/meetings`; the real harness requires a new temporary directory and
keeps its report inside that directory.

## Settings and resolution order

`Settings` is a typed enum over `UserDefaults` (`Settings.Key`,
`registerDefaults()` from the app delegate) and the only place that reads
or writes defaults. The engine is fixed (Settings › ASR shows it); only the
language and the diarization toggle are settings. CI's hygiene job checks tracked source for hardcoded
per-machine paths; that source check is evidence of repository text only, not
runtime behavior.

## External processes

| Process | Started by | Lifetime | Input and output |
| --- | --- | --- | --- |
| `MeetCapture` with `MEETCAPTURE_TRANSCRIPTION_WORKER=1` | TranscriptionWorkerClient | one transcription | One JSON request on stdin, `MCW1 ` progress and final outcome/error lines on stdout; stderr drained separately. |
| `afconvert` | AudioImporter | per import | Converts wav, m4a, aiff, caf to 16 kHz Int16. |
| `afplay` | RealPipelineCheck | per `capture` check | Plays the known WAV into the capture. |
| `meetcapture_summary_dispatcher.py` | optional `ai.hermes.meetcapture-summary` launchd agent or manual invocation | one pass per trigger | `.pending` in, `.summary.*` and `.done` out. |

`ProcessRunner` handles conversion/playback with drained pipes and
SIGTERM → SIGKILL escalation. `TranscriptionWorkerClient` uses a streaming
process harness because transcription also needs progress and a stdin
lifetime lease.

### Transcription worker

The menu-bar process never loads transcription or diarization models. Each
job runs in a fresh copy of the app executable, so model memory belongs to
that worker and disappears when it exits. The client queues jobs FIFO:
only one worker runs at a time on the single ANE, avoiding duplicate model
working sets. A cancelled queued job never launches a process.

The request contains the audio path, capture sample rate, language,
diarization option and aliases; the worker does not read app settings.
Prefetch, snapshot, launch-probe and QA mode triggers are removed from the
child environment. The parent keeps stdin open until completion; EOF or
SIGTERM cancels the worker task, preserving atomic chunk checkpoints.
Cancellation closes stdin, waits up to ten seconds, then kills a worker
that has not exited. The worker also enforces its own ten-second shutdown
deadline, so a dead parent cannot leave a model load running indefinitely.
Both output pipes are drained concurrently; worker termination starts the
same grace period to kill same-group descendants holding inherited pipes.
Unrelated stdout lines are ignored and failure diagnostics retain only the
last 4 KiB of stderr. A crash remains a recoverable transcription failure.

### Doubt-marker calibration

The 2026-10-21 calibration used only seven frozen dev blocks (9907 reference
tokens); holdout audio/references stayed closed. Words follow the adapter's
SentencePiece boundary rule, with minimum token confidence. Levenshtein aligns
case-folded Unicode alphanumeric tokens; a word is erroneous if any of its
tokens is substituted or inserted. Deleted words cannot be marked.

Thresholds 0.05 through 0.95 in steps of 0.05 were swept. The predeclared choice
was maximum F1 with at most 5% marked words and precision at least 50%.
`confidence < 0.50` won: F1 0.1333, 88 marked out of 9811 hypothesis words.
Three repeated jobs per block had identical text; only one counted.

| Dev source | Marked / hypothesis words | Precision | Recall of erroneous words |
| --- | ---: | ---: | ---: |
| OpenSLR61 | 14 / 4175 | 7.14% | 0.83% |
| MediaSpeech | 74 / 5636 | 59.46% | 9.42% |
| Combined | 88 / 9811 | 51.14% | 7.67% |

The pooled rule passes narrowly and is not reliable per source. These are read
and broadcast clips, not spontaneous meetings. An unmarked word is not a
correctness guarantee. ASR itself remains unchanged (455 substitutions,
221 deletions and 142 insertions over 9907 reference tokens, WER 8.26%).

## Build and signing

`swift build -c release` produces the optimized binary. `build.sh` wraps it
into `MeetCapture.app`: copies `Resources/Info.plist`, the icon and
`config.example.json`, then signs with the entitlements in `Resources/`
(microphone, network client, user-selected files). Ad-hoc signing is the
default; a real identity also enables the hardened runtime. Without arguments,
`build.sh` delegates to `install.sh`; explicit `--staging-dir` builds only in
that directory. `install.sh` verifies the staged bundle, refuses to replace a
running app, backs up the previous bundle under `~/meetings/.backups`, and
checks that LaunchServices starts the exact installed executable. It restores
the previous bundle on install or launch failure. Run `qa/app-smoke-test.sh`
separately. The version has a
single source, `Resources/Info.plist`; `scripts/version.sh --check`
rejects any other version literal.

FluidAudio is linked statically by SwiftPM. No model is bundled; see
`docs/THIRD_PARTY.md` for licenses and attribution.

## Test map

| Area | Where | How |
| --- | --- | --- |
| Contracts (`.pending`, marker, sidecar, chunk manifest, WAV header) | `Tests/MeetCaptureCoreTests` | `swift test` |
| ASR logic (channel split, bleed gate, chunk cuts and resume, turn merge, aliases) | same | `swift test` with stub recognizer and diarizer; no model is loaded |
| Policies (debounce, detection, retention, meeting filter) | same | `swift test` |
| Store (schema migration, FTS query builder, search) | same | `swift test` against a temp database |
| Settings, config, process runner | same | `swift test` with temp dirs and fake executables |
| Bundle, signature, isolated UI render and app liveness | `qa/app-smoke-test.sh` | renders `PopoverSnapshot` with synthetic `UIFixtureState`; a guarded `/tmp` LaunchServices launch checks app liveness, requires `NSStatusItem.isVisible` and a button attached to a window, and calls the status button's `performClick` twice, requiring the popover window to appear and then close; it skips operational startup and meeting writes |
| Dispatcher lifecycle and backoff | `tools/summary/test_dispatcher.py` | Python tests in a temporary directory with `dry_run`; does not prove app capture or import |
| Summary content gate | `tools/summary/test_real_summary_check.py` | Offline assertions over temporary fixtures; does not call the configured gateway or prove a real summary run |
| Visual evidence | `qa/visual-test.sh` | normal popover screenshot or headless synthetic fixture; visual evidence only |
| Real import/capture pipeline | `qa/capture-selftest.sh` with `MEETCAPTURE_REAL_CHECK=import|capture`, required `MEETCAPTURE_TEST_OUTPUT_DIR`, `MEETCAPTURE_CHECK_INPUT` WAV, and `MEETCAPTURE_CHECK_REPORT` JSON | import covers two imports plus one re-transcription; capture covers AppState, AV/Core Audio, `afplay`, the channel split, and Parakeet; the wrapper validates reference/WER |
| Real UI behavior | `MEETCAPTURE_REAL_CHECK=ui` with the same required fresh output, input WAV, and JSON report | real `AppState` and `PopoverContent` with `allowsSettings:false`, isolated history, manual import/re-transcription, search matches/non-matches and recovery through CUA; no Settings, normal startup or PASS emission |

CI (`.github/workflows/ci.yml`) runs the Swift build and tests on macOS 14
and 15, builds and signs the bundle, runs the smoke and version checks, and on
Ubuntu runs shellcheck, Python compile, both summary test
scripts, the landing lint and a hygiene pass. These jobs do not establish the
real capture/import contract, real UI behavior, or a WER result.

## Real harness contract and limits

The real check is selected in the executable entry point before normal
`MeetCaptureApp` startup. It must exit after the selected flow; it does not
enter calendar detection, ordinary startup, or persistent `UserDefaults`.

The fixed environment contract is:

```text
MEETCAPTURE_REAL_CHECK=import|capture|ui
MEETCAPTURE_TEST_OUTPUT_DIR=<new empty temporary directory; required>
MEETCAPTURE_CHECK_INPUT=<known WAV; required>
MEETCAPTURE_CHECK_REPORT=<JSON path inside TEST_OUTPUT_DIR; required>
MEETCAPTURE_CHECK_MIC_ONLY=1  # optional capture branch; default false
MEETCAPTURE_CHECK_DIARIZE=1   # optional diarization (macOS 15+); default false
```

The output directory must be completely empty before launch; the harness
rejects any existing entry, not only a database or report. `import` drives two
imports and one AppState re-transcription and checks the resulting SQLite rows
and real `.pending` handoffs. `capture` feeds the known
WAV through `afplay`, exercises AV/Core Audio, keeps the captured PCM and
format sidecar in the isolated output directory, splits it into channel WAVs,
and transcribes them with Parakeet (models already downloaded, or network on
the first run). `MEETCAPTURE_CHECK_MIC_ONLY=1` selects the
microphone-only branch and is reported as `micOnly:true`; the default is
`false`, preserving the microphone-plus-system contract. Diarization is
off unless `MEETCAPTURE_CHECK_DIARIZE=1`; the report lists the `speakers`. Missing microphone permission is a blocked prerequisite. `ui` opens the real
`PopoverContent` with `AppState`, real engines, isolated history, and volatile
settings with `allowsSettings:false`, so `SettingsView` cannot read or write
normal preferences. It disables automatic operations, lets CUA exercise the
known-WAV `NSOpenPanel` import, re-transcription, search matches and
non-matches, and error recovery, then closes through Quit. It uses a separate
bundle QA identifier and does not enter Settings or normal startup. The manual
verifier must save `ui-evidence.json` at the required report path after CUA; the
app does not auto-report or emit PASS.

App exit `0` means the selected pipeline completed, `77` means a prerequisite
blocked it, and `1` means the pipeline failed. The import/capture wrapper also
compares every record and the latest report text with the original reference;
`MEETCAPTURE_MAX_WER` defaults to `0.15` and `--max-wer` overrides it. For
`capture`, it derives recorded duration from the captured PCM and format
sidecar independently of the input WAV. App exit `0` alone is not a WER pass.
The UI path is a manual review and never maps counters to PASS. The
`capture-selftest.sh` command is the import/capture wrapper; UI orchestration
remains a separate QA-bundle/CUA run. The contract alone does not claim global
health; local evidence and unresolved capture/ASR limits are recorded in
`CHANGELOG.md`. The legacy duration-based self-test path is retired and is not
a substitute for the real check.

If transcription produces no segments, the app fails before `PostProcessor`
publishes a handoff; the input audio remains available for diagnosis or retry.
