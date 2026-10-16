#!/usr/bin/env python3
"""Run a bounded, local-only sherpa-onnx ASR acceptance check.

This check deliberately invokes the shipped sherpa scripts with the local
models and a real ``sherpa_onnx`` installation. It does not mock a
recognizer, download a model, inspect private configuration, or contact a
service. Every generated artifact and process log is kept under a unique
temporary directory so a failed run can be inspected afterwards.

Exit codes:
  0  all real-session, silence, streaming, and diarization checks pass
  1  the real scripts ran but a product/acceptance check failed
  2  a local prerequisite is missing or unusable
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


SAMPLE_RATE = 16_000
STREAM_CHUNK_SAMPLES = 1_600  # 100 ms, the production script default
DEFAULT_TIMEOUT_SECONDS = 120.0
MIN_PYTHON = (3, 9)

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
TRANSCRIBE_SCRIPT = REPO_ROOT / "scripts" / "transcribe_sherpa.py"
STREAM_SCRIPT = REPO_ROOT / "scripts" / "meetcapture_stream_asr.py"
DIARIZE_SCRIPT = REPO_ROOT / "scripts" / "speaker_diarize.py"
SHERPA_SCRIPTS_SWIFT = REPO_ROOT / "Sources" / "MeetCaptureCore" / "ASR" / "SherpaScripts.swift"
SETTINGS_SWIFT = REPO_ROOT / "Sources" / "MeetCaptureCore" / "Settings" / "Settings.swift"
APP_STATE_SWIFT = REPO_ROOT / "Sources" / "MeetCaptureCore" / "App" / "AppState.swift"
TRANSCRIPTION_JOB_SWIFT = REPO_ROOT / "Sources" / "MeetCaptureCore" / "ASR" / "TranscriptionJob.swift"

ES_MODEL_DIR = "sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06"
EN_MODEL_DIR = "sherpa-onnx-streaming-zipformer-en-2023-06-26"
MODEL_IDS = {"es": "zipformer-es", "en": "zipformer-en"}

# These are acceptance criteria, rather than observed-model tuning knobs.
# Keep them identical for offline and streaming so a protocol pass cannot hide
# an unusable transcript.
MAX_WER = 0.20
MIN_ESSENTIAL_COVERAGE = 0.80
SILENCE_FRAMES = 2 * SAMPLE_RATE + 137


@dataclass(frozen=True)
class Utterance:
    text: str
    essential: Tuple[str, ...]
    speaker: int = 0


@dataclass(frozen=True)
class Session:
    language: str
    model_dir_name: str
    utterances: Tuple[Utterance, ...]


SESSIONS: Tuple[Session, ...] = (
    Session(
        language="es",
        model_dir_name=ES_MODEL_DIR,
        utterances=(
            Utterance(
                "Sesión de prueba en español. El número de pedido es cuatro dos siete.",
                ("sesión", "prueba", "español", "número", "pedido", "cuatro", "dos", "siete"),
                speaker=0,
            ),
            Utterance(
                "Abre la carpeta azul, cuenta tres archivos y mueve el informe al escritorio.",
                ("abre", "carpeta", "azul", "cuenta", "tres", "archivos", "mueve", "informe", "escritorio"),
                speaker=1,
            ),
            Utterance(
                "La acción siguiente es guardar los cambios y cerrar la ventana.",
                ("acción", "siguiente", "guardar", "cambios", "cerrar", "ventana"),
                speaker=0,
            ),
            Utterance(
                "A las nueve treinta, envía el resumen al equipo.",
                ("nueve", "treinta", "envía", "resumen", "equipo"),
                speaker=1,
            ),
        ),
    ),
    Session(
        language="en",
        model_dir_name=EN_MODEL_DIR,
        utterances=(
            Utterance(
                "English test session. The order number is four two seven.",
                ("english", "test", "session", "order", "number", "four", "two", "seven"),
                speaker=0,
            ),
            Utterance(
                "Open the blue folder, count three files, and move the report to the desktop.",
                ("open", "blue", "folder", "count", "three", "files", "move", "report", "desktop"),
                speaker=1,
            ),
            Utterance(
                "The next action is to save the changes and close the window.",
                ("next", "action", "save", "changes", "close", "window"),
                speaker=0,
            ),
            Utterance(
                "At nine thirty, send the summary to the team.",
                ("nine", "thirty", "send", "summary", "team"),
                speaker=1,
            ),
        ),
    ),
)


class PrerequisiteError(RuntimeError):
    """The real check cannot start in the current local environment."""


class CommandError(RuntimeError):
    """A bounded helper command failed while creating the fixture."""


def _json_dump(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _run_bounded(
    argv: Sequence[str],
    *,
    timeout: float,
    cwd: Optional[Path] = None,
    env: Optional[Mapping[str, str]] = None,
    input_bytes: Optional[bytes] = None,
) -> subprocess.CompletedProcess[bytes]:
    """Run one local command with a hard timeout and captured output."""

    try:
        process = subprocess.Popen(
            list(argv),
            cwd=str(cwd) if cwd else None,
            env=dict(env) if env else None,
            stdin=subprocess.PIPE if input_bytes is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as exc:
        raise CommandError(f"no se pudo iniciar {' '.join(argv)}: {exc}") from exc

    try:
        stdout, stderr = process.communicate(input=input_bytes, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            process.kill()
        stdout, stderr = process.communicate()
        timeout_message = (
            f"timeout de {timeout:.0f}s en {' '.join(argv)}; "
            f"stdout={len(stdout)} bytes, stderr={len(stderr)} bytes"
        ).encode("utf-8")
        return subprocess.CompletedProcess(
            list(argv), -signal.SIGKILL, stdout, (stderr or b"") + timeout_message
        )

    return subprocess.CompletedProcess(list(argv), process.returncode, stdout, stderr)


def _decode(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def _write_process_evidence(
    artifact_dir: Path,
    label: str,
    result: subprocess.CompletedProcess[bytes],
) -> None:
    (artifact_dir / f"{label}.stdout.log").write_bytes(result.stdout or b"")
    (artifact_dir / f"{label}.stderr.log").write_bytes(result.stderr or b"")


def _local_python_candidates(home: Path) -> List[Path]:
    candidates: List[Path] = []
    venv = home / ".meetcapture" / "venv" / "bin"
    candidates.extend((venv / "python3", venv / "python"))
    mlx_root = home / ".mlx" / "venvs"
    if mlx_root.is_dir():
        for child in sorted(mlx_root.iterdir()):
            if child.is_dir():
                candidates.extend((child / "bin" / "python3", child / "bin" / "python"))
    result: List[Path] = []
    seen = set()
    for candidate in candidates:
        # Do not follow venv/bin/python symlinks: Python uses the executable
        # path to discover pyvenv.cfg and its site-packages.
        absolute = candidate.absolute()
        if absolute not in seen:
            seen.add(absolute)
            result.append(absolute)
    return result


def _python_version(python: Path, timeout: float) -> Tuple[int, int, str]:
    result = _run_bounded(
        [str(python), "-B", "-c", "import sys; print(sys.version.split()[0])"],
        timeout=timeout,
    )
    version_text = _decode(result.stdout).strip()
    if result.returncode != 0 or not version_text:
        raise PrerequisiteError(
            f"no se pudo consultar la versión de {python}: {_decode(result.stderr).strip()}"
        )
    try:
        pieces = version_text.split(".")
        version = (int(pieces[0]), int(pieces[1]))
    except (IndexError, ValueError) as exc:
        raise PrerequisiteError(f"versión de Python ilegible en {python}: {version_text}") from exc
    return version[0], version[1], version_text


def _check_python_dependencies(python: Path, timeout: float) -> Tuple[str, str]:
    code = (
        "import sherpa_onnx, numpy, sys; "
        "print(getattr(sherpa_onnx, '__version__', 'unknown')); "
        "print(numpy.__version__); "
        "print(sys.executable)"
    )
    result = _run_bounded([str(python), "-B", "-c", code], timeout=timeout)
    if result.returncode != 0:
        message = _decode(result.stderr).strip() or _decode(result.stdout).strip()
        raise PrerequisiteError(f"{python} no puede importar sherpa_onnx y numpy: {message}")
    lines = _decode(result.stdout).splitlines()
    if len(lines) < 2:
        raise PrerequisiteError(f"salida incompleta al validar dependencias de {python}")
    return lines[0].strip(), lines[1].strip()


def select_python(explicit: Optional[str], timeout: float) -> Dict[str, str]:
    """Select only a local interpreter with the real sherpa dependencies."""

    if explicit:
        candidates = [Path(explicit).expanduser().absolute()]
    else:
        candidates = _local_python_candidates(Path.home())
    if not candidates:
        raise PrerequisiteError(
            "no hay un intérprete candidato en ~/.meetcapture/venv ni ~/.mlx/venvs"
        )

    failures: List[str] = []
    for python in candidates:
        if not python.is_file() or not os.access(python, os.X_OK):
            failures.append(f"{python}: no ejecutable")
            continue
        try:
            major, minor, version = _python_version(python, timeout)
            if (major, minor) < MIN_PYTHON:
                failures.append(f"{python}: Python {version}, se requiere >= 3.9")
                continue
            sherpa_version, numpy_version = _check_python_dependencies(python, timeout)
            return {
                "python": str(python),
                "python_version": version,
                "sherpa_onnx_version": sherpa_version,
                "numpy_version": numpy_version,
            }
        except (CommandError, PrerequisiteError) as exc:
            failures.append(f"{python}: {exc}")
    detail = "; ".join(failures) if failures else "sin candidatos válidos"
    raise PrerequisiteError(
        "no se encontró un venv local válido con sherpa_onnx y numpy; "
        "no se instalaron dependencias: " + detail
    )


def _required_model_files(model_dir: Path) -> Tuple[str, str, str]:
    encoders = sorted(model_dir.glob("encoder*.onnx"))
    decoders = sorted(model_dir.glob("decoder*.onnx"))
    joiners = sorted(model_dir.glob("joiner*.onnx"))
    if not (encoders and decoders and joiners):
        raise PrerequisiteError(
            f"modelo incompleto en {model_dir}: faltan encoder/decoder/joiner onnx"
        )
    encoders = [path for path in encoders if ".int8." not in path.name] or encoders
    decoders = [path for path in decoders if ".int8." not in path.name] or decoders
    joiners = [path for path in joiners if ".int8." not in path.name] or joiners
    if any(path.stat().st_size == 0 for path in (encoders[0], decoders[0], joiners[0])):
        raise PrerequisiteError(f"modelo vacío en {model_dir}")
    return encoders[0].name, decoders[0].name, joiners[0].name


def validate_models(models_root: Path) -> Dict[str, Dict[str, str]]:
    if not models_root.is_dir():
        raise PrerequisiteError(f"no existe el directorio local de modelos: {models_root}")
    vad = models_root / "silero_vad.onnx"
    if not vad.is_file() or vad.stat().st_size == 0:
        raise PrerequisiteError(f"falta el VAD local requerido: {vad}")

    result: Dict[str, Dict[str, str]] = {}
    for session in SESSIONS:
        model_dir = models_root / session.model_dir_name
        if not model_dir.is_dir():
            raise PrerequisiteError(
                f"falta el modelo local {session.language}: {model_dir}; "
                "el checker no descarga modelos"
            )
        encoder, decoder, joiner = _required_model_files(model_dir)
        tokens = model_dir / "tokens.txt"
        if not tokens.is_file() or tokens.stat().st_size == 0:
            raise PrerequisiteError(f"falta tokens.txt en {model_dir}")
        result[session.language] = {
            "path": str(model_dir),
            "encoder": encoder,
            "decoder": decoder,
            "joiner": joiner,
            "tokens": tokens.name,
        }
    segmentation = models_root / "sherpa-onnx-pyannote-segmentation-3-0" / "model.int8.onnx"
    embedding = models_root / "3dspeaker_eres2net.onnx"
    if not segmentation.is_file() or segmentation.stat().st_size == 0:
        raise PrerequisiteError(f"falta el modelo de segmentación de diarización: {segmentation}")
    if not embedding.is_file() or embedding.stat().st_size == 0:
        raise PrerequisiteError(f"falta el modelo de embeddings de diarización: {embedding}")
    result["diarization"] = {
        "segmentation": str(segmentation),
        "embedding": str(embedding),
    }
    return result


def _voice_inventory() -> List[Tuple[str, str]]:
    say = shutil.which("say")
    if not say:
        raise PrerequisiteError("falta el comando local say")
    result = _run_bounded([say, "-v", "?"], timeout=20.0)
    if result.returncode != 0:
        raise PrerequisiteError(f"say -v ? falló: {_decode(result.stderr).strip()}")
    voices: List[Tuple[str, str]] = []
    line_pattern = re.compile(r"^(.+?)\s+(\w+_\w+)\s+#")
    for line in _decode(result.stdout).splitlines():
        match = line_pattern.match(line.strip())
        if match:
            voices.append((match.group(1).strip(), match.group(2)))
    if not voices:
        raise PrerequisiteError("say -v ? no devolvió voces utilizables")
    return voices


def _choose_voices(voices: Sequence[Tuple[str, str]], language: str, count: int = 2) -> List[str]:
    if language == "es":
        exact = (
            "Eddy (Spanish (Spain))",
            "Flo (Spanish (Spain))",
            "Eddy (Spanish (Mexico))",
            "Flo (Spanish (Mexico))",
            "Paulina",
            "Mónica",
            "Monica",
        )
        locale_prefixes = ("es_ES", "es_MX", "es_419")
    else:
        exact = ("Samantha", "Alex", "Eddy (English (US))", "Flo (English (US))", "Daniel")
        locale_prefixes = ("en_US", "en_GB", "en_AU", "en_IN")
    by_name = {name: locale for name, locale in voices}
    selected: List[str] = []
    for candidate in exact:
        if candidate in by_name and candidate not in selected:
            selected.append(candidate)
            if len(selected) == count:
                return selected
    for name, locale in voices:
        if locale in locale_prefixes and name not in selected:
            selected.append(name)
            if len(selected) == count:
                return selected
    raise PrerequisiteError(
        f"se requieren {count} voces macOS locales distintas para {language}; "
        f"sólo se encontraron {len(selected)}"
    )


def _read_wave(path: Path) -> Tuple[bytes, int]:
    with wave.open(str(path), "rb") as stream:
        params = stream.getparams()
        if (params.nchannels, params.sampwidth, params.framerate) != (1, 2, SAMPLE_RATE):
            raise CommandError(
                f"audio inesperado en {path}: "
                f"{params.nchannels}ch/{params.sampwidth * 8}bit/{params.framerate}Hz"
            )
        return stream.readframes(params.nframes), params.nframes


def _make_session_audio(
    session: Session,
    voices: Sequence[str],
    artifact_dir: Path,
    timeout: float,
) -> Dict[str, Any]:
    say = shutil.which("say")
    afconvert = shutil.which("afconvert")
    if not say or not afconvert:
        missing = " y ".join(
            name for name, path in (("say", say), ("afconvert", afconvert)) if not path
        )
        raise PrerequisiteError(f"faltan herramientas macOS locales: {missing}")

    utterance_dir = artifact_dir / f"{session.language}-utterances"
    utterance_dir.mkdir()
    chunks: List[bytes] = []
    utterance_info: List[Dict[str, Any]] = []
    silence_between = int(0.45 * SAMPLE_RATE)
    silence = b"\x00\x00" * silence_between
    cursor_frames = 0

    for index, utterance in enumerate(session.utterances, start=1):
        stem = f"{session.language}-{index:02d}"
        aiff = utterance_dir / f"{stem}.aiff"
        wav_path = utterance_dir / f"{stem}.wav"
        voice = voices[utterance.speaker % len(voices)]
        say_result = _run_bounded(
            [say, "-v", voice, "-r", "150", "-o", str(aiff), utterance.text],
            timeout=timeout,
        )
        _write_process_evidence(artifact_dir, f"say-{session.language}-{index:02d}", say_result)
        if say_result.returncode != 0:
            raise CommandError(
                f"say falló para {session.language} #{index}: {_decode(say_result.stderr).strip()}"
            )
        convert_result = _run_bounded(
            [afconvert, "-f", "WAVE", "-d", "LEI16@16000", str(aiff), str(wav_path)],
            timeout=timeout,
        )
        _write_process_evidence(artifact_dir, f"afconvert-{session.language}-{index:02d}", convert_result)
        if convert_result.returncode != 0:
            raise CommandError(
                f"afconvert falló para {wav_path}: {_decode(convert_result.stderr).strip()}"
            )
        raw, frames = _read_wave(wav_path)
        chunks.append(raw)
        utterance_info.append(
            {
                "index": index,
                "text": utterance.text,
                "essential": list(utterance.essential),
                "speaker": utterance.speaker,
                "voice": voice,
                "frames": frames,
                "start_sec": round(cursor_frames / SAMPLE_RATE, 3),
                "end_sec": round((cursor_frames + frames) / SAMPLE_RATE, 3),
                "duration_sec": round(frames / SAMPLE_RATE, 3),
                "wav": str(wav_path),
            }
        )
        cursor_frames += frames
        if index != len(session.utterances):
            chunks.append(silence)
            cursor_frames += silence_between

    # A non-aligned tail is intentional: the streaming check must account for
    # bytes left in its input buffer at EOF. Keep it silent so it cannot create
    # an extra word while still proving that the complete duration was observed.
    raw_audio = b"".join(chunks)
    tail_samples = (len(raw_audio) // 2) % STREAM_CHUNK_SAMPLES
    if tail_samples == 0:
        raw_audio += b"\x00\x00" * 137
        tail_samples = 137
    output_wav = artifact_dir / f"session-{session.language}.wav"
    with wave.open(str(output_wav), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(SAMPLE_RATE)
        stream.writeframes(raw_audio)
    raw_path = artifact_dir / f"session-{session.language}.pcm"
    raw_path.write_bytes(raw_audio)
    return {
        "language": session.language,
        "voices": list(voices),
        "wav": str(output_wav),
        "pcm": str(raw_path),
        "frames": len(raw_audio) // 2,
        "duration_sec": round(len(raw_audio) / 2 / SAMPLE_RATE, 3),
        "tail_samples": tail_samples,
        "utterances": utterance_info,
    }


def _make_silence_audio(artifact_dir: Path) -> Dict[str, Any]:
    """Create a real silence-only PCM/WAV fixture with a non-aligned tail."""

    raw_audio = b"\x00\x00" * SILENCE_FRAMES
    output_wav = artifact_dir / "silence-only.wav"
    with wave.open(str(output_wav), "wb") as stream:
        stream.setnchannels(1)
        stream.setsampwidth(2)
        stream.setframerate(SAMPLE_RATE)
        stream.writeframes(raw_audio)
    raw_path = artifact_dir / "silence-only.pcm"
    raw_path.write_bytes(raw_audio)
    return {
        "wav": str(output_wav),
        "pcm": str(raw_path),
        "frames": SILENCE_FRAMES,
        "duration_sec": round(SILENCE_FRAMES / SAMPLE_RATE, 3),
        "tail_samples": SILENCE_FRAMES % STREAM_CHUNK_SAMPLES,
    }


def _normalise_tokens(text: str, language: Optional[str] = None) -> List[str]:
    """Normalize words while treating spoken and digit-by-digit numbers alike."""

    text = unicodedata.normalize("NFKC", text).casefold()
    tokens: List[str] = []
    current: List[str] = []
    for char in text:
        category = unicodedata.category(char)
        if category[0] in {"L", "N"}:
            current.append(char)
        elif current:
            tokens.append("".join(current))
            current = []
    if current:
        tokens.append("".join(current))

    digit_words = {
        "es": ("cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve"),
        "en": ("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"),
    }.get(language or "", ())
    if not digit_words:
        return tokens
    expanded: List[str] = []
    for token in tokens:
        if token.isdigit() and len(token) <= 8:
            expanded.extend(digit_words[int(digit)] for digit in token)
        else:
            expanded.append(token)
    return expanded


def _levenshtein(reference: Sequence[str], hypothesis: Sequence[str]) -> int:
    previous = list(range(len(hypothesis) + 1))
    for row, ref_word in enumerate(reference, start=1):
        current = [row]
        for column, hyp_word in enumerate(hypothesis, start=1):
            current.append(
                min(
                    previous[column] + 1,
                    current[column - 1] + 1,
                    previous[column - 1] + (ref_word != hyp_word),
                )
            )
        previous = current
    return previous[-1]


def _content_metrics(
    reference: Sequence[str],
    hypothesis: Sequence[str],
    essential: Iterable[str],
    language: str,
) -> Dict[str, Any]:
    essential_tokens: List[str] = []
    for phrase in essential:
        essential_tokens.extend(_normalise_tokens(phrase, language))
    essential_set = list(dict.fromkeys(essential_tokens))
    hyp_set = set(hypothesis)
    found = [word for word in essential_set if word in hyp_set]
    return {
        "essential_total": len(essential_set),
        "essential_found": len(found),
        "essential_missing": [word for word in essential_set if word not in hyp_set],
        "essential_coverage": round(len(found) / max(1, len(essential_set)), 3),
        "reference_words": len(reference),
        "hypothesis_words": len(hypothesis),
        "wer": round(_levenshtein(reference, hypothesis) / max(1, len(reference)), 3),
    }


def _transcript_text(payload: Mapping[str, Any]) -> str:
    segments = payload.get("segments")
    if not isinstance(segments, list):
        raise CommandError("JSON offline sin lista segments")
    return " ".join(str(segment.get("text", "")) for segment in segments if isinstance(segment, dict))


def _runtime_env() -> Dict[str, str]:
    env = dict(os.environ)
    env.update(
        {
            "CUDA_VISIBLE_DEVICES": "",
            "PYTHONNOUSERSITE": "1",
            "OMP_NUM_THREADS": "4",
            "VECLIB_MAXIMUM_THREADS": "4",
            "TOKENIZERS_PARALLELISM": "false",
        }
    )
    return env


def _metric_acceptance_failures(
    metrics: Mapping[str, Any], *, require_segments: bool = False
) -> List[Dict[str, Any]]:
    failures: List[Dict[str, Any]] = []
    wer = float(metrics["wer"])
    essential_coverage = float(metrics["essential_coverage"])
    if wer > MAX_WER:
        failures.append(
            {
                "check": "wer",
                "actual": wer,
                "expected_max": MAX_WER,
            }
        )
    if essential_coverage < MIN_ESSENTIAL_COVERAGE:
        failures.append(
            {
                "check": "essential_coverage",
                "actual": essential_coverage,
                "expected_min": MIN_ESSENTIAL_COVERAGE,
            }
        )
    if require_segments and int(metrics.get("segments", 0)) <= 0:
        failures.append(
            {
                "check": "segments",
                "actual": int(metrics.get("segments", 0)),
                "expected_min": 1,
            }
        )
    return failures


def _offline_accepts(metrics: Mapping[str, Any]) -> bool:
    return not _metric_acceptance_failures(metrics, require_segments=True)


def _run_offline(
    session: Session,
    audio: Mapping[str, Any],
    python_info: Mapping[str, str],
    artifact_dir: Path,
    timeout: float,
) -> Dict[str, Any]:
    output = artifact_dir / f"offline-{session.language}.json"
    started = time.monotonic()
    result = _run_bounded(
        [
            python_info["python"],
            "-B",
            str(TRANSCRIBE_SCRIPT),
            "--audio",
            str(audio["wav"]),
            "--model",
            MODEL_IDS[session.language],
            "--language",
            session.language,
            "--out",
            str(output),
        ],
        timeout=timeout,
        cwd=REPO_ROOT,
        env=_runtime_env(),
    )
    elapsed = time.monotonic() - started
    _write_process_evidence(artifact_dir, f"offline-{session.language}", result)
    if result.returncode != 0:
        return {
            "status": "fail",
            "failure_class": "execution",
            "returncode": result.returncode,
            "elapsed_sec": round(elapsed, 3),
            "stderr_tail": _decode(result.stderr)[-1000:],
        }
    try:
        payload = json.loads(output.read_text(encoding="utf-8"))
        text = _transcript_text(payload)
    except (OSError, json.JSONDecodeError, CommandError) as exc:
        return {
            "status": "fail",
            "failure_class": "contract",
            "returncode": result.returncode,
            "elapsed_sec": round(elapsed, 3),
            "error": str(exc),
        }
    reference = _normalise_tokens(" ".join(item.text for item in session.utterances), session.language)
    essential = [word for utterance in session.utterances for word in utterance.essential]
    metrics = _content_metrics(reference, _normalise_tokens(text, session.language), essential, session.language)
    measured = {**metrics, "segments": len(payload.get("segments", []))}
    acceptance_failures = _metric_acceptance_failures(measured, require_segments=True)
    accepted = _offline_accepts(measured)
    metrics.update(
        {
            "status": "pass" if accepted else "fail",
            "failure_class": None if accepted else "acceptance",
            "acceptance_failures": acceptance_failures,
            "elapsed_sec": round(elapsed, 3),
            "audio_duration_sec": audio["duration_sec"],
            "rtf": round(elapsed / max(0.001, float(audio["duration_sec"])), 3),
            "segments": len(payload.get("segments", [])),
            "text": text,
            "json": str(output),
        }
    )
    return metrics


def _parse_jsonl(data: bytes) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    events: List[Dict[str, Any]] = []
    for line_number, raw_line in enumerate(_decode(data).splitlines(), start=1):
        if not raw_line.strip():
            continue
        try:
            event = json.loads(raw_line)
        except json.JSONDecodeError as exc:
            return events, f"línea JSONL inválida {line_number}: {exc}"
        if not isinstance(event, dict):
            return events, f"evento JSONL no objeto en línea {line_number}"
        events.append(event)
    return events, None


def _stream_accepts(metrics: Mapping[str, Any]) -> bool:
    return not _metric_acceptance_failures(metrics)


def _run_streaming(
    session: Session,
    audio: Mapping[str, Any],
    python_info: Mapping[str, str],
    artifact_dir: Path,
    timeout: float,
) -> Dict[str, Any]:
    raw_audio = Path(str(audio["pcm"])).read_bytes()
    started = time.monotonic()
    result = _run_bounded(
        [
            python_info["python"],
            "-B",
            str(STREAM_SCRIPT),
            "--model",
            MODEL_IDS[session.language],
            "--chunk-ms",
            "100",
            "--partial-every-ms",
            "400",
        ],
        timeout=timeout,
        cwd=REPO_ROOT,
        env=_runtime_env(),
        input_bytes=raw_audio,
    )
    elapsed = time.monotonic() - started
    _write_process_evidence(artifact_dir, f"stream-{session.language}", result)
    events, parse_error = _parse_jsonl(result.stdout)
    done = next((event for event in reversed(events) if event.get("type") == "done"), None)
    finals = [event for event in events if event.get("type") == "final" and str(event.get("text", "")).strip()]
    full_text = " ".join(str(event["text"]) for event in finals)
    reference = _normalise_tokens(" ".join(item.text for item in session.utterances), session.language)
    essential = [word for utterance in session.utterances for word in utterance.essential]
    metrics = _content_metrics(reference, _normalise_tokens(full_text, session.language), essential, session.language)
    expected_duration = float(audio["frames"]) / SAMPLE_RATE
    captured_duration = float(done.get("audio_sec", -1)) if done else -1.0
    # The production JSON rounds audio_sec to milliseconds; a dropped tail is
    # hundreds of samples, while normal rounding is at most half a millisecond.
    tail_captured = math.isclose(captured_duration, expected_duration, abs_tol=0.001)
    errors = [event for event in events if event.get("type") == "error"]
    protocol_ok = (
        bool(events)
        and events[0].get("type") == "ready"
        and done is not None
        and not errors
        and not parse_error
        and result.returncode == 0
        and bool(finals)
    )
    acceptance_failures = _metric_acceptance_failures(metrics)
    if not protocol_ok:
        acceptance_failures.append(
            {
                "check": "stream_protocol",
                "actual": "invalid",
                "expected": "ready, final, done, no errors, returncode 0",
            }
        )
    if not tail_captured:
        acceptance_failures.append(
            {
                "check": "tail_captured",
                "actual": round(captured_duration, 3),
                "expected": round(expected_duration, 3),
            }
        )
    accepted = not acceptance_failures
    metrics.update(
        {
            "status": "pass" if accepted else "fail",
            "failure_class": None if accepted else ("execution" if result.returncode else "acceptance"),
            "acceptance_failures": acceptance_failures,
            "returncode": result.returncode,
            "elapsed_sec": round(elapsed, 3),
            "audio_duration_sec": expected_duration,
            "rtf": round(elapsed / max(0.001, expected_duration), 3),
            "event_types": [str(event.get("type")) for event in events],
            "final_events": len(finals),
            "tail_samples": int(audio["tail_samples"]),
            "tail_audio_sec": round(captured_duration, 3),
            "tail_captured": tail_captured,
            "protocol_ok": protocol_ok,
            "jsonl_error": parse_error,
            "errors": errors,
            "text": full_text,
        }
    )
    if not protocol_ok and parse_error:
        metrics["failure_class"] = "contract"
        metrics["error"] = parse_error
    return metrics


def _run_silence_offline(
    session: Session,
    audio: Mapping[str, Any],
    python_info: Mapping[str, str],
    artifact_dir: Path,
    timeout: float,
) -> Dict[str, Any]:
    """Verify the real offline VAD/ASR emits no segment for pure silence."""

    output = artifact_dir / f"silence-offline-{session.language}.json"
    started = time.monotonic()
    result = _run_bounded(
        [
            python_info["python"],
            "-B",
            str(TRANSCRIBE_SCRIPT),
            "--audio",
            str(audio["wav"]),
            "--model",
            MODEL_IDS[session.language],
            "--language",
            session.language,
            "--out",
            str(output),
        ],
        timeout=timeout,
        cwd=REPO_ROOT,
        env=_runtime_env(),
    )
    elapsed = time.monotonic() - started
    _write_process_evidence(artifact_dir, f"silence-offline-{session.language}", result)
    base: Dict[str, Any] = {
        "returncode": result.returncode,
        "elapsed_sec": round(elapsed, 3),
        "audio_duration_sec": audio["duration_sec"],
        "rtf": round(elapsed / max(0.001, float(audio["duration_sec"])), 3),
        "expected_empty": True,
        "json": str(output),
    }
    if result.returncode != 0:
        base.update(
            {
                "status": "fail",
                "failure_class": "execution",
                "stderr_tail": _decode(result.stderr)[-1000:],
            }
        )
        return base
    try:
        payload = json.loads(output.read_text(encoding="utf-8"))
        segments = payload.get("segments")
        if not isinstance(segments, list):
            raise CommandError("JSON de silencio sin lista segments")
        text = _transcript_text(payload)
    except (OSError, json.JSONDecodeError, CommandError) as exc:
        base.update(
            {
                "status": "fail",
                "failure_class": "contract",
                "error": str(exc),
            }
        )
        return base

    acceptance_failures: List[Dict[str, Any]] = []
    if segments:
        acceptance_failures.append(
            {
                "check": "silence_segments_empty",
                "actual": len(segments),
                "expected": 0,
            }
        )
    if text.strip():
        acceptance_failures.append(
            {
                "check": "silence_text_empty",
                "actual": text,
                "expected": "",
            }
        )
    base.update(
        {
            "status": "pass" if not acceptance_failures else "fail",
            "failure_class": None if not acceptance_failures else "acceptance",
            "acceptance_failures": acceptance_failures,
            "segments": len(segments),
            "text": text,
        }
    )
    return base


def _run_silence_streaming(
    session: Session,
    audio: Mapping[str, Any],
    python_info: Mapping[str, str],
    artifact_dir: Path,
    timeout: float,
) -> Dict[str, Any]:
    """Verify the real streaming recognizer emits no text for pure silence."""

    raw_audio = Path(str(audio["pcm"])).read_bytes()
    started = time.monotonic()
    result = _run_bounded(
        [
            python_info["python"],
            "-B",
            str(STREAM_SCRIPT),
            "--model",
            MODEL_IDS[session.language],
            "--chunk-ms",
            "100",
            "--partial-every-ms",
            "400",
        ],
        timeout=timeout,
        cwd=REPO_ROOT,
        env=_runtime_env(),
        input_bytes=raw_audio,
    )
    elapsed = time.monotonic() - started
    _write_process_evidence(artifact_dir, f"silence-stream-{session.language}", result)
    events, parse_error = _parse_jsonl(result.stdout)
    done = next((event for event in reversed(events) if event.get("type") == "done"), None)
    text_events = [
        event
        for event in events
        if event.get("type") in {"partial", "final"} and str(event.get("text", "")).strip()
    ]
    errors = [event for event in events if event.get("type") == "error"]
    expected_duration = float(audio["frames"]) / SAMPLE_RATE
    captured_duration = float(done.get("audio_sec", -1)) if done else -1.0
    tail_captured = math.isclose(captured_duration, expected_duration, abs_tol=0.001)
    protocol_ok = (
        bool(events)
        and events[0].get("type") == "ready"
        and done is not None
        and not errors
        and not parse_error
        and result.returncode == 0
    )
    acceptance_failures: List[Dict[str, Any]] = []
    if not protocol_ok:
        acceptance_failures.append(
            {
                "check": "silence_stream_protocol",
                "actual": "invalid",
                "expected": "ready, done, no errors, returncode 0",
            }
        )
    if text_events:
        acceptance_failures.append(
            {
                "check": "silence_stream_text_empty",
                "actual": [str(event.get("text", "")) for event in text_events],
                "expected": [],
            }
        )
    if not tail_captured:
        acceptance_failures.append(
            {
                "check": "silence_stream_audio_duration",
                "actual": round(captured_duration, 3),
                "expected": round(expected_duration, 3),
            }
        )
    base = {
        "status": "pass" if not acceptance_failures else "fail",
        "failure_class": None
        if not acceptance_failures
        else ("execution" if result.returncode else "acceptance"),
        "acceptance_failures": acceptance_failures,
        "returncode": result.returncode,
        "elapsed_sec": round(elapsed, 3),
        "audio_duration_sec": expected_duration,
        "rtf": round(elapsed / max(0.001, expected_duration), 3),
        "expected_empty": True,
        "event_types": [str(event.get("type")) for event in events],
        "text_events": len(text_events),
        "tail_samples": int(audio["tail_samples"]),
        "tail_audio_sec": round(captured_duration, 3),
        "tail_captured": tail_captured,
        "protocol_ok": protocol_ok,
        "jsonl_error": parse_error,
        "errors": errors,
    }
    if not protocol_ok and parse_error:
        base["failure_class"] = "contract"
        base["error"] = parse_error
    return base


def _product_contract() -> Dict[str, Any]:
    """Record the product wiring without starting the app or reading config."""

    try:
        settings = SETTINGS_SWIFT.read_text(encoding="utf-8")
        app_state = APP_STATE_SWIFT.read_text(encoding="utf-8")
        sherpa_scripts = SHERPA_SCRIPTS_SWIFT.read_text(encoding="utf-8")
        transcription_job = TRANSCRIPTION_JOB_SWIFT.read_text(encoding="utf-8")
    except OSError as exc:
        return {"inspection_error": str(exc)}
    return {
        "default_diarize_true": "static let diarize = true" in settings,
        "app_passes_settings_diarize": "diarize: Settings.diarize" in app_state,
        "constructor_method_diarize": "func diarize(wav: URL, segments: [Segment])" in sherpa_scripts,
        "constructor_binds_script": 'toolchain.script("speaker_diarize.py")' in sherpa_scripts,
        "constructor_uses_segments_json": 'SegmentJSON.encodeForDiarizer(segments)' in sherpa_scripts,
        "job_calls_diarize": "sherpa?.diarize(wav: wav, segments: result)" in transcription_job,
        "files": [
            str(SETTINGS_SWIFT),
            str(APP_STATE_SWIFT),
            str(SHERPA_SCRIPTS_SWIFT),
            str(TRANSCRIPTION_JOB_SWIFT),
        ],
    }


def _overlap(a_start: float, a_end: float, b_start: float, b_end: float) -> float:
    return max(0.0, min(a_end, b_end) - max(a_start, b_start))


def _run_diarization(
    session: Session,
    audio: Mapping[str, Any],
    python_info: Mapping[str, str],
    artifact_dir: Path,
    timeout: float,
    segments_json: Optional[str],
) -> Dict[str, Any]:
    """Run the real diarizer using the genuine offline ASR JSON as input."""

    if not segments_json or not Path(segments_json).is_file():
        return {
            "status": "blocked",
            "failure_class": "dependency",
            "operated": False,
            "warning": "no hay segments JSON real de transcribe_sherpa para alimentar al diarizador",
        }
    output = artifact_dir / f"diarization-{session.language}.json"
    started = time.monotonic()
    result = _run_bounded(
        [
            python_info["python"],
            "-B",
            str(DIARIZE_SCRIPT),
            "--audio",
            str(audio["wav"]),
            "--segments",
            segments_json,
            "--num-speakers",
            "2",
            "--out",
            str(output),
        ],
        timeout=timeout,
        cwd=REPO_ROOT,
        env=_runtime_env(),
    )
    elapsed = time.monotonic() - started
    _write_process_evidence(artifact_dir, f"diarization-{session.language}", result)
    base: Dict[str, Any] = {
        "returncode": result.returncode,
        "elapsed_sec": round(elapsed, 3),
        "audio_duration_sec": audio["duration_sec"],
        "rtf": round(elapsed / max(0.001, float(audio["duration_sec"])), 3),
        "segments_source": segments_json,
        "json": str(output),
        "operated": result.returncode == 0 and output.is_file(),
    }
    if result.returncode != 0:
        base.update(
            {
                "status": "fail",
                "failure_class": "execution",
                "stderr_tail": _decode(result.stderr)[-1000:],
                "warning": "el script de diarización no completó con el modelo local",
            }
        )
        return base
    try:
        diarized = json.loads(output.read_text(encoding="utf-8"))
        source = json.loads(Path(segments_json).read_text(encoding="utf-8"))
        output_segments = diarized.get("segments")
        source_segments = source.get("segments")
        raw_diarization = diarized.get("diarization")
        if not isinstance(output_segments, list) or not isinstance(source_segments, list):
            raise CommandError("diarización sin lista segments")
        if not isinstance(raw_diarization, list):
            raise CommandError("diarización sin lista diarization")
    except (OSError, json.JSONDecodeError, CommandError) as exc:
        base.update(
            {
                "status": "fail",
                "failure_class": "contract",
                "warning": str(exc),
            }
        )
        return base

    labels = sorted(
        {
            str(segment.get("speaker", ""))
            for segment in raw_diarization
            if str(segment.get("speaker", "")).strip() and str(segment.get("speaker")) != "?"
        }
    )
    output_labels = [str(segment.get("speaker", "?")) for segment in output_segments]
    labeled_segments = sum(label not in {"", "?"} for label in output_labels)
    text_preserved = len(output_segments) == len(source_segments) and all(
        str(out.get("text", "")) == str(src.get("text", ""))
        for out, src in zip(output_segments, source_segments)
    )

    mapping_counts: Dict[str, Dict[str, float]] = {}
    for diar_segment in raw_diarization:
        label = str(diar_segment.get("speaker", "?"))
        start = float(diar_segment.get("start", 0.0))
        end = float(diar_segment.get("end", start))
        if label == "?" or end <= start:
            continue
        counts = mapping_counts.setdefault(label, {"speaker_0": 0.0, "speaker_1": 0.0})
        for utterance in audio.get("utterances", []):
            duration = _overlap(start, end, float(utterance["start_sec"]), float(utterance["end_sec"]))
            counts[f"speaker_{int(utterance['speaker'])}"] += duration
    speaker_mapping = {
        label: max(counts, key=counts.get) for label, counts in mapping_counts.items()
    }
    distinct_expected = len(set(speaker_mapping.values()))
    labels_ok = len(labels) >= 2 and distinct_expected >= 2
    all_labeled = labeled_segments == len(output_segments) and len(output_segments) > 0
    contract_ok = diarized.get("engine") == "sherpa" and text_preserved
    accepted = labels_ok and all_labeled and contract_ok
    warning: Optional[str] = None
    if len(labels) < 2:
        warning = (
            "el motor real operó pero distinguió menos de dos hablantes "
            f"({len(labels)}); no se asume diarización correcta"
        )
    elif not all_labeled:
        warning = "el motor real dejó segmentos sin etiqueta A/B"
    elif not text_preserved:
        warning = "el diarizador no preservó el texto de los segmentos ASR de entrada"
    base.update(
        {
            "status": "pass" if accepted else "fail",
            "failure_class": None if accepted else "acceptance",
            "engine": diarized.get("engine"),
            "declared_speakers": diarized.get("speakers"),
            "observed_speakers": labels,
            "expected_speakers": 2,
            "labeled_segments": labeled_segments,
            "output_segments": len(output_segments),
            "text_preserved": text_preserved,
            "speaker_mapping": speaker_mapping,
            "mapped_expected_speakers": sorted(set(speaker_mapping.values())),
            "mapped_expected_count": distinct_expected,
            "warning": warning,
        }
    )
    return base


def _failure_records(
    results: Mapping[str, Mapping[str, Mapping[str, Any]]],
    silence_results: Mapping[str, Mapping[str, Mapping[str, Any]]],
) -> List[Dict[str, Any]]:
    failures: List[Dict[str, Any]] = []
    for group, grouped_results in (("session", results), ("silence", silence_results)):
        for language, modes in grouped_results.items():
            for mode, result in modes.items():
                if result.get("status") == "pass":
                    continue
                failure: Dict[str, Any] = {
                    "group": group,
                    "language": language,
                    "mode": mode,
                    "failure_class": result.get("failure_class", "acceptance"),
                }
                if result.get("acceptance_failures"):
                    failure["acceptance_failures"] = result["acceptance_failures"]
                for field in ("error", "warning", "returncode"):
                    if field in result:
                        failure[field] = result[field]
                failures.append(failure)
    return failures


def _git_revision() -> str:
    try:
        result = _run_bounded(["git", "rev-parse", "HEAD"], timeout=10.0, cwd=REPO_ROOT)
        if result.returncode == 0:
            return _decode(result.stdout).strip()
    except CommandError:
        pass
    return "unknown"


def _git_worktree_dirty() -> Optional[bool]:
    try:
        result = _run_bounded(
            ["git", "status", "--porcelain", "--untracked-files=all"],
            timeout=10.0,
            cwd=REPO_ROOT,
        )
    except CommandError:
        return None
    if result.returncode != 0:
        return None
    return bool(result.stdout.strip())


def _file_sha256(path: Path) -> Optional[str]:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--python",
        dest="python_path",
        help="intérprete local explícito; debe tener sherpa_onnx y numpy instalados",
    )
    parser.add_argument(
        "--models-root",
        default=str(Path.home() / ".whisper" / "models" / "sherpa"),
        help="raíz local de modelos sherpa (default: ~/.whisper/models/sherpa)",
    )
    parser.add_argument(
        "--artifact-dir",
        help="directorio temporal explícito; por default /tmp/meetcapture-real-asr-<unique>",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help="timeout por proceso sherpa/fixture, en segundos",
    )
    return parser


def _new_artifact_dir(explicit: Optional[str]) -> Path:
    if explicit:
        path = Path(explicit).expanduser().resolve()
        path.mkdir(parents=True, exist_ok=False)
        return path
    return Path(tempfile.mkdtemp(prefix="meetcapture-real-asr-", dir="/tmp"))


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _build_parser().parse_args(argv)
    if args.timeout <= 0:
        print("prerrequisito inválido: --timeout debe ser positivo", file=sys.stderr)
        return 2
    artifact_dir = _new_artifact_dir(args.artifact_dir)
    fingerprint_paths = (
        TRANSCRIBE_SCRIPT,
        STREAM_SCRIPT,
        DIARIZE_SCRIPT,
        Path(__file__).resolve(),
        SETTINGS_SWIFT,
        APP_STATE_SWIFT,
        SHERPA_SCRIPTS_SWIFT,
        TRANSCRIPTION_JOB_SWIFT,
    )
    report: Dict[str, Any] = {
        "status": "blocked",
        "failure_class": "prerequisite",
        "artifact_dir": str(artifact_dir),
        "repo": str(REPO_ROOT),
        "git_revision": _git_revision(),
        "working_tree_dirty": _git_worktree_dirty(),
        "source_files": [
            str(TRANSCRIBE_SCRIPT),
            str(STREAM_SCRIPT),
            str(DIARIZE_SCRIPT),
            str(Path(__file__).resolve()),
        ],
        "source_sha256": {str(path): _file_sha256(path) for path in fingerprint_paths},
        "cpu_only": True,
        "models_root": str(Path(args.models_root).expanduser().resolve()),
        "acceptance": {
            "max_wer": MAX_WER,
            "min_essential_coverage": MIN_ESSENTIAL_COVERAGE,
            "silence_requires_empty_output": True,
        },
        "failures": [],
        "product_contract": _product_contract(),
    }
    _json_dump(artifact_dir / "report.json", report)
    try:
        models_root = Path(args.models_root).expanduser().resolve()
        default_models_root = (Path.home() / ".whisper" / "models" / "sherpa").resolve()
        prerequisite_errors: List[str] = []
        python_info: Optional[Dict[str, str]] = None
        models: Optional[Dict[str, Dict[str, str]]] = None
        voices: Optional[List[Tuple[str, str]]] = None
        selected_voices: Optional[Dict[str, List[str]]] = None

        try:
            python_info = select_python(args.python_path, min(args.timeout, 30.0))
            report["python"] = python_info
        except PrerequisiteError as exc:
            prerequisite_errors.append(f"python: {exc}")
        try:
            if models_root != default_models_root:
                raise PrerequisiteError(
                    "speaker_diarize.py resuelve sus modelos en ~/.whisper/models/sherpa; "
                    "no se usará --models-root alternativo para evitar una ejecución engañosa"
                )
            if not DIARIZE_SCRIPT.is_file():
                raise PrerequisiteError(f"falta el script local de diarización: {DIARIZE_SCRIPT}")
            models = validate_models(models_root)
            report["models"] = models
        except PrerequisiteError as exc:
            prerequisite_errors.append(f"modelos: {exc}")
        try:
            voices = _voice_inventory()
            selected_voices = {session.language: _choose_voices(voices, session.language) for session in SESSIONS}
            report["voices"] = selected_voices
        except PrerequisiteError as exc:
            prerequisite_errors.append(f"voces: {exc}")

        if prerequisite_errors:
            report["prerequisite_errors"] = prerequisite_errors
            report["error"] = "; ".join(prerequisite_errors)
            report["failures"] = [
                {
                    "group": "environment",
                    "failure_class": "prerequisite",
                    "error": error,
                }
                for error in prerequisite_errors
            ]
            _json_dump(artifact_dir / "environment.json", report)
            _json_dump(artifact_dir / "report.json", report)
            print(f"PREREQUISITO: {report['error']}", file=sys.stderr)
            print(f"evidencia: {artifact_dir}", file=sys.stderr)
            return 2

        assert python_info is not None
        assert models is not None
        assert selected_voices is not None
        _json_dump(artifact_dir / "environment.json", report)

        audio_by_language: Dict[str, Dict[str, Any]] = {}
        for session in SESSIONS:
            audio_by_language[session.language] = _make_session_audio(
                session,
                selected_voices[session.language],
                artifact_dir,
                min(args.timeout, 30.0),
            )
        _json_dump(artifact_dir / "corpus.json", audio_by_language)
        silence_audio = _make_silence_audio(artifact_dir)
        _json_dump(artifact_dir / "silence.json", silence_audio)

        results: Dict[str, Any] = {}
        silence_results: Dict[str, Any] = {}
        for session in SESSIONS:
            audio = audio_by_language[session.language]
            offline = _run_offline(session, audio, python_info, artifact_dir, args.timeout)
            streaming = _run_streaming(session, audio, python_info, artifact_dir, args.timeout)
            diarization = _run_diarization(
                session,
                audio,
                python_info,
                artifact_dir,
                args.timeout,
                offline.get("json"),
            )
            results[session.language] = {
                "offline": offline,
                "streaming": streaming,
                "diarization": diarization,
            }
            silence_results[session.language] = {
                "offline": _run_silence_offline(
                    session, silence_audio, python_info, artifact_dir, args.timeout
                ),
                "streaming": _run_silence_streaming(
                    session, silence_audio, python_info, artifact_dir, args.timeout
                ),
            }
        failures = _failure_records(results, silence_results)
        report.update(
            {
                "status": "pass" if not failures else "fail",
                "failure_class": failures[0]["failure_class"] if failures else None,
                "results": results,
                "silence": silence_results,
                "failures": failures,
            }
        )
        _json_dump(artifact_dir / "report.json", report)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        print(f"evidencia: {artifact_dir}", file=sys.stderr)
        return 0 if report["status"] == "pass" else 1
    except (PrerequisiteError, CommandError, OSError) as exc:
        report.update(
            {
                "status": "blocked",
                "failure_class": "prerequisite",
                "error": str(exc),
                "failures": [
                    {
                        "group": "environment",
                        "failure_class": "prerequisite",
                        "error": str(exc),
                    }
                ],
            }
        )
        _json_dump(artifact_dir / "report.json", report)
        print(f"PREREQUISITO: {exc}", file=sys.stderr)
        print(f"evidencia: {artifact_dir}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
