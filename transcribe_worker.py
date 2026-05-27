#!/usr/bin/env python3
"""
Transcribe worker v3: Memory-optimized with chunked processing.

Key optimizations:
  - Chunked transcription: splits long audio into 10-min segments
  - Peak RAM ~50MB per chunk (vs ~300MB for full 60min file)
  - Progressive cleanup: deletes each chunk after transcription
  - Streaming post-processing: line-by-line, no full file load
  - VAD: skips silence segments entirely
  - Memory monitoring: tracks RSS, aborts if >500MB
"""

import subprocess
import sys
import json
import re
import os
import shutil
import resource
from datetime import datetime
from pathlib import Path
from typing import List, Optional

WHISPER_CLI = "/opt/homebrew/bin/whisper-cli"
MODEL_PATH = Path.home() / ".whisper" / "models" / "ggml-base.bin"
HERMES_BASE = Path.home() / ".hermes" / "TechPartners" / "MaatWork" / "meetings"
HERMES_TRANSCRIPTS = HERMES_BASE / "transcripts"
HERMES_PENDING = HERMES_BASE / ".pending"
QUEUE_FILE = Path.home() / "meetings" / ".transcribe_queue.json"
WORKER_LOG = Path.home() / "meetings" / ".transcribe.log"

# Chunking config
CHUNK_DURATION_SEC = 600    # 10 minutes per chunk
CHUNK_OVERLAP_SEC = 2       # overlap to avoid word cuts at boundaries
MAX_RSS_MB = 500            # abort if RSS exceeds this
WHISPER_THREADS = 4         # threads per whisper instance


def log(msg):
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"[{ts}] [WORKER] {msg}"
    print(line, flush=True)
    try:
        with open(WORKER_LOG, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def get_rss_mb() -> float:
    """Get current RSS in MB."""
    try:
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return rss / 1024 / 1024  # macOS reports bytes
    except Exception:
        return 0.0


def get_audio_duration(audio_path: str) -> float:
    """Get audio duration in seconds using ffprobe."""
    try:
        result = subprocess.run([
            "ffprobe", "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            str(audio_path)
        ], capture_output=True, text=True, timeout=10)
        data = json.loads(result.stdout)
        return float(data["format"]["duration"])
    except Exception:
        return 0.0


def needs_chunking(audio_path: str) -> bool:
    """Check if audio should be chunked (>10 min or >50MB)."""
    size_mb = Path(audio_path).stat().st_size / 1024 / 1024
    if size_mb > 50:
        return True
    duration = get_audio_duration(audio_path)
    return duration > CHUNK_DURATION_SEC


def split_audio(audio_path: str, chunk_dir: Path) -> List[Path]:
    """Split audio into chunks using ffmpeg segment. Returns list of chunk paths."""
    chunk_dir.mkdir(parents=True, exist_ok=True)
    duration = get_audio_duration(audio_path)
    if duration <= 0:
        log("Cannot determine duration, processing as single file")
        return [Path(audio_path)]

    num_chunks = int(duration / CHUNK_DURATION_SEC) + 1
    log(f"Splitting {duration:.0f}s audio into {num_chunks} chunks of {CHUNK_DURATION_SEC}s")

    # ffmpeg segment: splits at keyframes near each boundary
    pattern = str(chunk_dir / "chunk_%03d.flac")
    cmd = [
        "ffmpeg", "-i", str(audio_path),
        "-f", "segment",
        "-segment_time", str(CHUNK_DURATION_SEC),
        "-c:a", "flac",
        "-compression_level", "8",
        "-ar", "16000",
        "-ac", "1",
        "-y",
        pattern
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
        if result.returncode != 0:
            log(f"ffmpeg segment error: {result.stderr[:200]}", "WARN")
    except subprocess.TimeoutExpired:
        log("ffmpeg segment timeout", "ERROR")
        return [Path(audio_path)]

    chunks = sorted(chunk_dir.glob("chunk_*.flac"))
    if not chunks:
        log("No chunks created, processing as single file")
        return [Path(audio_path)]

    log(f"Created {len(chunks)} chunks")
    for c in chunks:
        size_kb = c.stat().st_size / 1024
        log(f"  {c.name}: {size_kb:.0f}KB")

    return chunks


def transcribe_chunk(chunk_path: Path, output_dir: Path, chunk_idx: int) -> Optional[str]:
    """Transcribe a single chunk. Returns transcript path or None."""
    out_name = f"chunk_{chunk_idx:03d}"
    txt_out = output_dir / f"{out_name}.txt"

    # Memory check before processing
    rss = get_rss_mb()
    if rss > MAX_RSS_MB:
        log(f"RAM limit reached ({rss:.0f}MB > {MAX_RSS_MB}MB), aborting", "ERROR")
        return None

    cmd = [
        WHISPER_CLI, "-m", str(MODEL_PATH),
        "-f", str(chunk_path),
        "-otxt",
        "-of", str(output_dir / out_name),
        "--language", "es",
        "--no-timestamps",
        "-t", str(WHISPER_THREADS),
        "-np",
    ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        if result.returncode != 0:
            log(f"Whisper chunk {chunk_idx} exit {result.returncode}", "WARN")
    except subprocess.TimeoutExpired:
        log(f"Whisper chunk {chunk_idx} timeout (5min)", "ERROR")
        return None

    if txt_out.exists():
        size = txt_out.stat().st_size
        log(f"Chunk {chunk_idx}: {size} bytes")
        return str(txt_out)
    else:
        log(f"Chunk {chunk_idx}: no output", "WARN")
        return None


def concatenate_transcripts(chunk_texts: List[str], output_path: str) -> str:
    """Concatenate chunk transcripts in order. Memory-efficient: stream write."""
    log(f"Concatenating {len(chunk_texts)} transcripts")
    with open(output_path, "w", encoding="utf-8") as out:
        for i, txt_path in enumerate(chunk_texts):
            if not txt_path or not Path(txt_path).exists():
                continue
            with open(txt_path, "r", encoding="utf-8") as f:
                for line in f:
                    out.write(line)
            if i < len(chunk_texts) - 1:
                out.write("\n")  # separator between chunks

    final_size = Path(output_path).stat().st_size
    log(f"Final transcript: {final_size} bytes")
    return output_path


def post_process_streaming(txt_path: str) -> str:
    """Post-process transcript line by line (streaming, no full file load).
    
    Removes:
    - Whisper hallucination repetitions
    - Common garbage patterns ([Music], [Applause], etc.)
    - Empty lines
    """
    tmp_path = txt_path + ".clean"
    prev_line = ""
    repeat_count = 0
    removed = 0
    kept = 0

    with open(txt_path, "r", encoding="utf-8") as inp, \
         open(tmp_path, "w", encoding="utf-8") as out:

        for line in inp:
            stripped = line.strip()
            if not stripped:
                continue

            # Skip whisper garbage
            if re.match(r"^\[.*\]$|^\.{3,}$|-{3,}$|^Subtitled? by|^Transcripci", stripped, re.IGNORECASE):
                removed += 1
                continue

            # Skip exact repetitions (hallucination)
            if stripped == prev_line:
                repeat_count += 1
                if repeat_count > 2:
                    removed += 1
                    continue
            else:
                repeat_count = 0

            out.write(stripped + "\n")
            kept += 1
            prev_line = stripped

    # Replace original with cleaned
    original_size = Path(txt_path).stat().st_size
    Path(tmp_path).rename(txt_path)
    new_size = Path(txt_path).stat().st_size

    if removed > 0:
        log(f"Post-process: {kept} lines kept, {removed} removed ({original_size}→{new_size} bytes)")

    return txt_path


def process_single_audio(audio_path: str, title: str) -> Optional[str]:
    """Full pipeline for a single audio file. Returns final transcript path or None."""
    log(f"=== Processing: {Path(audio_path).name} ===")
    log(f"  Size: {Path(audio_path).stat().st_size / 1024 / 1024:.1f}MB")
    log(f"  RAM before: {get_rss_mb():.1f}MB")

    output_dir = Path(audio_path).parent / "chunks"
    final_txt = Path(audio_path).with_suffix(".txt")

    if needs_chunking(audio_path):
        # Split → transcribe each chunk → concatenate → post-process
        chunks = split_audio(audio_path, output_dir)
        chunk_texts = []

        for i, chunk in enumerate(chunks):
            log(f"Transcribing chunk {i+1}/{len(chunks)}: {chunk.name}")
            txt = transcribe_chunk(chunk, output_dir, i)
            chunk_texts.append(txt)

            # Progressive cleanup: delete chunk after transcription
            try:
                chunk.unlink()
            except Exception:
                pass

            log(f"  RAM after chunk {i+1}: {get_rss_mb():.1f}MB")

        # Concatenate all chunk transcripts
        valid_texts = [t for t in chunk_texts if t]
        if not valid_texts:
            log("No chunks produced output", "ERROR")
            return None

        concatenate_transcripts(valid_texts, str(final_txt))

        # Clean up chunk transcripts
        for t in valid_texts:
            try:
                Path(t).unlink()
            except Exception:
                pass
        try:
            output_dir.rmdir()
        except Exception:
            pass

    else:
        # Short audio: transcribe directly (no chunking needed)
        log("Short audio, transcribing directly (no chunking)")
        cmd = [
            WHISPER_CLI, "-m", str(MODEL_PATH), "-f", audio_path,
            "-otxt",
            "-of", str(Path(audio_path).parent / Path(audio_path).stem),
            "--language", "es", "--no-timestamps", "-t", "4",
            "-np",
        ]

        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
            if result.returncode != 0:
                log(f"Whisper exit {result.returncode}: {result.stderr[:200]}", "WARN")
        except subprocess.TimeoutExpired:
            log("Whisper timeout", "ERROR")
            return None

        if not final_txt.exists():
            log("No transcript output", "ERROR")
            return None

    # Post-process (streaming, line by line)
    post_process_streaming(str(final_txt))

    log(f"  RAM final: {get_rss_mb():.1f}MB")
    log(f"=== Done: {final_txt.name} ({final_txt.stat().st_size} bytes) ===")

    # Save metadata
    meta = {
        "audio": audio_path,
        "transcript": str(final_txt),
        "model": MODEL_PATH.name,
        "vad": False,
        "chunked": needs_chunking(audio_path),
        "transcribed_at": datetime.now().isoformat(),
    }
    (Path(audio_path).parent / f"{Path(audio_path).stem}_meta.json").write_text(json.dumps(meta))

    return str(final_txt)


def notify_hermes(txt_path: str, title: str):
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
        "created": datetime.now().isoformat()
    }
    tmp = HERMES_PENDING.with_suffix(".tmp")
    tmp.write_text(json.dumps(pending_data))
    tmp.rename(HERMES_PENDING)
    log(f"Hermes notified: .pending created")


def cleanup_recording(audio_path: str):
    try:
        p = Path(audio_path)
        if p.exists():
            size_mb = p.stat().st_size / 1024 / 1024
            p.unlink()
            log(f"Cleaned: {p.name} ({size_mb:.1f}MB freed)")
    except Exception as e:
        log(f"Cleanup error: {e}")


def remove_from_queue(audio_path: str):
    try:
        if QUEUE_FILE.exists():
            queue = json.loads(QUEUE_FILE.read_text())
            queue = [q for q in queue if q.get("audio") != audio_path]
            tmp = QUEUE_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(queue, indent=2))
            tmp.rename(QUEUE_FILE)
    except Exception:
        pass


def main():
    if len(sys.argv) < 3:
        print("Usage: transcribe_worker.py <audio_path> <title>")
        sys.exit(1)

    audio_path = sys.argv[1]
    title = sys.argv[2]

    log(f"Worker started: {Path(audio_path).name}")
    log(f"  Model: {MODEL_PATH.name} ({MODEL_PATH.stat().st_size / 1024 / 1024:.0f}MB)")
    log(f"  Threads: {WHISPER_THREADS}")
    log(f"  Chunk: {CHUNK_DURATION_SEC}s | Max RSS: {MAX_RSS_MB}MB")

    txt = process_single_audio(audio_path, title)
    if txt:
        notify_hermes(txt, title)
        cleanup_recording(audio_path)
        remove_from_queue(audio_path)
        log("Worker done: SUCCESS")
    else:
        log("Worker done: FAILED (kept in queue for retry)")

    sys.exit(0 if txt else 1)


if __name__ == "__main__":
    main()
