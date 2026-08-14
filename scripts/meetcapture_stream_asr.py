#!/usr/bin/env python3
"""
meetcapture_stream_asr.py — Streaming ASR server for MeetCapture live transcription.

Reads raw Int16 mono 16 kHz PCM from stdin (no WAV header) and decodes it
continuously with a sherpa-onnx online (streaming) recognizer, emitting JSONL
to stdout:

  {"type":"ready","model":"zipformer-es"}            # recognizer is up
  {"type":"partial","text":"hola cómo va ..."}        # provisional text (throttled)
  {"type":"final","text":"hola cómo va","start":1.2,"end":4.5}  # endpoint-segmented sentence

The Swift side (LiveASRService) spawns this process, feeds it 16 kHz mono
Int16 chunks from the capture pipeline and renders partial/final events in
the popover in real time. Final transcripts are still produced by the
whole-file engine (whisper/sherpa) for accuracy; this only powers the live
preview and an emergency fallback.

Reuses the model registry/loader from transcribe_sherpa.py (same dir).

Usage:
  meetcapture_stream_asr.py [--model zipformer-es|zipformer-en] [--chunk-ms 100]

Exit codes: 0 clean EOF, 1 runtime error, 2 model/python setup error.
"""
import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import sherpa_onnx  # noqa: E402  (must be importable before use)

try:
    import numpy as np
except ImportError:  # pragma: no cover
    np = None

from transcribe_sherpa import MODELS_DIR, MODEL_REGISTRY, make_recognizer  # noqa: E402

CHUNK_SAMPLES = 1600  # 100 ms @ 16 kHz
SAMPLE_RATE = 16000


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    ap = argparse.ArgumentParser(description="Streaming ASR server (stdin PCM -> stdout JSONL)")
    ap.add_argument("--model", default="zipformer-es", help="model id (MODEL_REGISTRY) or dir")
    ap.add_argument("--chunk-ms", type=int, default=100, help="feed chunk size in ms (default 100)")
    ap.add_argument("--partial-every-ms", type=int, default=400, help="min interval between partial events")
    args = ap.parse_args()

    # Resolve model dir (same logic as transcribe_sherpa.py)
    model_dir = args.model if os.path.isdir(args.model) else None
    if model_dir is None:
        if args.model not in MODEL_REGISTRY:
            emit({"type": "error", "message": f"modelo desconocido: {args.model}. Opciones: {list(MODEL_REGISTRY)}"})
            sys.exit(2)
        rel, _lang = MODEL_REGISTRY[args.model]
        model_dir = os.path.join(MODELS_DIR, rel)
    if not os.path.isdir(model_dir):
        emit({"type": "error", "message": f"no existe el modelo en {model_dir}"})
        sys.exit(2)

    try:
        recognizer = make_recognizer(model_dir)
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": f"no se pudo cargar el modelo: {exc}"})
        sys.exit(2)

    stream = recognizer.create_stream()
    emit({"type": "ready", "model": os.path.basename(model_dir)})

    chunk_samples = max(1, int(args.chunk_ms * SAMPLE_RATE / 1000))
    partial_min_interval = max(0.1, args.partial_every_ms / 1000.0)

    buf = bytearray()
    audio_sec = 0.0          # total audio fed so far
    seg_start = 0.0          # audio time when the current endpoint-segment began
    last_partial = ""        # last text we emitted as partial
    last_partial_t = 0.0
    last_emit_sec = 0.0
    pending_final = ""       # final text seen at endpoint, awaiting silence flush

    def feed(samples):
        """Feed a chunk of float samples, decode, emit partials/finals."""
        nonlocal audio_sec, seg_start, last_partial, last_partial_t, pending_final
        stream.accept_waveform(SAMPLE_RATE, samples)
        audio_sec += len(samples) / SAMPLE_RATE
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream).strip()
        now = audio_sec
        if text != last_partial and (now - last_partial_t) >= partial_min_interval and text:
            emit({"type": "partial", "text": text})
            last_partial = text
            last_partial_t = now
        if recognizer.is_endpoint(stream):
            final = recognizer.get_result(stream).strip()
            if final:
                emit({"type": "final", "text": final, "start": round(seg_start, 3), "end": round(now, 3)})
                seg_start = now
            recognizer.reset(stream)
            last_partial = ""
            pending_final = ""

    try:
        while True:
            raw = sys.stdin.buffer.read(8192)
            if not raw:
                break
            buf += raw
            while len(buf) >= chunk_samples * 2:
                piece = bytes(buf[: chunk_samples * 2])
                del buf[: chunk_samples * 2]
                # Int16 LE -> float32 [-1, 1] (numpy path ~50x faster than
                # per-sample int.from_bytes — keeps live RTF well under 1.0)
                if np is not None:
                    samples = (np.frombuffer(piece, dtype=np.int16).astype(np.float32) / 32768.0).tolist()
                else:
                    samples = [int.from_bytes(piece[i : i + 2], "little", signed=True) / 32768.0
                               for i in range(0, len(piece), 2)]
                feed(samples)
    except KeyboardInterrupt:
        pass
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": f"decode error: {exc}"})
        sys.exit(1)

    # EOF: drain trailing audio
    try:
        final = recognizer.get_result(stream).strip()
        if final:
            emit({"type": "final", "text": final, "start": round(seg_start, 3), "end": round(audio_sec, 3)})
    except Exception as exc:  # noqa: BLE001
        emit({"type": "error", "message": f"drain error: {exc}"})
        sys.exit(1)
    emit({"type": "done", "audio_sec": round(audio_sec, 3)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
