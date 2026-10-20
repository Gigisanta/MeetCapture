#!/usr/bin/env python3
"""Opt-in integration check for the real summary dispatcher and MLX gateway.

This command is intentionally separate from the dispatcher.  It creates one
synthetic v2 handoff in a temporary directory, runs the checked-in dispatcher
as a subprocess with ``dry_run=false``, and validates the files it actually
writes.  The only network requests are GETs to the loopback gateway and the
dispatcher chat completion at ``http://127.0.0.1:8080/v1``.

Exit status 0 is reserved for a real LLM response that satisfies the corpus
assertions.  Exit status 1 means the dispatcher ran but the resulting state or
content failed an assertion.  Exit status 2 means the local gateway is not a
usable dependency (including a GPU hold that remained active after the
bounded wait); that is never treated as a dry-run pass.

Examples::

    python3 tools/summary/real_summary_check.py --keep-audio
    python3 tools/summary/real_summary_check.py --delete-audio

The fixture is removed when the command exits.  The test module beside this
file checks the pure assertions without contacting the gateway; this command
is the real integration evidence.
"""
from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
DISPATCHER = Path(__file__).with_name("meetcapture_summary_dispatcher.py")
GATEWAY_BASE = "http://127.0.0.1:8080/v1"
HEALTH_URL = "http://127.0.0.1:8080/health"
DEFAULT_MODEL = "maat/smart"
MAX_HOLD_WAIT_SECONDS = 120
MAX_HOLD_RETRIES = 2
DEPENDENCY_PENDING = 2
CHECK_FAILED = 1

SUMMARY_FIELDS = ("resumen", "action_items", "decisiones", "asistentes")
EXPECTED_ATTENDEES = ("Ana", "Bruno", "Lucía")
EXPECTED_ACTIONS = (
    ("Lucía", "presupuesto", "30", "septiembre", "Ana"),
    ("Bruno", "demo", "2", "octubre", None),
)

TRANSCRIPT = """Reunión de planificación del proyecto Atlas.
Fecha de la reunión: 22 de septiembre de 2026.
Asistentes: Ana, Bruno y Lucía.
Decisión: usamos la API v2 y publicamos la primera versión el 5 de octubre de 2026.
Compromisos:
- Lucía enviará el presupuesto final a Ana el 30 de septiembre de 2026.
- Bruno preparará la demo técnica para el 2 de octubre de 2026.
"""
AUDIO_BYTES = b"synthetic-meetcapture-audio-fixture-v1\n"


class DependencyPendingError(RuntimeError):
    """The real local inference dependency cannot be used in this run."""


@dataclass
class RunResult:
    returncode: int
    stdout: str
    stderr: str
    timed_out: bool = False


def _json_request(url: str, timeout: float = 10) -> object:
    """Fetch JSON without consulting configured HTTP proxies."""
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with opener.open(request, timeout=timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        raise DependencyPendingError("GET %s devolvió HTTP %s" % (url, exc.code)) from exc
    except (urllib.error.URLError, TimeoutError, OSError, ValueError) as exc:
        raise DependencyPendingError("GET %s no disponible: %s" % (url, exc)) from exc


def _hold_value_active(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value > 0
    if isinstance(value, dict):
        for key in ("active", "held", "enabled"):
            if key in value and isinstance(value[key], bool) and value[key]:
                return True
        for key in ("seconds", "remaining_s", "remaining_seconds", "hold_s"):
            if key in value:
                try:
                    if float(value[key]) > 0:
                        return True
                except (TypeError, ValueError):
                    pass
        return False
    if isinstance(value, str):
        return value.casefold() in {"active", "held", "on", "true"}
    return False


def active_gpu_hold(payload: object) -> bool:
    """Return whether the health payload contains a positive hold signal.

    The gateway versions seen in this repository do not all expose the same
    health shape.  Only explicit hold-named fields count; unrelated tier
    counters are never interpreted as a hold.
    """
    hold_keys = {
        "gpu_hold",
        "gpuhold",
        "hold_s",
        "hold_seconds",
        "gpu_hold_seconds",
        "remaining_hold_s",
    }

    def scan(value: object) -> bool:
        if isinstance(value, dict):
            for key, nested in value.items():
                normalized = str(key).casefold().replace("-", "_")
                if normalized in hold_keys and _hold_value_active(nested):
                    return True
                if scan(nested):
                    return True
        elif isinstance(value, list):
            return any(scan(item) for item in value)
        return False

    return scan(payload)


def model_names(models_payload: object) -> set[str]:
    names: set[str] = set()
    if not isinstance(models_payload, dict):
        return names
    data = models_payload.get("data")
    if not isinstance(data, list):
        return names
    for item in data:
        if not isinstance(item, dict):
            continue
        model_id = item.get("id")
        if isinstance(model_id, str) and model_id:
            names.add(model_id)
        maat = item.get("maat")
        if isinstance(maat, dict):
            aliases = maat.get("aliases")
            if isinstance(aliases, list):
                names.update(alias for alias in aliases if isinstance(alias, str))
    return names


def _health_alias_alive(health_payload: object, model: str) -> bool:
    if not isinstance(health_payload, dict):
        return False
    tiers = health_payload.get("tiers")
    if not isinstance(tiers, dict):
        return False
    for tier in tiers.values():
        if not isinstance(tier, dict):
            continue
        aliases = tier.get("aliases")
        if model in aliases if isinstance(aliases, list) else False:
            return tier.get("alive") is True
    return False


def _gateway_report(health_payload: object, models_payload: object, model: str) -> dict:
    """Keep evidence useful without echoing backend paths or internal ports."""
    tiers = {}
    if isinstance(health_payload, dict) and isinstance(health_payload.get("tiers"), dict):
        for name, tier in health_payload["tiers"].items():
            if isinstance(tier, dict):
                tiers[name] = {
                    "alive": tier.get("alive"),
                    "aliases": tier.get("aliases", []),
                }
    names = sorted(model_names(models_payload))
    return {
        "health_status": health_payload.get("status") if isinstance(health_payload, dict) else None,
        "gpu_hold": "active" if active_gpu_hold(health_payload) else "no-active-signal",
        "requested_model": model,
        "model_names": names,
        "tiers": tiers,
    }


def check_gateway(model: str) -> dict:
    """Check health/models and wait only for the bounded hold budget."""
    for retry in range(MAX_HOLD_RETRIES + 1):
        try:
            health = _json_request(HEALTH_URL)
            models = _json_request(GATEWAY_BASE + "/models")
        except DependencyPendingError:
            raise
        report = _gateway_report(health, models, model)
        names = model_names(models)
        health_ok = isinstance(health, dict) and health.get("status") == "ok"
        alias_ok = model in names
        alive_ok = _health_alias_alive(health, model)
        if health_ok and alias_ok and alive_ok and not active_gpu_hold(health):
            return report

        if active_gpu_hold(health):
            if retry >= MAX_HOLD_RETRIES:
                raise DependencyPendingError(
                    "gpu_hold activo después de %d reintentos en %d s"
                    % (MAX_HOLD_RETRIES, MAX_HOLD_WAIT_SECONDS)
                )
            wait_s = MAX_HOLD_WAIT_SECONDS // MAX_HOLD_RETRIES
            print(
                "DEPENDENCIA: gpu_hold activo; esperando %d s (reintento %d/%d)"
                % (wait_s, retry + 1, MAX_HOLD_RETRIES),
                flush=True,
            )
            time.sleep(wait_s)
            continue

        if not health_ok:
            raise DependencyPendingError(
                "gateway health no está ok: %s" % report.get("health_status")
            )
        if not alias_ok:
            raise DependencyPendingError(
                "alias %s no aparece en GET /v1/models" % model
            )
        raise DependencyPendingError(
            "alias %s no tiene un tier vivo en GET /health" % model
        )
    raise AssertionError("check_gateway salió sin resultado")


def _normalize(text: object) -> str:
    value = unicodedata.normalize("NFKD", str(text).casefold())
    return "".join(char for char in value if not unicodedata.combining(char))


def validate_summary_payload(
    output: object,
    html_text: str,
    transcript: str,
    model: str,
) -> list[str]:
    """Validate the persisted contract, including content from the corpus."""
    errors = _validate_rendered_summary(output, html_text, transcript, model)
    if errors:
        return errors
    assert isinstance(output, dict)

    attendees_text = _normalize(" ".join(output["asistentes"]))
    for attendee in EXPECTED_ATTENDEES:
        if _normalize(attendee) not in attendees_text:
            errors.append("asistente ausente: %s" % attendee)

    action_text = [_normalize(item) for item in output["action_items"]]
    used_indices: set[int] = set()
    for person, subject, day, month, recipient in EXPECTED_ACTIONS:
        matches = [
            index
            for index, item in enumerate(action_text)
            if index not in used_indices
            and _normalize(person) in item
            and _normalize(subject) in item
        ]
        if not matches:
            errors.append("action item sin responsable/contenido: %s + %s" % (person, subject))
            continue
        index = matches[0]
        used_indices.add(index)
        item = action_text[index]
        if not _has_date(item, day, month):
            errors.append(
                "fecha incorrecta o ausente para %s/%s: esperado %s de %s"
                % (person, subject, day, month)
            )
        if recipient and _normalize(recipient) not in item:
            errors.append("destinatario ausente para %s: %s" % (person, recipient))

    decisions_text = _normalize(" ".join(output["decisiones"]))
    if "api" not in decisions_text or not ("v2" in decisions_text or "version 2" in decisions_text):
        errors.append("decisión API v2 ausente")
    return errors


def _has_date(text: str, day: str, month: str) -> bool:
    """Match a day/month pair without treating ``v2`` as day 2."""
    if re.search(r"\b0?%s\b\s*(?:de\s+)?%s\b" % (day, month), text):
        return True
    numeric_month = {"septiembre": "09", "octubre": "10"}[month]
    return bool(re.search(r"\b0?%s[/-]%s(?:[/-]2026)?\b" % (day, numeric_month), text))


POC_ALLOWED_WORDS = {
    "de",
    "del",
    "el",
    "informe",
    "la",
    "manana",
    "preparar",
    "preparara",
    "prepararemos",
    "prepara",
    "proyecto",
    "revisar",
    "revisara",
    "revisaremos",
    "revisa",
    "y",
}


def _poc_action_kind(action: str) -> str | None:
    words = re.findall(r"[a-zñ]+", _normalize(action))
    if not words or any(word not in POC_ALLOWED_WORDS for word in words):
        return None
    if "manana" not in words:
        return None
    has_review = any(word.startswith("revis") for word in words) and "proyecto" in words
    has_prepare = any(word.startswith("prepar") for word in words) and "informe" in words
    if has_review and not has_prepare:
        return "revisar-proyecto"
    if has_prepare and not has_review:
        return "preparar-informe"
    return None


def validate_poc_summary_payload(
    output: object,
    html_text: str,
    transcript: str,
    model: str,
) -> list[str]:
    """Validate the short real-app POC without inventing an assignee."""
    errors = _validate_rendered_summary(output, html_text, transcript, model)
    if errors:
        return errors
    assert isinstance(output, dict)

    if output["asistentes"] != []:
        errors.append("POC sin personas exige asistentes=[]")
    summary_text = _normalize(" ".join(output["resumen"]))
    if "proyecto" not in summary_text or "revis" not in summary_text:
        errors.append("resumen no refleja revisar/revisión del proyecto")
    if "informe" not in summary_text or "prepar" not in summary_text:
        errors.append("resumen no refleja preparar el informe")
    if "manana" not in summary_text:
        errors.append("resumen no conserva mañana")

    kinds = [_poc_action_kind(item) for item in output["action_items"]]
    if len(kinds) != 2 or set(kinds) != {"revisar-proyecto", "preparar-informe"}:
        errors.append("action_items deben ser exactamente revisar proyecto y preparar informe mañana, sin asignados")
    return errors


def _validate_rendered_summary(
    output: dict,
    html_text: str,
    transcript: str,
    model: str,
) -> list[str]:
    """Validate fields and rendering shared by real corpus checks."""
    errors: list[str] = []
    if output.get("dry_run") is not False:
        errors.append("dry_run no es false; una salida mock nunca es PASS")
    if output.get("summary_model") != model:
        errors.append("summary_model=%r, esperado %r" % (output.get("summary_model"), model))
    for field in SUMMARY_FIELDS:
        value = output.get(field)
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            errors.append("%s no es una lista de strings" % field)
    if not isinstance(html_text, str) or not html_text:
        errors.append("summary.html vacío")
        return errors
    if "DRY RUN" in html_text.upper():
        errors.append("summary.html contiene banner DRY RUN")
    if html.escape(transcript) not in html_text:
        errors.append("summary.html no preserva el transcript fuente")
    for field in ("action_items", "decisiones", "asistentes"):
        value = output.get(field)
        if isinstance(value, list):
            for item in value:
                if isinstance(item, str) and html.escape(item) not in html_text:
                    errors.append("summary.html no refleja %s: %s" % (field, item))
    return errors


def _make_fixture(root: Path, keep_audio: bool, model: str) -> dict:
    meetings = root / "meetings"
    meetings.mkdir(mode=0o700)
    base = "real-summary-fixture"
    transcript_path = meetings / (base + ".txt")
    audio_path = meetings / (base + ".m4a")
    pending_path = meetings / (base + ".pending")
    transcript_path.write_text(TRANSCRIPT, encoding="utf-8")
    audio_path.write_bytes(AUDIO_BYTES)
    checksum = hashlib.sha256(TRANSCRIPT.encode("utf-8")).hexdigest()
    contract = {
        "version": 2,
        "meetingId": base,
        "title": "Atlas — planificación sintética",
        "startedAt": "2026-09-22T15:00:00-03:00",
        "endedAt": "2026-09-22T15:30:00-03:00",
        "durationSec": 1800.0,
        "transcriptPath": transcript_path.name,
        "audioPath": audio_path.name,
        "engine": "synthetic-fixture",
        "model": "synthetic-transcript",
        "language": "es",
        "segments": [
            {"start": 0, "end": 30, "text": TRANSCRIPT.strip()},
        ],
        "speakerCount": 3,
        "checksum": checksum,
    }
    pending_path.write_text(json.dumps(contract, ensure_ascii=False, sort_keys=True), encoding="utf-8")
    fixture = _write_temp_config(root, meetings, model, keep_audio)
    fixture.update({
        "base": base,
        "transcript": transcript_path,
        "audio": audio_path,
        "pending": pending_path,
        "contract": contract,
    })
    return fixture


class FixtureError(RuntimeError):
    """The supplied handoff fixture is not safe or not a v2 corpus."""


def _confined_path(root: Path, value: object) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise FixtureError("path de contrato vacío o no textual")
    candidate = Path(value)
    if not candidate.is_absolute():
        candidate = root / candidate
    root_real = root.resolve()
    resolved = candidate.resolve()
    try:
        if os.path.commonpath((str(root_real), str(resolved))) != str(root_real):
            raise FixtureError("path de contrato fuera de la fixture: %s" % value)
    except ValueError as exc:
        raise FixtureError("path de contrato inválido: %s" % value) from exc
    return resolved


def _under(path: Path, parent: Path) -> bool:
    try:
        return os.path.commonpath((str(path), str(parent))) == str(parent)
    except ValueError:
        return False


def _write_temp_config(root: Path, meetings: Path, model: str, keep_audio: bool = True) -> dict:
    home = root / "home"
    home.mkdir(mode=0o700)
    config_path = root / "summary.json"
    config_path.write_text(
        json.dumps(
            {
                "endpoint": GATEWAY_BASE,
                "api_key": "meetcapture-real-check-dummy",
                "model": model,
                "max_tokens": 900,
                "keep_audio": keep_audio,
                "dry_run": False,
            },
            indent=2,
        ),
        encoding="utf-8",
    )
    os.chmod(config_path, 0o600)
    return {"root": root, "home": home, "meetings": meetings, "config": config_path, "model": model}


def _existing_fixture(root: Path, temp_root: Path, model: str) -> dict:
    root = root.resolve()
    if not root.is_absolute() or not root.is_dir():
        raise FixtureError("fixture-dir no es un directorio absoluto: %s" % root)
    if root == REPO_ROOT or REPO_ROOT in root.parents:
        raise FixtureError("fixture-dir apunta al checkout, no a una fixture temporal")
    tmp_root = Path("/tmp").resolve()
    system_temp = Path(tempfile.gettempdir()).resolve()
    under_tmp = _under(root, tmp_root)
    under_system_temp = _under(root, system_temp)
    if under_tmp:
        if not root.parent.name.startswith("meetcapture-real."):
            raise FixtureError("fixture /tmp fuera de un árbol meetcapture-real.*: %s" % root)
    elif not under_system_temp:
        raise FixtureError("fixture fuera de /tmp o tempfile.gettempdir(): %s" % root)

    pending_paths = sorted(root.glob("*.pending"))
    if not pending_paths:
        raise FixtureError("no hay .pending originales en %s" % root)
    bases = []
    sources = {}
    transcripts = {}
    for pending in pending_paths:
        try:
            contract = json.loads(pending.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise FixtureError("no se pudo leer %s: %s" % (pending.name, exc)) from exc
        base = pending.name[: -len(".pending")]
        if contract.get("version") != 2 or contract.get("meetingId") != base:
            raise FixtureError("handoff v2 inválido: %s" % pending.name)
        transcript = _confined_path(root, contract.get("transcriptPath"))
        if not transcript.is_file():
            raise FixtureError("transcript ausente: %s" % transcript)
        text = transcript.read_text(encoding="utf-8")
        checksum = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if checksum != str(contract.get("checksum", "")).lower():
            raise FixtureError("checksum inválido en %s" % pending.name)
        audio_value = contract.get("audioPath")
        audio = _confined_path(root, audio_value) if audio_value is not None else None
        if audio is None or not audio.is_file():
            raise FixtureError("audio fuente ausente en %s" % pending.name)
        bases.append(base)
        transcripts[base] = transcript
        sources[str(transcript)] = transcript.read_bytes()
        sources[str(audio)] = audio.read_bytes()

    for candidate in (root / "docs" / "report.json", root / "report.json"):
        if candidate.is_file():
            sources[str(candidate)] = candidate.read_bytes()
    fixture = _write_temp_config(temp_root, root, model)
    fixture.update(
        {
            "fixture_root": root,
            "bases": sorted(bases),
            "transcripts": transcripts,
            "sources": sources,
        }
    )
    return fixture


def _child_environment(fixture: dict) -> dict:
    env = {
        key: os.environ[key]
        for key in ("PATH", "LANG", "LC_ALL", "LC_CTYPE")
        if key in os.environ
    }
    env.update(
        {
            "HOME": str(fixture["home"]),
            "MEETCAPTURE_MEETINGS_DIR": str(fixture["meetings"]),
            "MEETCAPTURE_SUMMARY_CONFIG": str(fixture["config"]),
            "MEETCAPTURE_POST_SUMMARY": str(fixture["root"] / "hook-does-not-exist"),
            "NO_PROXY": "127.0.0.1,localhost",
            "no_proxy": "127.0.0.1,localhost",
        }
    )
    return env


def run_dispatcher(fixture: dict, timeout: int = 600) -> RunResult:
    try:
        completed = subprocess.run(
            [sys.executable, str(DISPATCHER), "--once"],
            cwd=str(REPO_ROOT),
            env=_child_environment(fixture),
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return RunResult(completed.returncode, completed.stdout or "", completed.stderr or "")
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode("utf-8", "replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        return RunResult(124, stdout, stderr, timed_out=True)


def _state(fixture: dict) -> list[str]:
    prefixes = tuple(
        [fixture["base"]] if "base" in fixture else fixture.get("bases", [])
    )
    return sorted(
        path.name
        for path in fixture["meetings"].iterdir()
        if path.name == ".logs" or path.name.startswith(prefixes)
    )


def _read_summary(meetings: Path, base: str) -> tuple[dict | None, str | None]:
    json_path = meetings / (base + ".summary.json")
    html_path = meetings / (base + ".summary.html")
    try:
        output = json.loads(json_path.read_text(encoding="utf-8"))
        rendered = html_path.read_text(encoding="utf-8")
    except (OSError, ValueError):
        return None, None
    return output, rendered


def _run_existing_check(args: argparse.Namespace) -> int:
    try:
        fixture_path = Path(args.fixture_dir)
        with tempfile.TemporaryDirectory(prefix="meetcapture-real-summary-config-") as temp_dir:
            fixture = _existing_fixture(fixture_path, Path(temp_dir), args.model)
            before_sources = dict(fixture["sources"])
            first = run_dispatcher(fixture)
            errors = _execution_errors(first)
            evidence = []
            for base in fixture["bases"]:
                done_path = fixture["meetings"] / (base + ".done")
                if not done_path.exists():
                    errors.append("%s no terminó en .done" % base)
                output, rendered = _read_summary(fixture["meetings"], base)
                if output is None or rendered is None:
                    errors.append("faltan artefactos de %s" % base)
                    continue
                transcript = fixture["transcripts"][base].read_text(encoding="utf-8")
                if "revisar el proyecto" not in _normalize(transcript) or "preparar el informe" not in _normalize(transcript):
                    errors.append("corpus inesperado en %s" % base)
                errors.extend(
                    "%s: %s" % (base, error)
                    for error in validate_poc_summary_payload(output, rendered, transcript, args.model)
                )
                evidence.append((base, output))

            pending_left = [
                name
                for name in _state(fixture)
                if name.endswith(".pending") or ".pending.retry" in name or name.endswith(".pending.error") or name.endswith(".pending.failed")
            ]
            if pending_left:
                errors.append("quedaron handoffs sin resolver: %s" % ", ".join(pending_left))
            for path_text, expected in before_sources.items():
                source = Path(path_text)
                if not source.exists() or source.read_bytes() != expected:
                    errors.append("fuente modificada o eliminada: %s" % source.name)

            if errors:
                _report_failure(fixture, first, errors)
                return CHECK_FAILED

            before_artifacts = {}
            for base in fixture["bases"]:
                for suffix in (".summary.json", ".summary.html", ".done"):
                    path = fixture["meetings"] / (base + suffix)
                    if path.exists():
                        before_artifacts[str(path)] = (path.read_bytes(), path.stat().st_mtime_ns)

            second = run_dispatcher(fixture)
            errors.extend(_execution_errors(second))
            for path_text, (expected_bytes, expected_mtime) in before_artifacts.items():
                path = Path(path_text)
                mismatch = _artifact_changed(path, expected_bytes, "segunda ejecución", expected_mtime)
                if mismatch:
                    errors.append(mismatch)
            for path_text, expected in before_sources.items():
                source = Path(path_text)
                if not source.exists() or source.read_bytes() != expected:
                    errors.append("segunda ejecución modificó fuente: %s" % source.name)
            if not errors:
                print("PASS: authentic summary E2E")
                print("fixture: %s (pending originales, sin recrear)" % fixture["fixture_root"])
                print("dispatcher: %s" % DISPATCHER)
                print("config temporal: %s (dry_run=false, keep_audio=true, api_key dummy)" % fixture["config"])
                print("estado final: %s" % ", ".join(_state(fixture)))
                for base, output in evidence:
                    print("%s LLM real: action_items=%s asistentes=%s" % (
                        base,
                        json.dumps(output["action_items"], ensure_ascii=False),
                        json.dumps(output["asistentes"], ensure_ascii=False),
                    ))
                print("HTML, transcript, audio, report.json y artefactos preservados; segunda pasada sin cambios")
                return 0
            _report_failure(fixture, second if _execution_errors(second) else first, errors)
            return CHECK_FAILED
    except FixtureError as exc:
        print("FAIL: authentic summary E2E: %s" % exc)
        return CHECK_FAILED


def _execution_errors(result: RunResult) -> list[str]:
    errors = []
    if result.timed_out:
        errors.append("dispatcher excedió el timeout de integración")
    if result.returncode != 0:
        errors.append("dispatcher terminó con código %d" % result.returncode)
    return errors


def _tail(text: str, limit: int = 6) -> list[str]:
    return [line for line in text.splitlines() if line.strip()][-limit:]


def _artifact_changed(path: Path, expected: bytes, label: str, expected_mtime: int | None = None) -> str | None:
    try:
        actual = path.read_bytes()
    except OSError:
        return "%s ausente tras la ejecución: %s" % (label, path.name)
    if actual != expected:
        return "%s sobrescribió %s" % (label, path.name)
    if expected_mtime is not None:
        try:
            if path.stat().st_mtime_ns != expected_mtime:
                return "%s cambió mtime de %s" % (label, path.name)
        except OSError:
            return "%s no pudo inspeccionar %s" % (label, path.name)
    return None


def _report_failure(fixture: dict, result: RunResult, errors: list[str]) -> None:
    print("FAIL: real summary check")
    for error in errors:
        print("- %s" % error)
    print("- estado final: %s" % ", ".join(_state(fixture)))
    for label, text in (("stdout", result.stdout), ("stderr", result.stderr)):
        tail = _tail(text)
        if tail:
            print("- %s final: %s" % (label, " | ".join(tail)))


def _run_check(args: argparse.Namespace) -> int:
    try:
        gateway = check_gateway(args.model)
    except DependencyPendingError as exc:
        print("DEPENDENCY_PENDING: %s" % exc)
        return DEPENDENCY_PENDING

    print("gateway: %s" % json.dumps(gateway, ensure_ascii=False, sort_keys=True))
    if args.fixture_dir:
        if not args.keep_audio:
            print("FAIL: --fixture-dir exige keep_audio=true para conservar la fixture original")
            return CHECK_FAILED
        return _run_existing_check(args)
    with tempfile.TemporaryDirectory(prefix="meetcapture-real-summary-") as temp_dir:
        fixture = _make_fixture(Path(temp_dir), args.keep_audio, args.model)
        first = run_dispatcher(fixture)
        errors = _execution_errors(first)
        output, rendered = _read_summary(fixture["meetings"], fixture["base"])
        done_path = fixture["meetings"] / (fixture["base"] + ".done")
        if not done_path.exists():
            errors.append("estado final sin .done")
        if output is None or rendered is None:
            errors.append("faltan o son ilegibles summary.json/summary.html")
        else:
            errors.extend(validate_summary_payload(output, rendered, TRANSCRIPT, args.model))
        retry_states = [
            name
            for name in _state(fixture)
            if ".pending.retry" in name or name.endswith(".pending.error") or name.endswith(".pending.failed")
        ]
        if retry_states:
            errors.append("estado de error/reintento presente: %s" % ", ".join(retry_states))
        if args.keep_audio:
            if not fixture["audio"].exists():
                errors.append("keep_audio=true no preservó el audio fuente")
            elif fixture["audio"].read_bytes() != AUDIO_BYTES:
                errors.append("keep_audio=true alteró el audio fuente")
        elif fixture["audio"].exists():
            errors.append("keep_audio=false no eliminó el audio fuente")
        if not fixture["transcript"].exists() or fixture["transcript"].read_text(encoding="utf-8") != TRANSCRIPT:
            errors.append("el transcript fuente no se preservó")

        if errors:
            _report_failure(fixture, first, errors)
            return CHECK_FAILED

        before_json = (fixture["meetings"] / (fixture["base"] + ".summary.json")).read_bytes()
        before_html = (fixture["meetings"] / (fixture["base"] + ".summary.html")).read_bytes()
        before_done = done_path.read_bytes()
        duplicate = fixture["meetings"] / (fixture["base"] + ".pending")
        duplicate.write_text(json.dumps(fixture["contract"], ensure_ascii=False, sort_keys=True), encoding="utf-8")
        second = run_dispatcher(fixture)
        errors.extend(_execution_errors(second))
        for path, expected, label in (
            (fixture["meetings"] / (fixture["base"] + ".summary.json"), before_json, "segunda ejecución"),
            (fixture["meetings"] / (fixture["base"] + ".summary.html"), before_html, "segunda ejecución"),
            (done_path, before_done, "segunda ejecución"),
        ):
            mismatch = _artifact_changed(path, expected, label)
            if mismatch:
                errors.append(mismatch)
        if not duplicate.exists():
            errors.append("segunda ejecución eliminó el handoff duplicado")
        if "skip" not in (second.stdout + second.stderr).casefold():
            errors.append("segunda ejecución no dejó evidencia de skip idempotente")

        if errors:
            _report_failure(fixture, second if _execution_errors(second) else first, errors)
            return CHECK_FAILED

        print("PASS: real summary check")
        print("fixture temporal: %s (eliminada al salir)" % fixture["root"])
        print("dispatcher: %s" % DISPATCHER)
        print("config: %s (dry_run=false, keep_audio=%s, api_key dummy)" % (fixture["config"], args.keep_audio))
        print("estado final: %s" % ", ".join(_state(fixture)))
        print("LLM real persistido en summary.json:")
        for field in SUMMARY_FIELDS:
            print("  %s: %s" % (field, json.dumps(output[field], ensure_ascii=False)))
        print("HTML: acciones, decisiones, asistentes y transcript fuente verificados")
        print("idempotencia: segunda ejecución conservó artifacts y dejó pending duplicado")
        print("fuentes: transcript preservado; audio %s según keep_audio" % ("preservado" if args.keep_audio else "eliminado"))
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    source = parser.add_mutually_exclusive_group()
    source.add_argument(
        "--keep-audio",
        dest="keep_audio",
        action="store_true",
        default=True,
        help="preserva el audio sintético y verifica keep_audio=true (default)",
    )
    source.add_argument(
        "--delete-audio",
        dest="keep_audio",
        action="store_false",
        help="verifica keep_audio=false con la misma fixture sintética",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL, help="alias del gateway (default: %(default)s)")
    parser.add_argument(
        "--fixture-dir",
        help="procesa .pending v2 existentes en una fixture /tmp/meetcapture-real.* sin recrearlos",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    return _run_check(build_parser().parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
