#!/usr/bin/env python3
"""meetcapture_summary_dispatcher.py — consumidor de handoffs .pending v2 de MeetCapture.

Lee los contratos .pending que MeetCapture escribe en ~/meetings (o
$MEETCAPTURE_MEETINGS_DIR),
genera resumen + action items con el LLM local MLX (endpoint OpenAI-compatible),
escribe <base>.summary.json y <base>.summary.html, hace ack atómico .pending -> .done
y borra el audio si keep_audio=false. Pensado para launchd WatchPaths +
StartInterval (--once): un fallo de red/LLM deja el handoff en
.pending.retry[.n] y se reintenta con backoff exponencial (5 min ... 6 h,
hasta MAX_RETRIES) antes de abandonarlo en .pending.failed; `--retry-failed`
los vuelve a encolar.

Stdlib only (urllib, json). Sin dependencias externas.
"""
from __future__ import annotations

import hashlib
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

from meeting_notes import build_markdown, filter_tags, load_tag_vocabulary

try:
    import fcntl  # macOS/Linux: lock de instancia única
except ImportError:  # pragma: no cover — Windows no aplica acá
    fcntl = None

MEETINGS_DIR = os.path.expanduser(os.environ.get("MEETCAPTURE_MEETINGS_DIR") or "~/meetings")
CONFIG_PATH = os.path.expanduser(os.environ.get("MEETCAPTURE_SUMMARY_CONFIG") or "~/.meetcapture/summary.json")
LOG_DIR = os.path.join(MEETINGS_DIR, ".logs")
LOG_PATH = os.path.join(LOG_DIR, "summary.log")

DEFAULT_CONFIG = {
    "endpoint": "http://127.0.0.1:8080/v1",   # router maat-gateway (aliases)
    "api_key": "mlx-local",
    "model": "maat/smart",  # alias del router; null -> auto-descubrir vía GET /models
    "keep_audio": False,
    "max_tokens": 2000,
    "dry_run": False,
    "tag_vocabulary_dir": "",
}

EMAIL_RE = re.compile(r"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")
# <base>.pending | <base>.pending.retry | <base>.pending.retry.<n>
PENDING_RE = re.compile(r"^(?P<base>.+?)\.pending(?:\.retry(?:\.(?P<gen>\d+))?)?$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
FAILED_SUFFIX = ".pending.failed"
MAX_RETRIES = 8
BACKOFF_BASE = 300       # 5 min after the first failure
BACKOFF_CAP = 6 * 3600   # never wait more than 6 h between attempts

SUMMARY_FIELDS = ("resumen", "action_items", "decisiones", "asistentes")
# ~6k tokens: longer transcripts are summarized by parts, then merged, so a
# local model's context window never truncates the end of a meeting.
MAP_CHARS = 24_000

SYSTEM_PROMPT = (
    "Sos un asistente de resúmenes de reuniones. Devolvé SIEMPRE JSON válido con "
    "claves: resumen (3-5 bullets en español), action_items (lista de strings), "
    "decisiones (lista de strings), asistentes (lista de strings), tags (lista de strings). "
    "No inventes asistentes, decisiones, responsables ni fechas. "
    "Incluí responsables y fechas en cada pendiente sólo si están expresados. "
    "Usá únicamente tags del vocabulario provisto; si está vacío, devolvé []."
)


def log(msg: str, level: str = "INFO") -> None:
    line = "%s [%s] %s" % (
        datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
        level,
        EMAIL_RE.sub("[EMAIL REDACTED]", str(msg)),
    )
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError as e:
        print("LOG-FAIL %s: %s" % (e, line), file=sys.stderr)
    print(line, flush=True)


def ensure_dirs() -> None:
    # PII: dir de reuniones y logs privados (0700/0600) — el audit adversarial
    # de MeetCapture marcó ~/meetings 0755 como riesgo.
    os.makedirs(MEETINGS_DIR, mode=0o700, exist_ok=True)
    os.chmod(MEETINGS_DIR, 0o700)
    os.makedirs(LOG_DIR, mode=0o700, exist_ok=True)
    os.chmod(LOG_DIR, 0o700)
    if not os.path.exists(LOG_PATH):
        open(LOG_PATH, "a").close()
    os.chmod(LOG_PATH, 0o600)


def load_config() -> dict:
    if not os.path.exists(CONFIG_PATH):
        os.makedirs(os.path.dirname(CONFIG_PATH), mode=0o700, exist_ok=True)
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, indent=2)
        log("config creada con defaults: %s" % CONFIG_PATH)
        return dict(DEFAULT_CONFIG)
    with open(CONFIG_PATH, encoding="utf-8") as f:
        data = json.load(f)
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(data or {})
    return cfg


def discover_model(cfg: dict) -> str:
    req = urllib.request.Request(
        cfg["endpoint"] + "/models",
        headers={"Authorization": "Bearer " + cfg["api_key"]},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode("utf-8"))
    ids = [m["id"] for m in data.get("data", []) if m.get("id")]
    if not ids:
        raise RuntimeError("GET /models no devolvió ningún model id")
    # Preferir un LLM de chat (qwen); jamás el primer id a ciegas (puede ser FLUX).
    chosen = next((m for m in ids if "qwen" in m.lower()), ids[0])
    return chosen


def call_llm(cfg: dict, model: str, transcript_text: str) -> str:
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": "Transcript:\n" + transcript_text},
        ],
        "max_tokens": cfg.get("max_tokens", 2000),
        "temperature": 0.2,
    }).encode("utf-8")
    last_err: Exception | None = None
    for attempt in range(3):  # 1 intento + 2 reintentos con backoff
        try:
            req = urllib.request.Request(
                cfg["endpoint"] + "/chat/completions",
                data=body,
                headers={"Content-Type": "application/json",
                         "Authorization": "Bearer " + cfg["api_key"]},
            )
            with urllib.request.urlopen(req, timeout=180) as r:
                resp = json.loads(r.read().decode("utf-8"))
            content = resp["choices"][0]["message"]["content"]
            if not content or not content.strip():
                raise RuntimeError("respuesta LLM vacía")
            return content
        except Exception as e:  # noqa: BLE001 — red/LLM: reintentar
            last_err = e
            if attempt < 2:
                time.sleep(5 * (attempt + 1))
    raise RuntimeError("LLM/red falló tras 3 intentos: %s" % last_err)


def split_transcript(text: str, limit: int = MAP_CHARS) -> list[str]:
    """Consecutive parts of at most ``limit`` characters, cut between lines."""
    parts, current, size = [], [], 0
    for line in text.splitlines():
        if current and size + len(line) + 1 > limit:
            parts.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += len(line) + 1
    if current:
        parts.append("\n".join(current))
    return parts


def summarize(cfg: dict, model: str, header: str, text: str) -> dict:
    """One call for a short transcript; map per part and reduce for a long one."""
    parts = split_transcript(text)
    if len(parts) <= 1:
        return parse_llm_json(call_llm(cfg, model, header + "Transcripción:\n" + text))
    partials = []
    for i, part in enumerate(parts, 1):
        partials.append(parse_llm_json(call_llm(
            cfg, model, header + "Transcripción, parte %d de %d:\n%s" % (i, len(parts), part))))
    return parse_llm_json(call_llm(cfg, model, header + (
        "Estos son resúmenes JSON de las %d partes consecutivas de una misma reunión. "
        "Unilos en un solo JSON con las mismas claves, sin repetir ni contradecir:\n%s"
        % (len(parts), json.dumps(partials, ensure_ascii=False)))))


def parse_llm_json(content: str) -> dict:
    if not isinstance(content, str) or not content.strip():
        raise ValueError("salida del LLM vacía o no textual")
    s = content.strip()
    try:
        return json.loads(s)
    except Exception:  # noqa: BLE001
        pass
    m = re.search(r"```(?:json)?\s*(.*?)```", s, re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except Exception:  # noqa: BLE001
            pass
    start, end = s.find("{"), s.rfind("}")
    if start != -1 and end > start:
        try:
            return json.loads(s[start:end + 1])
        except Exception:  # noqa: BLE001
            pass
    raise ValueError("no se pudo parsear JSON de la salida del LLM")


def normalize_summary(obj) -> dict:
    """Valida el objeto de resumen antes de permitir el ack del handoff."""
    if not isinstance(obj, dict):
        raise ValueError("salida LLM no es un objeto JSON")

    missing = [key for key in SUMMARY_FIELDS if key not in obj]
    if missing:
        raise ValueError("salida LLM sin claves requeridas: %s" % ", ".join(missing))

    def _strs(key, allow_single=False, require_nonempty=False):
        value = obj[key]
        if allow_single and isinstance(value, str):
            value = [value]
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            raise ValueError("salida LLM: %s debe ser una lista de strings" % key)
        if require_nonempty and (not value or any(not item.strip() for item in value)):
            raise ValueError("salida LLM: %s no puede estar vacío" % key)
        return value

    return {
        "resumen": _strs("resumen", allow_single=True, require_nonempty=True),
        "action_items": _strs("action_items"),
        "decisiones": _strs("decisiones"),
        "asistentes": _strs("asistentes"),
    }


def dry_run_summary(contract: dict) -> dict:
    return {
        "resumen": [
            "(DRY RUN) Resumen de prueba — no se llamó al LLM local "
            "(dry_run=true o endpoint MLX no disponible).",
            "(DRY RUN) Reunión: %s" % (contract.get("title") or "sin título"),
        ],
        "action_items": ["(DRY RUN) Verificar gateway MLX en :8080 (maat/smart) y re-procesar"],
        "decisiones": [],
        "asistentes": [],
    }


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def resolve(path: str) -> str:
    if not isinstance(path, str):
        raise TypeError("path debe ser string")
    root = os.path.realpath(MEETINGS_DIR)
    candidate = path if os.path.isabs(path) else os.path.join(MEETINGS_DIR, path)
    resolved = os.path.realpath(candidate)
    try:
        common = os.path.commonpath((root, resolved))
    except ValueError:
        common = None
    if common != root:
        raise ValueError("path fuera de MEETINGS_DIR: %s" % path)
    return resolved


def validate_contract(contract, base: str) -> dict:
    """Rechaza contratos v2 incompletos antes de leer o borrar sus archivos."""
    if not isinstance(contract, dict):
        raise ValueError("contrato no es un objeto JSON")

    if contract.get("version") != 2:
        raise ValueError("version=%r != 2 (contrato no soportado)" % contract.get("version"))
    if not isinstance(contract.get("meetingId"), str) or contract["meetingId"] != base:
        raise ValueError("meetingId=%r no coincide con el handoff %r" % (contract.get("meetingId"), base))
    if not isinstance(contract.get("transcriptPath"), str) or not contract["transcriptPath"].strip():
        raise ValueError("transcriptPath debe ser un string no vacío")
    audio = contract.get("audioPath")
    if audio is not None and (
        not isinstance(audio, str) or not audio.strip()
    ):
        raise ValueError("audioPath debe ser string o null")
    checksum = contract.get("checksum")
    if not isinstance(checksum, str) or not SHA256_RE.fullmatch(checksum):
        raise ValueError("checksum debe ser SHA-256 hexadecimal")
    return contract


def fmt_duration(sec) -> str:
    sec = int(sec or 0)
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return "%dh %02dm %02ds" % (h, m, s) if h else "%dm %02ds" % (m, s)


def fmt_date(iso) -> str:
    if not iso:
        return "desconocida"
    try:
        dt = datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
        return dt.strftime("%d/%m/%Y %H:%M")
    except Exception:  # noqa: BLE001
        return str(iso)


def build_html(contract: dict, summary: dict, dry: bool, model: str | None,
               transcript_text: str, user_notes: str = "") -> str:
    e = html.escape
    title = e(str(contract.get("title") or "Untitled Meeting"))
    fecha = e(fmt_date(contract.get("startedAt")))
    dur = e(fmt_duration(contract.get("durationSec")))
    engine = e(str(contract.get("engine") or "?"))
    mname = e(str(contract.get("model") or model or "?"))
    tpath = e(str(contract.get("transcriptPath") or ""))

    def bullets(items, empty_note="Sin ítems."):
        if not items:
            return "<li><em>%s</em></li>" % e(empty_note)
        return "".join("<li>%s</li>" % e(str(x)) for x in items)

    chips = "".join(
        '<span class="chip">%s</span>' % e(str(a)) for a in summary["asistentes"]
    ) or '<span class="mut">No detectados.</span>'

    banner = (
        '<div class="banner">⚠ DRY RUN — resumen de prueba generado sin LLM local '
        '(endpoint MLX no disponible o dry_run=true).</div>' if dry else ""
    )

    transcript = e(transcript_text)
    notes_section = "<section><h2>Mis notas</h2><pre>%s</pre></section>" % e(user_notes) if user_notes.strip() else ""

    return """<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s — Resumen</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--fg:#e6edf3;--mut:#8b949e;--acc:#58a6ff;--grn:#3fb950;--org:#d29922}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:32px 20px 64px}
header{border-bottom:1px solid #21262d;padding-bottom:18px;margin-bottom:24px}
h1{margin:0 0 6px;font-size:26px;word-wrap:break-word}
.meta{color:var(--mut);font-size:13px}
.banner{background:#3d2c00;border:1px solid var(--org);color:#ffd879;padding:10px 14px;border-radius:8px;margin:0 0 20px;font-size:13px}
section{background:var(--card);border:1px solid #21262d;border-radius:10px;padding:18px 20px;margin-bottom:18px}
h2{margin:0 0 12px;font-size:14px;color:var(--acc);text-transform:uppercase;letter-spacing:.06em}
ul{margin:0;padding-left:20px}
li{margin-bottom:6px}
.ai li::marker{color:var(--grn)}
.dec li::marker{color:var(--org)}
.asist{display:flex;flex-wrap:wrap;gap:8px}
.chip{background:#21262d;border:1px solid #30363d;border-radius:999px;padding:4px 12px;font-size:13px}
details{background:var(--card);border:1px solid #21262d;border-radius:10px;padding:14px 18px}
summary{cursor:pointer;color:var(--mut);font-size:14px}
pre{white-space:pre-wrap;word-wrap:break-word;font:13px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;color:#c9d1d9;margin:12px 0 0}
.mut{color:var(--mut)}
</style>
</head>
<body>
<div class="wrap">
<header>
<h1>%s</h1>
<div class="meta">%s · duración %s · %s/%s · transcript: %s</div>
</header>
%s
%s
<section><h2>Resumen</h2><ul>%s</ul></section>
<section class="ai"><h2>Action items</h2><ul>%s</ul></section>
<section class="dec"><h2>Decisiones</h2><ul>%s</ul></section>
<section><h2>Asistentes</h2><div class="asist">%s</div></section>
<details><summary>Transcript completo</summary><pre>%s</pre></details>
</div>
</body>
</html>""" % (
        title, title, fecha, dur, engine, mname, tpath,
        banner,
        notes_section,
        bullets(summary["resumen"]),
        bullets(summary["action_items"]),
        bullets(summary["decisiones"]),
        chips,
        transcript,
    )


def retry_generation(name: str) -> int:
    """.pending -> 0, .pending.retry -> 1, .pending.retry.N -> N (fallos previos)."""
    if name.endswith(".pending.retry"):
        return 1
    m = re.match(r"^.+?\.pending\.retry\.(?P<gen>\d+)$", name)
    return int(m.group("gen")) if m else 0


def backoff_seconds(gen: int) -> float:
    """Espera antes del intento gen+1: 5m, 10m, 20m, 40m, 80m, 160m, 320m, 6h."""
    if gen <= 0:
        return 0.0
    return float(min(BACKOFF_BASE * 2 ** (gen - 1), BACKOFF_CAP))


def due(path: str, now: float | None = None) -> bool:
    """Un .retry* sólo se reintenta cuando venció su backoff (mtime del rename)."""
    gen = retry_generation(os.path.basename(path))
    if gen == 0:
        return True
    try:
        mtime = os.stat(path).st_mtime
    except OSError:
        return False
    return (now if now is not None else time.time()) >= mtime + backoff_seconds(gen)


def move_state(path: str, target: str) -> bool:
    """Mueve dentro de la carpeta sin reemplazar otro handoff existente."""
    destination = os.path.join(MEETINGS_DIR, target)
    linked = False
    try:
        # link + unlink conserva el contenido y falla sin sobreescribir destino.
        os.link(path, destination)
        linked = True
        # El link conserva el mtime original; el backoff debe empezar en este
        # fallo, no en la creación del handoff.
        os.utime(destination, None)
    except (FileExistsError, OSError):
        if linked:
            try:
                os.unlink(destination)
            except OSError:
                pass
        return False
    try:
        os.unlink(path)
    except OSError:
        try:
            os.unlink(destination)
        except OSError:
            pass
        return False
    return True


def fail(path: str, base: str, reason: str, permanent: bool = False) -> None:
    """Nunca borra el handoff: lo mueve a estado .error (permanente) o .retry*."""
    name = os.path.basename(path)
    if permanent:
        target = base + ".pending.error"
        if move_state(path, target):
            log("ERROR %s -> %s: %s" % (name, target, reason), "ERROR")
        else:
            log("ERROR %s: no se pudo mover a %s; se conserva el handoff: %s"
                % (name, target, reason), "ERROR")
        return
    # Estado actual -> intento que falló: .pending=1, .retry=2, .retry.2=3, ...
    gen = retry_generation(name)
    nxt = gen + 1
    if nxt > MAX_RETRIES:
        target = base + FAILED_SUFFIX
        if move_state(path, target):
            log("ABANDONO %s -> %s (se agotaron %d intentos): %s"
                % (name, target, MAX_RETRIES, reason), "ERROR")
        else:
            log("ABANDONO %s: no se pudo mover a %s; se conserva el handoff: %s"
                % (name, target, reason), "ERROR")
        return
    elif nxt == 1:
        target = base + ".pending.retry"
    else:
        target = base + ".pending.retry.%d" % nxt
    if move_state(path, target):
        log("FALLO %s -> %s (intento %d/%d): %s"
            % (name, target, nxt, MAX_RETRIES, reason), "ERROR")
    else:
        log("FALLO %s: no se pudo mover a %s; se conserva el handoff: %s"
            % (name, target, reason), "ERROR")


def _backup_path(path: str) -> str:
    fd, backup = tempfile.mkstemp(
        prefix=".%s.backup-" % os.path.basename(path), dir=MEETINGS_DIR)
    os.close(fd)
    os.unlink(backup)
    return backup


def _remove_if_exists(path: str) -> None:
    try:
        os.remove(path)
    except FileNotFoundError:
        pass


def _rollback_artifacts(temp_paths, published, backups) -> None:
    for final in reversed(published):
        _remove_if_exists(final)
    for final, backup in reversed(backups):
        if backup and os.path.exists(backup):
            try:
                os.replace(backup, final)
            except OSError as e:
                log("ROLLBACK no pudo restaurar %s: %s" % (final, e), "ERROR")
    for temp in temp_paths:
        _remove_if_exists(temp)


def _publish_artifacts(artifacts: list[tuple[str, str]]):
    """Publica todos los artefactos o restaura los previos si uno falla."""
    temp_paths = tuple(path + ".tmp" for path, _ in artifacts)
    backups = []
    published = []
    try:
        for (final, content), temp in zip(artifacts, temp_paths):
            with open(temp, "w", encoding="utf-8") as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(temp, 0o600)

        for (final, _content), temp in zip(artifacts, temp_paths):
            backup = _backup_path(final) if os.path.exists(final) else None
            if backup:
                os.replace(final, backup)
            backups.append((final, backup))
            os.replace(temp, final)
            published.append(final)
        return backups
    except Exception:
        _rollback_artifacts(temp_paths, published, backups)
        raise


def _finalize_artifacts(backups) -> None:
    for _final, backup in backups:
        if backup:
            try:
                os.remove(backup)
            except OSError as e:
                log("no se pudo limpiar backup de artefacto: %s" % e, "WARN")


def _checksum_of(path: str):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f).get("checksum")
    except (OSError, ValueError, AttributeError):
        return None


def is_revision(path: str, done_path: str) -> bool:
    """A handoff whose transcript changed since the acknowledged one.

    The app re-publishes a meeting under the same id when a retry fills the
    gaps of its transcript; the same checksum is a duplicate and is skipped.
    """
    new = _checksum_of(path)
    return isinstance(new, str) and new != _checksum_of(done_path)


def process_file(path: str, cfg: dict) -> None:
    name = os.path.basename(path)
    m = PENDING_RE.match(name)
    if not m:  # defensivo: solo se llama con archivos que matchean
        log("ignorado (no matchea .pending): %s" % name, "WARN")
        return
    base = m.group("base")
    done_path = os.path.join(MEETINGS_DIR, base + ".done")
    revision = os.path.exists(done_path) and is_revision(path, done_path)
    if os.path.exists(done_path) and not revision:
        log("skip %s: %s.done ya existe (idempotente)" % (name, base))
        return
    if revision:
        log("revisión de %s: el transcript cambió, se rehace el resumen" % base)

    # --- contrato ---
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            contract = json.load(f)
    except Exception as e:  # noqa: BLE001
        return fail(path, base, "JSON inválido: %s" % e, permanent=True)
    try:
        validate_contract(contract, base)
    except (TypeError, ValueError) as e:
        return fail(path, base, "contrato inválido: %s" % e, permanent=True)

    try:
        tpath = resolve(contract["transcriptPath"])
        audio_path = (resolve(contract["audioPath"])
                      if contract.get("audioPath") is not None else None)
    except (TypeError, ValueError) as e:
        return fail(path, base, "path de contrato inválido: %s" % e, permanent=True)
    reserved = {
        os.path.realpath(os.path.join(MEETINGS_DIR, base + suffix))
        for suffix in (".pending", ".done", ".notes.md", ".summary.json",
                       ".summary.html", ".summary.md")
    }
    if tpath in reserved or (audio_path is not None and
                             (audio_path in reserved or audio_path == tpath)):
        return fail(path, base, "path de contrato coincide con archivo de la reunión", permanent=True)
    if not tpath or not os.path.isfile(tpath):
        return fail(path, base, "transcript no encontrado: %s" % tpath, permanent=True)

    try:
        actual = sha256_file(tpath)
    except OSError as e:
        return fail(path, base, "no se pudo comprobar checksum: %s" % e, permanent=True)
    cksum = contract["checksum"]
    if actual != cksum.lower():
        return fail(path, base, "checksum mismatch (esperado %s, real %s)" % (cksum, actual), permanent=True)

    try:
        with open(tpath, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError as e:
        return fail(path, base, "no se pudo leer transcript: %s" % e, permanent=True)
    if not text.strip():
        return fail(path, base, "transcript vacío", permanent=True)

    notes_path = os.path.join(MEETINGS_DIR, base + ".notes.md")
    user_notes = ""
    if os.path.lexists(notes_path):
        if os.path.islink(notes_path) or not os.path.isfile(notes_path):
            return fail(path, base, "notas inválidas: sidecar no regular", permanent=True)
        try:
            if os.path.getsize(notes_path) > 64 * 1024:
                raise ValueError("notas exceden 64 KiB")
            with open(notes_path, encoding="utf-8") as f:
                user_notes = f.read()
        except (OSError, UnicodeError, ValueError) as e:
            return fail(path, base, "notas inválidas: %s" % e, permanent=True)

    try:
        vocabulary = load_tag_vocabulary(cfg.get("tag_vocabulary_dir"))
    except ValueError as e:
        return fail(path, base, "config de vocabulario inválida: %s" % e)

    # --- LLM (o dry run) ---
    dry = bool(cfg.get("dry_run"))
    model = cfg.get("model")
    summary = None
    if dry:
        summary = dry_run_summary(contract)
        log("DRY RUN %s: resumen mock (sin LLM)" % name)
    else:
        try:
            if not model:
                model = discover_model(cfg)
                log("model auto-descubierto: %s" % model)
            raw = contract.get("speakers")
            speakers = [s for s in raw if isinstance(s, str) and s] if isinstance(raw, list) else []
            header = (
                "Título: %s\nFecha: %s\nTags permitidos: %s\nHablantes etiquetados: %s\n\n"
                "Notas escritas por la persona (priorizalas como contexto):\n%s\n\n"
                % (contract.get("title") or "", contract.get("startedAt") or "",
                   ", ".join(vocabulary) if vocabulary else "ninguno",
                   ", ".join(speakers) if speakers else "sin etiquetas", user_notes)
            )
            llm_obj = summarize(cfg, model, header, text)
            summary = normalize_summary(llm_obj)
            summary["tags"] = filter_tags(llm_obj.get("tags"), vocabulary)
        except Exception as e:  # noqa: BLE001 — red/LLM: retry, no se borra nada
            return fail(path, base, "fallo LLM/red: %s" % e)

    if dry:
        summary["tags"] = []

    # --- artefactos (publicación conjunta con rollback) ---
    out = {
        "meetingId": contract.get("meetingId"),
        "title": contract.get("title"),
        "fecha": contract.get("startedAt") or datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "durationSec": contract.get("durationSec"),
        "dry_run": dry,
        "summary_model": None if dry else model,
        "generatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "user_notes": user_notes,
    }
    out.update(summary)  # resumen, action_items, decisiones, asistentes
    json_path = os.path.join(MEETINGS_DIR, base + ".summary.json")
    html_path = os.path.join(MEETINGS_DIR, base + ".summary.html")
    md_path = os.path.join(MEETINGS_DIR, base + ".summary.md")
    try:
        html_text = build_html(contract, summary, dry, model, text, user_notes)
        markdown_text = build_markdown(contract, summary, text, dry, user_notes)
        backups = _publish_artifacts([
            (json_path, json.dumps(out, ensure_ascii=False, indent=2)),
            (html_path, html_text),
            (md_path, markdown_text),
        ])
    except Exception as e:  # noqa: BLE001
        return fail(path, base, "escritura de artefactos falló: %s" % e)

    # --- ack idempotente + cleanup de audio ---
    try:
        os.chmod(path, 0o600)
        if os.path.exists(done_path) and not revision:
            raise FileExistsError("ya existe %s" % done_path)
        os.replace(path, done_path)  # atómico: .pending -> .done (una revisión lo reemplaza)
    except Exception as e:  # noqa: BLE001 — sin ack, no debe quedar artefacto huérfano
        _rollback_artifacts((), (json_path, html_path, md_path), backups)
        return fail(path, base, "ack del handoff falló: %s" % e)
    _finalize_artifacts(backups)
    # Transcript: privado también (0600) — lo escribe la app con umask default.
    if os.path.isfile(tpath):
        try:
            os.chmod(tpath, 0o600)
        except OSError:
            pass
    log("OK %s -> %s (título: %s, %d chars transcript, modelo: %s)"
        % (name, os.path.basename(done_path), contract.get("title"), len(text), model))

    # --- puente post-resumen (Hermes/kanban/telegram): hook opcional ---
    # Orden de búsqueda: $MEETCAPTURE_POST_SUMMARY -> ~/.meetcapture/post-summary.sh
    hook = os.environ.get("MEETCAPTURE_POST_SUMMARY") or ""
    if not hook or not os.path.isfile(hook):
        hook = os.path.expanduser("~/.meetcapture/post-summary.sh")
    if os.path.isfile(hook) and os.access(hook, os.X_OK):
        json_path = os.path.join(MEETINGS_DIR, base + ".summary.json")
        try:
            rc = subprocess.run([hook, json_path], timeout=60,
                                capture_output=True, text=True)
            log("hook post-summary %s rc=%d%s"
                % (os.path.basename(hook), rc.returncode,
                   (" :: " + rc.stdout.strip()[:200]) if rc.stdout.strip() else ""))
        except Exception as e:  # noqa: BLE001 — el hook nunca rompe el pipeline
            log("hook post-summary falló: %s" % e, "ERROR")

    if audio_path is not None:
        apath = audio_path
        if cfg.get("keep_audio"):
            log("audio conservado (keep_audio=true): %s" % apath)
        elif os.path.isfile(apath):
            try:
                os.remove(apath)
                log("audio borrado (keep_audio=false): %s" % apath)
            except OSError as e:
                log("no se pudo borrar audio; se conserva: %s (%s)" % (apath, e), "WARN")
        else:
            log("audioPath sin archivo, nada que borrar: %s" % apath, "WARN")


def run_once(cfg: dict, now: float | None = None) -> int:
    if not os.path.isdir(MEETINGS_DIR):
        return 0
    candidates = sorted(f for f in os.listdir(MEETINGS_DIR) if PENDING_RE.match(f))
    files = [f for f in candidates if due(os.path.join(MEETINGS_DIR, f), now)]
    waiting = len(candidates) - len(files)
    if waiting:
        log("%d handoff(s) en backoff, todavía no vencen" % waiting)
    for name in files:
        try:
            process_file(os.path.join(MEETINGS_DIR, name), cfg)
        except Exception as e:  # noqa: BLE001 — nunca morir por un handoff
            log("EXCEPCIÓN inesperada procesando %s: %s" % (name, e), "ERROR")
    if files:
        log("pasada --once: %d handoff(s) procesado(s)" % len(files))
    return len(files)


def run_watch(cfg: dict) -> None:
    log("watch mode activo: polling cada 30s sobre %s" % MEETINGS_DIR)
    while True:
        try:
            run_once(cfg)
        except Exception as e:  # noqa: BLE001
            log("watch loop error: %s" % e, "ERROR")
        time.sleep(30)


def retry_failed() -> int:
    """Re-encola los .pending.failed (vuelven a .pending, gen 0)."""
    if not os.path.isdir(MEETINGS_DIR):
        return 0
    count = 0
    for name in sorted(os.listdir(MEETINGS_DIR)):
        if not name.endswith(FAILED_SUFFIX):
            continue
        base = name[: -len(FAILED_SUFFIX)]
        if move_state(os.path.join(MEETINGS_DIR, name), base + ".pending"):
            log("RE-ENCOLADO %s -> %s.pending" % (name, base))
            count += 1
        else:
            log("NO RE-ENCOLADO %s: ya existe %s.pending; se conservan ambos"
                % (name, base), "WARN")
    return count


def acquire_lock() -> bool:
    """Instancia única: si otro dispatcher ya está corriendo, salir ya."""
    if fcntl is None:
        return True
    lock_path = os.path.join(LOG_DIR, "dispatcher.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    # El descriptor entero permanece abierto mientras viva el proceso; no
    # ocupamos un fd global arbitrario (10) para sostener el lock.
    os.set_inheritable(fd, False)
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    return True


def main() -> None:
    ensure_dirs()
    if not acquire_lock():
        sys.stderr.write("otra instancia ya está procesando; saliendo\n")
        sys.exit(0)
    cfg = load_config()
    if "--retry-failed" in sys.argv:
        n = retry_failed()
        log("--retry-failed: %d handoff(s) re-encolado(s)" % n)
    if "--watch" in sys.argv:
        run_watch(cfg)
    else:  # default y --once: una pasada y sale
        run_once(cfg)


if __name__ == "__main__":
    main()
