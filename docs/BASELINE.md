# 7.1.0 release baseline

This baseline freezes process isolation, recovery and review-marker behavior.
It does **not** establish better speech-recognition accuracy.
The machine-readable measurements, input hashes, development-block identities
and acceptance results are in [`qa/baselines/7.1.0.json`](../qa/baselines/7.1.0.json).

## Measurement conditions

Measured on 2026-10-21: Apple M2 Max / Mac14,5, 64 GiB RAM, macOS 26.6.2,
Swift 6.4 and macOS SDK 27.0. This is not a native macOS 14.4 runtime test.
The release requires Swift tools 6.0+; the GitHub Actions matrix separately
builds and tests on macOS 14 and 15.

Both arms used FluidAudio `bd11ac8da17a944a7291a2c76e9a172eb275f629`,
Parakeet TDT 0.6B Ultra, Spanish, no aliases and no diarization. Models were
prepared before execution; network access was denied during recognition.
Filesystem/Core ML caches were not controlled or claimed cold. Requested
CPU/Neural Engine placement is not a measurement of actual device execution.

The input was the 91.4138125-second synthetic Spanish corpus produced by
`qa/gen_test_corpus.sh`, not a recorded meeting. Each arm performed two imports
and one re-transcription through actual AppState, SQLite and durable handoffs.
The 7.0.2 comparison adds only the observation patch linked below, not an ASR
change. The recorded binary hashes identify these measurements; rebuilds with
a different compiler, path or signature need not be byte-identical.

## Main-process physical footprint

Physical footprint is distinct from resident size and from a child's peak RSS.

| Observation | 7.0.2, MiB | 7.1.0, MiB |
|---|---:|---:|
| Start | 12.81 | 12.81 |
| After import 1 | 670.97 | 16.56 |
| After import 2 | 851.17 | 16.69 |
| After re-transcription | 901.52 | 16.64 |
| Five seconds idle | 901.52 | 19.49 |

The candidate grew by at most 6.67 MiB, within the predeclared 50 MiB limit.
Its helper's peak RSS was 761.81 MiB: the model working set moved to an exiting
child; it did not disappear. An earlier 7.0.2 run recovered to 26.56 MiB after
five idle seconds. Variable cleanup timing and high RSS do not establish a leak.
Do not add independently sampled main footprint and child peak RSS into a
claimed simultaneous total.

The largest added job interval was 1.053 seconds, within the predeclared
baseline-plus-two-seconds limit. Intervals come from successive app observation
timestamps and include import/serialization work; they are not isolated decoder
time. All three transcript bodies matched 7.0.2 after removing `[?]` markers.

## Accuracy and confidence boundaries

Both reference-wrapper runs exited **1**: the unchanged essential word `pongo`
was recognized as `puego`. Pipeline completion, persisted history and intact
handoffs did not turn that into a reference-acceptance pass. A direct SDK check
also produced `puego` with Ultra, before MeetCapture's timing adapter. The v3
alternative produced `puedo`, also wrong; it was not adopted. That bounded
single-fixture diagnostic is not an overall model-quality comparison.

The earlier frozen development study covered seven public read/media blocks,
4387.33 seconds and 9907 reference words: 455 substitutions, 221 deletions and
142 insertions, WER 8.2568%. These are **historical development-study results**,
not a new whole-corpus 7.1.0 run, independent-meeting validation or a WER gain.
Sources: [OpenSLR61](https://www.openslr.org/61/) (Argentinian read speech,
CC BY-SA 4.0) and [MediaSpeech/OpenSLR108](https://www.openslr.org/108/)
(Spanish media clips, CC BY 4.0). Published references were frozen before
recognition; reference errors and unknown speaker/session overlap remain possible.
Audio and published reference text are not redistributed in this repository.

The minimum-token-confidence threshold `<0.50` was selected on those development
blocks: 88/9811 words marked, 45 true positives, precision 51.14%, recall 7.67%.
Per-source precision was 7.14% on OpenSLR61 and 59.46% on MediaSpeech. Most errors
remain unmarked and deleted words cannot be marked. SDK CLI JSON averages token
confidence per word; it was not substituted for the app's minimum-token rule.
The holdout was not recognized or scored.

No retained ≥60-minute real-meeting benchmark is available. Upcoming meetings
are retained for that separate check; generated or concatenated public speech
is not a substitute. Real capture, exact-word acceptance, unit/fixture checks
and production installation are separate evidence categories.

## Reproduce the controlled import

Use a compatible native Apple Silicon toolchain and the pinned release source;
see [installation requirements](../README.md#requirements). On this workstation,
heavy builds and ASR additionally require its local resource guard. That private
operations tool is not a dependency of public installations.

```bash
RUN="$(mktemp -d /tmp/meetcapture-baseline.XXXXXX)"
./build.sh --staging-dir "$RUN/stage"
OUT="$RUN/corpus" qa/gen_test_corpus.sh
shasum -a 256 "$RUN/corpus/corpus.wav" "$RUN/corpus/ref.txt"
qa/capture-selftest.sh \
  --app "$RUN/stage/MeetCapture.app" \
  --mode import \
  --input "$RUN/corpus/corpus.wav" \
  --reference "$RUN/corpus/ref.txt" \
  --output "$RUN/import"
```

The generator needs installed Paulina and Mónica macOS voices by default.
Different OS/voice revisions or `VOICE_A`, `VOICE_B` and `RATE` overrides can
change the waveform: compare hashes before treating the input as identical.
Do not alter the reference, required words, aliases or WER limit to force a
pass. The known fixture may fail the exact-word gate described above. Inspect
`$RUN/import/check-report.json`: `memory.samples`, `children_max_rss_bytes`,
`records`, `status` and the wrapper exit are distinct observations. Preparing
models may require an initial network-enabled run; a later cached run can be
executed with network denied. Neither a download nor a warm run proves offline
behavior on a clean Mac.

For the 7.0.2 memory comparison, build tag `v7.0.2` in a separate checkout after
applying [`7.1.0-base-observer.patch`](../qa/baselines/7.1.0-base-observer.patch).
It adds memory snapshots and the five-second idle observation only. Use the
same WAV/reference, a fresh output directory and the same current wrapper for
both arms. The JSON baseline records that patch's SHA-256 and the measured
binaries. It does not supply or claim a portable full public-corpus rebuild.

Run the source, bundle, native UI and real-capture checks in
[`RELEASING.md`](../RELEASING.md) separately. CI artifacts are not notarized
public downloads, and an installer PID check is not end-to-end capture proof.
Keep any temporary output that contains microphone or meeting content private;
remove only your own disposable artifacts after inspecting the results.
