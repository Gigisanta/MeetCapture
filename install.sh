#!/bin/bash
# MeetCapture local installer
# Builds, installs/updates ~/meetings/MeetCapture.app, registers the socket daemon,
# launches the app, and runs safe smoke checks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/meetings/MeetCapture.app"
SOCKET="/tmp/meetcapture.sock"

printf '%s\n' "== MeetCapture installer =="
printf '%s\n' "Repo: $ROOT"
printf '%s\n' "Target app: $APP"

cd "$ROOT"
chmod +x ./build.sh
./build.sh "$APP"

printf '%s\n' "== Launching app =="
open "$APP"

printf '%s\n' "== Verifying daemon socket =="
for i in $(seq 1 30); do
  [ -S "$SOCKET" ] && break
  sleep 0.5
done
if [ ! -S "$SOCKET" ]; then
  printf '%s\n' "ERROR: $SOCKET did not appear. Last daemon log lines:" >&2
  tail -80 /tmp/meetcapture-daemon.log 2>/dev/null || true
  exit 1
fi

python3 - <<'PY'
import json, socket
for command in ("ping", "get_status", "health_check"):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect('/tmp/meetcapture.sock')
    s.sendall(json.dumps({'id': command, 'command': command, 'payload': {}}).encode() + b'\n')
    raw = b''
    while not raw.endswith(b'\n'):
        chunk = s.recv(8192)
        if not chunk:
            break
        raw += chunk
    s.close()
    resp = json.loads(raw.decode())
    if not resp.get('success'):
        raise SystemExit(f'{command} failed: {resp}')
    print(f'{command}: success=true')
PY

printf '%s\n' "== App smoke test =="
if [ -x "$ROOT/scripts/app-smoke-test.sh" ]; then
  "$ROOT/scripts/app-smoke-test.sh"
fi

printf '%s\n' "MeetCapture installed and verified."
