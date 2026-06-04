# Transcription Pipeline — Reference Guide

> **Status:** This is the ACTIVE transcription pipeline.
> The MeetCapture app docs (ARCHITECTURE.md, INSTALLATION.md, TROUBLESHOOTING.md) describe the PAUSED menu bar app.

---

## Quick Reference

```bash
# Transcribe any audio
python3 ~/.hermes/scripts/transcribe.py <audio_file> [title]

# Output location
~/.hermes/Transcripts/YYYY-MM-DD_HHMM-<title>.txt
```

---

## How It Works

### 1. Model Selection

```python
# Default: base (141MB, safe for 8GB RAM)
# Override: WHISPER_MODEL=medium (1.4GB, needs ~2GB free)
model = os.environ.get("WHISPER_MODEL", "base")
```

### 2. Chunking (for files >10 min)

- Audio is split into WAV segments of 600 seconds (10 min)
- Format: 16kHz mono PCM (whisper-cli native)
- Chunks are processed sequentially to avoid RAM spikes
- Each chunk is deleted after transcription (progressive cleanup)

### 3. Transcription

Each chunk goes through whisper-cli with:
- `--language es` — force Spanish
- `--prompt` — domain-specific terms (participants, projects, jargon)
- `--carry-initial-prompt` — maintain context across chunks
- `-t 4` — 4 threads
- `-np` — quiet mode

### 4. Post-Processing

The unified post-processor removes:
- Exact line repetitions (>2 consecutive)
- Near-duplicate lines (Jaccard similarity >0.85)
- Whisper garbage: `[Music]`, `[Applause]`, `Subtitled by...`
- Long single-word loops ("Bien" repeated 100+ times)
- Empty lines and dot/dash-only lines

### 5. Output

- Saved to `~/.hermes/Transcripts/`
- Filename: `YYYY-MM-DD_HHMM-<safe-title>.txt`
- Path printed to stdout (for scripting/chaining)

---

## Initial Prompt — Domain Terms

The initial prompt is the biggest accuracy lever for proper nouns. It includes:

**Participants:** Gio, Virginia, Nacho, Virginia Folgueiro, Nacho Infante

**Projects:** MaatWork, Reinnova, Infrannova, Cactus Wealth, MaatQuant,
Reinnova Consum, MaatWork Gym, MaatWorkHUB, PlanningMaatWork

**Technical terms:** certificacion, redeterminacion, planificacion, etapas,
obras, tickets, gestion documental, inventario, traslados, montajes, DTM,
ledger, presupuesto, partida, parte de obra, orden de compra, proveedor,
deposito, acopio, instalado, planificado, adquirido, baseline, desvio,
replan, cash flow, KPI, rubro, coimas, maquinaria, alquiler

**Tech stack:** Next.js, Drizzle ORM, Neon Postgres, Vercel, shadcn/ui, Zustand

**Roles:** gerencia, jefe de obra, admin, operativo, mantenimiento

**Ticket states:** abierto, en validacion, aprobado, resuelto, completado

### Updating the prompt

When new participants or projects appear, edit `DEFAULT_PROMPT` in:
```
~/.hermes/scripts/transcribe.py
```

---

## Accuracy Comparison

| Configuration | Nombres propios | Puntuacion | Terminos tecnicos |
|---|---|---|---|
| base sin prompt (v1) | Mala | Basica | Aceptable |
| base con prompt (v2) | Mala-Media | Buena | Buena |
| medium con prompt | Buena | Muy buena | Muy buena |
| medium + LLM post-proc | Excelente | Excelente | Excelente |

**Conclusion:** For 8GB machines, the prompt improves readability but not
proper noun recognition. For a real accuracy jump, either:
1. Use medium model (needs more RAM)
2. Add LLM post-processing (correccion de nombres via API)

---

## Chaining with LLM Summary

```bash
# Transcribe
TRANSCRIPT=$(python3 ~/.hermes/scripts/transcribe.py audio.m4a "Meeting")

# Generate summary (example with Hermes)
# The transcript path can be passed to any LLM for summarization
cat "$TRANSCRIPT" | head -50  # preview
```

---

## Models

| Model | Size | Accuracy | RAM Peak | Speed (66min audio) |
|---|---|---|---|---|
| ggml-base | 141MB | Basic | ~300MB | ~2 min |
| ggml-medium | 1.4GB | High | ~800MB | ~8 min |
| ggml-large-v3-turbo | 1.5GB | Very high | ~2GB | ~10 min |

Download models:
```bash
# Base (included)
# Already at ~/.whisper/models/ggml-base.bin

# Medium
curl -L --output ~/.whisper/models/ggml-medium.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"

# Large v3 turbo
curl -L --output ~/.whisper/models/ggml-large-v3-turbo.bin \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
```

---

## Troubleshooting

### "No whisper model found"
```bash
ls ~/.whisper/models/
# Should show ggml-base.bin at minimum
# If missing: whisper-cli will auto-download on first run
```

### "failed to read the frames of the audio data"
- Cause: FLAC format not supported by whisper-cli
- Fix: The script already uses WAV. If you see this, you're running the old code.

### RAM limit exceeded
- The script monitors RSS and aborts at 500MB
- For large files, use base model (not medium)
- If still failing, increase CHUNK_DURATION_SEC to process fewer chunks

### Whisper hallucinations (repeated words)
- The post-processor handles most cases
- If persistent, try `--temperature 0.0` in whisper-cli
- For extreme cases, run with different `--temperature-inc` values
