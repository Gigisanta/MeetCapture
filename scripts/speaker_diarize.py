#!/usr/bin/env python3
"""
speaker_diarize.py — diarización de hablantes con sherpa-onnx.

Uso:
  speaker_diarize.py --audio <wav> [--segments <segments.json>] \
      [--num-speakers N] [--cluster-threshold 0.5] --out <diar.json>

Con --segments (formato de transcribe_sherpa.py): mapea cada segmento ASR a
un hablante por solapamiento temporal mayoritario y emite los mismos segments
con campo "speaker" (A/B/C... por orden de aparición).
Sin --segments: emite {"speakers":N,"segments":[{"start":..,"end":..,"speaker":"A"}]}.

Modelos (en ~/.whisper/models/sherpa/):
  sherpa-onnx-pyannote-segmentation-3-0/model.onnx   (segmentation)
  3dspeaker_speech_eres2net_base_sv_zh-cn_3dspeaker_16k.onnx (embedding)
"""
import argparse
import array
import json
import os
import sys
import wave

import sherpa_onnx

MODELS_DIR = os.path.expanduser("~/.whisper/models/sherpa")
SEG_MODEL = os.path.join(MODELS_DIR, "sherpa-onnx-pyannote-segmentation-3-0", "model.int8.onnx")
EMB_MODEL = os.path.join(MODELS_DIR, "3dspeaker_eres2net.onnx")


def resample_linear(samples, in_rate, out_rate):
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


def read_audio(path):
    with wave.open(path) as f:
        assert f.getnchannels() == 1, "solo mono"
        sr = f.getframerate()
        a = array.array("h")
        a.frombytes(f.readframes(f.getnframes()))
        samples = [x / 32768.0 for x in a]
    return resample_linear(samples, sr, 16000)


def init_diarization(num_speakers, threshold):
    for p, label in ((SEG_MODEL, "segmentation"), (EMB_MODEL, "embedding")):
        if not os.path.isfile(p):
            sys.exit(f"falta el modelo de {label}: {p}")
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=SEG_MODEL
            )
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
            model=EMB_MODEL, num_threads=8, provider="cpu"
        ),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=num_speakers, threshold=threshold
        ),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    if not config.validate():
        sys.exit("config de diarización inválida")
    return sherpa_onnx.OfflineSpeakerDiarization(config)


def overlap(a_start, a_end, b_start, b_end):
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def label_by_appearance(diar_segments):
    """Mapea cluster index -> letra A/B/C por orden de primera aparición."""
    order = []
    for d in diar_segments:
        if d.speaker not in order:
            order.append(d.speaker)
    return {spk: chr(ord("A") + i) for i, spk in enumerate(order)}


def main():
    ap = argparse.ArgumentParser(description="Diarización de hablantes sherpa-onnx")
    ap.add_argument("--audio", required=True, help="wav mono")
    ap.add_argument("--segments", default=None, help="segments.json de transcribe_sherpa.py")
    ap.add_argument("--num-speakers", type=int, default=-1, dest="num_speakers")
    ap.add_argument("--cluster-threshold", type=float, default=0.5, dest="threshold")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    samples = read_audio(args.audio)
    sd = init_diarization(args.num_speakers, args.threshold)
    result = sd.process(samples).sort_by_start_time()

    label = label_by_appearance(result)
    speakers_n = len(label) if label else 0
    diar_segs = [
        {"start": round(r.start, 3), "end": round(r.end, 3), "speaker": label[r.speaker]}
        for r in result
    ]

    if args.segments:
        with open(args.segments) as f:
            asr = json.load(f)
        out_segments = []
        for seg in asr["segments"]:
            best, best_ov = None, 0.0
            for d in diar_segs:
                ov = overlap(seg["start"], seg["end"], d["start"], d["end"])
                if ov > best_ov:
                    best, best_ov = d["speaker"], ov
            out_segments.append(
                {"start": seg["start"], "end": seg["end"], "text": seg["text"],
                 "speaker": best if best else "?"}
            )
        out = {
            "engine": "sherpa",
            "speakers": speakers_n,
            "diarization": diar_segs,
            "segments": out_segments,
        }
    else:
        out = {"speakers": speakers_n, "segments": diar_segs}

    with open(args.out, "w") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
    print(f"{speakers_n} hablante(s), {len(diar_segs)} tramos de diarización -> {args.out}")


if __name__ == "__main__":
    main()
