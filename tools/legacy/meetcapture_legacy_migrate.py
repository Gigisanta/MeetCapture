#!/usr/bin/env python3
"""Safely harden and archive legacy MeetCapture artifacts.

Dry-run is the default. The helper never deletes meeting audio and refuses an
archive while the compatibility daemon reports an active recording.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
from pathlib import Path
from typing import NamedTuple


class MigrationError(RuntimeError):
    pass


class PlanItem(NamedTuple):
    source: Path
    category: str


PRIVATE_GLOBS = (
    ".daemon_state.json",
    ".daemon_state.json.bak*",
    ".daemon.log",
    ".transcribe.log",
    ".transcribe_queue.json",
    ".manual_session.json",
    ".daemon.pid",
)

LEGACY_CODE = (
    "meet-daemon.py",
    "MeetCaptureApp.py",
    "MeetCaptureLauncher.m",
    "MeetCaptureLauncher.swift",
    "launcher.c",
    "MeetCapture.sh",
    ".transcribe_worker.py",
    "capture.py",
    "meetcapture_transcription.py",
    "meetcapture_intelligence.py",
    "meetcapture",
    "create_meetcapture_output",
    "setoutput",
)

AUDIO_SUFFIXES = {".pcm", ".wav", ".flac", ".caf", ".aiff", ".m4a", ".mp3"}


def build_plan(root: Path, include_audio: bool = False) -> list[PlanItem]:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise MigrationError(f"legacy root is not a directory: {root}")

    items: dict[Path, PlanItem] = {}
    for pattern in PRIVATE_GLOBS:
        for path in root.glob(pattern):
            if path.is_file():
                items[path] = PlanItem(path, "private-runtime")
    for name in LEGACY_CODE:
        path = root / name
        if path.is_file():
            items[path] = PlanItem(path, "legacy-code")

    if include_audio:
        for directory_name in ("recordings", "inbox"):
            directory = root / directory_name
            if not directory.is_dir():
                continue
            for path in directory.rglob("*"):
                if path.is_file() and path.suffix.lower() in AUDIO_SUFFIXES:
                    items[path] = PlanItem(path, "audio")

    return sorted(items.values(), key=lambda item: str(item.source))


def harden(root: Path) -> list[Path]:
    root = root.expanduser().resolve()
    if not root.is_dir():
        raise MigrationError(f"legacy root is not a directory: {root}")

    changed: list[Path] = []
    os.chmod(root, 0o700)
    changed.append(root)

    for directory_name in ("recordings", "inbox", ".backups"):
        directory = root / directory_name
        if directory.is_dir():
            os.chmod(directory, 0o700)
            changed.append(directory)

    for item in build_plan(root, include_audio=False):
        os.chmod(item.source, 0o600)
        changed.append(item.source)
    return changed


def active_recording(socket_path: Path = Path("/tmp/meetcapture.sock")) -> bool:
    if not socket_path.exists():
        return False
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(1.0)
    try:
        client.connect(str(socket_path))
        request = {"id": "legacy-migration", "command": "get_status", "payload": {}}
        client.sendall(json.dumps(request, separators=(",", ":")).encode() + b"\n")
        raw = b""
        while not raw.endswith(b"\n") and len(raw) < 65_536:
            chunk = client.recv(8192)
            if not chunk:
                break
            raw += chunk
        response = json.loads(raw.decode())
        data = response.get("data") or {}
        return bool(data.get("is_recording") or data.get("active_session"))
    except (OSError, ValueError, json.JSONDecodeError):
        return False
    finally:
        client.close()


def archive(plan: list[PlanItem], root: Path, destination: Path) -> list[Path]:
    root = root.expanduser().resolve()
    destination = destination.expanduser().resolve()
    if destination.exists() and any(destination.iterdir()):
        raise MigrationError(f"archive destination is not empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(destination, 0o700)

    moved: list[Path] = []
    for item in plan:
        source = item.source.resolve()
        try:
            relative = source.relative_to(root)
        except ValueError as exc:
            raise MigrationError(f"refusing path outside legacy root: {source}") from exc
        target = destination / relative
        if target.exists():
            raise MigrationError(f"archive collision: {target}")
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(target.parent, 0o700)
        shutil.move(str(source), str(target))
        if target.is_file():
            os.chmod(target, 0o600)
        moved.append(target)
    return moved


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path.home() / "meetings")
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--harden", action="store_true")
    parser.add_argument("--archive", action="store_true")
    parser.add_argument("--include-audio", action="store_true")
    parser.add_argument("--apply", action="store_true", help="perform changes; default is dry-run")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.harden and not args.archive:
        raise SystemExit("choose --harden and/or --archive")
    if args.archive and args.destination is None:
        raise SystemExit("--archive requires --destination")

    plan = build_plan(args.root, include_audio=args.include_audio)
    summary = {
        "mode": "apply" if args.apply else "dry-run",
        "root": str(args.root.expanduser()),
        "harden": args.harden,
        "archive": args.archive,
        "include_audio": args.include_audio,
        "planned": [{"path": str(item.source), "category": item.category} for item in plan],
    }
    print(json.dumps(summary, indent=2))
    if not args.apply:
        return 0

    if args.archive and active_recording():
        raise MigrationError("refusing archive while MeetCapture reports an active recording")
    if args.harden:
        harden(args.root)
    if args.archive:
        assert args.destination is not None
        archive(plan, args.root, args.destination)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MigrationError as exc:
        raise SystemExit(f"ERROR: {exc}") from exc
