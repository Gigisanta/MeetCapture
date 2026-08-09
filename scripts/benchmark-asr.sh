#!/bin/bash
# benchmark-asr.sh — benchmark A/B: whisper.cpp (whisper-cli) vs
# sherpa-onnx streaming (transcribe_sherpa.py) sobre el corpus de test.
#
# Métricas: WER (levenshtein a nivel palabra, sin deps) y RTF
# (tiempo de transcripción / duración del audio). Salida: tabla en consola.
set -uo pipefail

CORPUS=${CORPUS:-/tmp/meetcapture_corpus/corpus.wav}
REF=${REF:-/tmp/meetcapture_corpus/ref.txt}
TMP=${TMP:-/tmp/meetcapture_corpus}
WHISPER_MODEL=${WHISPER_MODEL:-/Users/gigi/.whisper/models/ggml-medium-q5_0.bin}
VENV_PY=${VENV_PY:-/Users/gigi/HerMaatOS/venvs/venv-meet/bin/python3}
TRANSCRIBE=${TRANSCRIBE:-"$(cd "$(dirname "$0")" && pwd)/transcribe_sherpa.py"}

WHISPER_CLI=$(command -v whisper-cli 2>/dev/null || echo "")

[ -f "$CORPUS" ] || { echo "falta $CORPUS — correr primero scripts/gen_test_corpus.sh"; exit 1; }
[ -f "$REF" ] || { echo "falta $REF"; exit 1; }

DUR=$("$VENV_PY" -c "
import wave,sys; f=wave.open('$CORPUS'); print(f'{f.getnframes()/f.getframerate():.2f}')")

wer() { # wer <hipotesis.txt> <ref.txt>
  "$VENV_PY" - "$1" "$2" <<'EOF'
import re, sys

def norm(s):
    s = s.lower()
    s = re.sub(r"[^\w\sáéíóúüñÁÉÍÓÚÜÑ]", " ", s, flags=re.UNICODE)
    return s.split()

def lev(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, cb in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb))
        prev = cur
    return prev[-1]

hyp = norm(open(sys.argv[1]).read())
ref = []
for line in open(sys.argv[2]):
    line = line.rstrip("\n")
    if "|" in line:
        line = line.split("|", 1)[1]
    ref.extend(norm(line))
d = lev(hyp, ref)
print(f"{100.0 * d / max(1, len(ref)):.1f}")
EOF
}

run_timed() { # run_timed <label> <cmd...> ; setea ELAPSED
  local t0 t1
  shift # descartar la etiqueta: "$@" debe arrancar en el comando real
  t0=$("$VENV_PY" -c 'import time; print(time.time())')
  "$@" >/dev/null 2>&1
  t1=$("$VENV_PY" -c 'import time; print(time.time())')
  ELAPSED=$("$VENV_PY" -c "print('{:.2f}'.format($t1 - $t0))")
}

printf "%-28s %-34s %7s %8s\n" "engine" "model" "WER%" "RTF"
printf "%s\n" "----------------------------------------------------------------------"

# --- sherpa-onnx ---
SHERPA_JSON="$TMP/sherpa_segments.json"
run_timed sherpa "$VENV_PY" "$TRANSCRIBE" --audio "$CORPUS" --language es --out "$SHERPA_JSON"
SHERPA_TXT="$TMP/sherpa_hyp.txt"
"$VENV_PY" - "$SHERPA_JSON" "$SHERPA_TXT" <<'EOF'
import json, sys
segs = json.load(open(sys.argv[1]))["segments"]
open(sys.argv[2], "w").write("\n".join(s["text"] for s in segs))
EOF
SHERPA_WER=$(wer "$SHERPA_TXT" "$REF")
SHERPA_RTF=$("$VENV_PY" -c "print('{:.2f}'.format($ELAPSED / $DUR))")
printf "%-28s %-34s %6s%% %7s\n" "sherpa-onnx (streaming+VAD)" "zipformer-es-kroko" "$SHERPA_WER" "$SHERPA_RTF"

# --- whisper.cpp ---
if [ -n "$WHISPER_CLI" ] && [ -f "$WHISPER_MODEL" ]; then
  WHISPER_TXT="$TMP/whisper_hyp.txt"
  rm -f "$WHISPER_TXT"
  run_timed whisper "$WHISPER_CLI" -m "$WHISPER_MODEL" -f "$CORPUS" -l es -otxt -nt -of "$TMP/whisper_out" -t 4 >/dev/null 2>&1
  [ -f "$TMP/whisper_out.txt" ] && mv "$TMP/whisper_out.txt" "$WHISPER_TXT"
  if [ -f "$WHISPER_TXT" ]; then
    WHISPER_WER=$(wer "$WHISPER_TXT" "$REF")
    WHISPER_RTF=$("$VENV_PY" -c "print('{:.2f}'.format($ELAPSED / $DUR))")
    printf "%-28s %-34s %6s%% %7s\n" "whisper.cpp (offline)" "ggml-medium-q5_0" "$WHISPER_WER" "$WHISPER_RTF"
  else
    echo "whisper: no produjo salida (revisar flags) — se omite"
  fi
else
  echo "whisper-cli o modelo $WHISPER_MODEL no disponible — benchmark solo con sherpa"
fi

echo ""
echo "duración del corpus: ${DUR}s"
