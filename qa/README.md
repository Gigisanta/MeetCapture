# qa/

QA is split by evidence type. A synthetic UI fixture, an isolated engine
check, a real UI run, and a real app pipeline check answer different
questions; none of them can stand in for the others or justify calling the
whole system healthy.

| Script | Evidence | Needs | Does not prove |
| --- | --- | --- | --- |
| `installer-test.sh` | Disposable installer fixtures for clean install, replacement, rollback and refusal to replace a running bundle. | macOS shell tools and a temporary directory | Real capture, ASR or the user's production installation. |
| `app-smoke-test.sh` | The selected bundle's files, signature, version, bundled resources, isolated render, and process liveness. Its guarded `/tmp` LaunchServices probe checks status-button, popover click and Finder reopen. With `MEETCAPTURE_REQUIRE_HOSTED_ICON=1`, it additionally requires a new on-screen Control Center window aligned with the status button on macOS 26. | a built `.app` and a graphical macOS session; for strict mode, close any other MeetCapture instance first | Visibility on every display or Space, operational startup, permissions, capture, transcription, SQLite, `.pending`, or summary delivery. The probe constructs `AppState` but skips services. |
| `capture-selftest.sh` | The QA wrapper for the real `import` and `capture` contract below. | a built `.app`, disposable output directory, WAV and platform prerequisites | A WER result unless the wrapper's reference check also passes; UI and diarization are separate checks. |
| `gen_test_corpus.sh` | A disposable two-speaker WAV and reference text generated with macOS voices. | macOS voices and `afconvert` | A real app recording or a production microphone path. |
| `visual-test.sh` | A screenshot of the normal popover, or a headless synthetic render with `--headless`. | a built `.app`; Accessibility for interactive mode | Functional state transitions. The headless path uses `PopoverSnapshot` and synthetic state. |

## Checks that are currently reproducible

```bash
swift test
./build.sh --staging-dir /tmp/mc-stage
MEETCAPTURE_APP=/tmp/mc-stage/MeetCapture.app qa/app-smoke-test.sh
python3 tools/summary/test_dispatcher.py
scripts/version.sh --check
```

These commands use build or test fixtures and are safe to point at temporary
paths. The smoke render requires an existing isolated output directory
internally; its second probe opens the real AppKit menu-bar app through
LaunchServices and checks that it remains running. In the guarded `/tmp`
fixture, the app requires `NSStatusItem.isVisible` and an attached button and
checks that launch opens the popover, clicking closes it, and the Finder reopen
handler opens it again.
When checking a disposable `/tmp` bundle, the smoke test unregisters that
copy from LaunchServices on exit so it cannot shadow the installed app by name.
It also stops processes opened by that test bundle, including when a probe
fails before it can identify the new process.
On macOS 26, run `MEETCAPTURE_REQUIRE_HOSTED_ICON=1` with no other MeetCapture
instance open to require an actual on-screen Control Center host window. A
plain `NSStatusItem.isVisible` value can be true for a hidden item. This
geometric check still cannot prove visibility on every connected display or
Space and skips operational startup and recording.

For a visual-only headless render, the script supplies synthetic state through
`PopoverSnapshot`:

```bash
MEETCAPTURE_APP=/tmp/mc-stage/MeetCapture.app \
  MEETCAPTURE_SHOT_DIR=/tmp/mc-shots qa/visual-test.sh --headless
```

The interactive fixture is also UI-only. `MEETCAPTURE_UI_TEST=1` opens a
window titled `MeetCapture · UI fixture`; its `UIFixtureState` does not create
`AppState`, request permissions, access Core Audio, write SQLite, publish a
`.pending` file, or call the summary dispatcher. A successful fixture render
or interaction is therefore not functional evidence. Use real-check `ui` for
controls and manual import; use `PopoverSnapshot` only for appearance.

## Real pipeline check contract

The real app harness is selected before normal startup and exits after the
requested check. Its environment contract is:

```text
MEETCAPTURE_REAL_CHECK=import|capture|ui
MEETCAPTURE_TEST_OUTPUT_DIR=<new temporary directory; required>
MEETCAPTURE_CHECK_INPUT=<known WAV; required>
MEETCAPTURE_CHECK_REPORT=<JSON path inside TEST_OUTPUT_DIR; required>
MEETCAPTURE_CHECK_MIC_ONLY=1  # optional capture mode; default false
MEETCAPTURE_CHECK_DIARIZE=1   # optional diarization (macOS 15+); default false
```

The wrapper CLI for `import` and `capture` is:

```bash
MEETCAPTURE_CHECK_REPORT=/tmp/meetcapture-real.run/check-report.json \
  qa/capture-selftest.sh \
    --app /tmp/mc-stage/MeetCapture.app \
    --mode import \
    --input /tmp/known.wav \
    --reference /tmp/known.txt \
    --output /tmp/meetcapture-real.run
```

Use a new empty output directory for every invocation. The `ui` mode uses the
same environment contract when the separate QA bundle is launched and CUA
drives `PopoverContent`; it is not a `capture-selftest.sh --mode` result. The
variables and acceptance behavior are fixed:

- `import` performs two imports and one re-transcription through real
  AppState, SQLite, and `.pending` publication. The input is the known WAV.
- `capture` runs AppState with AV/Core Audio, plays the known WAV through
  `afplay`, records raw PCM plus its format sidecar, converts that capture to
  isolated channel WAVs, and transcribes them with Parakeet; the models must
  be downloaded already or the first run needs network. Setting
  `MEETCAPTURE_CHECK_MIC_ONLY=1` selects the microphone-only branch and the
  report records `micOnly: true`; the default is `false`, so the normal
  contract remains microphone plus system audio. Diarization is off unless
  `MEETCAPTURE_CHECK_DIARIZE=1`; the report lists the `speakers` found. Missing
  microphone permission is exit `77`, not evidence from a real call.
- `ui` opens `PopoverContent` with real `AppState`, real engines, isolated
  history, and volatile settings. Automatic operations are disabled. CUA
  exercises the controls and a real manual import of the known WAV; the run
  ends through the Quit button. It uses a separate bundle QA identifier. The
  manual verifier saves the UI evidence JSON at the required report path; no
  CUA driver is assumed, and the app never generates that evidence or emits
  PASS.
- No case enters calendar detection or ordinary startup, and no persistent
  UserDefaults are used. Every generated file and database stays below
  `MEETCAPTURE_TEST_OUTPUT_DIR`.
- The report is JSON and must be written inside the output directory.
- For `import` and `capture`, app exit `0` means the selected pipeline
  completed, `77` means a prerequisite blocked execution, and `1` means the
  pipeline failed. The wrapper returns success only after its report and
  WER/reference checks; app exit `0` by itself is not a WER pass. `ui` is a
  manual interaction review and never converts a report counter into PASS.

### Building and driving the real QA UI

Build a separate staging-only bundle; the installed production app can stay
running during this check:

```bash
./build.sh --staging-dir /tmp/mc-qa --qa --sign -
codesign --verify --deep --strict "/tmp/mc-qa/MeetCapture QA.app"
codesign -d -r- "/tmp/mc-qa/MeetCapture QA.app"
```

`--qa` requires `--staging` or `--staging-dir` and ad-hoc signing (`--sign -`
also overrides `MEETCAPTURE_SIGN_IDENTITY`). It produces `MeetCapture QA.app`
with display name `MeetCapture QA`, identifier
`com.maatwork.meetcapture.qa`, and the stable ad-hoc designated requirement
`designated => identifier "com.maatwork.meetcapture.qa"`. Only the staged
Info.plist is changed; `Resources/Info.plist` and user preferences are not.
The normal build keeps the production identifier, name, and signing behavior.
The normal installer rejects the QA identifier; never copy this bundle over
the production app.

Launch the exact QA executable with the required environment rather than
opening an app by name (which could target the installed app):

```bash
QA_OUTPUT="$(mktemp -d /tmp/meetcapture-ui.XXXXXX)"
env MEETCAPTURE_REAL_CHECK=ui \
  MEETCAPTURE_TEST_OUTPUT_DIR="$QA_OUTPUT" \
  MEETCAPTURE_CHECK_INPUT=/tmp/known.wav \
  MEETCAPTURE_CHECK_REPORT="$QA_OUTPUT/ui-evidence.json" \
  "/tmp/mc-qa/MeetCapture QA.app/Contents/MacOS/MeetCapture" &
QA_PID=$!
```

The input must be a nonempty 16 kHz mono Int16 WAV. Keep the output directory
empty before launch; save logs outside it until the harness has started.
Wait for `REAL_UI_READY` and the `MeetCapture · Real pipeline` window before
using CUA. The QA identity alone does not isolate data: always supply this
environment, which selects isolated AppPaths and volatile preferences before
normal startup. Do not open the QA bundle without it.

CUA must exercise known-WAV import via the open panel, re-transcription,
search matches/non-matches, and error recovery with the real controls.
Do not enter Settings or grant privacy permissions for this import check.
Save fresh screenshots and observed actions/results, failures or blockers,
the QA bundle identifier, input and output paths in
`$QA_OUTPUT/ui-evidence.json`; this is manual evidence, not an app-generated
PASS. After work finishes, use the QA window's Quit button and then
`wait "$QA_PID"` in the launching shell. Confirm that this QA process exited
and the already-running production app remains available. Do not quit or
kill by the shared `MeetCapture` executable name. Unregister the disposable
bundle after quitting it so LaunchServices does not retain the staging copy:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "/tmp/mc-qa/MeetCapture QA.app"
```

The legacy duration-based self-test path is retired and removed; it must not be
used as a replacement. An error must not be reported as a successful check.
Fixture counts do not establish system health; current local evidence and
pending hardware/ASR limits are recorded in `CHANGELOG.md`.

If real transcription produces no segments, the harness must exit `1`, publish no
`.pending` handoff, and retain the input audio. That state is a failed check,
not a passing counter.
