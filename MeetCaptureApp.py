#!/usr/bin/env python3
"""
MeetCapture — macOS menu bar app using native AppKit (PyObjC).
Works with macOS 26+ (Tahoe) scene-based architecture.
"""

import objc
from AppKit import (
    NSApplication, NSStatusBar, NSMenu, NSMenuItem,
    NSImage, NSVariableStatusItemLength, NSOnState,
    NSOffState, NSObject, NSApp, NSRunLoop, NSDate,
    NSWorkspace, NSAlert, NSAlertFirstButtonReturn,
    NSTextField, NSMakeRect, NSBezelStyleRounded,
    NSWindowStyleMaskTitled, NSWindowStyleMaskClosable,
    NSApplicationActivationPolicyAccessory,
    NSAlertStyleInformational, NSAlertStyleWarning,
    NSOpenPanel, NSColor,
)
from Foundation import NSTimer, NSBundle, NSString
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
DAEMON_SCRIPT = None


def _resolve_daemon():
    global DAEMON_SCRIPT
    candidates = [
        Path(__file__).parent / "meet-daemon.py",
        MEETINGS_DIR / "meet-daemon.py",
    ]
    for c in candidates:
        if c.exists():
            DAEMON_SCRIPT = c
            return
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


def read_pid() -> int:
    try:
        return int(DAEMON_PID_FILE.read_text().strip())
    except Exception:
        return 0


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


# ── App Delegate ─────────────────────────────────────────────────────────────

class MeetCaptureDelegate(NSObject):
    status_bar = None
    status_item = None
    menu = None
    daemon_proc = None
    cfg = None
    title_item = None
    meeting_item = None
    start_item = None
    stop_item = None

    def applicationDidFinishLaunching_(self, notification):
        self.cfg = load_config()
        _resolve_daemon()

        # Set as accessory app (no dock icon)
        NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

        # Create status bar item
        self.status_bar = NSStatusBar.systemStatusBar()
        self.status_item = self.status_bar.statusItemWithLength_(NSVariableStatusItemLength)

        # Set icon
        self._update_icon("idle")

        # Create menu
        self._build_menu()

        # Auto-start daemon
        if self.cfg.get("auto_start", True):
            self._start_daemon()

        # Start polling timer
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            3.0, self, "updateState:", None, True
        )

    def _build_menu(self):
        self.menu = NSMenu.alloc().init()

        # Status item (non-clickable, just info)
        self.title_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Initializing...", "", ""
        )
        self.title_item.setEnabled_(False)
        self.menu.addItem_(self.title_item)

        # Meeting item
        self.meeting_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "", "", ""
        )
        self.meeting_item.setEnabled_(False)
        self.menu.addItem_(self.meeting_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Start daemon
        self.start_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Start Daemon", "startDaemon:", ""
        )
        self.menu.addItem_(self.start_item)

        # Stop recording
        self.stop_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Stop Recording", "stopRecording:", ""
        )
        self.stop_item.setEnabled_(False)
        self.menu.addItem_(self.stop_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Open transcripts
        open_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Open Transcripts", "openTranscripts:", ""
        )
        self.menu.addItem_(open_item)

        # View log
        log_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "View Log", "viewLog:", ""
        )
        self.menu.addItem_(log_item)

        # Settings
        settings_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Settings...", "showSettings:", ""
        )
        self.menu.addItem_(settings_item)

        self.menu.addItem_(NSMenuItem.separatorItem())

        # Quit
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "Quit", "quitApp:", "q"
        )
        self.menu.addItem_(quit_item)

        self.status_item.setMenu_(self.menu)

    def _update_icon(self, state):
        """Update menu bar icon based on state."""
        # Use SF Symbols via text (works on macOS 11+)
        if state == "recording":
            # Red circle with dot
            self.status_item.setTitle_("◉")
            # Try to set red color
            try:
                attrs = {str("NSColor"): NSColor.systemRedColor()}
                self.status_item.button().setAttributedTitle_(
                    NSString.alloc().initWithString_("◉").size()
                )
            except Exception:
                pass
        elif state == "error":
            self.status_item.setTitle_("⚠")
        else:
            self.status_item.setTitle_("●")

    def updateState_(self, timer):
        """Poll daemon state every 3 seconds."""
        state = load_state()
        pid = read_pid()
        alive = (pid and pid_alive(pid)) or (self.daemon_proc and self.daemon_proc.poll() is None)

        recording = state.get("recording", False)
        meeting_title = state.get("title", "")

        if recording:
            self._update_icon("recording")
            self.title_item.setTitle_(f"● Recording")
            self.meeting_item.setTitle_(meeting_title or "Unknown meeting")
            self.stop_item.setEnabled_(True)
        elif alive:
            self._update_icon("idle")
            self.title_item.setTitle_("● Waiting for meeting")
            self.meeting_item.setTitle_("")
            self.stop_item.setEnabled_(False)
        else:
            self._update_icon("error")
            self.title_item.setTitle_("⚠ Daemon stopped")
            self.meeting_item.setTitle_("")
            self.stop_item.setEnabled_(False)

    def _start_daemon(self):
        pid = read_pid()
        if pid and pid_alive(pid):
            return

        python = find_python()
        cmd = [python, str(DAEMON_SCRIPT), "--daemon"]

        try:
            self.daemon_proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env={**os.environ, "PYTHONUNBUFFERED": "1",
                     "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"},
            )
            time.sleep(2)
        except Exception:
            pass

    def startDaemon_(self, sender):
        self._start_daemon()

    def stopRecording_(self, sender):
        python = find_python()
        try:
            subprocess.run([python, str(DAEMON_SCRIPT), "--stop"], timeout=10)
        except Exception:
            pass

    def openTranscripts_(self, sender):
        d = Path(self.cfg.get("transcript_dir", ""))
        if d.exists():
            subprocess.run(["open", str(d)])
        else:
            subprocess.run(["open", str(MEETINGS_DIR)])

    def viewLog_(self, sender):
        log_file = MEETINGS_DIR / ".daemon.log"
        if log_file.exists():
            subprocess.run(["open", "-a", "Console", str(log_file)])

    def showSettings_(self, sender):
        cfg = self.cfg

        # Create alert dialog
        alert = NSAlert.alloc().init()
        alert.setMessageText_("MeetCapture Settings")
        alert.setInformativeText_(
            f"Transcript directory:\n{cfg.get('transcript_dir', 'Not set')}\n\n"
            f"Auto-start: {'YES' if cfg.get('auto_start', True) else 'NO'}\n\n"
            f"Click 'Change Dir' to select a new transcript directory."
        )
        alert.addButtonWithTitle_("Change Dir")
        alert.addButtonWithTitle_("Toggle Auto-Start")
        alert.addButtonWithTitle_("Close")
        alert.setAlertStyle_(NSAlertStyleInformational)

        response = alert.runModal()

        if response == 1000:  # Change Dir
            panel = NSOpenPanel.alloc().init()
            panel.setCanChooseDirectories_(True)
            panel.setCanChooseFiles_(False)
            panel.setAllowsMultipleSelection_(False)
            panel.setMessage_("Select transcript directory")

            if panel.runModal() == 1:  # OK
                url = panel.URLs()[0]
                new_dir = url.path()
                cfg["transcript_dir"] = new_dir
                save_config(cfg)
                self.cfg = cfg

                # Show confirmation
                confirm = NSAlert.alloc().init()
                confirm.setMessageText_("Settings Saved")
                confirm.setInformativeText_(f"Transcripts → {new_dir}")
                confirm.runModal()

        elif response == 1001:  # Toggle Auto-Start
            cfg["auto_start"] = not cfg.get("auto_start", True)
            save_config(cfg)
            self.cfg = cfg

    def quitApp_(self, sender):
        # Stop daemon
        if self.daemon_proc and self.daemon_proc.poll() is None:
            self.daemon_proc.terminate()
        NSApp.terminate_(None)


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    MEETINGS_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)

    # Create NSApplication and set up as accessory app (no dock icon)
    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)

    # Create and set delegate
    delegate = MeetCaptureDelegate.alloc().init()
    app.setDelegate_(delegate)

    # Activate the app to connect to window server
    app.activateIgnoringOtherApps_(True)

    # Run the event loop
    app.run()


if __name__ == "__main__":
    main()
