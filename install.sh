#!/bin/bash
# MeetCapture local installer
# Builds, installs/updates ~/meetings/MeetCapture.app, launches the app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/meetings/MeetCapture.app"

printf '%s\n' "== MeetCapture installer =="
printf '%s\n' "Repo: $ROOT"
printf '%s\n' "Target app: $APP"

cd "$ROOT"
chmod +x ./build.sh
./build.sh "$APP"

printf '%s\n' "== Launching app =="
open "$APP"

printf '%s\n' "== App smoke test =="
if [ -x "$ROOT/scripts/app-smoke-test.sh" ]; then
  "$ROOT/scripts/app-smoke-test.sh"
fi

printf '%s\n' "MeetCapture installed and verified."
