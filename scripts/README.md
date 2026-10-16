# scripts/

These scripts are either bundled runtime helpers or setup helpers. They are
not the QA harness; checks that need a built app, fixtures, or a human display
live in `qa/`.

## Bundled runtime helpers

`build.sh` copies exactly these three files into the app bundle:

| Script | Caller | Contract |
| --- | --- | --- |
| `meetcapture_stream_asr.py` | `LiveASRService` while recording | Reads 16 kHz mono Int16 PCM from stdin and writes JSONL `ready`, `partial`, `final`, `error`, and `done` events. `--model` selects `zipformer-es` or `zipformer-en`. |
| `transcribe_sherpa.py` | `TranscriptionJob` for the sherpa whole-file engine | `--audio <wav> --out <json> [--model <id>]`; writes an object with a `segments` list. |
| `speaker_diarize.py` | `TranscriptionJob` after transcription | `--audio <wav> --segments <json> --out <json>`; reads the wrapped `segments` payload and writes segments with optional speaker labels. |

The sherpa helpers need a Python interpreter that can import `sherpa_onnx`
and the matching models. Whisper whole-file transcription uses the bundled or
Homebrew `whisper-cli` and does not require these Python scripts.

For scripts, `ToolchainResolver` checks Settings › ASR, `config.json`,
`$MEETCAPTURE_SCRIPTS_DIR`, and then `Contents/Resources/scripts` in the
bundle. For Python, it checks Settings › ASR, `config.json`,
`$MEETCAPTURE_PYTHON`, `~/.meetcapture/venv/bin/python3`, and executable
`python3` candidates on `PATH`. Automatic candidates are validated with
`import sherpa_onnx`; an explicit configured path remains visible for
diagnostics even when validation fails.

## Setup helpers

| Script | Purpose |
| --- | --- |
| `setup-venv.sh` | Creates `~/.meetcapture/venv` from `requirements.txt` and prints the interpreter path. |
| `fetch-models.sh` | Downloads Whisper, sherpa, and diarization models into the per-user model directory. |
| `version.sh` | Prints the version from `Resources/Info.plist`; `--check` rejects other version literals in tracked release files. |
| `deploy-site.sh` | Publishes `site/` to Vercel for maintainers who have separately authorized that external action. |

The canonical summary implementation is under `tools/summary/`, not an old
binary in this directory. The retired `com.maatwork.meetcapture.daemon`
launchd service is not a runtime dependency and must not be restored.

The legacy duration-based self-test is not a supported QA interface. Real
import and capture verification uses the `MEETCAPTURE_REAL_CHECK` contract documented in
[`qa/README.md`](../qa/README.md); its wrapper also owns the WER/reference
check and its temporary output directory. The wrapper compares all reported
records with the original `--reference` text, defaults `MEETCAPTURE_MAX_WER` to
`0.15` (`--max-wer` overrides it), and checks capture duration from the
captured PCM plus format sidecar. Its CLI remains `--app`, `--mode`, `--input`,
`--reference`, and `--output`, with the existing optional `--max-wer` and
`--required-words` arguments. For the capture diagnostic, the inherited
`MEETCAPTURE_CHECK_MIC_ONLY=1` opt-in selects microphone-only mixing and the
report carries `micOnly:true`; the default remains `false`.

The separate `qa/benchmark-asr.sh` command defaults to `ENGINE=both` and
`MAX_WER=0.15`. It creates and retains a unique `benchmark.*` directory below
`TMP`; a missing requested engine or an over-limit WER fails the benchmark.
