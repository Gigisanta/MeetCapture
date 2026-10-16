#!/usr/bin/env python3
"""Tests for the summary dispatcher: handoff lifecycle, backoff, --retry-failed.

Runs in dry_run mode inside a temp directory; never touches ~/meetings.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

TMP = tempfile.mkdtemp(prefix="meetcapture-dispatcher-")
MEETINGS = os.path.join(TMP, "meetings")
CONFIG = os.path.join(TMP, "summary.json")
os.makedirs(MEETINGS, mode=0o700)
with open(CONFIG, "w", encoding="utf-8") as f:
    json.dump({"dry_run": True, "keep_audio": False}, f)
os.environ["MEETCAPTURE_MEETINGS_DIR"] = MEETINGS
os.environ["MEETCAPTURE_SUMMARY_CONFIG"] = CONFIG
os.environ["MEETCAPTURE_POST_SUMMARY"] = os.path.join(TMP, "no-post-summary-hook")

SCRIPT = Path(__file__).with_name("meetcapture_summary_dispatcher.py")
spec = importlib.util.spec_from_file_location("dispatcher", SCRIPT)
mod = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(mod)


def _contract(base: str, text: str = "hola mundo\n", with_audio: bool = True, **extra) -> str:
    tpath = os.path.join(MEETINGS, base + ".txt")
    with open(tpath, "w", encoding="utf-8") as f:
        f.write(text)
    apath = None
    if with_audio:
        apath = os.path.join(MEETINGS, base + ".pcm")
        with open(apath, "wb") as f:
            f.write(b"\0" * 16)
    contract = {
        "version": 2, "meetingId": base, "title": "Demo", "startedAt": "2026-09-01T14:08:29Z",
        "endedAt": "2026-09-01T14:10:29Z", "durationSec": 120.0, "transcriptPath": tpath,
        "audioPath": apath, "engine": "parakeet", "model": "parakeet-tdt-0.6b-ultra", "language": "es",
        "segments": [{"start": 0, "end": 1, "text": "hola mundo"}], "speakerCount": 0,
        "checksum": hashlib.sha256(text.encode("utf-8")).hexdigest(),
    }
    contract.update(extra)
    path = os.path.join(MEETINGS, base + ".pending")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(contract, f)
    return path


def _rewrite_paths(base: str, transcript_path: str, audio_path) -> None:
    path = os.path.join(MEETINGS, base + ".pending")
    with open(path, encoding="utf-8") as f:
        contract = json.load(f)
    contract["transcriptPath"] = transcript_path
    contract["audioPath"] = audio_path
    with open(path, "w", encoding="utf-8") as f:
        json.dump(contract, f)


class DispatcherTests(unittest.TestCase):
    def setUp(self) -> None:
        for name in os.listdir(MEETINGS):
            p = os.path.join(MEETINGS, name)
            shutil.rmtree(p) if os.path.isdir(p) else os.remove(p)
        mod.ensure_dirs()
        self.cfg = mod.load_config()

    def names(self):
        return sorted(n for n in os.listdir(MEETINGS) if not n.startswith("."))

    def test_pending_becomes_done_with_artifacts(self):
        _contract("meet-1")
        self.assertEqual(mod.run_once(self.cfg), 1)
        self.assertIn("meet-1.done", self.names())
        self.assertIn("meet-1.summary.json", self.names())
        self.assertIn("meet-1.summary.html", self.names())
        self.assertIn("meet-1.summary.md", self.names())
        self.assertNotIn("meet-1.pcm", self.names(), "keep_audio=false deletes the audio")
        with open(os.path.join(MEETINGS, "meet-1.summary.json"), encoding="utf-8") as f:
            out = json.load(f)
        self.assertTrue(out["dry_run"])
        self.assertEqual(out["meetingId"], "meet-1")
        with open(os.path.join(MEETINGS, "meet-1.summary.md"), encoding="utf-8") as f:
            note = f.read()
        self.assertIn("## Pendientes\n\n- [ ] ", note)
        self.assertIn("## Transcripción\n\n```text\nhola mundo", note)
        self.assertEqual(os.stat(os.path.join(MEETINGS, "meet-1.summary.md")).st_mode & 0o777, 0o600)
        self.assertEqual(oct(os.stat(os.path.join(MEETINGS, "meet-1.done")).st_mode & 0o777), "0o600")
        # Idempotent: a second .pending for the same base is skipped.
        _contract("meet-1")
        mod.run_once(self.cfg)
        self.assertIn("meet-1.pending", self.names())

    def test_checksum_mismatch_is_permanent_error(self):
        _contract("meet-2", checksum="deadbeef")
        mod.run_once(self.cfg)
        self.assertIn("meet-2.pending.error", self.names())

    def test_malformed_contract_is_permanent_without_outputs_or_audio_delete(self):
        _contract("meet-bad-contract", transcriptPath=[])
        mod.run_once(self.cfg)
        self.assertIn("meet-bad-contract.pending.error", self.names())
        self.assertNotIn("meet-bad-contract.summary.json", self.names())
        self.assertNotIn("meet-bad-contract.summary.html", self.names())
        self.assertIn("meet-bad-contract.pcm", self.names())

    def test_external_absolute_and_traversal_paths_are_rejected(self):
        outside = os.path.join(TMP, "outside-paths")
        os.makedirs(outside, exist_ok=True)
        cases = (
            ("meet-outside-absolute", lambda name: os.path.join(outside, name)),
            ("meet-outside-traversal", lambda name: os.path.join("..", "outside-paths", name)),
        )
        for base, path_for in cases:
            transcript = path_for(base + ".txt")
            audio = path_for(base + ".pcm")
            absolute_transcript = os.path.join(MEETINGS, transcript) if not os.path.isabs(transcript) else transcript
            absolute_audio = os.path.join(MEETINGS, audio) if not os.path.isabs(audio) else audio
            with open(absolute_transcript, "w", encoding="utf-8") as f:
                f.write("hola mundo\n")
            with open(absolute_audio, "wb") as f:
                f.write(b"audio")
            _contract(base)
            _rewrite_paths(base, transcript, audio)

        mod.run_once(self.cfg)
        for base, _path_for in cases:
            self.assertIn(base + ".pending.error", self.names())
            self.assertNotIn(base + ".done", self.names())
            self.assertNotIn(base + ".summary.json", self.names())
            self.assertNotIn(base + ".summary.html", self.names())
            self.assertTrue(os.path.exists(os.path.join(outside, base + ".pcm")))

    def test_symlink_to_outside_is_rejected_without_audio_delete(self):
        outside = os.path.join(TMP, "outside-symlink")
        imports = os.path.join(MEETINGS, "imports")
        os.makedirs(outside, exist_ok=True)
        os.makedirs(imports, exist_ok=True)
        transcript = os.path.join(outside, "transcript.txt")
        audio = os.path.join(outside, "audio.pcm")
        with open(transcript, "w", encoding="utf-8") as f:
            f.write("hola mundo\n")
        with open(audio, "wb") as f:
            f.write(b"audio")
        os.symlink(transcript, os.path.join(imports, "transcript.txt"))
        os.symlink(audio, os.path.join(imports, "audio.pcm"))
        _contract("meet-symlink-outside")
        _rewrite_paths("meet-symlink-outside", "imports/transcript.txt", "imports/audio.pcm")

        mod.run_once(self.cfg)
        self.assertIn("meet-symlink-outside.pending.error", self.names())
        self.assertNotIn("meet-symlink-outside.done", self.names())
        self.assertTrue(os.path.exists(audio))

    def test_absolute_inside_relative_imports_and_null_audio_are_allowed(self):
        imports = os.path.join(MEETINGS, "imports")
        os.makedirs(imports, exist_ok=True)
        _contract("meet-relative")
        os.replace(os.path.join(MEETINGS, "meet-relative.txt"), os.path.join(imports, "meet-relative.txt"))
        os.replace(os.path.join(MEETINGS, "meet-relative.pcm"), os.path.join(imports, "meet-relative.pcm"))
        _rewrite_paths("meet-relative", "imports/meet-relative.txt", "imports/meet-relative.pcm")
        _contract("meet-null-audio", with_audio=False)

        mod.run_once(self.cfg)
        self.assertIn("meet-relative.done", self.names())
        self.assertNotIn("meet-relative.pcm", os.listdir(imports))
        self.assertIn("meet-null-audio.done", self.names())

    def test_valid_llm_response_acknowledges_and_deletes_audio(self):
        _contract("meet-llm")
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        response = json.dumps({
            "resumen": ["Se trató el lanzamiento."],
            "action_items": ["Preparar la demo."],
            "decisiones": [],
            "asistentes": ["Ana"],
        })
        with mock.patch.object(mod, "call_llm", return_value=response):
            self.assertEqual(mod.run_once(cfg), 1)
        self.assertIn("meet-llm.done", self.names())
        self.assertNotIn("meet-llm.pcm", self.names())
        with open(os.path.join(MEETINGS, "meet-llm.summary.json"), encoding="utf-8") as f:
            out = json.load(f)
        self.assertEqual(out["resumen"], ["Se trató el lanzamiento."])
        self.assertEqual(out["asistentes"], ["Ana"])

    def test_vocab_filters_invented_tags_and_exports_portable_note(self):
        vault = os.path.join(TMP, "vault")
        os.makedirs(vault, exist_ok=True)
        with open(os.path.join(vault, "existing.md"), "w", encoding="utf-8") as f:
            f.write("---\ntags: [cliente, proyecto/alpha]\n---\n#seguimiento\n")
        with open(os.path.join(vault, "sequence.md"), "w", encoding="utf-8") as f:
            f.write("---\ntags:\n  - reunion\n---\n")
        _contract("meet-vocab", text="Decidimos avanzar.\n")
        cfg = dict(self.cfg, dry_run=False, model="test-model", tag_vocabulary_dir=vault)
        response = json.dumps({
            "resumen": ["Se definió el plan."],
            "action_items": ["Ana — enviar propuesta el 2026-09-30"],
            "decisiones": ["Avanzar."], "asistentes": ["Ana"],
            "tags": ["cliente", "inventado", "proyecto/alpha", "cliente"],
        })
        with mock.patch.object(mod, "call_llm", return_value=response) as call:
            mod.run_once(cfg)
        self.assertIn("Tags permitidos: cliente, proyecto/alpha, reunion, seguimiento", call.call_args.args[2])
        with open(os.path.join(MEETINGS, "meet-vocab.summary.json"), encoding="utf-8") as f:
            out = json.load(f)
        self.assertEqual(out["tags"], ["cliente", "proyecto/alpha"])
        with open(os.path.join(MEETINGS, "meet-vocab.summary.md"), encoding="utf-8") as f:
            note = f.read()
        self.assertIn('tags: ["cliente", "proyecto/alpha"]', note)
        self.assertIn("- [ ] Ana — enviar propuesta el 2026-09-30", note)
        self.assertNotIn("inventado", note)

    def test_manual_notes_feed_model_and_survive_in_all_artifacts(self):
        _contract("meet-notes")
        notes_path = os.path.join(MEETINGS, "meet-notes.notes.md")
        with open(notes_path, "w", encoding="utf-8") as f:
            f.write("Prioridad: cerrar presupuesto. <interno>\n")
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        response = json.dumps({
            "resumen": ["Se conversó sobre presupuesto."],
            "action_items": [], "decisiones": [], "asistentes": [],
        })
        with mock.patch.object(mod, "call_llm", return_value=response) as call:
            mod.run_once(cfg)
        self.assertIn("Prioridad: cerrar presupuesto.", call.call_args.args[2])
        self.assertIn("meet-notes.done", self.names())
        with open(os.path.join(MEETINGS, "meet-notes.summary.json"), encoding="utf-8") as f:
            self.assertIn("Prioridad: cerrar presupuesto.", json.load(f)["user_notes"])
        with open(os.path.join(MEETINGS, "meet-notes.summary.html"), encoding="utf-8") as f:
            self.assertIn("&lt;interno&gt;", f.read())
        with open(os.path.join(MEETINGS, "meet-notes.summary.md"), encoding="utf-8") as f:
            self.assertIn("## Mis notas\n\nPrioridad: cerrar presupuesto.", f.read())

    def test_long_transcript_is_summarized_by_parts_then_merged(self):
        line = "[Gio]: " + "presupuesto " * 40 + "\n"
        _contract("meet-long", text=line * 120, speakers=["Gio", "Participante 1"])
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        partial = json.dumps({"resumen": ["parte"], "action_items": [], "decisiones": [], "asistentes": []})
        final = json.dumps({"resumen": ["reunión completa"], "action_items": [], "decisiones": [],
                            "asistentes": ["Gio"]})
        prompts = []

        def fake(_cfg, _model, prompt):
            prompts.append(prompt)
            return final if "resúmenes JSON" in prompt else partial

        with mock.patch.object(mod, "call_llm", side_effect=fake):
            mod.run_once(cfg)
        parts = mod.split_transcript(line * 120)
        self.assertGreater(len(parts), 1)
        self.assertTrue(all(len(p) <= mod.MAP_CHARS for p in parts))
        self.assertEqual("\n".join(parts), (line * 120).rstrip("\n"), "no line is lost or cut")
        self.assertEqual(len(prompts), len(parts) + 1)
        self.assertTrue(all("Hablantes etiquetados: Gio, Participante 1" in p for p in prompts))
        with open(os.path.join(MEETINGS, "meet-long.summary.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f)["resumen"], ["reunión completa"])

    def test_notes_symlink_outside_is_rejected_without_audio_delete(self):
        _contract("meet-bad-notes")
        outside = os.path.join(TMP, "outside-notes.md")
        with open(outside, "w", encoding="utf-8") as f:
            f.write("secret")
        os.symlink(outside, os.path.join(MEETINGS, "meet-bad-notes.notes.md"))
        mod.run_once(self.cfg)
        self.assertIn("meet-bad-notes.pending.error", self.names())
        self.assertIn("meet-bad-notes.pcm", self.names())
        self.assertNotIn("meet-bad-notes.summary.md", self.names())

    def test_audio_cannot_alias_generated_markdown(self):
        base = "meet-audio-alias"
        _contract(base)
        markdown_path = os.path.join(MEETINGS, base + ".summary.md")
        with open(markdown_path, "w", encoding="utf-8") as f:
            f.write("nota anterior")
        _rewrite_paths(base, os.path.join(MEETINGS, base + ".txt"), markdown_path)
        mod.run_once(self.cfg)
        self.assertIn(base + ".pending.error", self.names())
        self.assertNotIn(base + ".done", self.names())
        self.assertNotIn(base + ".summary.json", self.names())
        with open(markdown_path, encoding="utf-8") as f:
            self.assertEqual(f.read(), "nota anterior")

    def test_markdown_escapes_model_images_and_frontmatter_fields(self):
        note = mod.build_markdown(
            {"title": "Plan [privado]", "meetingId": "meet-x", "durationSec": "1\ninjected: yes"},
            {"resumen": ["![](https://example.test/track)"], "decisiones": [],
             "action_items": [], "asistentes": [], "tags": []},
            "texto\n````\n", False)
        self.assertIn("duration_sec: 0\n", note)
        self.assertNotIn("injected: yes", note)
        self.assertIn(r"\!\[\](https://example.test/track)", note)
        self.assertIn("`````text", note)

    def test_markdown_publish_failure_restores_previous_outputs(self):
        _contract("meet-md-failure")
        old = {}
        for suffix in ("json", "html", "md"):
            path = os.path.join(MEETINGS, "meet-md-failure.summary." + suffix)
            old[path] = "previous " + suffix
            with open(path, "w", encoding="utf-8") as f:
                f.write(old[path])
        original_replace = mod.os.replace
        failed = False

        def replace(src, dst):
            nonlocal failed
            if not failed and dst.endswith("meet-md-failure.summary.md"):
                failed = True
                raise OSError("simulated markdown publish failure")
            return original_replace(src, dst)

        with mock.patch.object(mod.os, "replace", side_effect=replace):
            mod.run_once(self.cfg)
        self.assertIn("meet-md-failure.pending.retry", self.names())
        self.assertIn("meet-md-failure.pcm", self.names())
        for path, content in old.items():
            with open(path, encoding="utf-8") as f:
                self.assertEqual(f.read(), content)

    def test_invalid_llm_response_retries_without_ack_or_audio_delete(self):
        _contract("meet-bad-summary")
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        response = json.dumps({"resumen": []})
        with mock.patch.object(mod, "call_llm", return_value=response):
            self.assertEqual(mod.run_once(cfg), 1)
        self.assertIn("meet-bad-summary.pending.retry", self.names())
        self.assertNotIn("meet-bad-summary.done", self.names())
        self.assertNotIn("meet-bad-summary.summary.json", self.names())
        self.assertNotIn("meet-bad-summary.summary.html", self.names())
        self.assertIn("meet-bad-summary.pcm", self.names())

    def test_whitespace_only_summary_retries_without_ack_or_audio_delete(self):
        _contract("meet-blank-summary")
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        response = json.dumps({
            "resumen": ["   "],
            "action_items": [],
            "decisiones": [],
            "asistentes": [],
        })
        with mock.patch.object(mod, "call_llm", return_value=response):
            self.assertEqual(mod.run_once(cfg), 1)
        self.assertIn("meet-blank-summary.pending.retry", self.names())
        self.assertNotIn("meet-blank-summary.done", self.names())
        self.assertNotIn("meet-blank-summary.summary.json", self.names())
        self.assertIn("meet-blank-summary.pcm", self.names())

    def test_retry_transition_resets_backoff_clock(self):
        path = _contract("meet-old-retry")
        mod.fail(path, "meet-old-retry", "first failure")
        retry = os.path.join(MEETINGS, "meet-old-retry.pending.retry")
        old = time.time() - 3600
        os.utime(retry, (old, old))
        cfg = dict(self.cfg, dry_run=False, model="test-model")
        with mock.patch.object(mod, "call_llm", side_effect=RuntimeError("gateway down")):
            now = time.time()
            self.assertEqual(mod.run_once(cfg, now=now), 1)
            next_retry = os.path.join(MEETINGS, "meet-old-retry.pending.retry.2")
            self.assertTrue(os.path.exists(next_retry))
            self.assertFalse(mod.due(next_retry, now=now))
            self.assertEqual(mod.run_once(cfg, now=now), 0)

    def test_artifact_publish_failure_rolls_back_outputs(self):
        _contract("meet-partial")
        original_replace = mod.os.replace
        failed = False

        def replace(src, dst):
            nonlocal failed
            if not failed and os.path.basename(dst) == "meet-partial.summary.html":
                failed = True
                raise OSError("simulated html publish failure")
            return original_replace(src, dst)

        with mock.patch.object(mod.os, "replace", side_effect=replace):
            self.assertEqual(mod.run_once(self.cfg), 1)
        self.assertIn("meet-partial.pending.retry", self.names())
        self.assertNotIn("meet-partial.summary.json", self.names())
        self.assertNotIn("meet-partial.summary.html", self.names())
        self.assertIn("meet-partial.pcm", self.names())

    def test_ack_failure_rolls_back_outputs_and_keeps_audio(self):
        _contract("meet-ack")
        original_replace = mod.os.replace

        def replace(src, dst):
            if os.path.basename(src) == "meet-ack.pending" and os.path.basename(dst) == "meet-ack.done":
                raise OSError("simulated ack failure")
            return original_replace(src, dst)

        with mock.patch.object(mod.os, "replace", side_effect=replace):
            self.assertEqual(mod.run_once(self.cfg), 1)
        self.assertIn("meet-ack.pending.retry", self.names())
        self.assertNotIn("meet-ack.done", self.names())
        self.assertNotIn("meet-ack.summary.json", self.names())
        self.assertNotIn("meet-ack.summary.html", self.names())
        self.assertIn("meet-ack.pcm", self.names())

    def test_state_collisions_preserve_existing_handoffs(self):
        path = _contract("meet-collision")
        retry = os.path.join(MEETINGS, "meet-collision.pending.retry")
        with open(retry, "w", encoding="utf-8") as f:
            f.write("older retry")
        mod.fail(path, "meet-collision", "transient")
        self.assertTrue(os.path.exists(path))
        with open(retry, encoding="utf-8") as f:
            self.assertEqual(f.read(), "older retry")

        failed = os.path.join(MEETINGS, "meet-requeue.pending.failed")
        pending = os.path.join(MEETINGS, "meet-requeue.pending")
        with open(failed, "w", encoding="utf-8") as f:
            f.write("failed")
        with open(pending, "w", encoding="utf-8") as f:
            f.write("newer")
        self.assertEqual(mod.retry_failed(), 0)
        with open(failed, encoding="utf-8") as f:
            self.assertEqual(f.read(), "failed")
        with open(pending, encoding="utf-8") as f:
            self.assertEqual(f.read(), "newer")

    def test_backoff_schedule(self):
        self.assertEqual(mod.backoff_seconds(0), 0)
        self.assertEqual([mod.backoff_seconds(g) for g in range(1, 9)],
                         [300, 600, 1200, 2400, 4800, 9600, 19200, 21600])
        self.assertEqual(mod.retry_generation("x.pending"), 0)
        self.assertEqual(mod.retry_generation("x.pending.retry"), 1)
        self.assertEqual(mod.retry_generation("x.pending.retry.7"), 7)

    def test_retry_waits_for_backoff_then_processes(self):
        path = _contract("meet-3")
        mod.fail(path, "meet-3", "gateway 502")
        retry = os.path.join(MEETINGS, "meet-3.pending.retry")
        self.assertTrue(os.path.exists(retry))
        self.assertEqual(mod.run_once(self.cfg), 0, "fresh retry is still in backoff")
        self.assertTrue(os.path.exists(retry))
        past = time.time() - 301
        os.utime(retry, (past, past))
        self.assertEqual(mod.run_once(self.cfg), 1)
        self.assertIn("meet-3.done", self.names())

    def test_exhausted_retries_become_failed_and_can_be_requeued(self):
        path = _contract("meet-4")
        current = path
        for gen in range(1, mod.MAX_RETRIES + 1):
            mod.fail(current, "meet-4", "still down")
            current = os.path.join(MEETINGS, "meet-4.pending.retry" + ("" if gen == 1 else ".%d" % gen))
            self.assertTrue(os.path.exists(current), current)
        mod.fail(current, "meet-4", "gave up")
        self.assertIn("meet-4.pending.failed", self.names())
        self.assertEqual(mod.retry_failed(), 1)
        self.assertIn("meet-4.pending", self.names())
        self.assertEqual(mod.run_once(self.cfg), 1)
        self.assertIn("meet-4.done", self.names())

    def test_unsupported_version_is_permanent(self):
        _contract("meet-5", version=1)
        mod.run_once(self.cfg)
        self.assertIn("meet-5.pending.error", self.names())


if __name__ == "__main__":
    try:
        unittest.main(verbosity=1)
    finally:
        shutil.rmtree(TMP, ignore_errors=True)
