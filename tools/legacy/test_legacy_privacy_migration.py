#!/usr/bin/env python3
"""Tests for the safe MeetCapture legacy privacy migration helper."""

from __future__ import annotations

import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("meetcapture_legacy_migrate.py")
spec = importlib.util.spec_from_file_location("meetcapture_legacy_migrate", SCRIPT)
module = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(module)


class LegacyMigrationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "meetings"
        self.root.mkdir()
        (self.root / ".daemon_state.json").write_text('{"meet_link":"secret"}')
        (self.root / ".daemon.log").write_text("private title")
        (self.root / "meet-daemon.py").write_text("print('legacy')")
        (self.root / "recordings").mkdir()
        (self.root / "recordings" / "meeting.wav").write_bytes(b"audio")
        for path in self.root.rglob("*"):
            os.chmod(path, 0o755 if path.is_dir() else 0o644)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_plan_excludes_audio_by_default(self) -> None:
        plan = module.build_plan(self.root, include_audio=False)
        names = {item.source.name for item in plan}
        self.assertIn(".daemon_state.json", names)
        self.assertIn("meet-daemon.py", names)
        self.assertNotIn("meeting.wav", names)

    def test_harden_sets_private_modes(self) -> None:
        module.harden(self.root)
        self.assertEqual(self.root.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.root / ".daemon_state.json").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / ".daemon.log").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.root / "recordings").stat().st_mode & 0o777, 0o700)

    def test_archive_moves_only_planned_files_and_keeps_permissions_private(self) -> None:
        destination = Path(self.tmp.name) / "archive"
        plan = module.build_plan(self.root, include_audio=False)
        moved = module.archive(plan, self.root, destination)
        self.assertTrue((destination / ".daemon_state.json").exists())
        self.assertTrue((destination / "meet-daemon.py").exists())
        self.assertTrue((self.root / "recordings" / "meeting.wav").exists())
        self.assertEqual(destination.stat().st_mode & 0o777, 0o700)
        self.assertTrue(moved)

    def test_archive_refuses_existing_destination_content(self) -> None:
        destination = Path(self.tmp.name) / "archive"
        destination.mkdir()
        (destination / "sentinel").write_text("keep")
        with self.assertRaises(module.MigrationError):
            module.archive(module.build_plan(self.root, False), self.root, destination)


if __name__ == "__main__":
    unittest.main()
