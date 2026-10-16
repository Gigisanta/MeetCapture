# ASR engine evaluation (plan Fase 3a)

`qa/asr_eval.py` picks MeetCapture's transcription engine by data before any
engine is integrated. It scores candidates against hand-checked references cut
from real meetings. The references and every intermediate file stay in a
private directory, `~/HerMaatOS/var/meetcapture-eval` (mode 700, never in git;
override with `MEETCAPTURE_EVAL_DIR`). The repository holds only code and a
synthetic fixture.

## Pieces

| Path | What |
|---|---|
| `qa/asr_eval.py` | cut, bleed gate, engine runs with RTF/RSS/GPU, compose, score, table, selftest |
| `qa/fluid-eval/` | separate SwiftPM package (not an app target): FluidAudio Parakeet ASR ± custom vocabulary, offline diarization |
| `qa/fixtures/asr_eval_synthetic.json` | invented dialogue with hand-computed expected metrics |

Python deps (jiwer, numpy, text2num) live in a venv outside the repo:

```bash
python3 -m venv ~/HerMaatOS/venvs/asr-eval
~/HerMaatOS/venvs/asr-eval/bin/pip install jiwer numpy text2num
~/HerMaatOS/venvs/asr-eval/bin/python qa/asr_eval.py selftest
```

## Workflow

```bash
PY=~/HerMaatOS/venvs/asr-eval/bin/python
E=~/HerMaatOS/var/meetcapture-eval
$PY qa/asr_eval.py cut --pcm capture.pcm --start 240 --dur 600 --out $E/A   # L.wav R.wav mix.wav
$PY qa/asr_eval.py gate --dir $E/A                                          # R_gated_c0.4_d10.0.wav
$PY qa/asr_eval.py vocab                                                  # $E/vocab.txt for Parakeet
(cd qa/fluid-eval && swift build -c release)
GUARD="$HOME/.hermes/hermes-agent/venv/bin/python $HOME/HerMaatOS/bin/system/resource_guard.py run --class gpu-heavy --ram-gib 4 --disk-gib 1 --run-seconds 1800 --"
$GUARD $PY qa/asr_eval.py run --engine whisper-turbo --wav $E/A/L.wav --out $E/runs/A/whisper-turbo__L.json
$PY qa/asr_eval.py compose --L ...__L.json --R ...__Rg.json [--dia dia.json] --out merged.json
$PY qa/asr_eval.py score --ref $E/A/ref.json --hyp merged.json --json score.json
$PY qa/asr_eval.py table $E/scores/*.json
```

Engines: `whisper-medium` (the app today: medium-q5_0, silero VAD, the app's
`domainPrompt` from `~/.meetcapture/config.json`), `whisper-turbo`
(large-v3-turbo-q8_0, same flags), `whisperkit-turbo` (`whisperkit-cli`,
large-v3-v20240930_turbo), `parakeet-v3[-vocab]`, `parakeet-ultra[-vocab]`,
`fluid-diarize`. `whisper-v3` (large-v3-q5_0) exists only to help draft
references; it is not a candidate.

`run` refuses to start while Simón's gateway (`127.0.0.1:8080/admin/gpu_hold`)
has a turn running or waiting, or a hold that is not its parent
resource_guard's, and exits 75 after `--wait` seconds. It records wall time,
RTF (wall / audio, model load included), peak RSS (`/usr/bin/time -l`) and
IOAccelerator GPU utilisation (all clients; the desktop alone keeps it near
50 %, so `gpu_util_idle_before` is recorded too; ANE use is not observable
without sudo).

## Metrics

Text is lowercased, accents and punctuation dropped, acronym dots joined,
numbers turned into digits (text2num; the articles *unos/unas* are protected),
fillers (*eh, mm, ajá…*) removed.

- **WER / CER** on the time-ordered transcript; `wer_certain` ignores errors
  on reference words inside `[? … ?]`.
- **wer_split** (`wer_gio`, `wer_remote`): each side scored against its own
  words. Channel pipelines merge L and R by segment start, and a coarse
  segment spanning several turns lands out of order, which plain WER counts
  twice; the split isolates recognition and bleed from that merge artifact.
  Compare channel pipelines with it and mono pipelines with plain WER.
- A reference speaker ending in `?` (`P2?`) is a guess: counted for WER, left
  out of attribution.
- **keyword_recall**: finance terms (`KEYWORDS` in the script), matched counts
  over reference counts; `keyword_false` counts extra hits.
- **number_recall**: multiset recall of digit tokens.
- **gio_attribution**: of reference words spoken by Gio that the engine
  transcribed, the share labelled Gio. **gio_precision**: the converse.
- **remote_purity**: word-weighted purity of the non-Gio labels (each label
  credited with its majority reference speaker); `remote_coverage` per speaker.
- Speaker pairs come from the WER alignment (equal and substituted words).
  ASR segments are split by the diarization speaker active at each word, with
  word times interpolated, so coarse and fine segmenters are judged alike.

Composed pipelines run channels one after another, so wall time adds up.

## Bleed gate

Gio uses the Mac speakers, so the mic (R) also carries the remote voices.
Per 0.5 s window the gate takes the peak normalized cross-correlation of the
band-passed (200–4000 Hz) mic against the system channel delayed 0–100 ms and
mutes the window when it exceeds `--corr`, the system channel is not silent
(> −55 dBFS), and the mic is not `--dominance-db` louder (double talk).

Defaults (`GATE_CORR` 0.4, `GATE_DOMINANCE_DB` 10) come from two real calls:
bleed windows had NCC p50 ≈ 0.65 and R−L between −7 and +5 dB, so the
planned 0.6 let half of them through (hundreds of duplicated words on Gio's
side); 0.4 mutes them while keeping > 95 % of Gio's words. Re-calibrate with a
corr sweep if the speakers, room or volume change.

## Decision rule (fixed before the runs)

Winner must cut WER ≥ 25 % relative to the baseline. Within 2 points, prefer
the ANE engine (Parakeet, then WhisperKit). Hard floors: Gio attribution
≥ 95 %, remote purity ≥ 85 %, RTF ≤ 0.05, RSS ≤ 1.5 GB. If nothing meets the
floors, report the numbers and stop for Gio's decision.
