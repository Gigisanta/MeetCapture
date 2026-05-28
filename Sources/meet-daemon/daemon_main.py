#!/usr/bin/env python3
"""
meet-daemon — MeetCapture v4 background daemon
Handles transcription via whisper.cpp and IPC via Unix socket.

This script is launched by SMAppService via the bundled LaunchAgent plist.
It MUST NOT daemonize itself — launchd manages the process lifecycle.
"""

import signal
import sys
import os
import json
import logging
import threading
from pathlib import Path

# Add the app bundle Resources to path
BUNDLE_DIR = Path(__file__).parent.parent
sys.path.insert(0, str(BUNDLE_DIR / "Resources"))

# Configure logging
LOG_DIR = Path.home() / "Library" / "Logs" / "MeetCapture"
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.FileHandler(LOG_DIR / "daemon.log"),
        logging.StreamHandler(sys.stdout),
    ]
)
logger = logging.getLogger("meet-daemon")

# Import socket server
from socket_server import SocketServer

class GracefulKiller:
    """Handle SIGTERM from launchd for clean shutdown."""
    should_exit = False

    def __init__(self):
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.should_exit = True


def main():
    """Main daemon entry point."""
    killer = GracefulKiller()

    logger.info("=== meet-daemon v4 starting ===")
    logger.info(f"  PID: {os.getpid()}")
    logger.info(f"  Transcripts → {Path.home() / '.hermes' / 'TechPartners' / 'MaatWork' / 'meetings' / 'transcripts'}")

    # Start socket server
    server = SocketServer()
    server_thread = threading.Thread(target=server.start, daemon=True)
    server_thread.start()
    logger.info("Socket server started on /tmp/meetcapture.sock")

    # Main loop — just wait for signals
    logger.info("Daemon ready, waiting for commands...")
    while not killer.should_exit:
        try:
            # Sleep in small increments so we respond to signals quickly
            signal.pause()
        except KeyboardInterrupt:
            break

    # Clean shutdown
    logger.info("Shutting down...")
    server.stop()
    logger.info("Daemon stopped cleanly")
    sys.exit(0)


if __name__ == "__main__":
    main()
