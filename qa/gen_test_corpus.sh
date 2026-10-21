#!/bin/bash
# gen_test_corpus.sh — generates synthetic two-speaker Spanish speech with macOS
# say. The benchmark scores the resulting audio against ref.txt with WER.
set -euo pipefail

OUT=$(printenv OUT 2>/dev/null || true)
VOICE_A=$(printenv VOICE_A 2>/dev/null || true)
VOICE_B=$(printenv VOICE_B 2>/dev/null || true)
RATE=$(printenv RATE 2>/dev/null || true)
[ -n "$OUT" ] || OUT=/tmp/meetcapture_corpus
[ -n "$VOICE_A" ] || VOICE_A=Paulina
[ -n "$VOICE_B" ] || VOICE_B=Mónica
[ -n "$RATE" ] || RATE=125

FRASES_A=(
  "Buenas, gracias por conectarse a la reunión de hoy. Vamos a tratar de ser puntuales así terminamos temprano."
  "El objetivo es cerrar los pendientes del sprint y definir prioridades para la próxima semana."
  "La semana pasada cerramos el módulo de pagos, que era lo más urgente. Quedó andando muy bien en producción."
  "Necesito que confirmen quién se encarga de la integración con el calendario. Es un tema que viene dando vueltas hace rato."
  "Mañana a primera hora les mando el resumen con los próximos pasos. Así lo pueden revisar antes del mediodía."
  "Antes de cerrar, ¿alguien tiene algo más para sumar al orden del día? Si no, pasamos directo a los temas de la semana que viene."
)
FRASES_B=(
  "Para mí el tema crítico es la estabilidad del proceso de captura de audio. Se cayó dos veces en la demo de ayer."
  "Estuve probando el nuevo motor de transcripción y anduvo bastante bien. Mejoró mucho la precisión con el acento local."
  "El problema es que el modelo tarda unos segundos en procesar reuniones largas. Habría que optimizar el pipeline completo."
  "Si me dan el acceso al repositorio, me pongo con la diarización de hablantes. Calculo que la tengo lista para el jueves."
  "Genial, entonces quedamos así y coordinamos la revisión para el viernes. Les aviso por el grupo cuando esté el pull request."
  "Sí, quedó pendiente el tema de las notificaciones, lo anoto en el tablero. Después lo priorizamos junto con el resto de los bugs."
)
COUNT=6

if [ -e "$OUT" ] && [ ! -d "$OUT" ]; then
  printf 'output is not a directory: %s\n' "$OUT" >&2
  exit 1
fi
mkdir -p "$OUT"
# Clear only this generator's products so a failed run cannot leave a corpus
# that a later benchmark mistakes for the current generation.
for old in "$OUT/corpus.wav" "$OUT/ref.txt" "$OUT"/spk_*.aiff "$OUT"/spk_*.wav; do
  if [ -e "$old" ]; then
    rm -f "$old"
  fi
done

STAGE=$(mktemp -d "$OUT/.corpus.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
command -v say >/dev/null 2>&1 || { printf 'macOS say is required\n' >&2; exit 1; }
command -v afconvert >/dev/null 2>&1 || { printf 'macOS afconvert is required\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'python3 is required\n' >&2; exit 1; }

WAVS=()
i=0
while [ "$i" -lt "$COUNT" ]; do
  for speaker in A B; do
    if [ "$speaker" = A ]; then
      voice=$VOICE_A
      phrase=${FRASES_A[$i]}
    else
      voice=$VOICE_B
      phrase=${FRASES_B[$i]}
    fi
    tag="spk_"$speaker"_$(printf '%02d' "$i")"
    aiff="$STAGE/$tag.aiff"
    wav="$STAGE/$tag.wav"
    say -v "$voice" -r "$RATE" -o "$aiff" "$phrase"
    [ -s "$aiff" ] || { printf 'empty say output: %s\n' "$aiff" >&2; exit 1; }
    afconvert -f WAVE -d LEI16@16000 "$aiff" "$wav"
    [ -s "$wav" ] || { printf 'empty afconvert output: %s\n' "$wav" >&2; exit 1; }
    WAVS+=("$wav")
    printf '%s|%s\n' "$speaker" "$phrase" >> "$STAGE/ref.txt"
  done
  i=$((i + 1))
done

python3 - "$STAGE/corpus.wav" "${WAVS[@]}" <<'PY'
import array
import sys
import wave

output, *paths = sys.argv[1:]
if len(paths) != 12:
    raise SystemExit(f'expected 12 speech WAVs, got {len(paths)}')
silence = array.array('h', [0] * int(0.4 * 16000))
audio = array.array('h')
for path in paths:
    with wave.open(path, 'rb') as source:
        spec = (source.getnchannels(), source.getsampwidth(), source.getframerate())
        if spec != (1, 2, 16000):
            raise SystemExit(f'{path}: unexpected WAV format {spec}')
        frames = source.getnframes()
        samples = array.array('h')
        samples.frombytes(source.readframes(frames))
        if len(samples) != frames or not samples:
            raise SystemExit(f'{path}: empty or truncated speech')
        audio.extend(samples)
        audio.extend(silence)
with wave.open(output, 'wb') as destination:
    destination.setnchannels(1)
    destination.setsampwidth(2)
    destination.setframerate(16000)
    destination.writeframes(audio.tobytes())
print(f'{len(audio) / 16000:.3f}s, {len(paths)} phrases')
PY

python3 - "$STAGE/corpus.wav" "$STAGE/ref.txt" <<'PY'
import sys
import wave
from pathlib import Path

audio, reference = map(Path, sys.argv[1:])
with wave.open(str(audio), 'rb') as source:
    if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, 16000):
        raise SystemExit('corpus format validation failed')
    if source.getnframes() <= 0:
        raise SystemExit('corpus is empty')
lines = [line for line in reference.read_text(encoding='utf-8').splitlines() if line.strip()]
if len(lines) != 12 or any('|' not in line or not line.split('|', 1)[1].strip() for line in lines):
    raise SystemExit('reference must contain 12 nonempty speaker/text lines')
PY

mv "$STAGE/corpus.wav" "$OUT/corpus.wav"
mv "$STAGE/ref.txt" "$OUT/ref.txt"
DURATION=$(python3 - "$OUT/corpus.wav" <<'PY'
import sys
import wave
with wave.open(sys.argv[1], 'rb') as source:
    print(f'{source.getnframes() / source.getframerate():.3f}')
PY
)
printf 'OK -> %s/corpus.wav (%ss)\n' "$OUT" "$DURATION"
printf 'ref  -> %s/ref.txt (%s phrases)\n' "$OUT" "$(wc -l < "$OUT/ref.txt" | tr -d ' ')"
