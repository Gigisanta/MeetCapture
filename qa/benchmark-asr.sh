#!/bin/bash
# benchmark-asr.sh — WER/RTF over a real speech corpus.
#
# Each engine runs in a unique directory. A nonzero exit, missing/empty
# transcript, malformed JSON or stale output is a benchmark failure.
set -euo pipefail

CORPUS=$(printenv CORPUS 2>/dev/null || true)
REF=$(printenv REF 2>/dev/null || true)
OUTPUT_ROOT=$(printenv TMP 2>/dev/null || true)
VENV_PY=$(printenv VENV_PY 2>/dev/null || true)
TRANSCRIBE=$(printenv TRANSCRIBE 2>/dev/null || true)
WHISPER_MODEL=$(printenv WHISPER_MODEL 2>/dev/null || true)
WHISPER_CLI=$(printenv WHISPER_CLI 2>/dev/null || true)
ENGINE=$(printenv ENGINE 2>/dev/null || true)
MAX_WER=${MAX_WER:-0.15}
[ -n "$CORPUS" ] || CORPUS=/tmp/meetcapture_corpus/corpus.wav
[ -n "$REF" ] || REF=/tmp/meetcapture_corpus/ref.txt
[ -n "$OUTPUT_ROOT" ] || OUTPUT_ROOT=/tmp/meetcapture_corpus
[ -n "$VENV_PY" ] || VENV_PY="$HOME/.meetcapture/venv/bin/python3"
[ -n "$WHISPER_MODEL" ] || WHISPER_MODEL="$HOME/.whisper/models/ggml-medium-q5_0.bin"
[ -n "$ENGINE" ] || ENGINE=both
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -n "$TRANSCRIBE" ] || TRANSCRIBE="$ROOT/scripts/transcribe_sherpa.py"

die() {
    printf 'benchmark-asr: %s\n' "$1" >&2
    exit 1
}

[ -f "$CORPUS" ] || die "falta $CORPUS: ejecutar qa/gen_test_corpus.sh"
[ -f "$REF" ] || die "falta $REF"
[ -x "$VENV_PY" ] || die "falta $VENV_PY"
[ "$ENGINE" = both ] || [ "$ENGINE" = sherpa ] || [ "$ENGINE" = whisper ] || die "ENGINE inválido: $ENGINE"
if [ "$ENGINE" != whisper ]; then
    [ -f "$TRANSCRIBE" ] || die "falta $TRANSCRIBE"
fi
mkdir -p "$OUTPUT_ROOT"

if ! DUR=$("$VENV_PY" - "$CORPUS" <<'PY'
import sys
import wave
try:
    with wave.open(sys.argv[1], 'rb') as source:
        spec = (source.getnchannels(), source.getsampwidth(), source.getframerate())
        frames = source.getnframes()
except (EOFError, OSError, wave.Error) as exc:
    print(f'invalid corpus WAV: {exc}', file=sys.stderr)
    raise SystemExit(1)
if spec != (1, 2, 16000) or frames <= 0:
    print('corpus must be nonempty 16 kHz mono Int16 WAV', file=sys.stderr)
    raise SystemExit(1)
print(f'{frames / spec[2]:.6f}')
PY
); then
    die "corpus WAV inválido: $CORPUS"
fi

RUN_DIR=$(mktemp -d "$OUTPUT_ROOT/benchmark.XXXXXX")
printf 'Evidence: %s\n' "$RUN_DIR"

wer() {
    "$VENV_PY" - "$1" "$2" "$MAX_WER" <<'PY'
import math
import re
import sys
from pathlib import Path

def tokens(text):
    return re.findall(r'[^\W_]+', text.casefold(), flags=re.UNICODE)

try:
    hypothesis_text = Path(sys.argv[1]).read_text(encoding='utf-8')
    reference_lines = Path(sys.argv[2]).read_text(encoding='utf-8').splitlines()
except OSError as exc:
    print(f'cannot read WER input: {exc}', file=sys.stderr)
    raise SystemExit(1)

reference_lines = [line.split('|', 1)[-1] for line in reference_lines
                   if line.strip() and not line.lstrip().startswith('#')]
hypothesis = tokens(hypothesis_text)
reference = tokens(' '.join(reference_lines))
if not reference:
    print('reference transcript is empty', file=sys.stderr)
    raise SystemExit(1)
if not hypothesis:
    print('engine transcript is empty', file=sys.stderr)
    raise SystemExit(1)

previous = list(range(len(reference) + 1))
for i, word in enumerate(hypothesis, 1):
    current = [i] + [0] * len(reference)
    for j, expected in enumerate(reference, 1):
        current[j] = min(previous[j] + 1, current[j - 1] + 1,
                          previous[j - 1] + (word != expected))
    previous = current
value = previous[-1] / len(reference)
limit = float(sys.argv[3])
if not math.isfinite(limit) or not 0 <= limit <= 1:
    raise SystemExit('MAX_WER must be a fraction from 0 to 1')
if value > limit:
    print(f'WER {value:.4f} exceeds limit {limit:.4f}', file=sys.stderr)
    raise SystemExit(1)
print(f'{value:.4f}')
PY
}

run_timed() {
    local label="$1"
    shift
    local started finished rc
    started=$("$VENV_PY" -c 'import time; print(time.time())')
    if "$@" >"$RUN_DIR/$label.stdout" 2>"$RUN_DIR/$label.stderr"; then
        rc=0
    else
        rc=$?
    fi
    finished=$("$VENV_PY" -c 'import time; print(time.time())')
    ELAPSED=$("$VENV_PY" -c "print('{:.6f}'.format($finished - $started))")
    if [ "$rc" -ne 0 ]; then
        printf '%s failed with exit %s\n' "$label" "$rc" >&2
        [ ! -s "$RUN_DIR/$label.stderr" ] || sed -n '1,8p' "$RUN_DIR/$label.stderr" >&2
        return "$rc"
    fi
}

extract_sherpa_text() {
    "$VENV_PY" - "$1" "$2" <<'PY'
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding='utf-8'))
except (OSError, ValueError) as exc:
    print(f'invalid sherpa JSON: {exc}', file=sys.stderr)
    raise SystemExit(1)
segments = payload.get('segments') if isinstance(payload, dict) else None
if not isinstance(segments, list):
    print('sherpa JSON has no segments list', file=sys.stderr)
    raise SystemExit(1)
texts = []
for index, segment in enumerate(segments):
    if not isinstance(segment, dict) or not isinstance(segment.get('text'), str):
        print(f'invalid sherpa segment {index}', file=sys.stderr)
        raise SystemExit(1)
    if segment['text'].strip():
        texts.append(segment['text'].strip())
if not texts:
    print('sherpa transcript is empty', file=sys.stderr)
    raise SystemExit(1)
Path(sys.argv[2]).write_text('\n'.join(texts) + '\n', encoding='utf-8')
PY
}

printf '%-28s %-34s %7s %8s\n' engine model WER% RTF
printf '%s\n' '----------------------------------------------------------------------'

if [ "$ENGINE" != whisper ]; then
    SHERPA_JSON="$RUN_DIR/sherpa_segments.json"
    SHERPA_TXT="$RUN_DIR/sherpa_hyp.txt"
    rm -f "$SHERPA_JSON" "$SHERPA_TXT"
    if ! run_timed sherpa "$VENV_PY" "$TRANSCRIBE" \
        --audio "$CORPUS" --language es --out "$SHERPA_JSON"; then
        die 'sherpa falló'
    fi
    [ -s "$SHERPA_JSON" ] || die 'sherpa no creó un JSON nuevo'
    if ! extract_sherpa_text "$SHERPA_JSON" "$SHERPA_TXT"; then
        die 'sherpa produjo un transcript inválido'
    fi
    if ! SHERPA_WER=$(wer "$SHERPA_TXT" "$REF"); then
        die 'no se pudo calcular WER de sherpa'
    fi
    SHERPA_RTF=$("$VENV_PY" -c "print('{:.2f}'.format($ELAPSED / $DUR))")
    SHERPA_PERCENT=$("$VENV_PY" -c "print(100.0 * $SHERPA_WER)")
    printf '%-28s %-34s %6.2f%% %7s\n' \
        'sherpa-onnx (streaming+VAD)' zipformer-es-kroko "$SHERPA_PERCENT" "$SHERPA_RTF"
fi

[ -n "$WHISPER_CLI" ] || WHISPER_CLI=$(command -v whisper-cli 2>/dev/null || true)
if [ "$ENGINE" != sherpa ] && [ -n "$WHISPER_CLI" ] && [ -x "$WHISPER_CLI" ] && [ -f "$WHISPER_MODEL" ]; then
    WHISPER_PREFIX="$RUN_DIR/whisper"
    WHISPER_TXT="$WHISPER_PREFIX.txt"
    rm -f "$WHISPER_TXT" "$WHISPER_PREFIX.json"
    if ! run_timed whisper "$WHISPER_CLI" -m "$WHISPER_MODEL" -f "$CORPUS" \
        -l es -otxt -nt -of "$WHISPER_PREFIX" -t 4 --no-gpu; then
        die 'whisper-cli falló'
    fi
    [ -s "$WHISPER_TXT" ] || die 'whisper-cli no creó un transcript nuevo'
    if ! WHISPER_WER=$(wer "$WHISPER_TXT" "$REF"); then
        die 'no se pudo calcular WER de whisper'
    fi
    WHISPER_RTF=$("$VENV_PY" -c "print('{:.2f}'.format($ELAPSED / $DUR))")
    WHISPER_PERCENT=$("$VENV_PY" -c "print(100.0 * $WHISPER_WER)")
    printf '%-28s %-34s %6.2f%% %7s\n' \
        'whisper.cpp (offline)' "$(basename "$WHISPER_MODEL")" \
        "$WHISPER_PERCENT" "$WHISPER_RTF"
elif [ "$ENGINE" != sherpa ]; then
    die 'el engine solicitado requiere whisper-cli ejecutable y un modelo local'
else
    : # Only sherpa was requested.
fi

printf '\nduración del corpus: %ss\n' "$DUR"
