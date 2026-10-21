#!/opt/homebrew/bin/python3
"""Offline preparation of the published OpenSLR61 and MediaSpeech ES corpora.

Inputs under --corpora-root:
  openslr61/{es_ar_female.zip,es_ar_male.zip,line_index_female.tsv,
             line_index_male.tsv,LICENSE,about.html}
  mediaspeech/{ES.tgz,README.md[,LICENSE]}
Already extracted audio is also accepted in the corresponding source directory.
No network requests or recognition are performed. Run extraction/conversion under
resource_guard.py; ffmpeg/ffprobe must be installed locally when conversion is
needed. Original archives, extracted audio and published references are retained.
The primary manifest evaluates approximately ten-minute concatenations, ONCE,
not those blocks plus their constituent clips. A separate diagnostic manifest
contains long concatenations and leading-silence variants; these are not primary
observations or evidence of spontaneous conversation or speaker independence.
"""
from __future__ import annotations

import csv
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import tarfile
import wave
import zipfile

SCHEMA_VERSION = 1
TARGET_SECONDS = 2 * 60 * 60
BLOCK_SECONDS = 600
SAMPLE_RATE = 16000
AUDIO_SUFFIXES = {".wav", ".flac"}
SOURCES = {
    "openslr61": {
        "url": "https://www.openslr.org/61/",
        "license": "CC-BY-SA-4.0",
        "description": "Read sentences recorded by volunteers in Buenos Aires, Argentina; reference errors remain possible.",
        "coverage": ["spanish", "argentinian_read_speech", "public_audio"],
    },
    "mediaspeech": {
        "url": "https://www.openslr.org/108/",
        "license": "CC-BY-4.0",
        "description": "MediaSpeech Spanish media clips shorter than 15 seconds; long pauses excluded by the publisher; references are not infallible.",
        "coverage": ["spanish", "media_speech", "public_audio"],
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def text_sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_json(path: Path, value: object) -> None:
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)
        stream.write("\n")


def fresh_directory(path: Path) -> Path:
    path = path.absolute()
    resolved = path.resolve()
    protected = (Path.home() / "meetings", Path.home() / ".meetcapture",
                 Path("/Applications"), Path("/System"), Path.home() / "Applications")
    if any(resolved.is_relative_to(root.resolve()) for root in protected):
        raise ValueError(f"refusing production/installed-app output location: {path}")
    if path.exists() or path.is_symlink():
        raise ValueError(f"output already exists (never reused): {path}")
    path.mkdir(mode=0o700, parents=True)
    return path.resolve()


def _archive_target(root: Path, name: str) -> Path:
    member = PurePosixPath(name)
    if (not name or member.is_absolute() or ".." in member.parts or
            "\\" in name or "\x00" in name):
        raise ValueError(f"unsafe archive member: {name!r}")
    target = root.joinpath(*member.parts)
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"archive member escapes extraction directory: {name!r}")
    return target


def _extract(archive: Path, root: Path) -> None:
    """Extract regular files only; never follow links or overwrite a member."""
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as package:
            for member in package.infolist():
                target = _archive_target(root, member.filename)
                mode = member.external_attr >> 16
                if stat.S_ISLNK(mode):
                    raise ValueError(f"archive contains a symlink: {member.filename}")
                if member.is_dir():
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with package.open(member) as source, target.open("xb") as dest:
                    shutil.copyfileobj(source, dest, 1024 * 1024)
    else:
        with tarfile.open(archive, "r:gz") as package:
            for member in package:
                target = _archive_target(root, member.name)
                if member.isdir():
                    target.mkdir(mode=0o700, parents=True, exist_ok=True)
                    continue
                if not member.isfile():
                    raise ValueError(f"archive contains a nonregular member: {member.name}")
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                source = package.extractfile(member)
                if source is None:
                    raise ValueError(f"cannot read archive member: {member.name}")
                with source, target.open("xb") as dest:
                    shutil.copyfileobj(source, dest, 1024 * 1024)


def _regular_files(root: Path) -> list[Path]:
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"symlink in corpus is not accepted: {path}")
        if path.is_file():
            result.append(path)
    return result


def audio_info(path: Path) -> dict:
    if path.suffix.casefold() == ".wav":
        try:
            with wave.open(str(path), "rb") as audio:
                rate, frames = audio.getframerate(), audio.getnframes()
                info = {"container": "wav", "codec": "pcm_s16le" if audio.getsampwidth() == 2 else "pcm",
                        "sample_rate": rate, "channels": audio.getnchannels(),
                        "bits_per_sample": audio.getsampwidth() * 8,
                        "frames": frames, "duration_seconds": frames / rate,
                        "compression": audio.getcomptype()}
                if frames <= 0 or rate <= 0:
                    raise ValueError(f"empty audio: {path}")
                return info
        except (wave.Error, EOFError):
            pass
    if path.suffix.casefold() == ".flac":
        with path.open("rb") as stream:
            if stream.read(4) == b"fLaC":
                while True:
                    header = stream.read(4)
                    if len(header) != 4:
                        break
                    length = int.from_bytes(header[1:], "big")
                    block = stream.read(length)
                    if len(block) != length:
                        break
                    if header[0] & 0x7f == 0 and length == 34:
                        value = int.from_bytes(block[10:18], "big")
                        rate, frames = value >> 44, value & ((1 << 36) - 1)
                        if rate <= 0 or frames <= 0:
                            raise ValueError(f"FLAC has no sample count: {path}")
                        return {"container": "flac", "codec": "flac", "sample_rate": rate,
                                "channels": ((value >> 41) & 7) + 1,
                                "bits_per_sample": ((value >> 36) & 31) + 1,
                                "frames": frames, "duration_seconds": frames / rate}
                    if header[0] & 0x80:
                        break
    executable = shutil.which("ffprobe")
    if not executable:
        raise ValueError(f"ffprobe required to inspect non-PCM audio: {path}")
    completed = subprocess.run([executable, "-v", "error", "-select_streams", "a:0",
                                "-show_entries", "stream=codec_name,sample_rate,channels,bits_per_sample,duration:format=duration",
                                "-of", "json", str(path)], check=True, capture_output=True, text=True)
    data = json.loads(completed.stdout)
    stream = data["streams"][0]
    duration = float(stream.get("duration") or data["format"]["duration"])
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError(f"invalid audio duration: {path}")
    return {"container": path.suffix[1:].casefold(), "codec": stream["codec_name"],
            "sample_rate": int(stream["sample_rate"]), "channels": int(stream["channels"]),
            "bits_per_sample": int(stream.get("bits_per_sample", 0)), "duration_seconds": duration,
            "duration_measurement": "ffprobe"}


def _metadata(source: str, input_root: Path, out: Path) -> list[dict]:
    candidates = [path for path in sorted(input_root.iterdir()) if path.is_file() and
                  (path.name.casefold().startswith(("license", "readme", "about")) or
                   path.suffix.casefold() == ".html" or path.name.startswith("line_index_"))]
    if source == "openslr61" and not any(path.name.casefold().startswith("license") for path in candidates):
        raise ValueError(f"OpenSLR61 LICENSE must be present in {input_root}")
    if source == "mediaspeech" and not any(path.name.casefold().startswith(("license", "readme")) for path in candidates):
        raise ValueError(f"MediaSpeech README/license attribution must be present in {input_root}")
    target = out / "licenses" / source
    target.mkdir(mode=0o700, parents=True)
    result = []
    for path in candidates:
        dest = target / path.name
        with path.open("rb") as src, dest.open("xb") as sink:
            shutil.copyfileobj(src, sink)
        result.append({"input_path": str(path), "preserved_path": str(dest), "sha256": sha256(dest)})
    return result


def _source_files(source: str, input_root: Path, out: Path) -> tuple[list[Path], list[dict]]:
    names = ("es_ar_female.zip", "es_ar_male.zip") if source == "openslr61" else ("ES.tgz",)
    archives = [input_root / name for name in names if (input_root / name).is_file()]
    if archives and len(archives) != len(names):
        raise ValueError(f"incomplete published archive set for {source}: expected {', '.join(names)}")
    files, provenance = [], []
    if archives:
        for archive in archives:
            digest = sha256(archive)
            dest = out / "originals" / source / archive.name.replace(".", "-")
            _extract(archive, dest)
            if sha256(archive) != digest:
                raise ValueError(f"source archive changed during extraction: {archive}")
            files.extend(_regular_files(dest))
            provenance.append({"path": str(archive), "sha256": digest, "extracted_path": str(dest)})
    else:
        files = _regular_files(input_root)
        if not any(path.suffix.casefold() in AUDIO_SUFFIXES for path in files):
            raise ValueError(f"no published archives or extracted WAV/FLAC audio in {input_root}")
        provenance.append({"path": str(input_root), "archive_sha256": None,
                           "note": "already extracted input; individual original files are hashed"})
    return files, provenance


def _parse_openslr(root: Path, files: list[Path]) -> list[dict]:
    audio = {}
    for path in files:
        if path.suffix.casefold() in AUDIO_SUFFIXES:
            if path.stem in audio:
                raise ValueError(f"ambiguous OpenSLR FileID {path.stem}")
            audio[path.stem] = path
    rows = []
    for name in ("line_index_female.tsv", "line_index_male.tsv"):
        index = root / name
        if not index.is_file():
            raise ValueError(f"missing published reference index: {index}")
        index_hash = sha256(index)
        with index.open(encoding="utf-8-sig", newline="") as stream:
            for line_number, row in enumerate(csv.reader(stream, delimiter="\t", quoting=csv.QUOTE_NONE), 1):
                if not row:
                    continue
                if len(row) != 2 or not row[0].strip() or not row[1].strip():
                    raise ValueError(f"invalid FileID<TAB>reference at {index}:{line_number}")
                file_id, reference = row
                if file_id not in audio:
                    raise ValueError(f"missing audio for {index}:{line_number}: {file_id}")
                rows.append({"file_id": file_id, "original_path": audio[file_id], "reference": reference,
                             "published_reference_path": str(index), "published_reference_sha256": index_hash,
                             "published_reference_line": line_number,
                             "published_reference_row_sha256": text_sha256("\t".join(row))})
    if len({row["file_id"] for row in rows}) != len(rows):
        raise ValueError("duplicate FileID in OpenSLR61 published indexes")
    return rows


def _parse_mediaspeech(files: list[Path]) -> list[dict]:
    # The published ES archive pairs each FLAC/WAV with a same-stem UTF-8 TXT.
    text_by_stem = {}
    for path in files:
        if path.suffix.casefold() == ".txt":
            text_by_stem.setdefault(path.stem, []).append(path)
    rows = []
    for audio in sorted(path for path in files if path.suffix.casefold() in AUDIO_SUFFIXES):
        adjacent = audio.with_suffix(".txt")
        choices = [adjacent] if adjacent in text_by_stem.get(audio.stem, []) else text_by_stem.get(audio.stem, [])
        if len(choices) != 1:
            raise ValueError(f"MediaSpeech audio must have exactly one published same-stem TXT: {audio}")
        reference_path = choices[0]
        reference = reference_path.read_text(encoding="utf-8-sig").strip()
        if not reference:
            raise ValueError(f"empty MediaSpeech reference: {reference_path}")
        rows.append({"file_id": audio.stem, "original_path": audio, "reference": reference,
                     "published_reference_path": str(reference_path),
                     "published_reference_sha256": sha256(reference_path)})
    if not rows:
        raise ValueError("MediaSpeech ES archive contains no paired WAV/FLAC and TXT files")
    return rows


def _rank(seed: int, namespace: str, value: str) -> str:
    return text_sha256(f"{seed}:{namespace}:{value}")


def _groups(rows: list[dict], source: str) -> list[list[dict]]:
    """Content components, NOT speaker/session groups; identical audio counted once."""
    parents = list(range(len(rows)))

    def find(index):
        while parents[index] != index:
            parents[index] = parents[parents[index]]
            index = parents[index]
        return index

    seen_audio, seen_text = {}, {}
    unique = []
    for index, row in enumerate(rows):
        original = row["original_path"]
        row["original_sha256"] = sha256(original)
        row["original_format"] = audio_info(original)
        row["duration_seconds"] = row["original_format"]["duration_seconds"]
        normalized = " ".join(re.findall(r"[^\W_]+", row["reference"].casefold()))
        if not normalized:
            raise ValueError(f"published reference has no Unicode tokens: {original}")
        row["reference_content_sha256"] = text_sha256(normalized)
        duplicate = seen_audio.get(row["original_sha256"])
        if duplicate is not None:
            if rows[duplicate]["reference_content_sha256"] != row["reference_content_sha256"]:
                raise ValueError(f"identical audio has conflicting published references: {original}")
            rows[duplicate].setdefault("duplicate_originals", []).append(str(original))
            continue
        unique.append(index)
        seen_audio[row["original_sha256"]] = index
        previous = seen_text.setdefault(row["reference_content_sha256"], index)
        parents[find(index)] = find(previous)
    groups = {}
    for index in unique:
        groups.setdefault(find(index), []).append(rows[index])
    result = []
    for values in groups.values():
        component_hash = text_sha256("\n".join(sorted(row["original_sha256"] for row in values)))
        group_id = f"{source}-content-{component_hash[:24]}"
        for row in values:
            row["group_id"] = group_id
        result.append(values)
    return result


def _select(groups: list[list[dict]], source: str, seed: int) -> tuple[list[list[dict]], dict]:
    ordered = sorted(groups, key=lambda group: _rank(seed, source + ":selection", group[0]["group_id"]))
    available = sum(row["duration_seconds"] for group in ordered for row in group)
    selected, duration = [], 0.0
    for group in ordered:
        selected.append(group)
        duration += sum(row["duration_seconds"] for row in group)
        if duration >= TARGET_SECONDS:
            break
    if not selected:
        raise ValueError(f"no unique samples for {source}")
    split_order = sorted(selected, key=lambda group: _rank(seed, source + ":split", group[0]["group_id"]))
    target, dev_duration = duration * 0.30, 0.0
    for index, group in enumerate(split_order):
        group_duration = sum(row["duration_seconds"] for row in group)
        # Nearest duration boundary, with at least one group in each split when possible.
        use_dev = (index == 0 if len(split_order) > 1 else False) or (
            index < len(split_order) - 1 and abs(dev_duration + group_duration - target) <= abs(dev_duration - target))
        split = "dev" if use_dev else "holdout"
        if use_dev:
            dev_duration += group_duration
        for row in group:
            row["split"] = split
    return selected, {"available_unique_duration_seconds": available,
                      "selected_unique_duration_seconds": duration,
                      "target_unique_duration_seconds": TARGET_SECONDS,
                      "selection": "all_unique_audio" if available < TARGET_SECONDS else "seeded_content_groups_until_at_least_2h",
                      "selected_content_groups": len(selected), "dev_duration_seconds": dev_duration,
                      "holdout_duration_seconds": duration - dev_duration,
                      "dev_fraction_by_duration": dev_duration / duration,
                      "speaker_or_recording_independence": "unverified; published source mapping unavailable"}


def _convert(row: dict, dest: Path, tool_versions: dict) -> tuple[Path, dict | None]:
    spec = row["original_format"]
    if (spec["container"] == "wav" and spec.get("compression") == "NONE" and
            spec["sample_rate"] == SAMPLE_RATE and spec["channels"] == 1 and spec["bits_per_sample"] == 16):
        return row["original_path"], None
    executable = shutil.which("ffmpeg")
    if not executable:
        raise ValueError("ffmpeg required for explicit lossless-to-16k-mono-Int16 evaluation conversion")
    if "ffmpeg" not in tool_versions:
        tool_versions["ffmpeg"] = subprocess.run([executable, "-version"], check=True, capture_output=True, text=True).stdout.splitlines()[0]
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    command = [executable, "-nostdin", "-v", "error", "-n", "-i", str(row["original_path"]),
               "-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-c:a", "pcm_s16le", str(dest)]
    subprocess.run(command, check=True, capture_output=True, text=True)
    if abs(audio_info(dest)["duration_seconds"] - row["duration_seconds"]) > 0.1:
        raise ValueError(f"conversion changed duration: {dest}")
    return dest, {"command": command, "tool": tool_versions["ffmpeg"],
                  "processing": "format_conversion_only; no denoising, VAD or gain normalization"}


def _prepared_item(row: dict, source: str, out: Path, tool_versions: dict) -> dict:
    digest = row["original_sha256"]
    item_id = f"{source}-{digest[:24]}"
    wav_path, conversion = _convert(row, out / "converted" / source / (item_id + ".wav"), tool_versions)
    reference_path = out / "references" / source / (item_id + ".txt")
    reference_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with reference_path.open("x", encoding="utf-8") as stream:
        stream.write(row["reference"] + "\n")
    info = audio_info(wav_path)
    item = {"id": item_id, "source": source, "license": SOURCES[source]["license"],
            "wav_path": str(wav_path), "wav_sha256": sha256(wav_path),
            "reference_path": str(reference_path), "reference_sha256": sha256(reference_path),
            "duration_seconds": info["duration_seconds"], "format": info,
            "split": row["split"], "group_id": row["group_id"],
            "group_basis": {"kind": "exact_audio_or_reference_content", "independence_verified": False,
                            "description": "Identical original audio deduplicated; exact Unicode/casefold reference content kept in one split. Speaker/session/source IDs unavailable, never inferred from filenames."},
            "speaker_id": None, "recording_id": None, "provenance_group_available": False,
            "coverage": SOURCES[source]["coverage"] + ["original_clip"],
            "evaluation_role": "corpus_clip", "primary_evaluation": False,
            "original_path": str(row["original_path"]), "original_sha256": digest,
            "original_format": row["original_format"], "conversion": conversion,
            "published_file_id": row["file_id"], "reference_content_sha256": row["reference_content_sha256"],
            "reference_audit": "published_reference_frozen_without_candidate_outputs; not independently human-audited"}
    for key, value in row.items():
        if key.startswith("published_reference_") or key == "duplicate_originals":
            item[key] = value
    return item


def _concatenate(clips: list[dict], dest: Path, offset: float = 0.0) -> list[dict]:
    """Frame-exact PCM joining; no crossfade, gain, resampling or hidden gaps."""
    dest.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if dest.exists():
        raise ValueError(f"concatenation output exists: {dest}")
    cursor = round(offset * SAMPLE_RATE)
    clip_map = []
    with dest.open("xb") as stream, wave.open(stream, "wb") as audio:
        audio.setparams((1, 2, SAMPLE_RATE, 0, "NONE", "not compressed"))
        if cursor:
            audio.writeframesraw(bytes(cursor * 2))
        for clip in clips:
            with wave.open(clip["wav_path"], "rb") as original:
                if (original.getnchannels(), original.getsampwidth(), original.getframerate(), original.getcomptype()) != (1, 2, SAMPLE_RATE, "NONE"):
                    raise ValueError(f"clip is not canonical PCM: {clip['wav_path']}")
                frames = original.getnframes()
                clip_map.append({"id": clip["id"], "group_id": clip["group_id"],
                                 "wav_path": clip["wav_path"], "wav_sha256": clip["wav_sha256"],
                                 "original_path": clip["original_path"], "original_sha256": clip["original_sha256"],
                                 "reference_path": clip["reference_path"], "reference_sha256": clip["reference_sha256"],
                                 "published_reference_path": clip["published_reference_path"],
                                 "published_reference_sha256": clip["published_reference_sha256"],
                                 "source": clip["source"], "split": clip["split"], "license": clip["license"],
                                 "start_frame": cursor, "end_frame": cursor + frames,
                                 "start_seconds": cursor / SAMPLE_RATE, "end_seconds": (cursor + frames) / SAMPLE_RATE})
                while data := original.readframes(SAMPLE_RATE * 30):
                    audio.writeframesraw(data)
                cursor += frames
        audio.writeframes(b"")
    return clip_map


def _block(clips: list[dict], source: str, split: str, block_id: str, out: Path,
           *, primary: bool, offset: float = 0.0, base_group: str | None = None) -> dict:
    wav_path = out / ("evaluation_blocks" if primary else "diagnostics") / (block_id + ".wav")
    clip_map = _concatenate(clips, wav_path, offset)
    reference_path = wav_path.with_suffix(".txt")
    with reference_path.open("x", encoding="utf-8") as stream:
        stream.write(" ".join(Path(clip["reference_path"]).read_text(encoding="utf-8").strip() for clip in clips) + "\n")
    source_groups = sorted({clip["group_id"] for clip in clips})
    group_id = base_group or f"{source}-block-content-{text_sha256(chr(10).join(source_groups))[:24]}"
    info = audio_info(wav_path)
    return {"id": block_id, "source": source, "license": SOURCES[source]["license"],
            "split": split, "group_id": group_id,
            "group_basis": {"kind": "content_component_block", "independence_verified": False,
                            "description": "Block retains complete exact-content groups in one split; original recording/speaker mapping unavailable. Block is not an independently recorded meeting."},
            "source_group_ids": source_groups, "provenance_group_available": False,
            "wav_path": str(wav_path), "wav_sha256": sha256(wav_path),
            "reference_path": str(reference_path), "reference_sha256": sha256(reference_path),
            "duration_seconds": info["duration_seconds"], "format": info,
            "coverage": SOURCES[source]["coverage"] + (["concatenated_evaluation"] if primary else [
                "diagnostic", "long_concatenation", "leading_silence_variant",
                f"offset_{str(offset).replace('.', '_')}_seconds"]),
            "evaluation_role": "primary" if primary else "diagnostic", "primary_evaluation": primary,
            "condition": "concatenated_evaluation" if primary else f"long_diagnostic_offset_{offset:g}s",
            "time_offset_seconds": offset, "timestamp_reference_adjustment_seconds": -offset,
            "clip_map": clip_map, "concatenation": {"kind": "PCM_sample_join", "inserted_gap_seconds": 0,
                "leading_silence_seconds": offset, "independent_observation": False,
                "limitation": "Concatenation does not create spontaneous speech, real crosstalk or a real long recording."}}


def _make_blocks(items: list[dict], out: Path, seed: int) -> tuple[list[dict], list[dict], list[dict]]:
    blocks, diagnostics, unavailable = [], [], []
    for source in SOURCES:
        for split in ("dev", "holdout"):
            groups = {}
            for item in items:
                if item["source"] == source and item["split"] == split:
                    groups.setdefault(item["group_id"], []).append(item)
            ordered = sorted(groups, key=lambda group: _rank(seed, source + ":" + split + ":blocks", group))
            batches, current, duration = [], [], 0.0
            for group_id in ordered:
                group = sorted(groups[group_id], key=lambda item: item["id"])
                group_duration = sum(item["duration_seconds"] for item in group)
                if current and duration >= BLOCK_SECONDS:
                    batches.append(current)
                    current, duration = [], 0.0
                current.extend(group)
                duration += group_duration
            if current:
                batches.append(current)
            # Avoid a tiny final block when it can be joined without making a >20min block.
            if len(batches) > 1 and sum(item["duration_seconds"] for item in batches[-1]) < BLOCK_SECONDS / 2:
                if sum(item["duration_seconds"] for item in batches[-2] + batches[-1]) <= 2 * BLOCK_SECONDS:
                    batches[-2].extend(batches.pop())
            for index, batch in enumerate(batches):
                blocks.append(_block(batch, source, split, f"{source}-{split}-eval-{index:04d}", out, primary=True))
            long_clips, seconds = [], 0.0
            for group_id in ordered:
                group = sorted(groups[group_id], key=lambda item: item["id"])
                addition = sum(item["duration_seconds"] for item in group)
                if seconds + addition > 1800:
                    continue
                long_clips.extend(group)
                seconds += addition
                if seconds >= 1200:
                    break
            if seconds < 1200:
                unavailable.append({"source": source, "split": split, "reason": "fewer than 20 minutes of complete selected content groups fit a 20-30 minute diagnostic"})
                continue
            base_group = f"{source}-{split}-long-diagnostic"
            for offset in (0.0, 0.25, 0.5, 0.75, 1.0):
                suffix = f"{round(offset * 1000):04d}ms"
                diagnostics.append(_block(long_clips, source, split, f"{base_group}-{suffix}", out,
                                          primary=False, offset=offset, base_group=base_group))
    return blocks, diagnostics, unavailable


def prepare(corpora_root: Path, out: Path, seed: int) -> dict:
    root = corpora_root.expanduser().resolve(strict=True)
    if not root.is_dir():
        raise ValueError("--corpora-root must be a directory of already downloaded public sources")
    if out.expanduser().resolve().is_relative_to(root):
        raise ValueError("--out must be separate from immutable --corpora-root")
    out = fresh_directory(out.expanduser())
    items, sources, tool_versions = [], {}, {}
    for source, specification in SOURCES.items():
        input_root = root / source
        if not input_root.is_dir():
            raise ValueError(f"missing downloaded source directory: {input_root}")
        assets = _metadata(source, input_root, out)
        files, archives = _source_files(source, input_root, out)
        rows = _parse_openslr(input_root, files) if source == "openslr61" else _parse_mediaspeech(files)
        groups = _groups(rows, source)
        selected, selection = _select(groups, source, seed)
        sources[source] = {**specification, "archives": archives, "preserved_license_and_reference_assets": assets,
                           "published_rows": len(rows), "unique_audio_rows": sum(len(group) for group in groups),
                           "selection": selection, "speaker_metadata": "unavailable", "recording_origin_metadata": "unavailable"}
        for group in selected:
            for row in group:
                items.append(_prepared_item(row, source, out, tool_versions))
    items.sort(key=lambda item: (item["source"], item["split"], item["id"]))
    blocks, diagnostics, unavailable = _make_blocks(items, out, seed)
    manifest = {"schema_version": SCHEMA_VERSION, "seed": seed, "sources": sources,
                "items": items, "evaluation_blocks": blocks, "diagnostic_manifest_path": str(out / "diagnostics-manifest.json"),
                "tool_versions": tool_versions, "diagnostics_unavailable": unavailable,
                "selection_frozen_before_asr": True,
                "reference_policy": "Published references frozen before recognition; no candidate-driven corrections. Reference errors remain possible.",
                "grouping_policy": "Content-only grouping prevents exact-content leakage, not unknown speaker/session overlap; independence unverified.",
                "evaluation_policy": "Run evaluation_blocks only. Never pool originals, technical replicas, diagnostic blocks or offset variants with these primary blocks.",
                "coverage_limits": ["read/media clips, not spontaneous meetings", "speaker and original-recording independence unverified",
                                    "no reference word timings", "critical spans not human-annotated", "no real dual-channel capture in these public corpora"]}
    diagnostic_manifest = {"schema_version": SCHEMA_VERSION, "seed": seed, "sources": sources, "items": diagnostics,
                           "selection_frozen_before_asr": True, "suite": "diagnostic_only",
                           "coverage_limits": manifest["coverage_limits"],
                           "evaluation_policy": "Diagnostic only. Each leading-silence variant shares a group; do not count as independent or pool into primary totals."}
    write_json(out / "diagnostics-manifest.json", diagnostic_manifest)
    write_json(out / "manifest.json", manifest)
    hashes = {"manifest.json": sha256(out / "manifest.json"),
              "diagnostics-manifest.json": sha256(out / "diagnostics-manifest.json")}
    write_json(out / "manifest-hashes.json", hashes)
    return {"manifest_path": str(out / "manifest.json"), "manifest_sha256": hashes["manifest.json"],
            "diagnostic_manifest_path": str(out / "diagnostics-manifest.json"),
            "unique_original_clips": len(items), "evaluation_blocks": len(blocks),
            "diagnostic_variants": len(diagnostics), "sources": {name: data["selection"] for name, data in sources.items()}}
