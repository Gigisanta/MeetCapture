#!/bin/bash
# gen_test_corpus.sh — genera un corpus de test bilingüe-español para el
# benchmark de ASR/diarización usando voces macOS (say + afconvert).
#
# Salida en /tmp/meetcapture_corpus/:
#   corpus.wav   audio 16kHz mono Int16 (~2 min) alternando 2 hablantes
#   ref.txt      referencia: una frase por línea, formato "<HABLANTE>|<texto>"
set -euo pipefail

OUT=/tmp/meetcapture_corpus
VOICE_A="Paulina"   # es_MX
VOICE_B="Mónica"    # es_ES
RATE=125

mkdir -p "$OUT"
rm -f "$OUT"/*.aiff "$OUT"/spk_*.wav "$OUT"/corpus.wav "$OUT"/ref.txt

# Frases en español rioplatense, tema: reunión de equipo. Alternan A/B.
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

WAVS=()
i=0
while [ $i -lt ${#FRASES_A[@]} ]; do
  for SPK in A B; do
    if [ "$SPK" = A ]; then VOICE="$VOICE_A"; FRASE="${FRASES_A[$i]}"; else VOICE="$VOICE_B"; FRASE="${FRASES_B[$i]}"; fi
    TAG="spk_${SPK}_$(printf '%02d' "$i")"
    say -v "$VOICE" -r "$RATE" -o "$OUT/$TAG.aiff" "$FRASE"
    afconvert -f WAVE -d LEI16@16000 "$OUT/$TAG.aiff" "$OUT/$TAG.wav"
    WAVS+=("$OUT/$TAG.wav")
    echo "$SPK|$FRASE" >> "$OUT/ref.txt"
  done
  i=$((i + 1))
done

# Concatena los wav (16k mono 16bit) con 0.4 s de silencio entre frases.
python3 - "$OUT" "${WAVS[@]}" <<'EOF'
import sys, wave, array, os

out_dir, wavs = sys.argv[1], sys.argv[2:]
chunks = []
for w in wavs:
    with wave.open(w) as f:
        assert f.getnchannels() == 1 and f.getsampwidth() == 2 and f.getframerate() == 16000, w
        chunks.append(array.array('h', f.readframes(f.getnframes())))
silence = array.array('h', [0] * int(0.4 * 16000))
out = array.array('h')
for c in chunks:
    out.extend(c)
    out.extend(silence)
with wave.open(os.path.join(out_dir, "corpus.wav"), "wb") as f:
    f.setnchannels(1); f.setsampwidth(2); f.setframerate(16000)
    f.writeframes(out.tobytes())
print(f"corpus.wav: {len(out)/16000:.1f}s, {len(chunks)} frases, {len(wavs)} archivos")
EOF

echo "OK -> $OUT/corpus.wav ($(python3 -c "
import wave; f=wave.open('$OUT/corpus.wav'); print(f'{f.getnframes()/f.getframerate():.1f}s')"))"
echo "ref  -> $OUT/ref.txt ($(wc -l < "$OUT/ref.txt") frases)"
