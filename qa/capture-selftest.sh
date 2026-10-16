#!/bin/bash
# capture-selftest.sh — wrapper for the real MeetCapture acceptance harness.
#
# The app owns import/capture, ASR, SQLite and handoff. This script supplies a
# fresh fixture directory and checks the app report against known text. It
# never synthesizes audio, converts PCM, or invokes an ASR CLI directly.
#
# Usage:
#   qa/capture-selftest.sh --app /tmp/mc-stage/MeetCapture.app \
#     --mode import|capture --input /tmp/known.wav \
#     --reference /tmp/known.txt --output /tmp/meetcapture-real.run
#
# Environment equivalents: MEETCAPTURE_APP, MEETCAPTURE_REAL_CHECK,
# MEETCAPTURE_CHECK_INPUT, MEETCAPTURE_TEST_OUTPUT_DIR,
# MEETCAPTURE_CHECK_REPORT and MEETCAPTURE_REFERENCE.
#
# Exit: 0 passed, 1 failed, 2 invalid invocation/fixture, 77 blocked.

set -euo pipefail

die() {
    printf 'capture-selftest: %s\n' "$1" >&2
    exit 2
}

usage() {
    printf '%s\n' \
        'Usage: capture-selftest.sh --app PATH --mode import|capture --input WAV' \
        '  --reference TXT --output DIR [--max-wer FRACTION] [--required-words WORDS]'
}

APP_PATH=$(printenv MEETCAPTURE_APP 2>/dev/null || true)
MODE=$(printenv MEETCAPTURE_REAL_CHECK 2>/dev/null || true)
INPUT=$(printenv MEETCAPTURE_CHECK_INPUT 2>/dev/null || true)
REFERENCE=$(printenv MEETCAPTURE_REFERENCE 2>/dev/null || true)
OUTPUT=$(printenv MEETCAPTURE_TEST_OUTPUT_DIR 2>/dev/null || true)
REPORT=$(printenv MEETCAPTURE_CHECK_REPORT 2>/dev/null || true)
MAX_WER=$(printenv MEETCAPTURE_MAX_WER 2>/dev/null || true)
REQUIRED_WORDS=$(printenv MEETCAPTURE_REQUIRED_WORDS 2>/dev/null || true)
[ -n "$MAX_WER" ] || MAX_WER=0.15

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) [ "$#" -ge 2 ] || die '--app requiere una ruta'; APP_PATH=$2; shift 2 ;;
        --mode) [ "$#" -ge 2 ] || die '--mode requiere un modo'; MODE=$2; shift 2 ;;
        --input) [ "$#" -ge 2 ] || die '--input requiere un WAV'; INPUT=$2; shift 2 ;;
        --reference) [ "$#" -ge 2 ] || die '--reference requiere un TXT'; REFERENCE=$2; shift 2 ;;
        --output) [ "$#" -ge 2 ] || die '--output requiere un directorio'; OUTPUT=$2; shift 2 ;;
        --max-wer) [ "$#" -ge 2 ] || die '--max-wer requiere una fracción'; MAX_WER=$2; shift 2 ;;
        --required-words) [ "$#" -ge 2 ] || die '--required-words requiere palabras'; REQUIRED_WORDS=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "argumento desconocido: $1" ;;
    esac
done

[ -n "$APP_PATH" ] || die 'falta --app: no se usa una instalación normal'
[ "$MODE" = import ] || [ "$MODE" = capture ] || die 'falta --mode import|capture'
[ -n "$INPUT" ] || die 'falta --input WAV'
[ -n "$REFERENCE" ] || die 'falta --reference TXT'
[ -n "$OUTPUT" ] || die 'falta --output DIR'
case "$APP_PATH" in /*) ;; *) die '--app debe ser absoluto' ;; esac
case "$INPUT" in /*) ;; *) die '--input debe ser absoluto' ;; esac
case "$OUTPUT" in /*) ;; *) die '--output debe ser absoluto' ;; esac
case "$APP_PATH" in /Applications/*|/System/Applications/*|/System/Library/*)
    die '--app apunta a una instalación normal'
    ;;
esac

if [ -d "$APP_PATH" ]; then
    APP_BIN="$APP_PATH/Contents/MacOS/MeetCapture"
else
    APP_BIN="$APP_PATH"
fi
[ -x "$APP_BIN" ] || die "binario no ejecutable: $APP_BIN"
[ -s "$INPUT" ] || die "WAV inexistente o vacío: $INPUT"
[ -r "$REFERENCE" ] || die "referencia inexistente o ilegible: $REFERENCE"
case "$INPUT" in *.wav|*.WAV) ;; *) die '--input debe terminar en .wav' ;; esac

if [ -e "$OUTPUT" ]; then
    [ -d "$OUTPUT" ] || die '--output no es un directorio'
else
    mkdir -p "$OUTPUT"
    chmod 700 "$OUTPUT"
fi
existing=$(find "$OUTPUT" -mindepth 1 -print -quit)
[ -z "$existing" ] || die "--output no está vacío: $OUTPUT"

[ -n "$REPORT" ] || REPORT="$OUTPUT/check-report.json"
case "$REPORT" in /*) ;; *) die 'MEETCAPTURE_CHECK_REPORT debe ser absoluto' ;; esac
REPORT_DIR=$(dirname "$REPORT")
[ -d "$REPORT_DIR" ] || die "directorio del reporte inexistente: $REPORT_DIR"
[ "$REPORT_DIR" = "$OUTPUT" ] || die 'el reporte debe estar dentro de --output'
REPORT="$OUTPUT/$(basename "$REPORT")"
[ ! -e "$REPORT" ] || die 'el reporte ya existe'

command -v python3 >/dev/null 2>&1 || die 'python3 es necesario para validar el fixture'
if ! INPUT_DURATION=$(python3 - "$INPUT" <<'PY'
import sys
import wave
try:
    with wave.open(sys.argv[1], 'rb') as source:
        spec = (source.getnchannels(), source.getsampwidth(), source.getframerate())
        frames = source.getnframes()
except (EOFError, OSError, wave.Error) as exc:
    print(f'invalid WAV: {exc}', file=sys.stderr)
    raise SystemExit(1)
if spec != (1, 2, 16000) or frames <= 0:
    print('input must be nonempty 16 kHz mono Int16 WAV', file=sys.stderr)
    raise SystemExit(1)
print(f'{frames / spec[2]:.6f}')
PY
); then
    die "WAV inválido: $INPUT"
fi

LOG=$(mktemp /tmp/capture-selftest.XXXXXX)
trap 'rm -f "$LOG"' EXIT
printf 'MeetCapture real self-test: mode=%s input=%ss output=%s\n' \
    "$MODE" "$INPUT_DURATION" "$OUTPUT"

set +e
env \
    MEETCAPTURE_REAL_CHECK="$MODE" \
    MEETCAPTURE_TEST_OUTPUT_DIR="$OUTPUT" \
    MEETCAPTURE_CHECK_INPUT="$INPUT" \
    MEETCAPTURE_CHECK_REPORT="$REPORT" \
    MEETCAPTURE_WHISPER_CPU_ONLY=1 \
    "$APP_BIN" >"$LOG" 2>&1
APP_RC=$?
set -e

STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' \
    "$REPORT" 2>/dev/null || true)
if [ "$APP_RC" -ne 0 ]; then
    if [ "$APP_RC" -eq 77 ] || [ "$STATUS" = blocked ]; then
        printf 'BLOCKED: real harness exit=%s\n' "$APP_RC"
        tail -n 6 "$LOG" >&2
        exit 77
    fi
    printf 'FAILED: real harness exit=%s\n' "$APP_RC" >&2
    tail -n 6 "$LOG" >&2
    exit 1
fi
[ "$STATUS" != blocked ] || { printf 'BLOCKED: report status=blocked\n' >&2; exit 77; }
if [ ! -s "$REPORT" ]; then
    printf 'FAILED: harness salió 0 sin un reporte nuevo\n' >&2
    exit 1
fi

if ! python3 - "$REPORT" "$REFERENCE" "$MODE" "$INPUT_DURATION" "$MAX_WER" "$REQUIRED_WORDS" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

report_path, reference_path, mode, actual_text, limit_text, required_text = sys.argv[1:]

def fail(message):
    print(f'FAILED: {message}', file=sys.stderr)
    raise SystemExit(1)

def number(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        fail(f'{label} no es numérico')
    value = float(value)
    if not math.isfinite(value):
        fail(f'{label} no es finito')
    return value

try:
    report = json.loads(Path(report_path).read_text(encoding='utf-8'))
except (OSError, ValueError) as exc:
    fail(f'reporte JSON inválido: {exc}')
if not isinstance(report, dict) or report.get('status') != 'passed':
    fail(f"status inesperado: {report.get('status') if isinstance(report, dict) else None!r}")
if report.get('mode') != mode:
    fail(f"mode inesperado: {report.get('mode')!r}")
if report.get('diarize') is not False or report.get('live') is not False:
    fail('el reporte no confirma diarize=false y live=false')

actual = float(actual_text)
limit = float(limit_text)
if not (math.isfinite(actual) and actual > 0 and math.isfinite(limit) and 0 <= limit <= 1):
    fail('duración o max-wer inválido')
tolerance = 1.0
reported = number(report.get('inputDurationSec'), 'inputDurationSec')
if abs(reported - actual) > tolerance:
    fail(f'inputDurationSec={reported:.3f} difiere de wave={actual:.3f}')
number(report.get('elapsedSec'), 'elapsedSec')

expected_count = 3 if mode == 'import' else 1
if report.get('historyCount') != expected_count:
    fail(f"historyCount={report.get('historyCount')!r}, esperado={expected_count}")
records = report.get('records')
if not isinstance(records, list) or len(records) != expected_count:
    fail('records no coincide con historyCount')

def tokens(text):
    return re.findall(r'[^\W_]+', text.casefold(), flags=re.UNICODE)

def word_error_rate(reference_words, hypothesis_words):
    previous = list(range(len(reference_words) + 1))
    for i, word in enumerate(hypothesis_words, 1):
        current = [i] + [0] * len(reference_words)
        for j, expected in enumerate(reference_words, 1):
            current[j] = min(previous[j] + 1, current[j - 1] + 1,
                              previous[j - 1] + (word != expected))
        previous = current
    return previous[-1] / len(reference_words)

try:
    lines = [line.split('|', 1)[-1] for line in
             Path(reference_path).read_text(encoding='utf-8').splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
except OSError as exc:
    fail(f'referencia ilegible: {exc}')
reference = tokens(' '.join(lines))
if not reference:
    fail('referencia vacía')

capture_duration = None
if mode == 'capture':
    capture = report.get('capturePath')
    dropped = report.get('droppedCallbacks')
    if not isinstance(capture, str) or not Path(capture).is_file():
        fail('capturePath ausente')
    capture_path = Path(capture)
    pcm_bytes = capture_path.stat().st_size
    if pcm_bytes <= 0:
        fail('capture PCM vacío')
    if isinstance(dropped, bool) or not isinstance(dropped, int) or dropped != 0:
        fail(f'droppedCallbacks inválido o no cero: {dropped!r}')
    sidecar_path = Path(str(capture_path) + '.format.json')
    try:
        sidecar = json.loads(sidecar_path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as exc:
        fail(f'sidecar de captura inválido: {exc}')
    sample_rate = number(sidecar.get('sample_rate'), 'sidecar.sample_rate')
    channels = sidecar.get('channels')
    sample_format = sidecar.get(
        'sample_format',
        sidecar.get('sampleFormat', sidecar.get('bit_format', sidecar.get('bitFormat'))),
    )
    if (isinstance(sample_rate, bool) or not isinstance(sample_rate, (int, float)) or
            sample_rate <= 0 or isinstance(channels, bool) or not isinstance(channels, int) or
            channels <= 0 or not isinstance(sample_format, str)):
        fail('sidecar de captura no describe sample rate, canales y formato')
    bytes_per_sample = {'s16le': 2, 'int16': 2,
                        'float32': 4, 'f32': 4, 'float': 4}.get(sample_format.casefold())
    if bytes_per_sample is None:
        fail(f'formato PCM no soportado en sidecar: {sample_format!r}')
    frame_bytes = channels * bytes_per_sample
    if pcm_bytes % frame_bytes:
        fail('PCM de captura truncado según el sidecar')
    capture_duration = pcm_bytes / frame_bytes / float(sample_rate)
    if capture_duration <= 0:
        fail('duración PCM de captura vacía')

seen = [set(), set(), set()]
for index, record in enumerate(records):
    if not isinstance(record, dict):
        fail(f'records[{index}] no es objeto')
    for key in ('id', 'transcriptPath', 'pendingPath', 'text', 'engine', 'model'):
        if not isinstance(record.get(key), str) or not record[key].strip():
            fail(f'records[{index}].{key} vacío')
    name = (record['engine'] + record['model']).lower()
    if 'fake' in name or 'mock' in name:
        fail(f'records[{index}] usa engine/model simulado')
    for n, key in enumerate(('id', 'transcriptPath', 'pendingPath')):
        if record[key] in seen[n]:
            fail(f'records[{index}].{key} duplicado')
        seen[n].add(record[key])
    record_words = tokens(record['text'])
    if not record_words:
        fail(f'records[{index}].text vacío')
    record_wer = word_error_rate(reference, record_words)
    if record_wer > limit:
        fail(f'records[{index}] WER={record_wer:.3f} supera max={limit:.3f}')
    duration = number(record.get('durationSec'), f'records[{index}].durationSec')
    if mode == 'import' and abs(duration - actual) > tolerance:
        fail(f'records[{index}].durationSec={duration:.3f} difiere de wave={actual:.3f}')
    if mode == 'capture' and abs(duration - capture_duration) > tolerance:
        fail(f'records[{index}].durationSec={duration:.3f} difiere de PCM={capture_duration:.3f}')
    if not Path(record['transcriptPath']).is_file() or not Path(record['pendingPath']).is_file():
        fail(f'records[{index}] no prueba transcript y handoff presentes')

text = report.get('text')
hypothesis = tokens(text) if isinstance(text, str) else []
if not reference or not hypothesis:
    fail('referencia o transcript vacío')
if tokens(records[0]['text']) != hypothesis:
    fail('report.text no coincide con el registro más reciente')
wer = word_error_rate(reference, hypothesis)
if wer > limit:
    fail(f'WER={wer:.3f} supera max={limit:.3f}')

stopwords = {'a', 'al', 'con', 'como', 'de', 'del', 'el', 'en', 'es', 'la',
             'las', 'lo', 'los', 'para', 'por', 'que', 'se', 'su', 'un', 'una', 'y'}
essential = tokens(required_text) if required_text.strip() else []
if not essential:
    essential = list(dict.fromkeys(w for w in reference if len(w) >= 4 and w not in stopwords))
if not essential:
    essential = list(dict.fromkeys(reference))
for index, record in enumerate(records):
    record_words = tokens(record['text'])
    missing = [word for word in essential if word not in record_words]
    if missing:
        fail(f'records[{index}] faltan palabras esenciales: ' + ', '.join(missing))
audio_duration = capture_duration if mode == 'capture' else actual
print(f'PASSED: mode={mode} WER={wer:.3f} audio_duration={audio_duration:.3f}s input_duration={actual:.3f}s history={expected_count}')
PY
then
    tail -n 6 "$LOG" >&2
    exit 1
fi
printf 'Report: %s\n' "$REPORT"
