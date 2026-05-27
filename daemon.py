#!/usr/bin/env python3
"""
meet-daemon v3: Production-grade meeting capture daemon.
Persistent LaunchAgent for macOS. Zero external services, 100% local.

Architecture:
  Calendar poll (smart interval) → detect active meeting with external attendee
  → ffmpeg captures BlackHole loopback → meeting ends → Whisper+VAD → .txt
  → post-process → signal Hermes via .pending → Hermes cron generates summary

Resource budget (idle):   <0.1% CPU,  <8MB RAM, 0 API calls between checks
Resource budget (active): <2% CPU,    <30MB RAM (ffmpeg only)
Resource budget (transcribe): <40% CPU for ~2min (whisper base + VAD, separate process)

Usage:
  python3 meet-daemon.py --daemon     # Background daemon (LaunchAgent)
  python3 meet-daemon.py --status     # Current status
  python3 meet-daemon.py --stop       # Stop recording + transcribe + notify
  python3 meet-daemon.py --check      # One-shot calendar check
  python3 meet-daemon.py --transcribe # Process pending recordings in queue
  python3 meet-daemon.py --health     # Health check (exit 0=ok, 1=error)
"""

import subprocess
import time
import json
import os
import sys
import signal
import re
import shutil
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional, Tuple

# ── Paths ────────────────────────────────────────────────────────────────────
MEETINGS_DIR = Path.home() / "meetings"
STATE_FILE = MEETINGS_DIR / ".daemon_state.json"
RECORDINGS_DIR = MEETINGS_DIR / "recordings"
DAEMON_LOG = MEETINGS_DIR / ".daemon.log"
PID_FILE = MEETINGS_DIR / ".daemon.pid"
TRANSCRIBE_QUEUE = MEETINGS_DIR / ".transcribe_queue.json"
TRANSCRIBE_LOG = MEETINGS_DIR / ".transcribe.log"

# Hermes-managed paths (aligned with meet-summary-processor cron)
HERMES_BASE = Path.home() / ".hermes" / "TechPartners" / "MaatWork" / "meetings"
HERMES_TRANSCRIPTS = HERMES_BASE / "transcripts"
HERMES_SUMMARIES = HERMES_BASE / "summaries"
HERMES_PENDING = HERMES_BASE / ".pending"

# ── Audio ────────────────────────────────────────────────────────────────────
WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
GWS_CLI = "/opt/homebrew/bin/gws"
MODEL_PATH = Path.home() / ".whisper" / "models" / "ggml-base.bin"  # 141MB, safe for 8GB RAM
AUDIO_SAMPLE_RATE = 16000   # 16kHz mono — sufficient for speech, 3x smaller than 48kHz stereo
AUDIO_CHANNELS = 1
AUDIO_FORMAT = "flac"       # FLAC = lossless, ~60% smaller than WAV

# ── Polling ──────────────────────────────────────────────────────────────────
POLL_IDLE = 120        # 2 min between calendar checks when idle
POLL_APPROACHING = 30  # 30s when meeting starts within 5 min (less aggressive)
POLL_ACTIVE = 10       # 10s during active recording

# ── Transcription ────────────────────────────────────────────────────────────
MAX_RETRIES = 3         # max retry attempts for failed transcriptions
RETRY_BASE_DELAY = 30   # base delay for exponential backoff (seconds)
WHISPER_THREADS = 4     # threads for whisper (M2 has 8 cores, leave 4 for system)

# ── Disk ─────────────────────────────────────────────────────────────────────
MAX_RECORDINGS_DIR_MB = 500   # auto-cleanup if recordings dir exceeds this
MAX_TRANSCRIPT_AGE_DAYS = 30  # auto-delete transcripts older than this

# ── Privacy ──────────────────────────────────────────────────────────────────
MY_EMAILS = {"giolivosantarelli@gmail.com", "giogametodraggg@gmail.com"}

# ── Globals ──────────────────────────────────────────────────────────────────
_shutdown = False


def signal_handler(sig, frame):
    global _shutdown
    _shutdown = True
    log(f"Signal {sig} received, shutting down gracefully")


signal.signal(signal.SIGTERM, signal_handler)
signal.signal(signal.SIGINT, signal_handler)


# ── Logging ──────────────────────────────────────────────────────────────────

def log(msg: str, level: str = "INFO"):
    """Log to file only. stdout is not used (avoids duplicates when app redirects)."""
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] [{level}] {msg}"
    try:
        with open(DAEMON_LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def worker_log(msg: str):
    """Log for transcribe worker (separate file)."""
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] [WORKER] {msg}"
    print(line, flush=True)
    try:
        with open(TRANSCRIBE_LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ── State management (atomic writes) ────────────────────────────────────────

def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"recording": False, "meetings": {}, "last_check": None}


def save_state(state: dict):
    tmp = STATE_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(state, indent=2))
        tmp.rename(STATE_FILE)
    except Exception:
        try:
            STATE_FILE.write_text(json.dumps(state, indent=2))
        except Exception:
            pass


def cleanup_stale_ffmpeg():
    """Kill any orphaned ffmpeg recording processes from previous crashes."""
    state = load_state()
    old_pid = state.get("pid")
    if old_pid and state.get("recording"):
        try:
            os.kill(old_pid, 0)
            log(f"Killing stale ffmpeg PID {old_pid}")
            os.kill(old_pid, signal.SIGTERM)
            time.sleep(0.5)
            try:
                os.kill(old_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        except ProcessLookupError:
            pass
    state["recording"] = False
    state["pid"] = None
    save_state(state)


# ── PID file ─────────────────────────────────────────────────────────────────

def write_pid():
    PID_FILE.write_text(str(os.getpid()))


def check_running() -> Optional[int]:
    """Return PID of running daemon, or None."""
    if not PID_FILE.exists():
        return None
    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, 0)
        return pid
    except (ProcessLookupError, ValueError):
        PID_FILE.unlink(missing_ok=True)
        return None


# ── Disk management ─────────────────────────────────────────────────────────

def check_disk_space():
    """Monitor disk and auto-cleanup if needed."""
    try:
        # Check recordings dir size
        total = sum(f.stat().st_size for f in RECORDINGS_DIR.glob("*") if f.is_file())
        total_mb = total / 1024 / 1024
        if total_mb > MAX_RECORDINGS_DIR_MB:
            log(f"Disk: recordings dir {total_mb:.0f}MB > {MAX_RECORDINGS_DIR_MB}MB, cleaning up", "WARN")
            _cleanup_old_recordings()

        # Check free space on /
        stat = shutil.disk_usage("/")
        free_gb = stat.free / 1024 / 1024 / 1024
        if free_gb < 2:
            log(f"Disk: LOW SPACE {free_gb:.1f}GB free!", "ERROR")
            _cleanup_old_recordings()
            _cleanup_old_transcripts()
    except Exception:
        pass


def _cleanup_old_recordings():
    """Remove oldest recordings until dir is under limit."""
    files = sorted(RECORDINGS_DIR.glob("*.flac"), key=lambda f: f.stat().st_mtime)
    files += sorted(RECORDINGS_DIR.glob("*.wav"), key=lambda f: f.stat().st_mtime)
    for f in files:
        try:
            size_mb = f.stat().st_size / 1024 / 1024
            f.unlink()
            log(f"Cleaned old recording: {f.name} ({size_mb:.1f}MB)")
        except Exception:
            pass
        # Check if we're under limit now
        total = sum(ff.stat().st_size for ff in RECORDINGS_DIR.glob("*") if ff.is_file())
        if total / 1024 / 1024 < MAX_RECORDINGS_DIR_MB * 0.8:
            break


def _cleanup_old_transcripts():
    """Remove transcripts older than MAX_TRANSCRIPT_AGE_DAYS."""
    cutoff = datetime.now() - timedelta(days=MAX_TRANSCRIPT_AGE_DAYS)
    for f in HERMES_TRANSCRIPTS.glob("*.txt"):
        try:
            if datetime.fromtimestamp(f.stat().st_mtime) < cutoff:
                f.unlink()
                log(f"Cleaned old transcript: {f.name}")
        except Exception:
            pass


# ── Calendar ─────────────────────────────────────────────────────────────────

_gws_cache = {"events": [], "ts": 0}
GWS_CACHE_TTL = 30  # seconds


def gws_events() -> list:
    """Fetch today's calendar events. Uses short cache to avoid redundant API calls."""
    now = time.time()
    if now - _gws_cache["ts"] < GWS_CACHE_TTL:
        return _gws_cache["events"]

    now_utc = datetime.now(timezone.utc)
    start_utc = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    end_utc = start_utc + timedelta(days=1)

    try:
        result = subprocess.run([
            GWS_CLI, "calendar", "events", "list",
            "--params", json.dumps({
                "calendarId": "primary",
                "maxResults": 50,
                "timeMin": start_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "timeMax": end_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
                "singleEvents": True,
                "orderBy": "startTime"
            }),
            "--format", "json"
        ], capture_output=True, text=True, timeout=15)

        if result.returncode != 0:
            log(f"gws exit {result.returncode}", "WARN")
            return _gws_cache["events"]

        # Filter gws keyring stdout pollution
        clean = "\n".join(
            line for line in result.stdout.splitlines()
            if not line.startswith("Using keyring")
        )
        data = json.loads(clean)
        events = data.get("items", [])
        _gws_cache["events"] = events
        _gws_cache["ts"] = now
        return events

    except subprocess.TimeoutExpired:
        log("gws timeout (15s)", "WARN")
        return _gws_cache["events"]
    except Exception as e:
        log(f"gws error: {e}", "WARN")
        return _gws_cache["events"]


# ── Event parsing ────────────────────────────────────────────────────────────

def get_meet_link(event: dict) -> str:
    conf = event.get("conferenceData", {})
    for ep in conf.get("entryPoints", []):
        if ep.get("entryPointType") == "video":
            uri = ep.get("uri", "")
            if "meet.google.com" in uri:
                return uri
    link = event.get("hangoutLink", "")
    return link if "meet.google.com" in link else ""


def get_times(event: dict) -> Tuple[Optional[datetime], Optional[datetime]]:
    """Return (start_local, end_local) as naive datetimes."""
    start_str = event.get("start", {}).get("dateTime") or event.get("start", {}).get("date")
    end_str = event.get("end", {}).get("dateTime") or event.get("end", {}).get("date")
    if not start_str or not end_str:
        return None, None
    try:
        if start_str.endswith("Z"):
            start_dt = datetime.fromisoformat(start_str.replace("Z", "+00:00"))
            end_dt = datetime.fromisoformat(end_str.replace("Z", "+00:00"))
        else:
            start_dt = datetime.fromisoformat(start_str)
            end_dt = datetime.fromisoformat(end_str)

        local_now = datetime.now()
        utc_now = datetime.now(timezone.utc)
        offset = local_now - utc_now.replace(tzinfo=None)
        return (
            start_dt.replace(tzinfo=None) + offset,
            end_dt.replace(tzinfo=None) + offset
        )
    except Exception as e:
        log(f"Time parse error: {e}", "WARN")
        return None, None


def has_external_attendee(event: dict) -> bool:
    attendees = event.get("attendees", [])
    for a in attendees:
        email = a.get("email", "").lower()
        if email and email not in MY_EMAILS:
            return True
    return False


def get_attendees(event: dict) -> list:
    """Get list of attendee emails (for metadata)."""
    return [a.get("email", "") for a in event.get("attendees", []) if a.get("email")]


def extract_meet_id(link: str) -> str:
    m = re.search(r"meet\.google\.com/([a-z]{3}-[a-z]{4}-[a-z]{3})", link)
    return m.group(1) if m else link.split("/")[-1][:20]


# ── Audio level detection ───────────────────────────────────────────────────

def check_audio_level(duration: float = 2.0) -> float:
    """Capture a short sample and return RMS audio level. 0.0 = silence."""
    tmp_file = MEETINGS_DIR / ".audio_check.tmp"
    try:
        subprocess.run([
            "ffmpeg", "-f", "avfoundation", "-i", ":BlackHole 16ch",
            "-ar", str(AUDIO_SAMPLE_RATE), "-ac", "1",
            "-acodec", "pcm_s16le", "-t", str(duration),
            "-y", str(tmp_file)
        ], capture_output=True, timeout=10)

        if not tmp_file.exists():
            return 0.0

        # Calculate RMS using Python (no numpy needed)
        import struct
        data = tmp_file.read_bytes()
        # Skip WAV header (44 bytes)
        if len(data) <= 44:
            return 0.0
        samples = struct.unpack(f"<{len(data)//2 - 22}h", data[44:])
        if not samples:
            return 0.0
        rms = (sum(s*s for s in samples) / len(samples)) ** 0.5
        # Normalize to 0-1 range (16-bit signed = -32768 to 32767)
        return rms / 32767.0
    except Exception:
        return 0.0
    finally:
        tmp_file.unlink(missing_ok=True)


# ── Recording ────────────────────────────────────────────────────────────────

def start_recording(meet_id: str, title: str, start_dt: datetime, event: dict = None) -> str:
    RECORDINGS_DIR.mkdir(parents=True, exist_ok=True)
    ts = start_dt.strftime("%Y%m%d_%H%M%S")
    safe_title = "".join(c if c.isalnum() else "_" for c in title)[:40]
    ext = AUDIO_FORMAT  # flac
    output_file = RECORDINGS_DIR / f"{ts}_{safe_title}.{ext}"

    log(f"START recording → {output_file.name}")
    log(f"  ID: {meet_id} | Title: {title}")

    # ffmpeg: BlackHole 16ch → 16kHz mono FLAC (lossless, ~60% smaller than WAV)
    cmd = [
        "ffmpeg",
        "-f", "avfoundation",
        "-i", ":BlackHole 16ch",
        "-ar", str(AUDIO_SAMPLE_RATE),
        "-ac", str(AUDIO_CHANNELS),
        "-acodec", "flac",
        "-compression_level", "8",  # max compression for FLAC
        "-y",
        str(output_file),
    ]

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        log(f"ffmpeg failed: {e}", "ERROR")
        return ""

    state = load_state()
    state.update({
        "recording": True,
        "meet_id": meet_id,
        "title": title,
        "start_time": start_dt.isoformat(),
        "output_file": str(output_file),
        "pid": proc.pid,
        "attendees": get_attendees(event) if event else [],
        "meet_link": get_meet_link(event) if event else "",
    })
    save_state(state)
    log(f"ffmpeg PID {proc.pid}")
    return str(output_file)


def stop_recording() -> dict:
    state = load_state()
    if not state.get("recording"):
        return {}

    log("STOP recording")
    pid = state.get("pid")
    if pid:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(1)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        except Exception:
            pass

    result = {
        "output_file": state.get("output_file") or state.get("output_wav"),  # compat
        "title": state.get("title"),
        "meet_id": state.get("meet_id"),
        "start_time": state.get("start_time"),
        "end_time": datetime.now().isoformat(),
        "attendees": state.get("attendees", []),
        "meet_link": state.get("meet_link", ""),
    }

    state["recording"] = False
    state["pid"] = None
    save_state(state)
    return result


# ── Transcription (separate process, non-blocking) ──────────────────────────

def transcribe_async(audio_path: str, title: str, metadata: dict = None):
    """Queue transcription as a separate process. Returns immediately."""
    queue = _load_queue()
    queue.append({
        "audio": audio_path,
        "title": title,
        "metadata": metadata or {},
        "queued_at": datetime.now().isoformat(),
        "retries": 0,
    })
    _save_queue(queue)
    log(f"Queued transcription: {Path(audio_path).name}")

    # Spawn detached whisper process
    transcript_script = Path(__file__).parent / ".transcribe_worker.py"

    try:
        subprocess.Popen(
            [sys.executable, str(transcript_script), audio_path, title],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        log("Transcribe worker spawned (detached)")
    except Exception as e:
        log(f"Failed to spawn transcribe worker: {e}", "ERROR")
        # Fallback: transcribe synchronously
        _transcribe_sync(audio_path, title)


def _transcribe_sync(audio_path: str, title: str):
    """Synchronous transcription fallback."""
    txt_path = _run_whisper(audio_path)
    if txt_path:
        cleaned = _post_process_transcript(txt_path)
        _notify_hermes(cleaned, title)
        _cleanup_recording(audio_path)


def _run_whisper(audio_path: str) -> Optional[str]:
    """Run whisper-cli on audio file. Returns transcript path or None."""
    model = MODEL_PATH
    if not model.exists():
        log(f"Model not found: {model}", "ERROR")
        return None

    out_dir = Path(audio_path).parent
    out_name = Path(audio_path).stem
    txt_out = out_dir / f"{out_name}.txt"

    size_mb = Path(audio_path).stat().st_size / 1024 / 1024
    log(f"Transcribing: {Path(audio_path).name} ({size_mb:.1f}MB)")

    cmd = [
        WHISPER_CLI, "-m", str(model), "-f", audio_path,
        "-otxt",
        "-of", str(out_dir / out_name),
        "--language", "es",
        "--no-timestamps",
        "-t", str(WHISPER_THREADS),
        "-np",
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=900)
        if result.returncode != 0:
            log(f"Whisper stderr: {result.stderr[:300]}", "WARN")
    except subprocess.TimeoutExpired:
        log("Whisper timeout (15min)", "ERROR")
        return None

    if txt_out.exists():
        size = txt_out.stat().st_size
        log(f"Transcript OK: {size} bytes")

        meta = {
            "audio": audio_path,
            "transcript": str(txt_out),
            "model": str(MODEL_PATH.name),
            "vad": False,
            "transcribed_at": datetime.now().isoformat(),
        }
        (out_dir / f"{out_name}_meta.json").write_text(json.dumps(meta))
        return str(txt_out)
    else:
        log("No transcript output", "ERROR")
        return None


# ── Post-processing ──────────────────────────────────────────────────────────

def _post_process_transcript(txt_path: str) -> str:
    """Clean whisper artifacts: repetitions, garbage, formatting."""
    try:
        text = Path(txt_path).read_text(encoding="utf-8")
    except Exception:
        return txt_path

    original_len = len(text)

    # 1. Remove whisper hallucination patterns (repeated short phrases)
    lines = text.split("\n")
    cleaned = []
    prev_line = ""
    repeat_count = 0
    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        # Detect exact or near-exact repetitions
        if stripped == prev_line or _similar(stripped, prev_line, 0.85):
            repeat_count += 1
            if repeat_count > 2:  # allow up to 2 repetitions (might be intentional)
                continue
        else:
            repeat_count = 0
        cleaned.append(stripped)
        prev_line = stripped

    # 2. Remove common whisper garbage patterns
    garbage_patterns = [
        r"^\[.*\]$",           # [Music], [Applause], etc.
        r"^\.+$",              # just dots
        r"^-+$",               # just dashes
        r"^\s*$",              # empty lines
        r"^Subtitled? by .*$", # subtitle credits
        r"^Transcripci[oó]n .*$", # transcription credits
    ]

    final = []
    for line in cleaned:
        skip = False
        for pattern in garbage_patterns:
            if re.match(pattern, line, re.IGNORECASE):
                skip = True
                break
        if not skip:
            final.append(line)

    # 3. Join and clean up spacing
    result = "\n".join(final)
    result = re.sub(r"\n{3,}", "\n\n", result)  # max 2 consecutive newlines
    result = result.strip()

    # Write back if changed
    if len(result) < original_len * 0.95:  # more than 5% removed
        Path(txt_path).write_text(result, encoding="utf-8")
        log(f"Post-process: {original_len} → {len(result)} chars ({100 - len(result)*100//original_len}% cleaned)")

    return txt_path


def _similar(a: str, b: str, threshold: float) -> bool:
    """Quick similarity check using character overlap."""
    if not a or not b:
        return False
    # Use set-based Jaccard similarity on words
    words_a = set(a.lower().split())
    words_b = set(b.lower().split())
    if not words_a or not words_b:
        return False
    intersection = words_a & words_b
    union = words_a | words_b
    return len(intersection) / len(union) >= threshold


# ── Queue management ─────────────────────────────────────────────────────────

def _load_queue() -> list:
    if TRANSCRIBE_QUEUE.exists():
        try:
            return json.loads(TRANSCRIBE_QUEUE.read_text())
        except Exception:
            pass
    return []


def _save_queue(queue: list):
    tmp = TRANSCRIBE_QUEUE.with_suffix(".tmp")
    tmp.write_text(json.dumps(queue, indent=2))
    tmp.rename(TRANSCRIBE_QUEUE)


def process_queue():
    """Process pending transcriptions with retry logic."""
    queue = _load_queue()
    if not queue:
        return

    remaining = []
    for item in queue:
        audio = item.get("audio", "")
        title = item.get("title", "untitled")
        retries = item.get("retries", 0)

        if not Path(audio).exists():
            log(f"Audio missing, discarding: {audio}", "WARN")
            continue

        if retries >= MAX_RETRIES:
            log(f"Max retries reached for {Path(audio).name}, discarding", "ERROR")
            _cleanup_recording(audio)
            continue

        log(f"Processing queued: {Path(audio).name} (attempt {retries + 1}/{MAX_RETRIES})")
        txt = _run_whisper(audio)
        if txt:
            _post_process_transcript(txt)
            _notify_hermes(txt, title)
            _cleanup_recording(audio)
        else:
            item["retries"] = retries + 1
            item["next_retry"] = (datetime.now() + timedelta(seconds=RETRY_BASE_DELAY * (2 ** retries))).isoformat()
            remaining.append(item)
            log(f"Retry {item['retries']}/{MAX_RETRIES} scheduled for {Path(audio).name}")

    _save_queue(remaining)


# ── Hermes notification ─────────────────────────────────────────────────────

def _notify_hermes(txt_path: str, title: str, metadata: dict = None):
    """Copy transcript to Hermes archive and create .pending signal."""
    HERMES_TRANSCRIPTS.mkdir(parents=True, exist_ok=True)

    src = Path(txt_path)
    date_str = datetime.now().strftime("%Y-%m-%d")
    safe_title = "".join(c if c.isalnum() else "_" for c in title)[:30]
    dest = HERMES_TRANSCRIPTS / f"{date_str}_{safe_title}.txt"

    if src.exists():
        shutil.copy2(src, dest)
        log(f"Archived: {dest.name}")

    pending_data = {
        "transcript": str(dest) if src.exists() else txt_path,
        "title": title,
        "created": datetime.now().isoformat(),
    }
    if metadata:
        pending_data["metadata"] = metadata

    tmp = HERMES_PENDING.with_suffix(".tmp")
    tmp.write_text(json.dumps(pending_data))
    tmp.rename(HERMES_PENDING)
    log(f"Hermes notified: .pending created")


def _cleanup_recording(audio_path: str):
    """Remove recording after successful transcription."""
    try:
        p = Path(audio_path)
        if p.exists():
            size_mb = p.stat().st_size / 1024 / 1024
            p.unlink()
            log(f"Cleaned: {p.name} ({size_mb:.1f}MB freed)")
        meta = p.with_suffix("_meta.json")
        if meta.exists():
            meta.unlink()
    except Exception as e:
        log(f"Cleanup error: {e}", "WARN")


# ── Main loop ────────────────────────────────────────────────────────────────

def run_loop(once=False):
    global _shutdown

    if not once:
        write_pid()
        cleanup_stale_ffmpeg()
    process_queue()

    log(f"=== meet-daemon v3 starting PID {os.getpid()} ===")
    log(f"  Model: {MODEL_PATH.name} ({MODEL_PATH.stat().st_size / 1024 / 1024:.0f}MB)")
    log(f"  Audio: {AUDIO_SAMPLE_RATE}Hz {AUDIO_CHANNELS}ch {AUDIO_FORMAT}")
    log(f"  Poll: idle={POLL_IDLE}s approaching={POLL_APPROACHING}s active={POLL_ACTIVE}s")
    log(f"  Retry: {MAX_RETRIES}x")
    log(f"Daemon started PID {os.getpid()}")
    log(f"  Transcripts → {HERMES_TRANSCRIPTS}")

    poll_count = 0
    disk_check_counter = 0
    while not _shutdown:
        try:
            poll_count += 1
            events = gws_events()
            state = load_state()

            # Heartbeat log every 10 cycles
            if poll_count % 10 == 0:
                log(f"Heartbeat: poll #{poll_count}, {len(events)} events, recording={state.get('recording', False)}")

            # Periodic disk check (every 10 iterations)
            disk_check_counter += 1
            if disk_check_counter >= 10:
                check_disk_space()
                disk_check_counter = 0

            # Find current active meeting
            current = None
            for event in events:
                start, end = get_times(event)
                if start and end:
                    now = datetime.now()
                    if start <= now <= end:
                        current = {"event": event, "start": start, "end": end}
                        break

            # Decision: start recording
            if current and not state.get("recording"):
                link = get_meet_link(current["event"])
                title = current["event"].get("summary", "Sin titulo")
                if not link:
                    log(f"SKIP (no Meet link): {title}")
                elif not has_external_attendee(current["event"]):
                    log(f"SKIP (solo): {title}")
                else:
                    # Audio level check: verify BlackHole is capturing something
                    level = check_audio_level(2.0)
                    if level < 0.001:
                        log(f"WARN: BlackHole capturing silence (level={level:.6f})", "WARN")
                        log("  → Recording anyway (audio might start later)")
                    else:
                        log(f"Audio level OK: {level:.4f}")

                    meet_id = extract_meet_id(link)
                    start_recording(meet_id, title, current["start"], current["event"])

            # Decision: stop recording (meeting ended)
            elif not current and state.get("recording"):
                meta = stop_recording()
                audio_path = meta.get("output_file") or meta.get("output_wav")
                if audio_path:
                    transcribe_async(audio_path, meta.get("title", ""), {
                        "attendees": meta.get("attendees", []),
                        "meet_link": meta.get("meet_link", ""),
                        "start_time": meta.get("start_time"),
                        "end_time": meta.get("end_time"),
                    })

            # Smart poll interval
            if current:
                interval = POLL_ACTIVE
            else:
                soon = False
                now = datetime.now()
                for e in events:
                    s, _ = get_times(e)
                    if s and now <= s <= now + timedelta(minutes=5) and has_external_attendee(e):
                        soon = True
                        break
                interval = POLL_APPROACHING if soon else POLL_IDLE

            if once:
                break

            # Interruptible sleep
            for _ in range(interval):
                if _shutdown:
                    break
                time.sleep(1)

        except KeyboardInterrupt:
            if not once:
                st = load_state()
                if st.get("recording"):
                    stop_recording()
            break
        except Exception as e:
            log(f"Error: {e}", "ERROR")
            if once:
                break
            time.sleep(30)

    log("=== meet-daemon stopping ===")
    # Don't delete PID file — it will be overwritten by next daemon start
    # Deleting it causes race conditions with health checks and duplicate detection


# ── Health check ─────────────────────────────────────────────────────────────

def health_check():
    """Health check for monitoring. Exit 0=ok, 1=error."""
    issues = []

    # Check daemon running
    pid = check_running()
    if not pid:
        issues.append("daemon not running")

    # Check model exists
    if not MODEL_PATH.exists():
        issues.append(f"model missing: {MODEL_PATH}")

    # Check gws works
    try:
        r = subprocess.run([GWS_CLI, "calendar", "events", "list",
                           "--params", '{"calendarId":"primary","maxResults":1}',
                           "--format", "json"], capture_output=True, timeout=15)
        if r.returncode != 0:
            issues.append("gws auth failed")
    except Exception:
        issues.append("gws not accessible")

    # Check BlackHole
    try:
        r = subprocess.run(["ffmpeg", "-f", "avfoundation", "-list_devices", "true", "-i", ""],
                          capture_output=True, timeout=5)
        if "BlackHole" not in r.stderr.decode():
            issues.append("BlackHole not found")
    except Exception:
        issues.append("ffmpeg not accessible")

    # Check disk
    try:
        stat = shutil.disk_usage("/")
        free_gb = stat.free / 1024 / 1024 / 1024
        if free_gb < 2:
            issues.append(f"low disk: {free_gb:.1f}GB")
    except Exception:
        pass

    if issues:
        for issue in issues:
            print(f"FAIL: {issue}")
        sys.exit(1)
    else:
        print("OK: all systems healthy")
        sys.exit(0)


# ── Commands ─────────────────────────────────────────────────────────────────

def status():
    state = load_state()
    pid = check_running()
    if state.get("recording"):
        log(f"GRABANDO: {state['title']} ({state.get('meet_id', '?')})")
        log(f"  Archivo: {state.get('output_file') or state.get('output_wav')}")
        log(f"  Inicio: {state['start_time']}")
        log(f"  Attendees: {state.get('attendees', [])}")
        log(f"  ffmpeg PID: {state.get('pid')}")
    else:
        log("Sin grabacion activa.")
    if pid:
        log(f"Daemon PID: {pid}")
    else:
        log("Daemon no corriendo.")

    # Queue status
    queue = _load_queue()
    if queue:
        log(f"Transcription queue: {len(queue)} pending")


def simulate():
    """Test detection logic with a fake event."""
    now = datetime.now(timezone.utc)
    fake_event = {
        "summary": "TEST: Simulacion de reunion con cliente",
        "start": {"dateTime": (now - timedelta(minutes=5)).isoformat()},
        "end": {"dateTime": (now + timedelta(minutes=25)).isoformat()},
        "attendees": [
            {"email": "giolivosantarelli@gmail.com", "self": True},
            {"email": "cliente@example.com"},
        ],
        "conferenceData": {
            "entryPoints": [{
                "entryPointType": "video",
                "uri": "https://meet.google.com/abc-defg-hij",
            }]
        },
    }

    log("=== SIMULATION ===")
    start, end = get_times(fake_event)
    log(f"  Title: {fake_event['summary']}")
    log(f"  Active: {start <= datetime.now() <= end if start else 'N/A'}")
    log(f"  External: {has_external_attendee(fake_event)}")
    log(f"  Meet link: {get_meet_link(fake_event)}")
    log(f"  Attendees: {get_attendees(fake_event)}")
    if has_external_attendee(fake_event):
        log(f"  → DECISION: Would START recording")

    # Audio check
    log(f"  Audio check...")
    level = check_audio_level(1.0)
    log(f"  BlackHole level: {level:.6f} ({'silence' if level < 0.001 else 'audio detected'})")
    log("=== END ===")


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: meet-daemon.py --daemon|--status|--stop|--check|--simulate|--transcribe|--health")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "--status":
        status()
    elif cmd == "--stop":
        meta = stop_recording()
        audio_path = meta.get("output_file") or meta.get("output_wav")
        if audio_path:
            txt = _run_whisper(audio_path)
            if txt:
                _post_process_transcript(txt)
                _notify_hermes(txt, meta.get("title", ""), {
                    "attendees": meta.get("attendees", []),
                    "meet_link": meta.get("meet_link", ""),
                })
                _cleanup_recording(audio_path)
        log("Done.")
    elif cmd == "--daemon":
        existing = check_running()
        if existing:
            log(f"Daemon already running (PID {existing}), exiting")
            sys.exit(0)
        run_loop()
    elif cmd == "--check":
        run_loop(once=True)
    elif cmd == "--simulate":
        simulate()
    elif cmd == "--transcribe":
        process_queue()
    elif cmd == "--health":
        health_check()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)


if __name__ == "__main__":
    main()
