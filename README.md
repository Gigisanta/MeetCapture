# MeetCapture — Audio Transcription Suite

Suite de herramientas para captura y transcripcion de reuniones en macOS.

---

## Estado Actual (2026-05-29)

| Componente | Estado | Descripcion |
|---|---|---|
| `transcribe.py` | **Activo** | Script unificado de transcripcion en `~/.hermes/scripts/` |
| `transcribe_worker.py` | Referencia | Worker original con chunking (base para `transcribe.py`) |
| `MeetCapture.app` | Pausado | Menu bar app para captura automatica de Google Meet |
| `meet-daemon` | **Deprecado** | Daemon de captura de calendario (reemplazado por transcribe.py) |
| Skill `audio-transcription-batch` | **Activo** | Documentacion del pipeline en `~/.hermes/skills/media/` |

---

## Pipeline Actual

```
Audio (m4a, mp3, wav, ogg, etc.)
    │
    ▼
~/.hermes/scripts/transcribe.py <audio> [title]
    │
    ├── ffmpeg → split en chunks WAV de 10min (si >10min)
    ├── whisper-cli + ggml-base (141MB) + initial prompt
    ├── concatenar chunks
    ├── post-proceso (hallucinations, repeticiones, garbage)
    │
    ▼
~/.hermes/Transcripts/YYYY-MM-DD_HHMM-<title>.txt
```

### Uso

```bash
# Transcripcion basica
python3 ~/.hermes/scripts/transcribe.py ~/Downloads/reunion.m4a "Reunion-Virginia"

# Con modelo medium (si tenes RAM suficiente, ~2GB libre)
WHISPER_MODEL=medium python3 ~/.hermes/scripts/transcribe.py ~/Downloads/reunion.m4a

# Verificar modelo seleccionado
python3 -c "from pathlib import Path; print('Modelos:', list(Path.home().joinpath('.whisper/models').glob('ggml-*.bin')))"
```

### Output

Los transcripts se guardan en `~/.hermes/Transcripts/`:
```
~/.hermes/Transcripts/
├── 2026-05-26_0000-Reunion-Infranoba.txt
├── 2026-05-28_1548-Reunion-con-Virginia.txt
└── 2026-05-29_1316-Reunion-Virginia-v2.txt
```

---

## Precision de Transcripcion

### Modelo Actual: ggml-base (141MB)

| Aspecto | Calidad |
|---|---|
| Palabras comunes en español | Buena |
| Nombres propios (Virginia, Reinnova, MaatWork) | Limitada |
| Terminos tecnicos (certificacion, redeterminacion) | Aceptable |
| Puntuacion y segmentacion | Basica |

### Mejoras Implementadas

1. **Initial prompt** con terminos de dominio (participantes, proyectos, jargon tecnico)
2. **Carry initial prompt** entre chunks para mantener contexto
3. **Post-proceso unificado**: repeticiones + Jaccard similarity + garbage patterns
4. **Formato WAV** (no FLAC) para compatibilidad con whisper-cli

### Mejoras Disponibles

| Opcion | Costo | Impacto | RAM |
|---|---|---|---|
| Modelo medium (ggml-medium.bin, 1.4GB) | $0 | Alto | ~2GB libre |
| Post-proceso con LLM (correccion de nombres) | Tokens | Alto | API |
| Fine-tuning con datos especificos | ~$100 GPU | Muy alto | N/A |

Para usar medium:
```bash
# Descargar (una sola vez)
curl -L --output ~/.whisper/models/ggml-medium.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"

# Usar
WHISPER_MODEL=medium python3 ~/.hermes/scripts/transcribe.py audio.m4a
```

---

## Dependencias

| Tool | Version | Instalacion |
|---|---|---|
| whisper-cli | ultima | `brew install whisper-cpp` |
| ffmpeg | ultima | `brew install ffmpeg` |
| ggml-base.bin | 141MB | Auto-descarga en primer uso |
| Python | 3.10+ | Sistema |

### Verificar dependencias

```bash
which whisper-cli && whisper-cli --version
which ffmpeg && ffmpeg -version | head -1
ls -lh ~/.whisper/models/ggml-base.bin
```

---

## Estructura del Proyecto

```
meetings-repo/                    # Este repo
├── README.md                     # Este archivo
├── SPEC.md                       # Spec original de MeetCapture v4
├── Sources/                      # Swift sources (MeetCapture.app)
├── transcribe_worker.py          # Worker original (referencia)
├── docs/
│   ├── ARCHITECTURE.md           # Arquitectura de MeetCapture.app
│   ├── INSTALLATION.md           # Instalacion de MeetCapture.app
│   └── TROUBLESHOOTING.md        # Troubleshooting de MeetCapture.app
└── build.sh                      # Build script para MeetCapture.app

~/.hermes/
├── scripts/
│   └── transcribe.py             # Script unificado de transcripcion
├── Transcripts/                  # Output de transcripciones
│   ├── YYYY-MM-DD_HHMM-title.txt
│   └── ...
└── skills/media/
    └── audio-transcription-batch/ # Skill documentacion
        └── SKILL.md

~/meetings/                       # Runtime directory (MeetCapture app)
├── inbox/                        # dropzone para audios
└── recordings/                   # grabaciones del daemon (legacy)

~/.hermes/Transcripts/            # Output centralizado
├── YYYY-MM-DD_HHMM-title.txt     # transcripts crudos
├── summaries/                    # resumenes HTML
│   └── YYYY-MM-DD_resumen.html
└── README.md
```

---

## MeetCapture.app (Pausado)

La app nativa de menu bar para captura automatica de Google Meet esta pausada.
Los docs en `docs/` describen su arquitectura y funcionamiento.

Para reactivar:
```bash
cd ~/meetings-repo
./build.sh
open ~/meetings/MeetCapture.app
```

**Nota:** El `meet-daemon` fue deprecado. La captura automatica de calendario
y la transcripcion en vivo requieren re-evaluacion de la arquitectura.

---

## Cambios Recientes

### 2026-05-29 — Consolidacion del pipeline

- Creado `~/.hermes/scripts/transcribe.py` como script unificado
- Deprecado `meet-daemon` (era parte de MeetCapture, no del pipeline de transcripcion)
- Migrado formato de FLAC a WAV (compatibilidad con whisper-cli)
- Agregado initial prompt con terminos de dominio
- Creado directorio `~/.hermes/Transcripts/` como output estandar
- Creada skill `audio-transcription-batch` con documentacion completa
- Limpiado PID file, state, y logs del daemon viejo

---

## Licencia

Proyecto interno MaatWork.
