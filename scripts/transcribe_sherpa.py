#!/usr/bin/env python3
"""
transcribe_sherpa.py — ASR streaming con sherpa-onnx + Silero VAD.

Uso:
  transcribe_sherpa.py --audio <ruta.wav|.pcm> [--model <id|dir>] \
      [--language es|en|auto] [--sample-rate 16000] --out <segments.json>

Modelos (por defecto en ~/.whisper/models/sherpa/):
  zipformer-es : sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06 (streaming, español)
  zipformer-en : sherpa-onnx-streaming-zipformer-en-2023-06-26      (streaming, inglés)
  silero_vad.onnx : VAD

Salida JSON: {"engine":"sherpa","model":"<id>","language":"es",
              "segments":[{"start":0.0,"end":5.5,"text":"..."}]}
start/end en segundos (float). .pcm = PCM crudo 16kHz mono Int16.
"""
import argparse
import array
import glob
import json
import os
import sys
import time
import wave

import sherpa_onnx

MODELS_DIR = os.path.expanduser("~/.whisper/models/sherpa")

# id -> (dir_relativa_al_models_dir, idioma)
MODEL_REGISTRY = {
    "zipformer-es": ("sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06", "es"),
    "zipformer-en": ("sherpa-onnx-streaming-zipformer-en-2023-06-26", "en"),
}
LANG_TO_MODEL = {"es": "zipformer-es", "en": "zipformer-en", "auto": "zipformer-es"}


def resample_linear(samples, in_rate, out_rate):
    """Resample lineal stdlib (ponytail: suficiente para test; upgrade: soxr)."""
    if in_rate == out_rate:
        return samples
    n_out = int(len(samples) * out_rate / in_rate)
    ratio = in_rate / out_rate
    out = []
    for i in range(n_out):
        pos = i * ratio
        i0 = int(pos)
        i1 = min(i0 + 1, len(samples) - 1)
        frac = pos - i0
        out.append(samples[i0] * (1 - frac) + samples[i1] * frac)
    return out


def read_audio(path, sample_rate):
    """Devuelve (samples float32 en [-1,1] a `sample_rate`, sr)."""
    if path.endswith(".pcm"):
        with open(path, "rb") as f:
            raw = f.read()
        n = len(raw) // 2
        a = array.array("h")
        a.frombytes(raw[: n * 2])
        samples = [x / 32768.0 for x in a]
        return resample_linear(samples, sample_rate, sample_rate), sample_rate
    with wave.open(path) as f:
        assert f.getnchannels() == 1, "solo mono"
        sr = f.getframerate()
        a = array.array("h")
        a.frombytes(f.readframes(f.getnframes()))
        samples = [x / 32768.0 for x in a]
    samples = resample_linear(samples, sr, sample_rate)
    return samples, sample_rate


def resolve_model(model_arg, language):
    """Devuelve (model_id, dir_del_modelo)."""
    if model_arg and os.path.isdir(model_arg):
        return os.path.basename(model_arg), model_arg
    mid = model_arg if model_arg else LANG_TO_MODEL.get(language, "zipformer-es")
    if mid not in MODEL_REGISTRY:
        sys.exit(f"modelo desconocido: {mid}. Opciones: {list(MODEL_REGISTRY)}")
    rel, lang = MODEL_REGISTRY[mid]
    d = os.path.join(MODELS_DIR, rel)
    if not os.path.isdir(d):
        sys.exit(f"no existe el modelo en {d}")
    return mid, d


def find_model_files(model_dir):
    """Encoder/decoder/joiner por glob (los nombres varían entre modelos)."""
    enc = glob.glob(model_dir + "/encoder*.onnx")
    dec = glob.glob(model_dir + "/decoder*.onnx")
    joi = glob.glob(model_dir + "/joiner*.onnx")
    enc = [f for f in enc if ".int8." not in f] or enc
    dec = [f for f in dec if ".int8." not in f] or dec
    joi = [f for f in joi if ".int8." not in f] or joi
    if not (enc and dec and joi):
        sys.exit(f"no se encontraron encoder/decoder/joiner onnx en {model_dir}")
    return enc[0], dec[0], joi[0]


def make_recognizer(model_dir):
    tokens = os.path.join(model_dir, "tokens.txt")
    enc, dec, joi = find_model_files(model_dir)
    bpe_vocab = os.path.join(model_dir, "bpe.model")
    has_bpe = os.path.isfile(bpe_vocab)
    # Kroko y otros modelos convertidos no traen bpe.model: sus tokens son BPE
    # (▁ prefijo). Usar tokens.txt como vocab BPE en ese caso.
    if not has_bpe:
        try:
            with open(tokens, encoding="utf-8") as f:
                first = f.read(4096)
            if "▁" in first:
                has_bpe = True
                bpe_vocab = tokens
        except OSError:
            pass
    return sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=tokens,
        encoder=enc,
        decoder=dec,
        joiner=joi,
        num_threads=4,
        provider="cpu",
        sample_rate=16000,
        feature_dim=80,
        decoding_method="greedy_search",
        modeling_unit="bpe" if has_bpe else "cjkchar",
        bpe_vocab=bpe_vocab if has_bpe else "",
    )


def make_vad(vad_model):
    config = sherpa_onnx.VadModelConfig()
    config.silero_vad.model = vad_model
    config.silero_vad.min_silence_duration = 0.5
    config.silero_vad.min_speech_duration = 0.25
    config.silero_vad.threshold = 0.5
    config.sample_rate = 16000
    config.num_threads = 2
    if not config.validate():
        sys.exit("config VAD inválida")
    return sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=300)


def main():
    ap = argparse.ArgumentParser(description="ASR streaming sherpa-onnx + Silero VAD")
    ap.add_argument("--audio", required=True, help="wav mono 16-bit o .pcm crudo 16k")
    ap.add_argument("--model", default=None, help="id de modelo o dir; default: zipformer-es")
    ap.add_argument("--language", default="auto", choices=["es", "en", "auto"])
    ap.add_argument("--sample-rate", type=int, default=16000, dest="sample_rate")
    ap.add_argument("--out", required=True, help="ruta del JSON de salida")
    args = ap.parse_args()

    if not os.path.isfile(args.audio):
        sys.exit(f"no existe {args.audio}")
    model_id, model_dir = resolve_model(args.model, args.language)
    language = MODEL_REGISTRY.get(model_id, (None, "es"))[1]
    vad_model = os.path.join(MODELS_DIR, "silero_vad.onnx")
    if not os.path.isfile(vad_model):
        sys.exit(f"falta el VAD en {vad_model}")

    samples, sr = read_audio(args.audio, args.sample_rate)
    if sr != 16000:
        sys.exit("el audio debe quedar a 16kHz para el VAD")

    recognizer = make_recognizer(model_dir)
    vad = make_vad(vad_model)
    window = vad.config.silero_vad.window_size

    segments = []
    t0 = time.time()
    fed = 0
    pos = 0
    n = len(samples)
    # 1) Alimentar todo el audio en ventanas del VAD
    while pos < n:
        chunk = samples[pos : pos + window]
        pos += len(chunk)
        fed += len(chunk)
        vad.accept_waveform(chunk)
    # 2) Drenar segmentos de voz completos (patrón oficial sherpa-onnx:
    #    empty() es MÉTODO en 1.13.x; front = utterance finalizada de la cola,
    #    FIFO cronológica; is_speech_detected() NO aplica acá)
    vad.flush()
    cursor = 0.0  # la cola es cronológica: timestamps hacia adelante
    while not vad.empty():
        seg = vad.front
        samples_len = len(seg.samples)
        seg_start = cursor
        seg_end = cursor + samples_len / 16000.0
        # ¡pop() VACÍA el buffer zero-copy de seg.samples! Copiar antes de pop.
        seg_data = list(seg.samples)
        vad.pop()
        stream = recognizer.create_stream()
        stream.accept_waveform(16000, seg_data)
        while recognizer.is_ready(stream):
            recognizer.decode_stream(stream)
        text = recognizer.get_result(stream).strip()
        if text:
            segments.append(
                {"start": round(seg_start, 3), "end": round(seg_end, 3), "text": text}
            )
        cursor = seg_end
    # 3) Cola final (tras flush debería estar vacía; por seguridad)
    while not vad.empty():
        vad.pop()

    elapsed = time.time() - t0
    segments.sort(key=lambda s: s["start"])
    result = {
        "engine": "sherpa",
        "model": model_id,
        "language": language,
        "segments": segments,
    }
    with open(args.out, "w") as f:
        json.dump(result, f, ensure_ascii=False, indent=2)
    dur = n / 16000.0
    print(
        f"sherpa {model_id}: {len(segments)} segmentos, "
        f"audio {dur:.1f}s, decode {elapsed:.2f}s (RTF {elapsed / dur:.2f})",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
