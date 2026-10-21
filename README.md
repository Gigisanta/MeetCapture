<!-- maatwork-brand:maatwork-mw-20260901 -->
<p align="center"><img src="docs/brand/meetcapture-cover.png" alt="MeetCapture · MaatWork" width="1200"></p>

# MeetCapture

[![CI](https://github.com/Gigisanta/MeetCapture/actions/workflows/ci.yml/badge.svg)](https://github.com/Gigisanta/MeetCapture/actions/workflows/ci.yml)

[Install](#install-from-a-pinned-release) · [Releases](https://github.com/Gigisanta/MeetCapture/releases) · [Measured baseline](docs/BASELINE.md) · [Report a bug](https://github.com/Gigisanta/MeetCapture/issues/new?template=bug_report.yml)

MeetCapture is a native macOS menu-bar app for recording calls, transcribing
them locally, and keeping the resulting meeting history on the Mac. It has no
main window or Dock icon. Opening the app from Finder or Spotlight shows its
controls below the menu-bar icon; later, click that icon to reopen them.
Opening the app again while it is running also shows the controls. The native
Swift app uses short-lived transcription helpers, with no Python in the app.
Speech and speaker labels run locally through
[FluidAudio](https://github.com/FluidInference/FluidAudio) and Core ML.
Parakeet requests CPU/Neural Engine execution; actual device placement and GPU
contention are not instrumented. Summary generation is a separate, optional
Python dispatcher; its default endpoint is the local gateway at
`http://127.0.0.1:8080/v1`. A configured remote summary endpoint would send
transcript text off the Mac.

Website: https://meetcapture.maat.work

## What it does

- **Local capture.** A Core Audio process tap records the call app and the
  microphone into 16 kHz Int16 stereo PCM. In the normal two-track layout,
  left is system audio and right is the microphone; microphone-only mode
  leaves the left channel silent and records the microphone on the right.
- **Transcript after the call.** There is no live transcription. After
  capture, each channel is transcribed separately with NVIDIA Parakeet TDT
  0.6B in ~5 min chunks. Checkpoints bind audio content, model artifacts, SDK
  and effective configuration, so compatible work resumes after interruption.
  An acoustic bleed gate mutes remote audio leaking into the microphone;
  identical words from different speakers are not deleted by lexical matching.
  The actual engine and model are recorded in the handoff.
- **Speaker labels.** The microphone channel is labeled `Yo`. With "Identificar
  hablantes" on (macOS 15 or newer), the call channel is diarized into
  `Participante 1`, `Participante 2`… by order of appearance; otherwise it is
  one `Participante`. Transcript lines read `[Yo]: text`; old transcripts are not renamed.
- **Doubtful words.** A word the recognizer was unsure of is written as
  `palabra[?]` (before any punctuation). The threshold was calibrated on read
  and broadcast Spanish, not real meetings: about 1 in 100 words is marked,
  roughly half of those are wrong, and most errors stay unmarked; a dropped
  word is never marked. Search ignores the marker.
- **Silence.** A recording with no speech ends with "No se detectó habla"; the
  audio is kept for a manual run and is not retried automatically.
- **Summaries.** The canonical dispatcher at
  `tools/summary/meetcapture_summary_dispatcher.py` consumes each `.pending`
  handoff and writes JSON, HTML and a portable Markdown note with decisions,
  checkable pending tasks and the full transcript. The history row opens the
  Markdown note when it is ready. While recording, you can type private notes
  in the popover; they are saved alongside the meeting and included as context
  in the generated note. It uses the configured
  OpenAI-compatible endpoint and can run in `dry_run` mode.
- **History.** SQLite history with full-text search is shown in the popover.
  Audio can be imported or an existing recording can be re-transcribed.

Raw audio is retained until the transcript, history row, processing marker
and `.pending` handoff are durable. The app then applies its retention policy;
the summary dispatcher removes handoff audio after a successful summary unless
`keep_audio` is enabled.

## Requirements

- **App runtime:** a native Apple Silicon Mac (`arm64`), macOS 14.4 or newer.
  Speaker diarization needs macOS 15. Intel Macs and running the build from a
  Rosetta terminal are not supported.
- **Source build:** Swift **6.0 or newer** plus the macOS SDK, Git and Apple's
  build/signing tools. Both `Package.swift` and the pinned FluidAudio
  `Package.swift` declare Swift tools 6.0; Swift 5 language mode does not lower
  that compiler requirement. Use a compatible Xcode 16 or newer, or Command
  Line Tools that provide Swift 6.0+ and the macOS SDK.
  [Apple's compatibility table](https://developer.apple.com/xcode/system-requirements/)
  lists the required host OS: Xcode 16–16.2 require **macOS 14.5+**. A Mac
  still on 14.4 must update for that source-build route. The app's 14.4 runtime
  target is not a promise that a current Xcode installs on 14.4.
- **Initial downloads:** network access to GitHub for the pinned dependency
  source and checksum-verified binary dependency, then to Hugging Face for
  speech models (about 0.6 GB). `install.sh` attempts to prepare the models in
  `~/Library/Application Support/FluidAudio/`; a failed download is deferred
  to first transcription. Speaker-label models may download separately.
  Leave disk space for the toolchain, build cache, models and retained audio.
- **Optional summaries:** a separately available Python 3 interpreter and a
  working OpenAI-compatible endpoint. Neither Python, Whisper nor a summary
  service is required to capture and transcribe with the native app.

If no developer tools are installed, run `xcode-select --install` and finish
the macOS installer before continuing. On an older macOS, choose a compatible
version through [Apple Developer Downloads](https://developer.apple.com/download/all/)
instead of assuming the latest Xcode supports your Mac. If using the full
Xcode app, open it once and finish its setup. Check the selected tools:

```bash
uname -m
sw_vers -productVersion
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-path
git --version
```

`uname -m` must report `arm64`, and `swift --version` must report 6.0 or newer.
The build script checks the host, compiler and SDK before replacing a staging
bundle; an outdated Command Line Tools installation is not sufficient.

## Local resources

ASR and speaker labeling need no cloud service or subscription after the model
download. Each transcription runs in a fresh helper process; the menu-bar
process never loads the models. Jobs queue one at a time, and the helper exits
on completion, failure or cancellation. The disk cache remains.

In the 91 s import check, the menu-bar process stayed near 17 MiB of physical
footprint after each of three jobs. This moves model memory to a short-lived
child; it does not remove the roughly 0.8 GiB recognition working set.
The 7.0.2 baseline's physical footprint recovered after five idle seconds in
one run but not the repeat; high RSS alone was not evidence of a leak. See
[`docs/BASELINE.md`](docs/BASELINE.md) for the frozen 7.1.0 measurements, input
hashes, reproduction steps and explicit acceptance failures.

For local-only summaries, keep the endpoint and every gateway upstream local,
or leave the optional scheduler disabled. Installing the app does not install
that scheduler, a model server, external training or a cloud runtime.

## Install from a pinned release

MeetCapture's public installation path is a **local source build**, not a
downloadable notarized app. The commands below target `v7.1.0`. First confirm
that tag and its notes are present on
[GitHub Releases](https://github.com/Gigisanta/MeetCapture/releases).
If the tag is not published yet, stop; a pull request or `main` checkout is
not a substitute for the release.

Do not install while a call, recording or transcription is active. The
installer launches the app when it succeeds, and automatic recording is on
by default. Review the onboarding below before using it for a real meeting.
Run as your normal macOS user, **without `sudo`**:

```bash
git clone --branch v7.1.0 --depth 1 https://github.com/Gigisanta/MeetCapture.git MeetCapture-7.1.0 && \
cd MeetCapture-7.1.0 && \
./install.sh
```

This checks out the release rather than the moving `main` branch.
`Package.swift` and `Package.resolved` pin FluidAudio; do not run a dependency
update to work around an installation error.

`install.sh` builds and verifies a staging bundle, backs up the current local
bundle, installs to `~/meetings/MeetCapture.app`, then launches and checks the
exact installed executable. It refuses to replace a live installed bundle,
checks for recent recordings before building and immediately before the swap,
and refuses installation if that inspection fails. A failed install/launch
attempt restores the previous bundle when it can safely confirm the candidate
has stopped; otherwise it preserves recovery paths and prints them. It never
kills a recording process to force an update.

After installation, use `open "$HOME/meetings/MeetCapture.app"` or open that
exact bundle in Finder. Opening it again reveals the menu-bar controls.
A successful installer launch proves process liveness, not successful audio
capture or transcription; make a short, consented recording and review both
channels and the transcript before relying on it.

### Local signing and Gatekeeper

The default build is signed ad-hoc on your Mac. Signature verification checks
bundle integrity; it is **not** Developer ID identity verification or Apple
notarization. CI app artifacts and a ZIP copied from another Mac are not the
supported public installation route. Building locally does not disable
Gatekeeper or organization-managed security policy. If macOS blocks a build,
keep that protection in place, save the exact message and use the support
steps below. There is no quarantine-removal or Gatekeeper-bypass step.

### First launch and permissions

1. Open the menu-bar controls, then Settings. In General, review **"Grabar
   llamadas y reuniones automáticamente"** before joining a call; turn it off
   if you want manual recording only. Obtain participants' consent as required
   before recording.
2. Allow **Microphone** for your voice. For the call's audio, allow MeetCapture
   under System Settings › Privacy & Security › **Screen & System Audio
   Recording** (the label varies by macOS). After changing audio permissions,
   quit and reopen the installed bundle. If the call channel is silent, the
   app warns you; a transcript from the microphone alone is not proof that
   other participants were captured.
3. **Calendar** is optional for calendar-based meeting detection. **Notifications**
   are optional for completion alerts. Declining either does not prevent
   manual recording. macOS may request permissions again after an ad-hoc rebuild.
4. In General, review **"Audio original"** retention before recording. For
   later listening or re-transcription, choose to keep audio; the normal
   default is 24 hours. If you enable summaries, also review `keep_audio` in
   `~/.meetcapture/summary.json`: a successful summary can delete its handoff
   audio unless that option is true.
5. Leave the optional summary scheduler uninstalled unless you have configured
   and reviewed its endpoint. The loopback default does not install a local
   model server, and a local gateway can itself forward to a remote provider.
   Confirm the gateway's routing before treating summaries as local-only.

### Update, backup and rollback

Before updating, finish recording **and** transcription, then use the app's
Quit control. If you enabled the optional summary agent, pause it with
`tools/summary/install-summary-agent.sh --uninstall` from its source checkout
and wait for summary work to finish before making a consistent data backup.
Keep that checkout: the agent runs its Python files in place.

The installer backs up only the old **app bundle** as
`~/meetings/.backups/MeetCapture-<date>-<time>-<pid>.app.zip`. It does not back up
meeting data, settings or credentials. With the app and dispatcher stopped,
use Time Machine or a private backup of:

- `~/meetings/` in full, including `meetcapture.db`, any `-wal`/`-shm` companions,
  transcripts, imports, audio/format sidecars, checkpoints and handoffs;
- `~/.meetcapture/`, including any summary credentials;
- preferences exported with `defaults export com.maatwork.meetcapture <private-backup-path>/preferences.plist`
  if you have saved app settings.

Protect this backup as meeting content; do not upload it to an issue.
For an update, use a fresh checkout of the chosen published tag and run its
`./install.sh` as above. Do not `git pull` a working production checkout onto
`main`, delete the model cache, or replace a running `.app` by dragging files
over it. Personal configuration remains outside the checkout.

If the new version launches but has a functional regression, quit it and run
`./install.sh` from your retained, previously working release checkout. This
uses that release's installer rather than a live-bundle overwrite. App
rollback does **not** roll back SQLite or meeting data; preserve the data
backup and check the release notes for downgrade compatibility first. Keep
zipped app backups for manual recovery; extract one only into a separate
recovery directory for inspection, not over a running app, and do not launch
multiple production-identity copies. If automatic recovery reports preserved
paths, keep them and request support instead of deleting them.

If summaries were enabled, deliberately reinstall their agent from the chosen
checkout after reviewing its configuration; `install.sh` does not update,
enable or migrate that service.

## Configuration

Personal configuration stays outside the repository in `~/.meetcapture/`:

- `config.json` (see `Resources/config.example.json`) contains
  `whitelistedEmails` and optional `aliases`, which map a canonical spelling
  to what the recognizer writes instead, for example
  `{"AppSheet": ["app sheet"], "CEDEAR": ["cedear", "sedear"]}`. Aliases
  replace whole words, ignore case, and apply to the merged transcript.
  Settings › Calendario opens it.
- `summary.json` contains `endpoint`, `api_key`, `model`, `max_tokens`,
  `keep_audio`, `dry_run`, and optional `tag_vocabulary_dir`. Settings › Resumen
  edits it. When a Markdown notes directory is configured, the dispatcher
  reads existing tags from it and only accepts tags from that vocabulary;
  the directory contents are not copied to the summary endpoint. Keep any real
  credential there; never put it in the repository or a test fixture.

Models are downloaded at runtime and are never bundled from this repository.
Their licenses and the required attribution are in
[`docs/THIRD_PARTY.md`](docs/THIRD_PARTY.md).

The tested FluidAudio revision remains pinned in `Package.swift` and
`Package.resolved`. The 2026-10-20 dependency review found that tag `v0.17.7`
predates this Ultra-capable pin; the six inspected newer main commits did not
change Ultra recognition. See the
[reviewed upstream comparison](https://github.com/FluidInference/FluidAudio/compare/bd11ac8da17a944a7291a2c76e9a172eb275f629...61d41b3ca04833d1cb80632c82ba401f117a01ef).
An apparently newer tag is not a reason to discard the tested model revision.

## Summaries

The app installer does not start a model server or install this scheduler.
Before running the dispatcher or its installer, review `summary.json` and
confirm where the endpoint actually sends requests. Summary requests contain
the meeting title/date, transcript, notes and any configured tag names; a
remote endpoint receives that text, but not raw audio. Optional post-summary
hooks can also send summary/notes to another service. A loopback gateway alone
does not guarantee its upstream provider is local. Do not enable the scheduler
until that data flow and both audio-retention settings are acceptable.

The canonical summary implementation is the Python dispatcher in the nested
`tools/summary/` directory. The optional per-user launchd agent is
`ai.hermes.meetcapture-summary` and only schedules that dispatcher. Its
installer refuses to proceed if the legacy plist or a loaded
`com.maatwork.meetcapture-summary` agent exists; migrating that live service is
a separate operational action. It does not unload or kill the legacy service,
and it does not update an existing host-level legacy parent binary:

```bash
tools/summary/install-summary-agent.sh
python3 tools/summary/meetcapture_summary_dispatcher.py --once
python3 tools/summary/meetcapture_summary_dispatcher.py --retry-failed
```

See [`tools/summary/README.md`](tools/summary/README.md) for the handoff
states and retry behavior. The retired `com.maatwork.meetcapture.daemon`
launchd service is not part of the current architecture and must not be
re-enabled.


## Build without installing

```bash
./build.sh --staging-dir /tmp/meetcapture-stage
codesign --verify --deep --strict /tmp/meetcapture-stage/MeetCapture.app
```

Local builds are ad-hoc signed by default. Developer ID signing and
notarization are separate, unprovisioned distribution steps; see
[`RELEASING.md`](RELEASING.md). Neither is required for this source-build path.

## Tests and evidence boundaries

```bash
swift test
MEETCAPTURE_APP=/tmp/meetcapture-stage/MeetCapture.app qa/app-smoke-test.sh
python3 tools/summary/test_dispatcher.py
python3 tools/summary/test_real_summary_check.py
scripts/version.sh --check
```

`swift test` covers pure policies, contracts, stores, and process fixtures in
temporary locations. The two summary tests cover dispatcher lifecycle and the
offline content gate with temporary fixtures; they do not call the configured
gateway. The smoke check verifies the selected bundle, signing, bundled
resources, a render, and normal app launch from that exact binary. Version consistency is checked
separately by `scripts/version.sh --check`.

`qa/app-smoke-test.sh` verifies the selected bundle, signing, bundled
resources, a synthetic popover render and process liveness when LaunchServices
starts the native AppKit app. Its guarded `/tmp` launch probe checks the
status button, opening on launch, click to close, and Finder reopen. On macOS
26, run it with `MEETCAPTURE_REQUIRE_HOSTED_ICON=1` while other MeetCapture
instances are closed: the probe then requires a new on-screen Control Center
window aligned with its status button. A plain `isVisible` value does not
establish this, and the geometric check does not cover every display or Space.
The render uses
`PopoverSnapshot` and synthetic `UIFixtureState`; the
probe skips operational startup, permissions, capture, meeting writes and the
summary dispatcher.

`qa/visual-test.sh --headless` has the same fixture boundary. Its interactive
mode is a screenshot check of the normal popover and is visual evidence only.
`qa/capture-selftest.sh` is the real app wrapper for
`import` and `capture`, while the `ui` mode is launched from the separate QA
bundle and exercised by CUA. The real `ui` mode below replaces the
`PopoverSnapshot` fixture for functional UI evidence; snapshots remain an
appearance check only.

The import/capture wrapper takes the original reference text with
`--reference`, checks every reported record and the latest report text against
that reference, and uses `MEETCAPTURE_MAX_WER=0.15` by default (`--max-wer`
overrides it). For `capture`, the wrapper computes the recorded duration from
the returned PCM and its format sidecar, independently of the input WAV. It
keeps the disposable output directory so the report and artifacts can be
inspected after the run.

### Real pipeline check contract

The real pipeline and UI harness share one opt-in interface. The QA wrapper
supplies the CLI for `import` and `capture`; the `ui` mode is driven from the
separate QA bundle with CUA. The interface is:

- `MEETCAPTURE_REAL_CHECK=import|capture|ui` selects the check before normal
  startup. The selected check omits automatic operations and calendar
  detection. `import` and `capture` exit after their pipeline; `ui` stays open
  for manual interaction until the user presses the Quit button.
- `MEETCAPTURE_TEST_OUTPUT_DIR` is mandatory and must point to a new temporary
  directory that is completely empty. The harness rejects any existing entry,
  not only an existing database or report. All generated meeting files, SQLite
  state, reports, and test artifacts stay there.
- `MEETCAPTURE_CHECK_INPUT` is the input WAV. The capture case feeds that
  known WAV through `afplay`; the import case uses it as the source for the
  import flow.
- `MEETCAPTURE_CHECK_REPORT` is a JSON report path inside
  `MEETCAPTURE_TEST_OUTPUT_DIR`.
- `MEETCAPTURE_CHECK_MIC_ONLY=1` opts the `capture` case into microphone-only
  mixing and makes the report carry `micOnly:true`; its default is `false`, so
  the normal contract remains microphone plus system audio.
- The import case exercises two imports and one re-transcription through real
  AppState, SQLite, and `.pending` publication.
- The capture case exercises AppState, AV/Core Audio, `afplay`, a real PCM
  recording with its format sidecar, the per-channel WAV split, and Parakeet
  itself. The models must already be downloaded or the first run needs
  network. Diarization defaults off; `MEETCAPTURE_CHECK_DIARIZE=1` enables it
  on macOS 15 or newer and the report lists the speakers. If microphone
  permission blocks the run, classify it as exit `77`, not a real-call result.
- The `ui` case opens `PopoverContent` with real `AppState`, real engines,
  isolated history, and volatile settings, with `allowsSettings:false` so
  `SettingsView` cannot read or write normal preferences. CUA exercises the
  known-WAV `NSOpenPanel` import, re-transcription, search matches and
  non-matches, and error recovery, then closes through Quit. It does not enter
  Settings or normal startup. The required report path guards the fresh run;
  the manual verifier must save `ui-evidence.json` under the output directory.
  The app does not auto-report or emit a pipeline PASS.
- Exit `0` means the requested pipeline completed. Exit `77` means a required
  prerequisite blocked the check. Exit `1` means the pipeline failed. The
  import/capture wrapper additionally validates the WER/reference result; an
  app exit of `0` alone is not a WER pass. UI evidence is decided by the
  separate manual review and never by a counter in the report.

The real UI run uses a separate bundle QA identifier and CUA interaction. It
supersedes the synthetic `UIFixtureState` for functional controls and manual
import, while `PopoverSnapshot` remains the appearance-only path.

`qa/capture-selftest.sh` supplies the reproducible CLI for `import` and
`capture`, including reference/WER validation. The `ui` mode uses the same
environment guard from the separate QA bundle and CUA driver. No result or
PASS is inferred from fixture counts; the local evidence and unresolved limits
are recorded in `CHANGELOG.md`. The legacy duration-based self-test is not a
substitute because an error must not become a successful check.

A real transcription that produces no segments is exit `1`; it publishes no
`.pending` handoff and retains its input audio for diagnosis or retry.

See [`qa/README.md`](qa/README.md) for the current check matrix and
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the data-flow contracts.

## Known recognition limits

7.1.0 changes process isolation, silence handling and review markers; it does
not retrain the recognizer or establish a word-error-rate improvement. The
known exact-word failure `pongo` → `puego` remains in the public 91-second
Spanish reference check. `[?]` misses most errors and cannot flag deleted
words. No ≥60-minute retained real-meeting benchmark is available for this
release; read/broadcast development audio is not a substitute. Review names,
numbers and important wording against retained audio before using a
transcript or generated summary as a record.

## Troubleshooting

1. **No menu-bar icon.** Open System Settings › Menu Bar and check that
   MeetCapture is enabled under “Allow in the Menu Bar.” If you use multiple
   displays, check the menu bar on the active display too. Quit MeetCapture
   before reinstalling with `./install.sh`; the installer refuses to replace
   a running bundle. On macOS 26, run the strict hosted-icon smoke check above
   to separate an on-screen item from an AppKit-only proxy.
2. **No transcript on the first meeting.** The speech models download at
   install or on first use; a failed download keeps the audio. Check the network: recent
   recordings are retried at the next launch, older ones with "Transcribir".
3. **Everyone on the call is one `Participante`.** Enable "Identificar
   hablantes" in Settings › ASR. Diarization is skipped on macOS 14.
4. **A handoff remains in retry or failed state.** Inspect the endpoint in
   `~/.meetcapture/summary.json` and the private summary log; use
   `--retry-failed` only after fixing the underlying cause.
5. **The left channel is silent.** Grant Screen and System Audio Recording in
   System Settings › Privacy and restart the app; the process tap requires it.
   A meeting whose system channel stayed silent is transcribed from the
   microphone alone.

For installation or app issues, use
[GitHub Issues](https://github.com/Gigisanta/MeetCapture/issues) with the release
tag/commit, macOS version, `uname -m`, `swift --version`, the failed command
and its exact error. For runtime errors, Console can filter the app's unified
logs by subsystem `com.maatwork.meetcapture`; summary logs are at
`~/meetings/.logs/summary.log`. Review and redact logs before sharing. Do not
attach audio, private transcripts, the database, configuration files or API
keys. Include only a consented, non-sensitive reproduction if one is needed.

## License

MIT. See `LICENSE`.
