# Releasing

## Source-first distribution contract

7.2.0 is distributed as pinned source for a local build. The canonical public
installation instructions are in `README.md`; they must name the published
release tag, not `main`. Do not label a tag or release as available before it
exists on GitHub.

The manifest minimum is Swift tools 6.0 for both MeetCapture and the pinned
FluidAudio dependency. Runtime support starts at Apple Silicon/macOS 14.4,
with diarization on macOS 15+. The build host must also support its chosen
Xcode/Command Line Tools: Apple's Xcode 16–16.2 route needs macOS 14.5+.
Record the actual compiler/SDK and OS used for release evidence; satisfying
a manifest minimum is not proof of a clean-machine install.

Local and CI bundles use ad-hoc signing by default. No Developer ID signing
identity or notarization account has been provisioned for this release.
Do not attach a CI bundle as a supported public binary, advertise a DMG/app
download, call `codesign --verify` a notarization check, or suggest disabling
Gatekeeper/removing quarantine. Source builds remain subject to macOS and
organization security policy. A future binary channel needs a separately
provisioned Developer ID/notarization workflow and verification on another Mac.

Release notes must disclose the optional summary endpoint's text egress,
the source-build prerequisites, permissions, backup/rollback path and known
ASR limits. In particular, 7.2.0 does not retrain the model or establish a WER
improvement, the `pongo` → `puego` reference failure remains, confidence marks
miss most errors, and a retained real-meeting benchmark is still unavailable.
Do not turn historical text-only corrections or unit-test counts into
accuracy claims.

## Release checklist

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

   Producer-v3 evidence and ancestry checks also stay entirely in temporary
   AppPaths. Never reimport production recordings into `~/meetings` as QA:
   a live consumer may create external work for every new id. Intentional
   production improvements require explicit authorization and a verified
   `supersedesMeetingId` carried through `.done`.

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

5. After the reviewed changes have been merged and the evidence above is
   accepted, tag the exact reviewed commit and publish its source release.
   Check that the version metadata, changelog, release title and README
   installation tag all agree on `7.2.0` / `v7.2.0`. Tagging and publication
   are production actions, separate from building a staged app:

   ```bash
   git tag -a v7.2.0 <reviewed-merge-commit> -m "MeetCapture 7.2.0"
   git push origin v7.2.0
   gh release create v7.2.0 --verify-tag --title "MeetCapture 7.2.0" --notes-file <reviewed-release-notes>
   ```

   Review the release notes before sending them; include only measured
   evidence, remaining failures and installation instructions. Do not upload
   private audio, transcripts, databases, configuration or local evidence
   containing meeting data. GitHub's generated source archives are source,
   not installed app bundles. Keep the source tag available for reproducible
   cloning; do not silently move a published release tag to a later commit.

   On this Mac, finish recordings and transcription, quit the exact installed
   bundle, back up data and run `./install.sh` from the reviewed checkout.
   Preserve its zipped app backup and any recovery paths it reports. Verify
   permissions and a consented capture after installation; installer liveness
   alone does not prove the app works. The installer does not migrate or
   start the optional summary agent. See README for update/rollback details.

6. The public product page is maintained in
   [`Gigisanta/maatwork-landing`](https://github.com/Gigisanta/maatwork-landing)
   at `https://maat.work/casos/meetcapture`; `meetcapture.maat.work` redirects
   there. This app repository does not deploy a second website. Verify that
   the linked page and source-first setup instructions describe the released
   behavior. Publish page changes through its owning repository and checks.
