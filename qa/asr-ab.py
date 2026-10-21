#!/opt/homebrew/bin/python3
"""Reproducible, offline A/B of the real MeetCapture QA import pipeline.

prepare --corpora-root DIR --out NEW_DIR --seed 20261020
run --baseline-app QA_APP --candidate-app QA_APP --manifest manifest.json
    --split dev|holdout --out NEW_DIR --timeout-seconds 7200
compare --results RESULTS_DIR_OR_JSON --out NEW_DIR

prepare never downloads. prepare (archive extraction/ffmpeg) and run must be
launched by bin/system/resource_guard.py run, with adequate declared budgets.
Builds, downloads, model prefetch/initial compilation and the unchanged
capture-selftest gate remain separate parent-owned operations. Benchmark apps
are network-denied, so local models must already be available. Missing models,
timeouts, blocked imports or integrity errors are failures, never WER zero.

Every app requires an external adjacent APP.asr-provenance.json sidecar:
  {"schema_version":1,"binary_sha256":"...","commit":"40hex",
   "engine":"parakeet","model":{"name":"...","revision":null},
   "dependencies":{},"configuration":{"decoder":{},"chunking":{},
   "gate":{},"aliases":{}},"environment":{}}
Unknown revisions/cache/placement must be explicitly unavailable, not guessed.
For holdout, candidate provenance must additionally contain frozen_candidate:
  {"binary_sha256":"...","manifest_sha256":"...","selected_on":"dev",
   "effective_identity_sha256":"...","frozen_at":"ISO-8601 timestamp"}.
Use effective_identity(provenance, timeout_seconds) to obtain the required digest
and its versioned canonical payload before adding frozen_candidate. The identity
includes every provenance field except frozen_candidate and observations (the
reserved container for read-only volatile measurements), plus the effective
MEETCAPTURE environment. Per-item input/output paths use fixed role placeholders;
the frozen manifest binds the inputs. Unknown configuration/model fields remain
included. An old binary-only freeze is not accepted.
Create provenance AFTER final QA signing; embedding the executable hash inside
the signed bundle would be circular. This harness never installs a bundle,
changes production preferences, runs a dispatcher, or invokes an alternate ASR.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

from asr_corpora import audio_info, fresh_directory, prepare, sha256, write_json

QA_BUNDLE_ID = "com.maatwork.meetcapture.qa"
ARM_NAMES = ("baseline", "candidate")
RESERVED_ENV = {
    "MEETCAPTURE_REAL_CHECK", "MEETCAPTURE_TEST_OUTPUT_DIR", "MEETCAPTURE_CHECK_INPUT",
    "MEETCAPTURE_CHECK_REPORT", "MEETCAPTURE_CHECK_TIMEOUT_SECONDS", "MEETCAPTURE_CHECK_LANGUAGE",
    "MEETCAPTURE_CHECK_DIARIZE", "MEETCAPTURE_CHECK_MIC_ONLY", "MEETCAPTURE_PREFETCH_MODELS",
}
NETWORK_PROFILE = "(version 1) (allow default) (deny network*)"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _object(path: Path) -> dict:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"JSON object required: {path}")
    return data


def _finite(value, label: str, minimum: float = 0.0) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} is not numeric")
    number = float(value)
    if not math.isfinite(number) or number < minimum:
        raise ValueError(f"{label} is not a finite number >= {minimum}")
    return number


def _inside(path: str | Path, root: Path) -> Path:
    if not isinstance(path, (str, Path)):
        raise ValueError("artifact path is not a string")
    result = Path(path).resolve(strict=True)
    if not result.is_relative_to(root.resolve()) or not result.is_file():
        raise ValueError(f"artifact is not a regular file inside isolated output: {path}")
    return result


def _require_guard() -> dict:
    """Require an actual guard ancestor; no user-set bypass environment flag."""
    pid = os.getppid()
    visited = set()
    while pid > 1 and pid not in visited:
        visited.add(pid)
        completed = subprocess.run(["/bin/ps", "-ww", "-p", str(pid), "-o", "ppid=", "-o", "command="],
                                   capture_output=True, text=True, check=True)
        parts = completed.stdout.strip().split(None, 1)
        if len(parts) != 2:
            break
        parent_pid, command = parts
        words = shlex.split(command)
        for index, word in enumerate(words):
            if Path(word).name == "resource_guard.py" and "run" in words[index + 1:]:
                return {"guard_pid": pid, "guard_script": word,
                        "admission": "external resource_guard ancestor; quotas/hold remain guard-owned"}
        pid = int(parent_pid)
    raise ValueError("prepare/run require resource_guard.py run; exit 75 means deferred, never bypass the guard")


def _hardware() -> dict:
    values = {"platform": sys.platform, "machine": os.uname().machine,
              "os_release": os.uname().release, "os_version": os.uname().version,
              "cpu_count": os.cpu_count(), "python": sys.version.split()[0]}
    for key in ("hw.model", "hw.memsize", "machdep.cpu.brand_string"):
        completed = subprocess.run(["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True)
        values[key] = completed.stdout.strip() if completed.returncode == 0 else "unavailable"
    completed = subprocess.run(["/usr/bin/sw_vers", "-productVersion"], capture_output=True, text=True)
    values["macos_version"] = completed.stdout.strip() if completed.returncode == 0 else "unavailable"
    return values


def _meetcapture_environment(provenance: dict, timeout_seconds: int, *,
                            input_path: str = "<manifest-item.wav_path>",
                            output_dir: str = "<isolated-output-directory>",
                            report_path: str = "<isolated-report-path>") -> dict:
    environment = provenance.get("environment", {})
    if not isinstance(environment, dict):
        raise ValueError("provenance environment must be an object")
    for key, value in environment.items():
        if (not isinstance(key, str) or not key.startswith("MEETCAPTURE_") or key in RESERVED_ENV or
                not isinstance(value, str) or "\x00" in value):
            raise ValueError(f"invalid/reserved experimental environment entry: {key}")
    return {**environment, "MEETCAPTURE_REAL_CHECK": "import",
            "MEETCAPTURE_TEST_OUTPUT_DIR": output_dir, "MEETCAPTURE_CHECK_INPUT": input_path,
            "MEETCAPTURE_CHECK_REPORT": report_path,
            "MEETCAPTURE_CHECK_TIMEOUT_SECONDS": str(timeout_seconds),
            "MEETCAPTURE_CHECK_LANGUAGE": "es", "MEETCAPTURE_CHECK_DIARIZE": "0",
            "MEETCAPTURE_CHECK_MIC_ONLY": "0"}


def effective_identity(provenance: dict, timeout_seconds: int) -> dict:
    """Export the arm's reproducible identity without reading any corpus files.

    Payload v1 has exactly identity_version, provenance, and
    effective_meetcapture_environment. provenance retains all keys/subobjects
    (including unknown model artifacts/configuration) except frozen_candidate
    and observations. Only observations is reserved for non-controlling,
    volatile measurements; all other unknown metadata is conservatively bound.
    The effective environment is generated by the same owner as the real arm,
    with stable role placeholders for the three per-invocation paths.
    Canonical bytes are UTF-8 JSON, sorted keys, compact separators, literal
    Unicode, and no NaN/Infinity; object key order is immaterial, array order is
    preserved. The returned payload is an independent snapshot of those bytes.
    """
    payload = {"identity_version": 1,
               "provenance": {key: value for key, value in provenance.items()
                              if key not in ("frozen_candidate", "observations")},
               "effective_meetcapture_environment": _meetcapture_environment(provenance, timeout_seconds)}
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    return {"effective_identity_version": 1,
            "effective_identity_sha256": hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
            "effective_identity_payload": json.loads(canonical)}


def _require_frozen_candidate(provenance: dict, binary_digest: str,
                              manifest_digest: str, timeout_seconds: int) -> None:
    identity = effective_identity(provenance, timeout_seconds)
    frozen = provenance.get("frozen_candidate", {})
    if (not isinstance(frozen, dict) or frozen.get("binary_sha256") != binary_digest or
            frozen.get("manifest_sha256") != manifest_digest or frozen.get("selected_on") != "dev" or
            frozen.get("effective_identity_sha256") != identity["effective_identity_sha256"] or
            not isinstance(frozen.get("frozen_at"), str) or not frozen["frozen_at"].strip()):
        raise ValueError("holdout remains unopened: candidate provenance must freeze this binary and effective_identity_sha256 against this manifest after dev selection")
    try:
        frozen_at = datetime.fromisoformat(frozen["frozen_at"].replace("Z", "+00:00"))
        if frozen_at.tzinfo is None or frozen_at > datetime.now(timezone.utc):
            raise ValueError("freeze timestamp must be timezone-aware and not in the future")
    except ValueError as exc:
        raise ValueError("invalid frozen_candidate.frozen_at timestamp") from exc


def _bundle(path: Path, timeout_seconds: int) -> dict:
    app = path.expanduser().resolve(strict=True)
    if app.suffix != ".app" or not app.is_dir():
        raise ValueError(f"--app must be a staged QA .app bundle, not a binary: {app}")
    installed = [Path("/Applications"), Path("/System/Applications"), Path("/System/Library"),
                 Path.home() / "Applications", Path.home() / "Library"]
    if any(app.is_relative_to(root) for root in installed):
        raise ValueError(f"refusing an installed app: {app}")
    plist_path = app / "Contents" / "Info.plist"
    with plist_path.open("rb") as stream:
        plist = plistlib.load(stream)
    if plist.get("CFBundleIdentifier") != QA_BUNDLE_ID:
        raise ValueError(f"only bundle ID {QA_BUNDLE_ID} is allowed: {app}")
    executable_name = plist.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or Path(executable_name).name != executable_name:
        raise ValueError(f"invalid CFBundleExecutable: {app}")
    binary = (app / "Contents" / "MacOS" / executable_name).resolve(strict=True)
    if not binary.is_relative_to(app) or not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError(f"QA executable is not an executable regular file inside bundle: {binary}")
    digest = sha256(binary)
    provenance_path = app.with_suffix(".asr-provenance.json")
    provenance = _object(provenance_path)
    if provenance.get("schema_version") != 1 or provenance.get("binary_sha256") != digest:
        raise ValueError(f"missing schema-v1 provenance or mismatched binary hash: {provenance_path}")
    if not re.fullmatch(r"[0-9a-fA-F]{40}", str(provenance.get("commit", ""))):
        raise ValueError(f"provenance must declare the actual build's full commit: {provenance_path}")
    if not isinstance(provenance.get("dependencies"), (dict, list)):
        raise ValueError("provenance dependencies must preserve actual resolved revisions")
    model = provenance.get("model")
    if not isinstance(model, dict) or not isinstance(model.get("name"), str) or not model["name"].strip():
        raise ValueError("provenance model.name must identify the actual local model")
    if "revision" not in model:
        raise ValueError("provenance model.revision is required; use null if unavailable")
    engine = provenance.get("engine")
    if not isinstance(engine, str) or not engine or any(word in (engine + model["name"]).casefold() for word in ("fake", "mock")):
        raise ValueError("provenance must identify an actual non-mock engine")
    configuration = provenance.get("configuration")
    if not isinstance(configuration, dict) or not all(key in configuration for key in ("decoder", "chunking", "gate", "aliases")):
        raise ValueError("provenance configuration must declare decoder/chunking/gate/aliases (unavailable explicitly if unknown)")
    identity = effective_identity(provenance, timeout_seconds)
    signature = subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(app)], capture_output=True, text=True)
    if signature.returncode:
        raise ValueError(f"staged QA bundle signature invalid: {app}: {signature.stderr.strip()}")
    return {"app_path": str(app), "binary_path": str(binary), "binary_sha256": digest,
            "bundle_id": QA_BUNDLE_ID, "bundle_version": plist.get("CFBundleShortVersionString"),
            "info_plist_sha256": sha256(plist_path), "provenance_path": str(provenance_path),
            "provenance_sha256": sha256(provenance_path), "provenance": provenance, **identity,
            "cache_state": {"process_models": "fresh_process_each_arm; technical operations may reuse models",
                            "filesystem_and_CoreML_cache": "unavailable; not cleared or inferred"},
            "compute_placement": {"declared": provenance.get("compute_placement", "unavailable"),
                                  "verified": "unavailable; no CPU/ANE placement claim made by this harness"}}


def _check_bundle_unchanged(bundle: dict) -> None:
    checks = ((bundle["binary_path"], bundle["binary_sha256"]),
              (bundle["provenance_path"], bundle["provenance_sha256"]),
              (str(Path(bundle["app_path"]) / "Contents" / "Info.plist"), bundle["info_plist_sha256"]))
    for path, expected in checks:
        if sha256(Path(path)) != expected:
            raise ValueError(f"frozen QA app changed during benchmark: {path}")


def _selected_units(manifest: dict, split: str) -> list[dict]:
    if manifest.get("schema_version") != 1 or not isinstance(manifest.get("items"), list):
        raise ValueError("manifest must use schema_version=1 and contain items")
    # Do not read references, audio, or hashes for the unselected split.
    units = manifest.get("evaluation_blocks", manifest["items"])
    if not isinstance(units, list):
        raise ValueError("manifest evaluation_blocks must be an array")
    selected = [item for item in units if isinstance(item, dict) and item.get("split") == split]
    if not selected:
        raise ValueError(f"manifest has no evaluation units in selected split: {split}")
    seen = set()
    for item in selected:
        item_id = item.get("id")
        if not isinstance(item_id, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", item_id) or item_id in seen:
            raise ValueError("selected evaluation unit IDs must be unique safe filenames")
        seen.add(item_id)
        for key in ("source", "license", "group_id", "group_basis", "duration_seconds", "format", "coverage"):
            if key not in item:
                raise ValueError(f"selected item {item_id} missing {key}")
        _finite(item["duration_seconds"], "manifest duration", minimum=0.000001)
        if "evaluation_blocks" in manifest and not item.get("primary_evaluation"):
            raise ValueError("primary evaluation block must be explicitly primary_evaluation=true")
    return selected


def _input_checks(item: dict) -> dict:
    checked = {}
    entries = [item, *item.get("clip_map", [])]
    for entry in entries:
        for path_key, hash_key in (("wav_path", "wav_sha256"), ("reference_path", "reference_sha256"),
                                   ("original_path", "original_sha256"),
                                   ("published_reference_path", "published_reference_sha256")):
            if path_key not in entry:
                if path_key in ("wav_path", "reference_path"):
                    raise ValueError(f"manifest entry missing {path_key}")
                continue
            path = Path(entry[path_key]).resolve(strict=True)
            expected = entry.get(hash_key)
            if not isinstance(expected, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", expected):
                raise ValueError(f"manifest entry missing valid {hash_key}: {path}")
            if path not in checked:
                checked[path] = sha256(path)
            if checked[path] != expected.casefold():
                raise ValueError(f"frozen input hash mismatch: {path}")
    actual = audio_info(Path(item["wav_path"]))
    if (actual.get("container"), actual.get("sample_rate"), actual.get("channels"), actual.get("bits_per_sample"), actual.get("compression")) != ("wav", 16000, 1, 16, "NONE"):
        raise ValueError(f"evaluation WAV must be 16kHz mono Int16 PCM: {item['wav_path']}")
    if abs(actual["duration_seconds"] - item["duration_seconds"]) > 0.001:
        raise ValueError("frozen manifest duration disagrees with evaluation WAV")
    clip_map = item.get("clip_map", [])
    if clip_map:
        cursor = round(_finite(item.get("time_offset_seconds", 0), "leading offset") * 16000)
        seen_ids = set()
        for clip in clip_map:
            if clip.get("split") != item["split"] or clip.get("source") != item["source"]:
                raise ValueError("evaluation block crosses source/split boundaries")
            if clip["id"] in seen_ids or clip.get("start_frame") != cursor:
                raise ValueError("clip map duplicates a clip or has noncontiguous PCM boundaries")
            seen_ids.add(clip["id"])
            clip_info = audio_info(Path(clip["wav_path"]))
            cursor += clip_info["frames"]
            if clip.get("end_frame") != cursor:
                raise ValueError("clip map frame count disagrees with original evaluation clip")
        if cursor != actual["frames"]:
            raise ValueError("clip map does not cover the complete evaluation WAV")
        reference = " ".join(Path(clip["reference_path"]).read_text(encoding="utf-8").strip() for clip in clip_map)
        if Path(item["reference_path"]).read_text(encoding="utf-8").strip() != reference:
            raise ValueError("block reference is not the predefined joined original references")
    return {str(path): digest for path, digest in checked.items()}


def _unchanged_inputs(checks: dict) -> None:
    for path, expected in checks.items():
        if sha256(Path(path)) != expected:
            raise ValueError(f"source/reference changed during real import: {path}")


def _transcript_tokens(text: str, tokenizer) -> list[str]:
    return tokenizer(re.sub(r"(?m)^\[[^\]\n]+\]:\s*", "", text))


def _validate_report(report: dict, root: Path, item: dict, bundle: dict, tokenizer) -> dict:
    if report.get("status") != "passed" or report.get("mode") != "import":
        raise ValueError(f"real pipeline did not pass import: {report.get('status')!r}: {report.get('error', '')}")
    if report.get("diarize") is not False or report.get("micOnly") is not False:
        raise ValueError("report does not confirm predefined diarize=false, micOnly=false")
    duration = item["duration_seconds"]
    if abs(_finite(report.get("inputDurationSec"), "report.inputDurationSec") - duration) > 1:
        raise ValueError("report WAV duration differs by more than one second")
    _finite(report.get("elapsedSec"), "report.elapsedSec")
    records = report.get("records")
    if report.get("historyCount") != 3 or not isinstance(records, list) or len(records) != 3:
        raise ValueError("real import must persist three distinct technical operations")
    hypothesis = report.get("text")
    if not isinstance(hypothesis, str):
        raise ValueError("predefined hypothesis report.text must be a string")
    database = _inside(root / "meetcapture.db", root)
    connection = sqlite3.connect(f"file:{quote(str(database))}?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    verified, segment_evidence = [], []
    try:
        rows = connection.execute("SELECT id, started_at, duration_sec, engine, model, transcript_path, transcript_text FROM meetings").fetchall()
        by_id = {row["id"]: row for row in rows}
        if len(rows) != 3 or len(by_id) != 3:
            raise ValueError("actual SQLite must contain exactly three distinct history rows")
        seen_ids, seen_transcripts, seen_pending = set(), set(), set()
        for index, record in enumerate(records):
            if not isinstance(record, dict):
                raise ValueError("report record is not an object")
            for key in ("id", "transcriptPath", "pendingPath", "text", "engine", "model"):
                if not isinstance(record.get(key), str) or (key != "text" and not record[key].strip()):
                    raise ValueError(f"records[{index}].{key} is missing")
            row = by_id.get(record["id"])
            if row is None or record["id"] in seen_ids:
                raise ValueError("report IDs do not map one-to-one to actual SQLite history")
            seen_ids.add(record["id"])
            transcript = _inside(record["transcriptPath"], root)
            pending = _inside(record["pendingPath"], root)
            if transcript in seen_transcripts or pending in seen_pending:
                raise ValueError("technical operations share transcript/handoff artifacts")
            seen_transcripts.add(transcript)
            seen_pending.add(pending)
            text = transcript.read_text(encoding="utf-8")
            if text != record["text"] or text != row["transcript_text"] or str(transcript) != str(Path(row["transcript_path"]).resolve()):
                raise ValueError("report, SQLite and transcript text/path disagree")
            if index == 0 and _transcript_tokens(text, tokenizer) != tokenizer(hypothesis):
                raise ValueError("report.text is not the newest predefined history hypothesis")
            if index == 0 and any(row["started_at"] < other["started_at"] for other in rows):
                raise ValueError("report's predefined first record is not the most recent history row")
            expected_engine = bundle["provenance"]["engine"]
            expected_model = bundle["provenance"]["model"]["name"]
            if record["engine"] != row["engine"] or record["model"] != row["model"]:
                raise ValueError("actual engine/model disagree between report and SQLite")
            if record["engine"] != expected_engine or record["model"] != expected_model:
                raise ValueError("actual engine/model do not match frozen app provenance; no engine relabeling allowed")
            if abs(_finite(record.get("durationSec"), "record.durationSec") - duration) > 1 or abs(_finite(row["duration_sec"], "SQLite.duration_sec") - duration) > 1:
                raise ValueError("actual history duration differs from source WAV by more than one second")
            contract = _object(pending)
            checksum = sha256(transcript)
            if (contract.get("version") != 2 or contract.get("meetingId") != record["id"] or
                    contract.get("checksum") != checksum or contract.get("transcriptPath") != record["transcriptPath"] or
                    contract.get("engine") != record["engine"] or contract.get("model") != record["model"]):
                raise ValueError("pending handoff checksum/identity/path disagree with actual transcript/history")
            if abs(_finite(contract.get("durationSec"), "handoff.durationSec") - duration) > 1:
                raise ValueError("handoff duration differs from source WAV by more than one second")
            if not contract.get("audioPath"):
                raise ValueError("handoff has no retained complete audio (partial/gapped transcription)")
            retained_audio = _inside(contract["audioPath"], root)
            retained_hash = sha256(retained_audio)
            if retained_hash != item["wav_sha256"]:
                raise ValueError("retained imported audio differs from the exact benchmark WAV")
            marker_path = transcript.with_suffix(".processed.json") if transcript.suffix == ".txt" else Path(str(transcript) + ".processed.json")
            marker = _object(_inside(marker_path, root))
            if (marker.get("schema") != "meetcapture.processed.v1" or marker.get("transcript_path") != record["transcriptPath"] or
                    marker.get("retention") != "handoff_complete"):
                raise ValueError("processed marker disagrees with handoff/transcript")
            words = _transcript_tokens(text, tokenizer)
            search_evidence = {"status": "not_applicable", "reason": "empty transcript"}
            if words:
                query = next((word for word in words if any(char.isalpha() for char in word)), words[0])
                expression = '"' + query.replace('"', '""') + '"*'
                try:
                    matches = connection.execute("SELECT id FROM meetings WHERE rowid IN (SELECT rowid FROM meetings_fts WHERE meetings_fts MATCH ?)", (expression,)).fetchall()
                    search_mode = "fts5"
                except sqlite3.OperationalError:
                    escaped = query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
                    matches = connection.execute("SELECT id FROM meetings WHERE title LIKE '%' || ? || '%' ESCAPE '\\' OR transcript_text LIKE '%' || ? || '%' ESCAPE '\\'", (escaped, escaped)).fetchall()
                    search_mode = "store_like_fallback"
                if record["id"] not in {match["id"] for match in matches}:
                    raise ValueError("actual history search cannot find its own recognized text")
                search_evidence = {"status": "passed", "mode": search_mode, "query": query}
            segments = contract.get("segments")
            if not isinstance(segments, list):
                raise ValueError("handoff segments missing")
            if words and not segments:
                raise ValueError("nonempty transcript without persisted timed segments")
            previous_start, monotonic = -1.0, True
            offset = _finite(item.get("time_offset_seconds", 0), "diagnostic offset")
            adjusted = []
            for segment in segments:
                if not isinstance(segment, dict) or not isinstance(segment.get("text"), str):
                    raise ValueError("invalid handoff segment")
                start = _finite(segment.get("start"), "segment.start")
                end = _finite(segment.get("end"), "segment.end")
                if end < start or end > duration + 1:
                    raise ValueError("persisted timestamps are outside source bounds or reversed")
                monotonic = monotonic and start >= previous_start
                previous_start = start
                adjusted.append({**segment, "start": start - offset, "end": end - offset})
            segment_evidence.append({"id": record["id"], "valid_bounds": True,
                                     "starts_monotonic": monotonic, "segment_count": len(segments),
                                     "timestamp_granularity": "persisted_segments; not a word timing accuracy claim",
                                     "source_offset_seconds": offset,
                                     "offset_corrected_segments": adjusted if offset else None})
            verified.append({"id": record["id"], "transcript_sha256": checksum,
                             "transcript_path": str(transcript), "pending_path": str(pending),
                             "marker_path": str(marker_path), "engine": record["engine"], "model": record["model"],
                             "duration_seconds": row["duration_sec"], "search": search_evidence,
                             "retained_audio_path": str(retained_audio), "retained_audio_sha256": retained_hash})
        if seen_ids != set(by_id):
            raise ValueError("report does not cover all actual SQLite rows")
    finally:
        connection.close()
    return {"history_rows": verified, "persisted_timestamps": segment_evidence,
            "replicas": {"count": 3, "purpose": "repeatability/integrity only; NOT independent observations",
                         "same_tokens_as_predefined_hypothesis": [_transcript_tokens(record["text"], tokenizer) == tokenizer(hypothesis) for record in records]},
            "hypothesis_selection": "report.text only; matches records[0] newest history; never select best replica"}


def _stop(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
    except ProcessLookupError:
        return
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def _rss(path: Path) -> dict:
    text = path.read_text(encoding="utf-8", errors="replace") if path.exists() else ""
    match = re.search(r"(?m)^\s*(\d+)\s+maximum resident set size\s*$", text)
    return {"maximum_resident_set_size_bytes": int(match[1]) if match else None,
            "measurement": "macOS /usr/bin/time -l (maximum RSS; wrapper and app process tree)",
            "status": "available" if match else "unavailable"}


def _arm(item: dict, bundle: dict, arm_name: str, item_out: Path, timeout: int,
         metrics, hardware: dict, manifest_digest: str) -> dict:
    arm_out = item_out / arm_name
    arm_out.mkdir(mode=0o700)
    temporary = Path(tempfile.mkdtemp(prefix="meetcapture-asr-"))
    temporary.chmod(0o700)
    report_path = temporary / "check-report.json"
    raw_dest = arm_out / "raw"
    timing_path = arm_out / "process-time.txt"
    environment = {key: value for key, value in os.environ.items() if not key.startswith("MEETCAPTURE_")}
    environment.update(_meetcapture_environment(bundle["provenance"], timeout,
                                               input_path=str(Path(item["wav_path"]).resolve()),
                                               output_dir=str(temporary), report_path=str(report_path)))
    command = ["/usr/bin/time", "-l", "-o", str(timing_path), "/usr/bin/sandbox-exec", "-p", NETWORK_PROFILE, bundle["binary_path"]]
    write_json(arm_out / "invocation.json", {"command": command, "temporary_output": str(temporary),
               "durable_raw_output": str(raw_dest), "real_check_environment": {key: value for key, value in environment.items() if key.startswith("MEETCAPTURE_")},
               "timeout_seconds": timeout, "external_deadline_seconds": timeout + 30,
               "network_policy": "all networking denied to app; models must already be prepared"})
    result = {"pipeline_status": "failed", "acceptance_status": "not_evaluated", "report_path": None,
              "hypothesis": None, "elapsed_seconds": None, "score": None,
              "metadata": {"bundle": bundle, "hardware": hardware, "manifest_sha256": manifest_digest,
                           "started_at": _now(),
                           "timing_scope": "whole real-check process: two imports and one retranscription, NOT single recognition latency",
                           "technical_operations": 3, "network_policy": "sandbox deny network*",
                           "temporary_output_original_path": str(temporary), "raw_output_path": str(raw_dest)}}
    process = None
    start = time.monotonic()
    checks = None
    process_start = None
    process_elapsed = None
    try:
        _check_bundle_unchanged(bundle)
        checks = _input_checks(item)
        with (arm_out / "stdout.log").open("xb") as stdout, (arm_out / "stderr.log").open("xb") as stderr:
            process_start = time.monotonic()
            process = subprocess.Popen(command, stdout=stdout, stderr=stderr, env=environment, start_new_session=True)
            try:
                return_code = process.wait(timeout=timeout + 30)
            except subprocess.TimeoutExpired:
                result["metadata"]["failure_kind"] = "timeout"
                result["metadata"]["error"] = f"external deadline exceeded ({timeout + 30}s); raw output retained"
                _stop(process)
                return_code = process.returncode
        process_elapsed = time.monotonic() - process_start
        result["metadata"]["exit_code"] = return_code
        if return_code == 77:
            result["pipeline_status"] = "blocked"
        if report_path.is_file():
            result["report_path"] = str(raw_dest / "check-report.json")
            report = _object(report_path)
            result["metadata"]["report_status"] = report.get("status")
            result["metadata"]["reported_elapsed_seconds_three_operations"] = report.get("elapsedSec")
            if report.get("status") == "blocked" or return_code == 77:
                result["pipeline_status"] = "blocked"
                raise ValueError(f"real import blocked: {report.get('error', 'no reason provided')}")
            if return_code != 0:
                if "exceeded" in str(report.get("error", "")) or "timed out" in str(report.get("error", "")):
                    result["metadata"]["failure_kind"] = "timeout"
                raise ValueError(f"real import exited {return_code}: {report.get('error', 'no successful report')}")
            validation = _validate_report(report, temporary, item, bundle, metrics.tokens)
            _check_bundle_unchanged(bundle)
            result["metadata"]["validation"] = validation
            result["hypothesis"] = report["text"]
            result["score"] = metrics.score(Path(item["reference_path"]).read_text(encoding="utf-8"), report["text"], item["duration_seconds"])
            result["pipeline_status"] = "passed"
        else:
            raise ValueError(f"real import exited {return_code} without a new JSON report")
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        result["metadata"].setdefault("failure_kind", "pipeline_or_integrity_error")
        result["metadata"].setdefault("error", f"{type(exc).__name__}: {exc}")
    except KeyboardInterrupt:
        result["metadata"]["failure_kind"] = "interrupted"
        result["metadata"]["error"] = "benchmark interrupted; raw output retained"
    finally:
        if process is not None:
            _stop(process)
        if process_start is not None and process_elapsed is None:
            process_elapsed = time.monotonic() - process_start
        result["elapsed_seconds"] = process_elapsed
        result["metadata"]["harness_wall_seconds"] = time.monotonic() - start
        result["metadata"]["ended_at"] = _now()
        result["metadata"]["resource_usage"] = _rss(timing_path)
        if checks is not None:
            try:
                _unchanged_inputs(checks)
            except (OSError, ValueError) as exc:
                result["pipeline_status"] = "failed"
                result["hypothesis"] = result["score"] = None
                result["metadata"]["failure_kind"] = "source_mutated"
                result["metadata"]["error"] = str(exc)
        # Preserve raw bytes and their original paths; never rewrite/checksum-fix a handoff.
        try:
            shutil.move(str(temporary), str(raw_dest))
        except OSError as exc:
            result["pipeline_status"] = "failed"
            result["hypothesis"] = result["score"] = None
            result["metadata"]["failure_kind"] = "raw_preservation_failed"
            result["metadata"]["error"] = f"{exc}; untouched temporary artifacts remain at {temporary}"
        result["metadata"]["artifact_path_mapping"] = {"original_root": str(temporary), "durable_root": str(raw_dest),
             "note": "Raw reports/SQLite/handoffs retain original absolute paths; resolve that root to durable_root. Validation occurred before moving, without rewriting artifacts."}
    write_json(arm_out / "result.json", result)
    return result


def _metrics():
    try:
        import asr_metrics
    except ImportError as exc:
        raise ValueError("locked QA scoring environment required: install qa/asr-requirements.lock with Homebrew Python in a QA-only venv") from exc
    return asr_metrics


def run(args) -> dict:
    if sys.platform != "darwin":
        raise ValueError("real QA app runner requires macOS")
    if not Path("/usr/bin/sandbox-exec").is_file():
        raise ValueError("macOS sandbox-exec is required to deny app networking during benchmark")
    guard = _require_guard()
    metrics = _metrics()
    manifest_path = args.manifest.expanduser().resolve(strict=True)
    manifest_digest = sha256(manifest_path)
    manifest = _object(manifest_path)
    units = _selected_units(manifest, args.split)
    bundles = {"baseline": _bundle(args.baseline_app, args.timeout_seconds),
               "candidate": _bundle(args.candidate_app, args.timeout_seconds)}
    if args.split == "holdout":
        _require_frozen_candidate(bundles["candidate"]["provenance"], bundles["candidate"]["binary_sha256"],
                                  manifest_digest, args.timeout_seconds)
    out = fresh_directory(args.out.expanduser())
    write_json(out / "frozen-manifest.json", manifest)
    hardware = _hardware()
    results = {"schema_version": 1, "manifest_path": str(manifest_path), "manifest_sha256": manifest_digest,
               "split": args.split, "seed": manifest.get("seed"), "sources": manifest.get("sources", {}),
               "started_at": _now(), "guard": guard, "hardware": hardware, "bundles": bundles,
               "selected_item_count": len(units), "selected_item_ids": [item["id"] for item in units],
               "hypothesis_selection": "report.text only, newest history record; score once per WAV",
               "acceptance_status": "not_evaluated", "operational_gate": "not run or relaxed by benchmark",
               "latency_scope": "Each arm executes 3 technical operations; wall/report elapsed are not single-recognition timings.",
               "evaluation_unit_policy": manifest.get("evaluation_policy"),
               "coverage_limits": manifest.get("coverage_limits", []), "items": []}
    write_json(out / "run-plan.json", {**{key: value for key, value in results.items() if key != "items"},
                                      "selected_item_ids": [item["id"] for item in units], "timeout_seconds": args.timeout_seconds})
    interrupted = False
    old_term = signal.getsignal(signal.SIGTERM)

    def terminate(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        for item in units:
            if sha256(manifest_path) != manifest_digest:
                raise ValueError("frozen manifest changed during benchmark")
            item_out = out / item["id"]
            item_out.mkdir(mode=0o700)
            # Only selected split references are opened, after holdout freeze validation.
            entry = dict(item)
            entry["reference"] = Path(item["reference_path"]).read_text(encoding="utf-8")
            entry["manifest_sha256"] = manifest_digest
            entry["arms"] = {}
            results["items"].append(entry)
            for arm_name in ARM_NAMES:
                print(f"{item['id']} {arm_name}", flush=True)
                arm = _arm(item, bundles[arm_name], arm_name, item_out, args.timeout_seconds,
                           metrics, hardware, manifest_digest)
                entry["arms"][arm_name] = arm
                if arm["metadata"].get("failure_kind") in ("interrupted", "source_mutated"):
                    interrupted = True
                    break
            if interrupted:
                break
    except KeyboardInterrupt:
        interrupted = True
    except (OSError, ValueError, KeyError, TypeError) as exc:
        results["run_error"] = f"{type(exc).__name__}: {exc}"
    finally:
        signal.signal(signal.SIGTERM, old_term)
        results["ended_at"] = _now()
        results["interrupted"] = interrupted
        complete = len(results["items"]) == len(units) and all(len(item["arms"]) == 2 for item in results["items"])
        results["status"] = "completed" if complete and not results.get("run_error") and not interrupted else "incomplete"
        results["all_pipelines_passed"] = complete and all(arm["pipeline_status"] == "passed" for item in results["items"] for arm in item["arms"].values())
        write_json(out / "results.json", results)
    return {"results_path": str(out / "results.json"), "status": results["status"],
            "all_pipelines_passed": results["all_pipelines_passed"], "selected_items": len(units),
            "completed_items": sum(len(item["arms"]) == 2 for item in results["items"])}


def _flatten(value, prefix="") -> dict:
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            result.update(_flatten(item, f"{prefix}.{key}" if prefix else str(key)))
        return result
    if isinstance(value, list):
        return {prefix: json.dumps(value, ensure_ascii=False, sort_keys=True)}
    return {prefix: value}


def compare(args) -> dict:
    metrics = _metrics()
    results_path = args.results.expanduser().resolve(strict=True)
    if results_path.is_dir():
        results_path = results_path / "results.json"
    results = _object(results_path)
    if results.get("schema_version") != 1 or not isinstance(results.get("items"), list):
        raise ValueError("results must use schema_version=1 with items")
    if not re.fullmatch(r"[a-fA-F0-9]{64}", str(results.get("manifest_sha256", ""))):
        raise ValueError("results must preserve frozen manifest_sha256")
    seed = results.get("seed", 20261020)
    if isinstance(seed, bool) or not isinstance(seed, int):
        raise ValueError("results seed must be an integer")
    comparison = metrics.compare(results["items"], seed=seed, replicates=10000)
    planned = results.get("selected_item_ids")
    observed = [item.get("id") for item in results["items"]]
    missing_planned = not isinstance(planned, list) or set(planned) != set(observed) or len(planned) != len(observed)
    incomplete = results.get("status") != "completed" or results.get("all_pipelines_passed") is not True
    if missing_planned or incomplete:
        decision = comparison.setdefault("decision", {})
        blockers = decision.setdefault("blockers", [])
        for blocker, applies in (("missing_planned_items", missing_planned), ("incomplete_run_coverage", incomplete)):
            if applies and blocker not in blockers:
                blockers.append(blocker)
        decision["strong_improvement_demonstrated"] = False
        decision["status"] = "not_demonstrated"
    comparison["run_coverage"] = {"status": results.get("status"), "planned_items": results.get("selected_item_count"),
                                  "observed_items": len(observed), "missing_planned_items": missing_planned,
                                  "all_pipelines_passed": results.get("all_pipelines_passed")}
    out = fresh_directory(args.out.expanduser())
    comparison.update({"schema_version": 1, "results_path": str(results_path), "results_sha256": sha256(results_path),
                       "manifest_sha256": results["manifest_sha256"], "split": results.get("split"),
                       "hypothesis_selection": results.get("hypothesis_selection"),
                       "acceptance_status": "not_evaluated", "coverage_limits": results.get("coverage_limits", []),
                       "latency_scope": results.get("latency_scope"),
                       "provenance_group_independence": "unverified unless original source mapping explicitly certifies it; concatenated blocks are not spontaneous meetings"})
    write_json(out / "comparison.json", comparison)
    write_json(out / "error-pairs.json", comparison.get("error_pairs", []))
    with (out / "metrics.tsv").open("x", encoding="utf-8") as stream:
        stream.write("scope\tmetric\tvalue\n")
        for section in ("pooled", "per_source", "by_condition"):
            for key, value in sorted(_flatten(comparison.get(section, {})).items()):
                value = "unavailable" if value is None else str(value).replace("\t", " ").replace("\n", " ")
                stream.write(f"{section}\t{key}\t{value}\n")
    return {"comparison_path": str(out / "comparison.json"), "metrics_table": str(out / "metrics.tsv"),
            "error_pairs_path": str(out / "error-pairs.json"), "decision": comparison.get("decision")}


def _timeout(value: str) -> int:
    if not value.isascii() or not value.isdecimal() or not 60 <= int(value) <= 7200:
        raise argparse.ArgumentTypeError("timeout must be an integer from 60 to 7200 seconds")
    return int(value)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    preparation = commands.add_parser("prepare", help="freeze already downloaded public sources, references and split without recognition")
    preparation.add_argument("--corpora-root", type=Path, required=True)
    preparation.add_argument("--out", type=Path, required=True)
    preparation.add_argument("--seed", type=int, required=True)
    runner = commands.add_parser("run", help="run only the selected split through each real staged QA app, sequentially, offline")
    runner.add_argument("--baseline-app", type=Path, required=True)
    runner.add_argument("--candidate-app", type=Path, required=True)
    runner.add_argument("--manifest", type=Path, required=True)
    runner.add_argument("--split", choices=("dev", "holdout"), required=True)
    runner.add_argument("--out", type=Path, required=True)
    runner.add_argument("--timeout-seconds", type=_timeout, default=240)
    comparison = commands.add_parser("compare", help="score one predefined hypothesis per evaluation unit; never failed arms or replicas")
    comparison.add_argument("--results", type=Path, required=True)
    comparison.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "prepare":
            _require_guard()
            summary = prepare(args.corpora_root, args.out, args.seed)
        elif args.command == "run":
            summary = run(args)
        else:
            summary = compare(args)
        print(json.dumps(summary, indent=2, ensure_ascii=False, allow_nan=False))
        if args.command == "run" and (summary["status"] != "completed" or not summary["all_pipelines_passed"]):
            return 1
        return 0
    except (OSError, ValueError, KeyError, TypeError, sqlite3.Error, subprocess.SubprocessError) as exc:
        print(f"asr-ab: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
