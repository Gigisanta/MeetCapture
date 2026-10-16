"""Portable meeting notes and bounded vocabulary extraction for the dispatcher."""

from __future__ import annotations

import json
import math
import os
import re
from datetime import datetime

TAG_RE = re.compile(r"^[\w-]+(?:/[\w-]+)*$", re.UNICODE)
INLINE_TAG_RE = re.compile(r"(?<!\S)#([\w-]+(?:/[\w-]+)*)", re.UNICODE)
MAX_VAULT_FILES = 300
MAX_VAULT_FILE_BYTES = 64 * 1024
MAX_TAGS = 100


def _tag(value: str) -> str | None:
    value = value.strip().lstrip("#").lower()
    return value if 0 < len(value) <= 50 and TAG_RE.fullmatch(value) else None


def load_tag_vocabulary(directory: str | None) -> list[str]:
    """Read only tag names from a bounded number of regular Markdown files."""
    if not directory:
        return []
    root = os.path.expanduser(directory)
    if not os.path.isdir(root):
        raise ValueError("tag_vocabulary_dir no es un directorio")
    tags: set[str] = set()
    count = 0
    for parent, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and not os.path.islink(os.path.join(parent, d)))
        for name in sorted(files):
            path = os.path.join(parent, name)
            if not name.lower().endswith(".md") or os.path.islink(path):
                continue
            try:
                if os.path.getsize(path) > MAX_VAULT_FILE_BYTES:
                    continue
                with open(path, encoding="utf-8") as stream:
                    content = stream.read(MAX_VAULT_FILE_BYTES + 1)
            except (OSError, UnicodeError):
                continue
            count += 1
            for match in INLINE_TAG_RE.finditer(content):
                tag = _tag(match.group(1))
                if tag:
                    tags.add(tag)
            # Obsidian-style YAML frontmatter. Only the tags field is read.
            if content.startswith("---\n"):
                end = content.find("\n---", 4)
                if end != -1:
                    frontmatter = content[4:end]
                    field = re.search(r"(?m)^tags:[ \t]*(.*)$", frontmatter)
                    if field:
                        raw = field.group(1).strip().strip("[]")
                        for part in raw.split(","):
                            tag = _tag(part.strip(" \t\"'"))
                            if tag:
                                tags.add(tag)
                        for line in frontmatter[field.end():].lstrip("\r\n").splitlines():
                            if not line.startswith((" ", "\t")):
                                break
                            item = re.fullmatch(r"\s*-\s*(.*?)\s*", line)
                            if item:
                                tag = _tag(item.group(1).strip("\"'"))
                                if tag:
                                    tags.add(tag)
            if count >= MAX_VAULT_FILES or len(tags) >= MAX_TAGS:
                return sorted(tags)[:MAX_TAGS]
    return sorted(tags)[:MAX_TAGS]


def filter_tags(value: object, vocabulary: list[str]) -> list[str]:
    if not isinstance(value, list):
        return []
    allowed = set(vocabulary)
    result: list[str] = []
    for item in value:
        tag = _tag(item) if isinstance(item, str) else None
        if tag in allowed and tag not in result:
            result.append(tag)
        if len(result) == 4:
            break
    return result


def build_markdown(contract: dict, summary: dict, transcript: str, dry: bool,
                   user_notes: str = "") -> str:
    def single_line(value: object) -> str:
        return " ".join(str(value).split())

    def safe_inline(value: object) -> str:
        return re.sub(r"([\\`\[\]!<>])", r"\\\1", single_line(value))

    def items(values: list[str], checklist: bool = False) -> str:
        if not values:
            return "Sin ítems.\n"
        prefix = "- [ ] " if checklist else "- "
        return "".join(prefix + safe_inline(item) + "\n" for item in values)

    title = single_line(contract.get("title") or "Reunión sin título")
    started = single_line(contract.get("startedAt") or "")
    try:
        date = datetime.fromisoformat(started.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        date = ""
    ticks = max((len(m.group(0)) for m in re.finditer(r"`+", transcript)), default=0)
    fence = "`" * max(3, ticks + 1)
    tags = summary.get("tags", [])
    duration = contract.get("durationSec")
    duration = duration if type(duration) in (int, float) and math.isfinite(duration) and duration >= 0 else 0
    return (
        "---\n"
        + "title: " + json.dumps(title, ensure_ascii=False) + "\n"
        + "date: " + json.dumps(date) + "\n"
        + "meeting_id: " + json.dumps(single_line(contract.get("meetingId") or "")) + "\n"
        + "duration_sec: " + str(duration) + "\n"
        + "tags: " + json.dumps(tags, ensure_ascii=False) + "\n"
        + "source: meetcapture\n"
        + "dry_run: " + ("true" if dry else "false") + "\n"
        + "---\n\n# " + safe_inline(title) + "\n\n"
        + ("## Mis notas\n\n" + user_notes.rstrip() + "\n\n" if user_notes.strip() else "")
        + "## Resumen\n\n" + items(summary["resumen"]) + "\n"
        + "## Decisiones\n\n" + items(summary["decisiones"]) + "\n"
        + "## Pendientes\n\n" + items(summary["action_items"], checklist=True) + "\n"
        + "## Asistentes\n\n" + items(summary["asistentes"]) + "\n"
        + "## Transcripción\n\n" + fence + "text\n" + transcript.rstrip("\n") + "\n" + fence + "\n"
    )
