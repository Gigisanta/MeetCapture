#!/usr/bin/env python3
"""ASR and speaker-attribution evaluation for MeetCapture (plan Fase 3a).

Picks one engine by data before anything is integrated. Every step reads and
writes files under one private evaluation directory (default
``~/HerMaatOS/var/meetcapture-eval``, override with MEETCAPTURE_EVAL_DIR);
nothing here ships meeting audio or text into the repository.

  cut      stereo capture → excerpt dir (excerpt.pcm, L.wav, R.wav, mix.wav)
  gate     bleed gate on R: mute windows that correlate with L → R_gated.wav
  vocab    write the custom-vocabulary file used by Parakeet
  run      one engine on one WAV → hyp JSON with wall time, peak RSS, GPU use
  compose  L/R (and diarization) hyps → one speaker-labelled transcript
  score    reference vs composed transcript → WER, CER, keywords, numbers,
           speaker attribution
  table    score JSONs → Markdown table
  selftest metrics and gate on the synthetic fixture (no audio, no models)

Reference format (``ref.json``)::

  {"turns": [{"speaker": "Gio"|"P1"|..., "start": s, "end": s, "text": "..."}]}
  (speaker "P2?" = unsure who spoke: kept for WER, left out of attribution)

Text inside ``[? ... ?]`` is the best guess for a span nobody could verify;
``wer_certain`` leaves those words out.

Exit codes: 0 ok, 1 selftest/score failure, 2 bad input, 75 the local LLM
gateway is busy (wait and retry, as resource_guard does).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata
import urllib.request
import wave
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

import numpy as np

SAMPLE_RATE = 16_000
REPO_ROOT = Path(__file__).resolve().parent.parent
FIXTURE = REPO_ROOT / "qa" / "fixtures" / "asr_eval_synthetic.json"
FLUID_EVAL = REPO_ROOT / "qa" / "fluid-eval" / ".build" / "release" / "fluid-eval"
EVAL_DIR = Path(os.environ.get("MEETCAPTURE_EVAL_DIR", Path.home() / "HerMaatOS" / "var" / "meetcapture-eval"))
WHISPER_MODELS = Path.home() / ".whisper" / "models"
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
WHISPERKIT_CLI = "/opt/homebrew/bin/whisperkit-cli"
APP_CONFIG = Path.home() / ".meetcapture" / "config.json"
GATEWAY_HOLD_URL = "http://127.0.0.1:8080/admin/gpu_hold"
WHISPER_THREADS = max(4, min(8, os.cpu_count() or 4))  # WhisperModels.threads

# Finance jargon the transcripts must get right. Patterns run on normalized
# text (lowercase, no accents, acronym dots removed, numbers as digits).
KEYWORDS: Dict[str, str] = {
    "AppSheet": r"\bapp ?sheets?\b",
    "estado de resultados": r"\bestados? de resultados?\b",
    "palos": r"\bpalos?\b",
    "CEDEAR": r"\bcedears?\b",
    "FCI": r"\bfcis?\b",
    "caución": r"\bcaucion(?:es)?\b",
    "MEP": r"\bmep\b",
    "CCL": r"\bccl\b",
    "Cactus Wealth": r"\bcactus(?: wealth)?\b",
    "Balanz": r"\bbalanz\b",
    "plazo fijo": r"\bplazos? fijos?\b",
    "bono": r"\bbonos?\b",
    "dólar": r"\bdolar(?:es)?\b",
    "cartera": r"\bcarteras?\b",
    "rendimiento": r"\brendimientos?\b",
    "renta fija": r"\brenta fija\b",
    "acciones": r"\bacciones\b",
    "inversión": r"\binversion(?:es)?\b",
    "comitente": r"\bcomitentes?\b",
    "Excel": r"\bexcel\b",
}

# Spelling the Parakeet vocabulary booster should prefer (term: aliases).
VOCABULARY = [
    "AppSheet: app sheet, apshit",
    "CEDEAR: cedear, sedear, cedears",
    "FCI",
    "MEP",
    "CCL",
    "caución: caucion",
    "Cactus Wealth",
    "Balanz: balance",
    "estado de resultados",
    "comitente",
]

FILLERS = {"eh", "ehh", "ehm", "em", "mm", "mmm", "hmm", "ah", "aja", "uh", "um", "mhm"}
GIO = "Gio"


# ---------------------------------------------------------------- audio io --

def read_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as source:
        if (source.getnchannels(), source.getsampwidth(), source.getframerate()) != (1, 2, SAMPLE_RATE):
            raise SystemExit(f"{path}: se espera WAV mono 16 kHz Int16")
        return np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").copy()


def write_wav(path: Path, samples: np.ndarray) -> None:
    tmp = path.with_suffix(".tmp")
    with wave.open(str(tmp), "wb") as sink:
        sink.setnchannels(1)
        sink.setsampwidth(2)
        sink.setframerate(SAMPLE_RATE)
        sink.writeframes(np.asarray(samples, dtype="<i2").tobytes())
    os.replace(tmp, path)


def private_dir(path: Path) -> Path:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def cmd_cut(args: argparse.Namespace) -> int:
    source = Path(args.pcm)
    sidecar = Path(str(source) + ".format.json")
    layout = json.loads(sidecar.read_text()) if sidecar.exists() else {}
    if layout.get("channels", 2) != 2 or layout.get("sample_format", "s16le") != "s16le" \
            or layout.get("sample_rate", SAMPLE_RATE) != SAMPLE_RATE:
        raise SystemExit(f"{source}: se espera PCM s16le estéreo 16 kHz")
    frames = np.memmap(source, dtype="<i2", mode="r")
    frames = frames[: len(frames) // 2 * 2].reshape(-1, 2)
    first = int(args.start * SAMPLE_RATE)
    last = min(len(frames), first + int(args.dur * SAMPLE_RATE))
    if first >= last:
        raise SystemExit("el recorte queda vacío")
    excerpt = np.array(frames[first:last])
    out = private_dir(Path(args.out))
    excerpt.tofile(out / "excerpt.pcm")
    left, right = excerpt[:, 0], excerpt[:, 1]
    write_wav(out / "L.wav", left)
    write_wav(out / "R.wav", right)
    # Same mix as PCMToWAV.mix: sum with clamp.
    write_wav(out / "mix.wav", np.clip(left.astype(np.int32) + right.astype(np.int32), -32768, 32767))
    meta = {
        "source": source.name,
        "start_s": args.start,
        "duration_s": round((last - first) / SAMPLE_RATE, 3),
        "layout": layout.get("layout", "L=system,R=mic"),
        "r_silent": bool(np.abs(right).max() < 64),
    }
    (out / "meta.json").write_text(json.dumps(meta, indent=2))
    for name in ("excerpt.pcm", "L.wav", "R.wav", "mix.wav", "meta.json"):
        os.chmod(out / name, 0o600)
    print(json.dumps(meta))
    return 0


# -------------------------------------------------------------- bleed gate --

# Calibrated on two real calls (Mac speakers): bleed windows have NCC p50 ~0.65
# and R-L between -7 and +5 dB, so 0.6 let half of them through; 0.4 mutes
# them and keeps >95% of Gio's own words. Dominance barely matters above 6 dB.
GATE_CORR = 0.4
GATE_DOMINANCE_DB = 10.0

def bandpass(signal: np.ndarray, low: float = 200.0, high: float = 4000.0) -> np.ndarray:
    spectrum = np.fft.rfft(signal.astype(np.float64))
    freqs = np.fft.rfftfreq(len(signal), 1.0 / SAMPLE_RATE)
    spectrum[(freqs < low) | (freqs > high)] = 0
    return np.fft.irfft(spectrum, len(signal))


def gate_windows(left: np.ndarray, right: np.ndarray, window_s: float = 0.5,
                 max_lag_ms: float = 100.0) -> List[Dict[str, float]]:
    """Per window: peak |normalized cross-correlation| of R against L delayed
    0..max_lag (bleed reaches the mic after the speaker plays it) and both
    levels in dBFS."""
    size = int(window_s * SAMPLE_RATE)
    max_lag = int(max_lag_ms * SAMPLE_RATE / 1000)
    lf, rf = bandpass(left), bandpass(right)
    nfft = 1 << int(np.ceil(np.log2(size + max_lag + size)))
    rows = []
    for index in range(len(right) // size):
        start = index * size
        r = rf[start:start + size]
        lo = max(0, start - max_lag)
        l = lf[lo:start + size]
        pad = max_lag - (start - lo)
        if pad:
            l = np.concatenate([np.zeros(pad), l])
        # c[k] = sum_n l[k+n] r[n]; lag d = max_lag - k.
        corr = np.fft.irfft(np.fft.rfft(l, nfft) * np.conj(np.fft.rfft(r, nfft)), nfft)[: max_lag + 1]
        energy = np.concatenate([[0.0], np.cumsum(l * l)])
        l_norm = np.sqrt(energy[size:size + max_lag + 1] - energy[: max_lag + 1])
        r_norm = np.sqrt(float(np.dot(r, r)))
        denom = l_norm * r_norm
        ncc = np.divide(np.abs(corr), denom, out=np.zeros_like(corr), where=denom > 1e-9)
        best = int(np.argmax(ncc))
        raw_r = right[start:start + size].astype(np.float64)
        raw_l = left[start:start + size].astype(np.float64)
        rows.append({
            "t": start / SAMPLE_RATE,
            "ncc": float(ncc[best]),
            "lag_ms": (max_lag - best) * 1000.0 / SAMPLE_RATE,
            "r_db": float(20 * np.log10(np.sqrt(np.mean(raw_r ** 2)) / 32768 + 1e-9)),
            "l_db": float(20 * np.log10(np.sqrt(np.mean(raw_l ** 2)) / 32768 + 1e-9)),
        })
    return rows


def gate_mask(rows: Sequence[Dict[str, float]], corr: float, dominance_db: float,
              silence_db: float = -55.0) -> List[bool]:
    """True = mute. Bleed: R follows L closely and is not clearly louder."""
    return [
        row["l_db"] > silence_db and row["ncc"] > corr and row["r_db"] - row["l_db"] < dominance_db
        for row in rows
    ]


def apply_gate(right: np.ndarray, mask: Sequence[bool], window_s: float = 0.5) -> np.ndarray:
    size = int(window_s * SAMPLE_RATE)
    gated = right.copy()
    for index, mute in enumerate(mask):
        if mute:
            gated[index * size:(index + 1) * size] = 0
    return gated


def cmd_gate(args: argparse.Namespace) -> int:
    directory = Path(args.dir)
    left, right = read_wav(directory / "L.wav"), read_wav(directory / "R.wav")
    cache = directory / f"gate_windows_{args.window}_{args.max_lag_ms}.json"
    if cache.exists():
        rows = json.loads(cache.read_text())
    else:
        rows = gate_windows(left, right, args.window, args.max_lag_ms)
        cache.write_text(json.dumps(rows))
        os.chmod(cache, 0o600)
    mask = gate_mask(rows, args.corr, args.dominance_db)
    out = directory / (args.out or f"R_gated_c{args.corr}_d{args.dominance_db}.wav")
    write_wav(out, apply_gate(right, mask, args.window))
    os.chmod(out, 0o600)
    stats = {
        "out": out.name, "corr": args.corr, "dominance_db": args.dominance_db,
        "windows": len(mask), "muted": sum(mask),
        "muted_fraction": round(sum(mask) / max(1, len(mask)), 4),
        "ncc_p50": round(float(np.median([r["ncc"] for r in rows])), 3),
        "ncc_p90": round(float(np.percentile([r["ncc"] for r in rows], 90)), 3),
    }
    print(json.dumps(stats))
    return 0


def cmd_vocab(args: argparse.Namespace) -> int:
    out = Path(args.out)
    out.write_text("\n".join(VOCABULARY) + "\n")
    print(out)
    return 0


# ------------------------------------------------------------------ engines --

def app_prompt() -> str:
    """The prompt the installed app passes to whisper-cli (config.json)."""
    try:
        prompt = json.loads(APP_CONFIG.read_text()).get("domainPrompt")
    except (OSError, ValueError):
        prompt = None
    if not prompt:
        raise SystemExit(f"falta domainPrompt en {APP_CONFIG}; pasá --prompt-file")
    return prompt


def whisper_command(model: str, wav: Path, work: Path, prompt: str) -> Tuple[List[str], Path]:
    stem = work / "out"
    command = [
        WHISPER_CLI, "-m", str(WHISPER_MODELS / model), "-f", str(wav), "-l", "es",
        "-oj", "-of", str(stem), "-t", str(WHISPER_THREADS), "--prompt", prompt,
        "--suppress-nst", "--no-prints",
        "--vad", "--vad-model", str(WHISPER_MODELS / "ggml-silero-v5.1.2.bin"),
    ]
    return command, stem.with_suffix(".json")


def parse_whisper(path: Path) -> List[Dict[str, Any]]:
    data = json.loads(path.read_text())
    return [
        {"start": item["offsets"]["from"] / 1000, "end": item["offsets"]["to"] / 1000, "text": item["text"].strip()}
        for item in data.get("transcription", []) if item.get("text", "").strip()
    ]


def parse_whisperkit(report_dir: Path) -> List[Dict[str, Any]]:
    reports = sorted(report_dir.glob("*.json"))
    if not reports:
        raise RuntimeError("whisperkit-cli no escribió reporte JSON")
    data = json.loads(reports[0].read_text())
    segments = data.get("segments") or data.get("transcription", {}).get("segments") or []
    clean = re.compile(r"<\|[^|]*\|>")
    return [
        {"start": float(s["start"]), "end": float(s["end"]), "text": clean.sub("", s["text"]).strip()}
        for s in segments if clean.sub("", s.get("text", "")).strip()
    ]


def engine_spec(engine: str, wav: Path, work: Path, prompt: str, extra: Sequence[str]):
    """→ (command, parser). The parser reads the engine's own output."""
    if engine in ("whisper-medium", "whisper-turbo", "whisper-v3"):
        model = {
            "whisper-medium": "ggml-medium-q5_0.bin",
            "whisper-turbo": "ggml-large-v3-turbo-q8_0.bin",
            "whisper-v3": "ggml-large-v3-q5_0.bin",
        }[engine]
        command, output = whisper_command(model, wav, work, prompt)
        return command + list(extra), lambda: parse_whisper(output)
    if engine == "whisperkit-turbo":
        command = [
            WHISPERKIT_CLI, "transcribe", "--audio-path", str(wav),
            "--model", "large-v3-v20240930_turbo",
            "--download-model-path", str(EVAL_DIR / "models" / "whisperkit"),
            "--download-tokenizer-path", str(EVAL_DIR / "models" / "whisperkit-tokenizers"),
            "--language", "es", "--prompt", prompt, "--report", "--report-path", str(work),
        ]
        return command + list(extra), lambda: parse_whisperkit(work)
    match = re.fullmatch(r"parakeet-(v3|ultra)(-vocab)?", engine)
    if match:
        output = work / "out.json"
        command = [str(FLUID_EVAL), "asr", "--wav", str(wav), "--out", str(output), "--model", match.group(1)]
        if match.group(2):
            command += ["--vocab", str(EVAL_DIR / "vocab.txt")]
        return command + list(extra), lambda: json.loads(output.read_text())["segments"]
    if engine == "fluid-diarize":
        output = work / "out.json"
        command = [str(FLUID_EVAL), "diarize", "--wav", str(wav), "--out", str(output)]
        return command + list(extra), lambda: json.loads(output.read_text())["segments"]
    raise SystemExit(f"motor desconocido: {engine}")


def gateway_busy() -> Optional[str]:
    """Why Simón's gateway is busy, or None when idle/unreachable."""
    try:
        with urllib.request.urlopen(GATEWAY_HOLD_URL, timeout=3) as response:
            state = json.load(response).get("gpu_turns", {})
    except (OSError, ValueError):
        return None
    # resource_guard --class gpu-heavy takes the hold for us; only someone
    # else's hold or a running/waiting turn means busy.
    own_hold = str(state.get("hold_who") or "").startswith(f"resource_guard_{os.getppid()}_")
    if state.get("active") or state.get("waiting") or (state.get("hold_s") and not own_hold):
        return f"active={state.get('active')} waiting={state.get('waiting')} hold={state.get('hold_who')}"
    return None


class GpuSampler(threading.Thread):
    """Samples IOAccelerator 'Device Utilization %' (all GPU clients; no ANE
    counter is readable without sudo)."""

    pattern = re.compile(rb'"Device Utilization %"=(\d+)')

    def __init__(self, period: float = 0.5) -> None:
        super().__init__(daemon=True)
        self.period, self.samples, self.done = period, [], threading.Event()

    def run(self) -> None:
        while not self.done.is_set():
            try:
                out = subprocess.run(["ioreg", "-r", "-d", "1", "-c", "IOAccelerator"],
                                     capture_output=True, timeout=5).stdout
                found = self.pattern.search(out)
                if found:
                    self.samples.append(int(found.group(1)))
            except (OSError, subprocess.SubprocessError):
                pass
            self.done.wait(self.period)


def wav_seconds(path: Path) -> float:
    with wave.open(str(path), "rb") as source:
        return source.getnframes() / source.getframerate()


def cmd_run(args: argparse.Namespace) -> int:
    wav, out = Path(args.wav), Path(args.out)
    deadline = time.monotonic() + args.wait
    while (busy := gateway_busy()) is not None:
        if time.monotonic() > deadline:
            print(f"asr_eval: gateway ocupado ({busy}); reintentar más tarde", file=sys.stderr)
            return 75
        time.sleep(15)
    prompt = Path(args.prompt_file).read_text().strip() if args.prompt_file else app_prompt()
    with tempfile.TemporaryDirectory(prefix="asr_eval.", dir=private_dir(EVAL_DIR / "tmp")) as tmp:
        work = Path(tmp)
        command, parse = engine_spec(args.engine, wav, work, prompt, args.extra)
        idle = GpuSampler()
        idle.start()
        time.sleep(2)
        idle.done.set()
        idle.join()
        sampler = GpuSampler()
        sampler.start()
        started = time.monotonic()
        proc = subprocess.run(["/usr/bin/time", "-l", *command], capture_output=True, text=True)
        wall = time.monotonic() - started
        sampler.done.set()
        sampler.join()
        log = out.with_suffix(".log")
        log.write_text(proc.stdout[-20000:] + "\n--- stderr ---\n" + proc.stderr[-20000:])
        os.chmod(log, 0o600)
        if proc.returncode != 0:
            print(f"asr_eval: {args.engine} terminó con {proc.returncode}; ver {log}", file=sys.stderr)
            return 1
        rss = re.search(r"(\d+)\s+maximum resident set size", proc.stderr)
        segments = parse()
    audio = wav_seconds(wav)
    result = {
        "engine": args.engine,
        "wav": wav.name,
        "segments": segments,
        "metrics": {
            "wall_s": round(wall, 2),
            "audio_s": round(audio, 2),
            "rtf": round(wall / audio, 4),
            "rss_mb": round(int(rss.group(1)) / 2 ** 20, 1) if rss else None,
            "gpu_util_mean": round(float(np.mean(sampler.samples)), 1) if sampler.samples else None,
            "gpu_util_max": max(sampler.samples) if sampler.samples else None,
            "gpu_util_idle_before": round(float(np.mean(idle.samples)), 1) if idle.samples else None,
            "contended": gateway_busy() is not None,
        },
    }
    out.write_text(json.dumps(result, ensure_ascii=False, indent=1))
    os.chmod(out, 0o600)
    print(json.dumps({"engine": args.engine, "wav": wav.name, **result["metrics"]}))
    return 0


# ------------------------------------------------------------------ compose --

def speaker_at(turns: Sequence[Dict[str, Any]], t: float) -> Optional[str]:
    best, distance = None, 1e9
    for turn in turns:
        if turn["start"] <= t <= turn["end"]:
            return turn["speaker"]
        gap = min(abs(turn["start"] - t), abs(turn["end"] - t))
        if gap < distance:
            best, distance = turn["speaker"], gap
    return best if distance <= 1.0 else None


def label_by_diarization(segments: Sequence[Dict[str, Any]], diarization: Sequence[Dict[str, Any]],
                         fallback: str) -> List[Dict[str, Any]]:
    """Split each segment's words (times interpolated uniformly) by the
    diarization speaker active at each word, so coarse ASR segments are not
    favoured or punished against fine ones."""
    names: Dict[str, str] = {}
    for turn in sorted(diarization, key=lambda d: d["start"]):
        names.setdefault(turn["speaker"], f"P{len(names) + 1}")
    turns = [{**d, "speaker": names[d["speaker"]]} for d in diarization]
    labelled = []
    for segment in segments:
        words = segment["text"].split()
        if not words:
            continue
        step = (segment["end"] - segment["start"]) / len(words)
        run: List[str] = []
        current = None
        run_start = segment["start"]
        for index, word in enumerate(words):
            t = segment["start"] + (index + 0.5) * step
            speaker = speaker_at(turns, t) or fallback
            if run and speaker != current:
                labelled.append({"start": run_start, "end": t, "text": " ".join(run), "speaker": current})
                run, run_start = [], t
            run.append(word)
            current = speaker
        labelled.append({"start": run_start, "end": segment["end"], "text": " ".join(run), "speaker": current})
    return labelled


def cmd_compose(args: argparse.Namespace) -> int:
    def load(path: Optional[str]) -> Optional[Dict[str, Any]]:
        return json.loads(Path(path).read_text()) if path else None

    mono, left, right, dia = load(args.mono), load(args.L), load(args.R), load(args.dia)
    segments: List[Dict[str, Any]] = []
    parts: List[str] = []
    if mono:
        segments += [{**s, "speaker": s.get("speaker")} for s in mono["segments"]]
        parts.append(mono["engine"] + ":mono")
    if left:
        if dia:
            segments += label_by_diarization(left["segments"], dia["segments"], "Remote")
        else:
            segments += [{**s, "speaker": "Remote"} for s in left["segments"]]
        parts.append(left["engine"] + ":" + left["wav"] + ("+dia" if dia else ""))
    if right:
        segments += [{**s, "speaker": GIO} for s in right["segments"]]
        parts.append(right["engine"] + ":" + right["wav"])
    segments.sort(key=lambda s: s["start"])
    metrics = [m for m in (mono, left, right, dia) if m]
    audio = max(m["metrics"]["audio_s"] for m in metrics)
    # Channels run one after another, so wall time adds up; RSS is the peak.
    combined = {
        "wall_s": round(sum(m["metrics"]["wall_s"] for m in metrics), 2),
        "audio_s": audio,
        "rss_mb": max((m["metrics"]["rss_mb"] or 0) for m in metrics),
        "gpu_util_mean": max((m["metrics"]["gpu_util_mean"] or 0) for m in metrics),
        "contended": any(m["metrics"].get("contended") for m in metrics),
    }
    combined["rtf"] = round(combined["wall_s"] / audio, 4)
    out = Path(args.out)
    out.write_text(json.dumps({"engine": " + ".join(parts), "segments": segments, "metrics": combined},
                              ensure_ascii=False, indent=1))
    os.chmod(out, 0o600)
    return 0


# -------------------------------------------------------------------- score --

UNCERTAIN = re.compile(r"\[\?(.*?)\?\]", re.S)


def normalize(text: str) -> List[str]:
    from text_to_num import alpha2digit  # lazy: only scoring needs it

    text = text.lower().replace("%", " por ciento ")
    text = re.sub(r"(?<=\w)\.(?=\w)", "", text)          # F.C.I. / 5.000
    text = unicodedata.normalize("NFKD", text)
    text = "".join(c for c in text if not unicodedata.combining(c))
    text = re.sub(r"[^\w\s]", " ", text)
    # alpha2digit reads the articles "unos/unas" as 1.
    text = re.sub(r"\b(un)(os|as)\b", r"\1_\2", text)
    text = alpha2digit(text, "es").replace("_", "")
    words = [w for w in text.split() if w not in FILLERS]
    return words


def ref_words(ref: Dict[str, Any]) -> Tuple[List[str], List[str], List[bool]]:
    words, speakers, uncertain = [], [], []
    for turn in sorted(ref["turns"], key=lambda t: t["start"]):
        position = 0
        text = turn["text"]
        for match in list(UNCERTAIN.finditer(text)) + [None]:
            end = match.start() if match else len(text)
            for piece, flag in ((text[position:end], False), (match.group(1) if match else "", True)):
                for word in normalize(piece):
                    words.append(word)
                    speakers.append(turn["speaker"])
                    uncertain.append(flag)
            position = match.end() if match else len(text)
    return words, speakers, uncertain


def hyp_words(hyp: Dict[str, Any]) -> Tuple[List[str], List[Optional[str]]]:
    words, speakers = [], []
    for segment in sorted(hyp["segments"], key=lambda s: s["start"]):
        for word in normalize(segment.get("text", "")):
            words.append(word)
            speakers.append(segment.get("speaker"))
    return words, speakers


def keyword_counts(words: Sequence[str]) -> Dict[str, int]:
    text = " ".join(words)
    return {label: len(re.findall(pattern, text)) for label, pattern in KEYWORDS.items()}


def score(ref: Dict[str, Any], hyp: Dict[str, Any]) -> Dict[str, Any]:
    import jiwer

    rw, rs, ru = ref_words(ref)
    hw, hs = hyp_words(hyp)
    if not rw:
        raise SystemExit("referencia vacía")
    alignment = jiwer.process_words(" ".join(rw), " ".join(hw) or "∅")
    hw_aligned = hw or ["∅"]
    errors = errors_certain = 0
    pairs: List[Tuple[str, Optional[str]]] = []
    for chunk in alignment.alignments[0]:
        span = range(chunk.ref_start_idx, chunk.ref_end_idx)
        if chunk.type == "equal":
            pairs += [(rs[i], hs[j]) for i, j in zip(span, range(chunk.hyp_start_idx, chunk.hyp_end_idx))]
            continue
        if chunk.type == "substitute":
            pairs += [(rs[i], hs[j]) for i, j in zip(span, range(chunk.hyp_start_idx, chunk.hyp_end_idx))]
        if chunk.type in ("substitute", "delete"):
            errors += len(span)
            errors_certain += sum(1 for i in span if not ru[i])
        if chunk.type == "insert":
            count = chunk.hyp_end_idx - chunk.hyp_start_idx
            errors += count
            near = [i for i in (chunk.ref_start_idx - 1, chunk.ref_start_idx) if 0 <= i < len(ru)]
            if not any(ru[i] for i in near):
                errors_certain += count
    certain = sum(1 for flag in ru if not flag)

    ref_kw, hyp_kw = keyword_counts(rw), keyword_counts(hw)
    kw_total = sum(ref_kw.values())
    kw_hit = sum(min(ref_kw[k], hyp_kw[k]) for k in KEYWORDS)
    kw_false = sum(max(0, hyp_kw[k] - ref_kw[k]) for k in KEYWORDS)
    ref_num = Counter(w for w in rw if w.isdigit())
    hyp_num = Counter(w for w in hw if w.isdigit())
    num_total = sum(ref_num.values())

    result: Dict[str, Any] = {
        "engine": hyp.get("engine"),
        "ref_words": len(rw),
        "uncertain_fraction": round(1 - certain / len(rw), 4),
        "wer": round(errors / len(rw), 4),
        "wer_certain": round(errors_certain / max(1, certain), 4),
        "substitutions": alignment.substitutions,
        "deletions": alignment.deletions,
        "insertions": alignment.insertions,
        "cer": round(jiwer.cer(" ".join(rw), " ".join(hw_aligned)), 4),
        "keyword_recall": round(kw_hit / kw_total, 4) if kw_total else None,
        "keyword_false": kw_false,
        "keywords": {k: [ref_kw[k], hyp_kw[k]] for k in KEYWORDS if ref_kw[k] or hyp_kw[k]},
        "number_recall": round(sum((ref_num & hyp_num).values()) / num_total, 4) if num_total else None,
        "numbers_ref": num_total,
        "metrics": hyp.get("metrics", {}),
    }
    result.update(speaker_metrics(pairs))
    result.update(split_wer(rw, rs, hw, hs))
    return result


def split_wer(rw: Sequence[str], rs: Sequence[str], hw: Sequence[str],
              hs: Sequence[Optional[str]]) -> Dict[str, Any]:
    """WER per side (Gio vs remotes), scored separately.

    Channel pipelines merge L and R by segment start; a coarse segment that
    spans several turns lands out of order and plain WER counts it twice (a
    deletion and an insertion). Scoring each side against its own words
    measures recognition and bleed without that merge artifact.
    """
    import jiwer

    if not any(hs):
        return {"wer_split": None, "wer_gio": None, "wer_remote": None}
    out: Dict[str, Any] = {}
    errors = 0
    for side, is_side in (("gio", lambda s: s == GIO), ("remote", lambda s: s != GIO)):
        ref = [w for w, s in zip(rw, rs) if is_side(s.rstrip("?"))]
        hyp = [w for w, s in zip(hw, hs) if s is not None and is_side(s)]
        if not ref:
            out[f"wer_{side}"] = None
            errors += len(hyp)
            continue
        a = jiwer.process_words(" ".join(ref), " ".join(hyp) or "∅")
        side_errors = a.substitutions + a.deletions + a.insertions
        errors += side_errors
        out[f"wer_{side}"] = round(side_errors / len(ref), 4)
    out["wer_split"] = round(errors / len(rw), 4)
    return out


def speaker_metrics(pairs: Sequence[Tuple[str, Optional[str]]]) -> Dict[str, Any]:
    # A reference speaker ending in "?" is a guess; it counts for WER, not for attribution.
    labelled = [(r, h) for r, h in pairs if h is not None and not r.endswith("?")]
    if not labelled:
        return {"gio_attribution": None, "gio_precision": None, "remote_purity": None,
                "remote_purity_min": None, "hyp_speakers": 0}
    gio_ref = [h for r, h in labelled if r == GIO]
    gio_hyp = [r for r, h in labelled if h == GIO]
    clusters: Dict[str, Counter] = defaultdict(Counter)
    for r, h in labelled:
        if h != GIO:
            clusters[h][r] += 1
    total = sum(sum(c.values()) for c in clusters.values())
    purities = {h: c.most_common(1)[0][1] / sum(c.values()) for h, c in clusters.items()}
    big = [p for h, p in purities.items() if sum(clusters[h].values()) >= 20]
    ref_remote = Counter(r for r, _ in labelled if r != GIO)
    coverage = {}
    for speaker in ref_remote:
        best = max((c[speaker] for c in clusters.values()), default=0)
        coverage[speaker] = round(best / ref_remote[speaker], 3)
    return {
        "gio_attribution": round(sum(1 for h in gio_ref if h == GIO) / len(gio_ref), 4) if gio_ref else None,
        "gio_precision": round(sum(1 for r in gio_hyp if r == GIO) / len(gio_hyp), 4) if gio_hyp else None,
        "remote_purity": round(sum(c.most_common(1)[0][1] for c in clusters.values()) / total, 4) if total else None,
        "remote_purity_min": round(min(big), 4) if big else None,
        "remote_coverage": coverage,
        "hyp_speakers": len(clusters) + (1 if gio_hyp else 0),
        "clusters": {h: dict(c) for h, c in clusters.items()},
    }


def cmd_score(args: argparse.Namespace) -> int:
    result = score(json.loads(Path(args.ref).read_text()), json.loads(Path(args.hyp).read_text()))
    result["ref"], result["hyp"] = Path(args.ref).parent.name, Path(args.hyp).name
    if args.json:
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=1))
        os.chmod(args.json, 0o600)
    brief = {k: v for k, v in result.items() if k not in ("keywords", "clusters", "metrics")}
    print(json.dumps(brief, ensure_ascii=False))
    return 0


def fmt(value: Any, pct: bool = False) -> str:
    if value is None:
        return "—"
    return f"{100 * value:.1f}" if pct else f"{value}"


def cmd_table(args: argparse.Namespace) -> int:
    rows = [json.loads(Path(p).read_text()) for p in args.scores]
    print("| excerpt | pipeline | WER % | WER cert % | WER split % | Gio WER % | remote WER % | CER % | kw % "
          "| num % | Gio attr % | Gio prec % | purity % | spk | RTF | RSS MB | GPU % |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in rows:
        m = r.get("metrics", {})
        print(f"| {r.get('ref')} | {r.get('label') or r.get('engine')} | {fmt(r['wer'], 1)} | "
              f"{fmt(r['wer_certain'], 1)} | {fmt(r.get('wer_split'), 1)} | {fmt(r.get('wer_gio'), 1)} | "
              f"{fmt(r.get('wer_remote'), 1)} | {fmt(r['cer'], 1)} | {fmt(r['keyword_recall'], 1)} | "
              f"{fmt(r['number_recall'], 1)} | {fmt(r['gio_attribution'], 1)} | {fmt(r['gio_precision'], 1)} | "
              f"{fmt(r['remote_purity'], 1)} | {r['hyp_speakers']} | {fmt(m.get('rtf'))} | "
              f"{fmt(m.get('rss_mb'))} | {fmt(m.get('gpu_util_mean'))} |")
    return 0


# ----------------------------------------------------------------- selftest --

def cmd_selftest(_: argparse.Namespace) -> int:
    fixture = json.loads(FIXTURE.read_text())
    failures = []
    for case in fixture["cases"]:
        got = score(fixture["ref"], case["hyp"])
        for key, want in case["expect"].items():
            if got.get(key) != want:
                failures.append(f"{case['name']}: {key}={got.get(key)!r}, se esperaba {want!r}")

    # Gate: L is a noise-modulated tone; R = L delayed 30 ms at -10 dB in the
    # first half (bleed), an unrelated signal at +8 dB in the second (Gio).
    rng = np.random.default_rng(7)
    n = 4 * SAMPLE_RATE
    left = (rng.standard_normal(n) * 3000).astype(np.int16)
    delay = int(0.030 * SAMPLE_RATE)
    right = np.zeros(n, dtype=np.int16)
    half = n // 2
    right[delay:half] = (left[: half - delay] * 0.32).astype(np.int16)
    right[half:] = (rng.standard_normal(n - half) * 7500).astype(np.int16)
    rows = gate_windows(left, right)
    mask = gate_mask(rows, corr=GATE_CORR, dominance_db=GATE_DOMINANCE_DB)
    want = [True] * 4 + [False] * 4
    if mask != want:
        failures.append(f"gate: mask={mask}, se esperaba {want}")
    lags = [round(r["lag_ms"]) for r in rows[1:4]]
    if lags != [30, 30, 30]:
        failures.append(f"gate: lag_ms={lags}, se esperaba 30")

    for failure in failures:
        print("FAIL", failure)
    print("selftest:", "ok" if not failures else f"{len(failures)} fallas")
    return 1 if failures else 0


# --------------------------------------------------------------------- main --

def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("cut")
    p.add_argument("--pcm", required=True)
    p.add_argument("--start", type=float, required=True)
    p.add_argument("--dur", type=float, default=600.0)
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_cut)

    p = sub.add_parser("gate")
    p.add_argument("--dir", required=True)
    p.add_argument("--corr", type=float, default=GATE_CORR)
    p.add_argument("--dominance-db", type=float, default=GATE_DOMINANCE_DB)
    p.add_argument("--window", type=float, default=0.5)
    p.add_argument("--max-lag-ms", type=float, default=100.0)
    p.add_argument("--out")
    p.set_defaults(func=cmd_gate)

    p = sub.add_parser("vocab")
    p.add_argument("--out", default=str(EVAL_DIR / "vocab.txt"))
    p.set_defaults(func=cmd_vocab)

    p = sub.add_parser("run")
    p.add_argument("--engine", required=True)
    p.add_argument("--wav", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--prompt-file")
    p.add_argument("--wait", type=float, default=1800.0, help="segundos máximos esperando al gateway")
    p.add_argument("extra", nargs="*", help="argumentos extra para el motor (tras --)")
    p.set_defaults(func=cmd_run)

    p = sub.add_parser("compose")
    p.add_argument("--mono")
    p.add_argument("--L")
    p.add_argument("--R")
    p.add_argument("--dia")
    p.add_argument("--out", required=True)
    p.set_defaults(func=cmd_compose)

    p = sub.add_parser("score")
    p.add_argument("--ref", required=True)
    p.add_argument("--hyp", required=True)
    p.add_argument("--json")
    p.set_defaults(func=cmd_score)

    p = sub.add_parser("table")
    p.add_argument("scores", nargs="+")
    p.set_defaults(func=cmd_table)

    p = sub.add_parser("selftest")
    p.set_defaults(func=cmd_selftest)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
