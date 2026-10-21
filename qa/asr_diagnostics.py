#!/opt/homebrew/bin/python3
"""Create frozen synthetic channel controls, never a meeting-quality benchmark.

Usage: python qa/asr_diagnostics.py --out NEW_DIRECTORY --known-corpus DIR
Run under resource_guard.py. Existing known WAV/reference are copied unchanged.
References are the TTS input script; only utterance intervals, not word times,
are known. No private microphone or remote-call audio is recorded.
"""
from __future__ import annotations

import argparse
from array import array
from pathlib import Path
import shutil
import subprocess
import wave

from asr_corpora import fresh_directory, sha256, write_json

RATE = 16000


def wav(path: Path, samples: array) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(RATE)
        output.writeframes(samples.tobytes())


def speech(root: Path, name: str, voice: str, text: str) -> array:
    aiff, target = root / (name + ".aiff"), root / (name + ".wav")
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", "125", "-o", str(aiff), text], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", str(aiff), str(target)], check=True)
    with wave.open(str(target), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, RATE):
            raise ValueError("TTS output is not mono Int16 16 kHz")
        return array("h", audio.readframes(audio.getnframes()))


def scaled(samples: array, gain: float, delay: int = 0) -> array:
    return array("h", [0] * delay + [round(value * gain) for value in samples])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--known-corpus", type=Path, required=True)
    args = parser.parse_args()
    # Same admission check as the public-corpus orchestration, no bypass flag.
    import importlib.util
    spec = importlib.util.spec_from_file_location("asr_ab", Path(__file__).with_name("asr-ab.py"))
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    admission = harness._require_guard()
    root = fresh_directory(args.out)
    scripts = {
        "remote": "Sí, confirmo la entrega mañana. No autorizo pagar 120 pesos.",
        "mic": "No, no. El importe es 121 pesos. Dale, revisamos el martes.",
        "answers": "Sí. No. Dale. No, no. Confirmo la entrega mañana.",
    }
    a = speech(root, "remote-paulina", "Paulina", scripts["remote"])
    b = speech(root, "mic-monica", "Mónica", scripts["mic"])
    same_a = speech(root, "answers-paulina", "Paulina", scripts["answers"])
    same_b = speech(root, "answers-monica", "Mónica", scripts["answers"])
    prefix = array("h", [0] * RATE)
    def padded(samples):
        return prefix + samples + prefix
    # Keep system nonzero in voice_soft so the real dual-channel path is used;
    # remote speech ends before soft microphone speech starts.
    soft_remote = padded(a)
    soft_mic = array("h", [0] * len(soft_remote)) + scaled(padded(b), 0.10)
    definitions = [
        ("voice_soft", soft_remote, soft_mic, scripts["remote"], scripts["mic"]),
        ("echo_remote", padded(a), scaled(padded(a), 0.30, RATE // 20), scripts["remote"], ""),
        ("double_talk", padded(a), padded(b), scripts["remote"], scripts["mic"]),
        ("identical_answers", padded(same_a), padded(same_b), scripts["answers"], scripts["answers"]),
        ("silence", array("h", [0] * (30 * RATE)), array("h", [0] * (30 * RATE)), "", ""),
    ]
    cases = []
    for name, left, right, left_ref, right_ref in definitions:
        case = root / name
        case.mkdir(mode=0o700)
        frames = max(len(left), len(right))
        # Explicit construction of controlled conditions, not capture repair.
        left.extend([0] * (frames - len(left)))
        right.extend([0] * (frames - len(right)))
        interleaved = array("h", [0]) * (2 * frames)
        interleaved[0::2], interleaved[1::2] = left, right
        pcm = case / "channels.pcm"
        pcm.write_bytes(interleaved.tobytes())
        wav(case / "remote.wav", left)
        wav(case / "mic.wav", right)
        sidecar = {"schema": "meetcapture.audio.v1", "sample_rate": RATE,
                   "sample_format": "s16le", "channels": 2, "layout": "L=system,R=mic",
                   "tap_strategy": "controlled-synthetic", "tap_info": "Not a live capture"}
        write_json(Path(str(pcm) + ".format.json"), sidecar)
        for channel, reference in (("remote", left_ref), ("mic", right_ref)):
            (case / (channel + ".txt")).write_text(reference + "\n", encoding="utf-8")
        files = sorted(path for path in case.iterdir() if path.is_file())
        cases.append({"id": name, "coverage": [name, "controlled_synthetic", "diagnostic"],
                      "primary_evaluation": False, "duration_seconds": frames / RATE,
                      "frames_per_channel": frames, "channels": 2,
                      "pcm_path": str(pcm), "sample_rate": RATE,
                      "references": {"remote": left_ref, "mic": right_ref},
                      "files": [{"path": str(path), "sha256": sha256(path)} for path in files],
                      "timing_reference": "utterance intervals only; no verified word timings",
                      "group_id": "controlled-tts-one-script", "split": "dev"})
    known = root / "known-regression"
    known.mkdir(mode=0o700)
    for filename in ("corpus.wav", "ref.txt"):
        source = args.known_corpus / filename
        digest = sha256(source)
        shutil.copyfile(source, known / filename)
        if sha256(known / filename) != digest or sha256(source) != digest:
            raise ValueError("known corpus copy changed original content")
    write_json(root / "manifest.json", {"schema_version": 1, "seed": 20261020,
        "source": "macOS local TTS; Paulina and Mónica at 125 words/minute",
        "license": "locally generated diagnostic audio; not redistributed as public corpus",
        "scripts": scripts, "admission": admission, "items": cases,
        "known_corpus": [{"path": str(path), "sha256": sha256(path)} for path in sorted(known.iterdir())],
        "limits": ["Synthetic two-channel controls are not live capture.",
                   "TTS text is not a human-audited meeting reference.",
                   "No candidate outputs consulted; no word timestamps inferred."]})
    print(root / "manifest.json")


if __name__ == "__main__":
    main()
