#!/usr/bin/env python3
"""
meet-daemon — MeetCapture v4 background daemon
Handles transcription via whisper.cpp and IPC via Unix socket.

Merged: daemon_main.py + socket_server.py
Launched by SMAppService via the bundled LaunchAgent plist.
"""

import json
import os
import signal
import socket
import sys
import time
import uuid
import logging
import threading
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SOCKET_PATH = "/tmp/meetcapture.sock"
BUFFER_SIZE = 65536
BACKLOG = 5
RECV_TIMEOUT = 10.0
MAX_CMD_LENGTH = 1_048_576  # 1 MB safety limit

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Daemon State
# ---------------------------------------------------------------------------


class DaemonState:
    """Manages the daemon's internal state (recording status, etc.)."""

    def __init__(self) -> None:
        self._is_recording: bool = False
        self._recording_start: Optional[float] = None
        self._meeting_title: Optional[str] = None
        self._total_sessions: int = 0
        self._start_time: float = time.time()

    @property
    def is_recording(self) -> bool:
        return self._is_recording

    @property
    def recording_start_time(self) -> Optional[str]:
        if self._recording_start is not None:
            return time.strftime(
                "%Y-%m-%dT%H:%M:%S", time.localtime(self._recording_start)
            )
        return None

    @property
    def meeting_title(self) -> Optional[str]:
        return self._meeting_title

    @property
    def uptime(self) -> float:
        return time.time() - self._start_time

    def start_recording(self, meeting_title: Optional[str] = None) -> dict:
        if self._is_recording:
            return {"ok": False, "error": "Already recording", "meeting_title": self._meeting_title}
        self._is_recording = True
        self._recording_start = time.time()
        self._meeting_title = meeting_title or f"Recording {time.strftime('%Y-%m-%d %H:%M')}"
        self._total_sessions += 1
        logger.info("Recording started: %s", self._meeting_title)
        return {"ok": True, "meeting_title": self._meeting_title, "recording_start_time": self.recording_start_time}

    def stop_recording(self) -> dict:
        if not self._is_recording:
            return {"ok": False, "error": "Not currently recording"}
        title = self._meeting_title
        duration = time.time() - (self._recording_start or time.time())
        self._is_recording = False
        self._recording_start = None
        self._meeting_title = None
        logger.info("Recording stopped: %s (%.1fs)", title, duration)
        return {"ok": True, "meeting_title": title, "duration_seconds": round(duration, 1)}

    def get_status(self) -> dict:
        return {
            "is_recording": self._is_recording,
            "recording_start_time": self.recording_start_time,
            "meeting_title": self._meeting_title,
            "uptime": round(self.uptime, 1),
            "total_sessions": self._total_sessions,
            "pid": os.getpid(),
        }


# ---------------------------------------------------------------------------
# Command Dispatcher
# ---------------------------------------------------------------------------


def handle_command(command: str, payload: Optional[dict], state: DaemonState) -> dict:
    handlers = {
        "start_recording": lambda p, s: s.start_recording(meeting_title=p.get("meeting_title")),
        "stop_recording": lambda _p, s: s.stop_recording(),
        "get_status": lambda _p, s: s.get_status(),
        "ping": lambda _p, _s: {"ok": True, "pong": True, "timestamp": time.time()},
    }
    handler = handlers.get(command)
    if handler is None:
        return {"ok": False, "error": f"Unknown command: {command}"}
    try:
        return handler(payload or {}, state)
    except Exception as exc:
        logger.exception("Error handling command '%s'", command)
        return {"ok": False, "error": f"Internal error: {exc}"}


# ---------------------------------------------------------------------------
# Socket Server
# ---------------------------------------------------------------------------


class SocketServer:
    """Unix Domain Socket server for MeetCapture IPC."""

    def __init__(self, socket_path: str = SOCKET_PATH) -> None:
        self.socket_path = socket_path
        self.state = DaemonState()
        self._server_socket: Optional[socket.socket] = None
        self._running = False

    def start(self) -> None:
        self._remove_stale_socket()
        self._bind_and_listen()
        self._running = True
        logger.info("Server listening on %s (pid=%d)", self.socket_path, os.getpid())
        self._accept_loop()

    def stop(self) -> None:
        logger.info("Shutting down server...")
        self._running = False
        if self._server_socket:
            try:
                self._server_socket.close()
            except OSError:
                pass
            self._server_socket = None
        self._remove_stale_socket()
        logger.info("Server stopped.")

    def _remove_stale_socket(self) -> None:
        if os.path.exists(self.socket_path):
            try:
                os.unlink(self.socket_path)
            except OSError as exc:
                logger.warning("Could not remove stale socket: %s", exc)

    def _bind_and_listen(self) -> None:
        self._server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self._server_socket.bind(self.socket_path)
            self._server_socket.listen(BACKLOG)
            self._server_socket.settimeout(1.0)
        except OSError as exc:
            logger.error("Failed to bind/listen on %s: %s", self.socket_path, exc)
            self._cleanup_socket_file()
            raise
        try:
            os.chmod(self.socket_path, 0o600)
        except OSError:
            pass

    def _accept_loop(self) -> None:
        assert self._server_socket is not None
        while self._running:
            try:
                client_socket, _ = self._server_socket.accept()
            except socket.timeout:
                continue
            except OSError:
                if self._running:
                    logger.exception("Error accepting connection")
                break
            thread = threading.Thread(target=self._handle_client, args=(client_socket,), daemon=True, name="client-handler")
            thread.start()

    def _handle_client(self, client_socket: socket.socket) -> None:
        client_socket.settimeout(RECV_TIMEOUT)
        try:
            buffer = b""
            while self._running:
                try:
                    chunk = client_socket.recv(BUFFER_SIZE)
                except socket.timeout:
                    continue
                except ConnectionResetError:
                    break
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    if len(line) > MAX_CMD_LENGTH:
                        self._send_response(client_socket, {"id": "", "success": False, "error": "Command too large", "data": None})
                        continue
                    response = self._process_message(line)
                    self._send_response(client_socket, response)
        except Exception as exc:
            logger.exception("Client handler error: %s", exc)
        finally:
            try:
                client_socket.close()
            except OSError:
                pass

    def _process_message(self, raw: bytes) -> dict:
        try:
            request = json.loads(raw)
        except json.JSONDecodeError as exc:
            return {"id": "", "success": False, "error": f"Invalid JSON: {exc}", "data": None}
        command = request.get("command", "")
        request_id = request.get("id", str(uuid.uuid4()))
        payload = request.get("payload")
        if not isinstance(payload, dict):
            payload = {}
        data = handle_command(command, payload, self.state)
        is_ok = data.pop("ok", True)
        error_msg = data.pop("error", None)
        return {"id": request_id, "success": is_ok, "error": error_msg, "data": data if data else None}

    def _send_response(self, client_socket: socket.socket, response: dict) -> None:
        try:
            payload = json.dumps(response, separators=(",", ":")) + "\n"
            client_socket.sendall(payload.encode("utf-8"))
        except (BrokenPipeError, OSError):
            pass

    def _cleanup_socket_file(self) -> None:
        try:
            if os.path.exists(self.socket_path):
                os.unlink(self.socket_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Graceful Shutdown
# ---------------------------------------------------------------------------


class GracefulKiller:
    should_exit = False

    def __init__(self):
        signal.signal(signal.SIGTERM, self._handle)
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum, frame):
        logger.info(f"Received signal {signum}, shutting down...")
        self.should_exit = True


# ---------------------------------------------------------------------------
# Main Entry Point
# ---------------------------------------------------------------------------


def main():
    killer = GracefulKiller()
    logger.info("=== meet-daemon v4 starting ===")
    logger.info(f"  PID: {os.getpid()}")

    server = SocketServer()
    server_thread = threading.Thread(target=server.start, daemon=True)
    server_thread.start()

    logger.info("Daemon ready, waiting for commands...")
    while not killer.should_exit:
        try:
            signal.pause()
        except KeyboardInterrupt:
            break

    logger.info("Shutting down...")
    server.stop()
    logger.info("Daemon stopped cleanly")
    sys.exit(0)


if __name__ == "__main__":
    main()
