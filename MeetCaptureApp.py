#!/usr/bin/env python3
"""
MeetCapture — macOS menu bar app for Google Meet transcription.
Manages the meet-daemon, shows status, provides settings UI.
"""

import rumps
import subprocess
import os
import sys
import json
import threading
import time
from pathlib import Path
from datetime import datetime

# ── Paths ────────────────────────────────────────────────────────────────────
HOME = Path.home()
MEETINGS_DIR = HOME / "meetings"
CONFIG_FILE = HOME / ".meetcapture.json"
STATE_FILE = MEETINGS_DIR / ".daemon_state.json"
DAEMON_PID_FILE = MEETINGS_DIR / ".daemon.pid"
DAEMON_SCRIPT = None  # resolved in _resolve_daemon


def _resolve_daemon():
    """Find meet-daemon.py: try Resources/ first, then ~/meetings/."""
    global DAEMON_SCRIPT
    candidates = [
        Path(__file__).parent / "meet-daemon.py",           # same dir (bundled)
        MEETINGS_DIR / "meet-daemon.py",                     # ~/meetings/
    ]
    for c in candidates:
        if c.exists():
            DAEMON_SCRIPT = c
            return
    # Default
    DAEMON_SCRIPT = MEETINGS_DIR / "meet-daemon.py"


def load_config() -> dict:
    defaults = {
        "transcript_dir": str(HOME / ".hermes" / "TechPartners" / "MaatWork" / "meetings" / "transcripts"),
        "auto_start": True,
    }
    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE) as f:
                user = json.load(f)
            defaults.update(user)
        except Exception:
            pass
    return defaults


def save_config(cfg: dict):
    tmp = CONFIG_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(cfg, indent=2))
    tmp.rename(CONFIG_FILE)


def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            pass
    return {"recording": False}


def find_python() -> str:
    """Find Python with rumps installed."""
    candidates = [
        str(HOME / "meetings" / ".app-venv" / "bin" / "python3"),
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]
    for p in candidates:
        if os.access(p, os.X_OK):
            return p
    return "python3"


# ── App ──────────────────────────────────────────────────────────────────────

class MeetCaptureApp(rumps.App):
    def __init__(self):
        super().__init__(name="MeetCapture", title="●", quit_button=None)
        _resolve_daemon()

        self._cfg = load_config()
        self._daemon_proc = None
        self._recording = False
        self._meeting_title = ""

        # Menu items
        self._status = rumps.MenuItem("Initializing...")
        self._meeting = rumps.MenuItem("")
        self._start_btn = rumps.MenuItem("Start Daemon", callback=self._on_start)
        self._stop_btn = rumps.MenuItem("Stop Recording", callback=self._on_stop)

        self.menu = [
            self._status,
            self._meeting,
            None,
            self._start_btn,
            self._stop_btn,
            None,
            rumps.MenuItem("Open Transcripts", callback=self._on_open),
            rumps.MenuItem("View Log", callback=self._on_log),
            rumps.MenuItem("Settings...", callback=self._on_settings),
            None,
            rumps.MenuItem("Quit", callback=self._on_quit),
        ]

        # Auto-start daemon
        if self._cfg.get("auto_start", True):
            self._start_daemon()

        # Poll state
        self._timer = rumps.Timer(self._update, 3)
        self._timer.start()

    def _start_daemon(self):
        """Start the daemon as a subprocess."""
        # Check if already running
        pid = self._read_pid()
        if pid and self._pid_alive(pid):
            return

        python = find_python()
        cmd = [python, str(DAEMON_SCRIPT), "--daemon"]

        try:
            self._daemon_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env={**os.environ, "PYTHONUNBUFFERED": "1",
                     "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"},
            )
            time.sleep(2)
        except Exception as e:
            rumps.notification("MeetCapture", "Error", str(e))

    def _read_pid(self) -> int:
        try:
            return int(DAEMON_PID_FILE.read_text().strip())
        except Exception:
            return 0

    def _pid_alive(self, pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def _update(self, _=None):
        """Poll daemon state."""
        state = load_state()
        pid = self._read_pid()
        alive = (pid and self._pid_alive(pid)) or (self._daemon_proc and self._daemon_proc.poll() is None)

        self._recording = state.get("recording", False)
        self._meeting_title = state.get("title", "")

        if self._recording:
            self.title = "◉"
            self._status.title = "● Recording"
            self._meeting.title = self._meeting_title
        elif alive:
            self.title = "●"
            self._status.title = "● Waiting for meeting"
            self._meeting.title = ""
        else:
            self.title = "⚠"
            self._status.title = "⚠ Daemon stopped"
            self._meeting.title = ""

    def _on_start(self, _):
        self._start_daemon()
        rumps.notification("MeetCapture", "", "Daemon started")

    def _on_stop(self, _):
        python = find_python()
        try:
            subprocess.run([python, str(DAEMON_SCRIPT), "--stop"], timeout=10)
            rumps.notification("MeetCapture", "", "Stopped. Transcribing...")
        except Exception as e:
            rumps.notification("MeetCapture", "Error", str(e))

    def _on_open(self, _):
        d = Path(self._cfg["transcript_dir"])
        d.mkdir(parents=True, exist_ok=True)
        subprocess.run(["open", str(d)])

    def _on_log(self, _):
        log_file = MEETINGS_DIR / ".daemon.log"
        if log_file.exists():
            subprocess.run(["open", "-a", "Console", str(log_file)])

    def _on_settings(self, _):
        cfg = self._cfg
        resp = rumps.Window(
            message="Transcript directory:",
            title="MeetCapture Settings",
            default_text=cfg.get("transcript_dir", ""),
            ok="Save",
            cancel="Cancel",
            dimensions=(400, 24),
        ).run()

        if resp.clicked and resp.text.strip():
            new_dir = resp.text.strip()
            Path(new_dir).mkdir(parents=True, exist_ok=True)
            cfg["transcript_dir"] = new_dir
            save_config(cfg)
            self._cfg = cfg
            rumps.notification("MeetCapture", "", f"Transcripts → {new_dir}")

    def _on_quit(self, _):
        # Don't kill daemon — let it keep running
        rumps.quit_application()


def main():
    MEETINGS_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    app = MeetCaptureApp()
    app.run()


if __name__ == "__main__":
    main()
