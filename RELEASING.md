# Releasing

1. Update `CFBundleShortVersionString` and `CFBundleVersion` in
   `Resources/Info.plist` with the same value. Move the `Unreleased` notes in
   `CHANGELOG.md` under the new version and date them.

2. Run the local evidence gate in a disposable staging location:

   ```bash
   scripts/version.sh --check
   swift test
   qa/installer-test.sh
   ./build.sh --staging-dir /tmp/mc-stage
   codesign --verify --deep --strict /tmp/mc-stage/MeetCapture.app
   MEETCAPTURE_APP=/tmp/mc-stage/MeetCapture.app qa/app-smoke-test.sh
   python3 tools/summary/test_dispatcher.py
   python3 tools/summary/test_real_summary_check.py
   ```

   The smoke check verifies the bundle and synthetic UI render, then launches
   the selected AppKit app through LaunchServices and checks process liveness.
   Its guarded `/tmp` probe checks the status button and exercises launch,
   click-to-close and Finder reopen. On macOS 26, quit other MeetCapture
   instances and rerun it with `MEETCAPTURE_REQUIRE_HOSTED_ICON=1`; this also
   requires a new on-screen Control Center window aligned with the button.
   The graphical check below still covers each display and Space in use.
   It does not establish real capture, import, operational AppState, SQLite,
   `.pending`, transcription, or summary behavior. CI also runs shell/Python syntax
   and repository hygiene checks; those checks do not replace the real
   pipeline harness.

   The installer fixture test covers replacement, rollback and refusal to
   replace a running bundle without touching the user's installed app. Quit
   MeetCapture after any recording finishes before a real `./install.sh` run.

   In a graphical session, open the staged bundle and confirm its icon appears
   in the menu bar, with no main window or Dock icon. Click the icon to open the
   controls in the popover; click outside to close it, then click the icon again
   to reopen it. Confirm the app remains available from the menu bar. This is a
   manual UI check, separate from the smoke result.

3. Run the real `import` and `capture` modes through
   `qa/capture-selftest.sh`, and run the real UI mode from the separate QA
   bundle with CUA. Use a new temporary output directory for each run and a
   known WAV. The fixed app contract is:

   ```text
   MEETCAPTURE_REAL_CHECK=import|capture|ui
   MEETCAPTURE_TEST_OUTPUT_DIR=<new empty temporary directory>
   MEETCAPTURE_CHECK_INPUT=<WAV>
   MEETCAPTURE_CHECK_REPORT=<JSON inside TEST_OUTPUT_DIR>
   MEETCAPTURE_CHECK_MIC_ONLY=1  # optional capture branch; default false
   MEETCAPTURE_CHECK_DIARIZE=1   # optional macOS 15+ branch; default false
   ```

   Both modes transcribe with Parakeet. Download the models beforehand (any
   normal transcription does it) or allow network on the first run.

   Set `MEETCAPTURE_CHECK_MIC_ONLY=1` only when checking the microphone-only
   diagnostic branch; the resulting report must say `micOnly:true`. It does
   not establish the normal dual microphone-plus-system capture path.

   The wrapper also needs the original reference text (`--reference`). It
   checks every reported record and the latest report text against that
   reference. `MEETCAPTURE_MAX_WER` defaults to `0.15` and `--max-wer` can
   override it. In `capture`, duration is checked from the recorded PCM and
   its format sidecar independently of the input WAV; the temporary output is
   retained for inspection.

   For the CLI modes, use a new output directory and the original reference:

   ```bash
   MEETCAPTURE_MAX_WER=0.15 \
   MEETCAPTURE_CHECK_REPORT=/tmp/meetcapture-real.run/check-report.json \
   qa/capture-selftest.sh \
     --app /tmp/mc-stage/MeetCapture.app \
     --mode import \
     --input /tmp/known.wav \
     --reference /tmp/known.txt \
     --output /tmp/meetcapture-real.run
   ```

   Repeat with `--mode capture` when the microphone prerequisite is available.

   For `ui`, build the opt-in staging-only QA identity and launch its exact
   executable with a fresh output directory:

   ```bash
   ./build.sh --staging-dir /tmp/mc-qa --qa --sign -
   codesign --verify --deep --strict "/tmp/mc-qa/MeetCapture QA.app"
   codesign -d -r- "/tmp/mc-qa/MeetCapture QA.app"
   QA_OUTPUT="$(mktemp -d /tmp/meetcapture-ui.XXXXXX)"
   env MEETCAPTURE_REAL_CHECK=ui \
     MEETCAPTURE_TEST_OUTPUT_DIR="$QA_OUTPUT" \
     MEETCAPTURE_CHECK_INPUT=/tmp/known.wav \
     MEETCAPTURE_CHECK_REPORT="$QA_OUTPUT/ui-evidence.json" \
     "/tmp/mc-qa/MeetCapture QA.app/Contents/MacOS/MeetCapture" &
   QA_PID=$!
   ```

   This bundle is named `MeetCapture QA`, with identifier
   `com.maatwork.meetcapture.qa` and a matching identifier-only ad-hoc
   designated requirement. `--qa` requires a staging destination and ad-hoc
   signing; `--sign -` overrides any configured signing identity. It edits
   only the staged plist, not `Resources/Info.plist` or user preferences.
   Normal builds retain their production identity, and `install.sh` rejects
   the QA identifier. The installed app may remain running for this UI check.
   Always use the real-check environment: the QA identity by itself does not
   select isolated AppPaths or skip normal startup.

   Wait for `REAL_UI_READY` and the real-pipeline window, then drive it with
   CUA as described below. Keep the output directory empty before launch,
   including logs; the input must be a nonempty 16 kHz mono Int16 WAV. Save
   fresh screenshots and observed actions/results, failures or blockers,
   bundle identity and input/output paths in the manual evidence JSON. After
   work finishes, use this QA window's Quit button, then `wait "$QA_PID"` in
   the launching shell. Confirm the QA process exits and production remains
   available; never quit by the shared executable name. Unregister the
   disposable bundle after quitting:

   ```bash
   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
     -u "/tmp/mc-qa/MeetCapture QA.app"
   ```

   See `qa/README.md` for the QA identity and CUA evidence contract.

   `import` must cover two imports and one re-transcription through real
   AppState, SQLite, and `.pending` publication. `capture` must use AppState,
   AV/Core Audio, `afplay`, a real PCM recording plus format sidecar, convert
   that recording into isolated channel WAVs, and transcribe them with
   Parakeet. Diarization defaults off; opt in with `MEETCAPTURE_CHECK_DIARIZE=1`
   to verify the macOS 15+ speaker-label branch separately. `ui` must open
   `PopoverContent` with real AppState,
   real engines, isolated history, and volatile settings with
   `allowsSettings:false`; CUA exercises known-WAV import through
   `NSOpenPanel`, re-transcription, search matches/non-matches, and error
   recovery, then closes through Quit. Use a separate bundle QA identifier.
   The UI run does not enter Settings or normal startup. The manual verifier
   must save `ui-evidence.json` at the required report path; the app does not
   auto-report or emit PASS. The harness must avoid calendar/automatic
   operations and persistent UserDefaults.

   Treat exit `77` as blocked by a prerequisite and exit `1` as a failure.
   Exit `0` means the selected pipeline completed; the import/capture wrapper
   then validates the report and WER/reference before returning a release
   result. The UI run uses the same required report path for CUA evidence and
   never emits PASS. Use `PopoverSnapshot` only for appearance and the real UI
   run for functionality. Do not reuse the legacy duration-based self-test.

4. Open a pull request and review the actual reports and diffs. The current CI
   matrix builds on macOS 14 and 15 and uploads the staging bundle from macOS
   14. It does not currently prove the real capture/import contract or
   hardware behavior.

5. After merging, tag and publish:

   ```bash
   git tag -a vX.Y.Z -m "MeetCapture X.Y.Z"
   git push origin vX.Y.Z
   gh release create vX.Y.Z --title "MeetCapture X.Y.Z" --notes-file <(sed -n '/^## \[X.Y.Z\]/,/^## \[/p' CHANGELOG.md | sed '$d')
   ```

   The CI artifact is ad-hoc signed. Users on other Macs need a local build,
   or a separately authorized Developer ID signing and notarization flow.

6. Landing changes are published by maintainers with
   `scripts/deploy-site.sh` when `site/` content changed.
