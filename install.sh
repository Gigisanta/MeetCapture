#!/bin/bash
# Production-safe local installer for MeetCapture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MEETINGS="$HOME/meetings"
APP="$MEETINGS/MeetCapture.app"
BACKUP_DIR="$MEETINGS/.backups"
STAGE="$(mktemp -d /tmp/meetcapture-install.XXXXXX)"
NEW_APP="$MEETINGS/.MeetCapture.app.new.$$"
BACKUP=""

cleanup() {
  rm -rf "$STAGE" "$NEW_APP"
}
trap cleanup EXIT

rollback() {
  printf '%s\n' "Install verification failed — rolling back."
  pkill -x MeetCapture 2>/dev/null || true
  rm -rf "$APP"
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ]; then
    ditto "$BACKUP" "$APP"
    open "$APP"
    printf '%s\n' "Previous build restored from $BACKUP"
  fi
}

printf '%s\n' "== MeetCapture production installer =="
printf 'Repo: %s\nTarget: %s\n' "$ROOT" "$APP"

cd "$ROOT"
chmod +x build.sh scripts/app-smoke-test.sh
./build.sh --staging-dir "$STAGE"
codesign --verify --deep --strict "$STAGE/MeetCapture.app"
plutil -lint "$STAGE/MeetCapture.app/Contents/Info.plist" >/dev/null

mkdir -p "$MEETINGS" "$BACKUP_DIR"
chmod 700 "$MEETINGS" "$BACKUP_DIR"
if [ -d "$APP" ]; then
  BACKUP="$BACKUP_DIR/MeetCapture-$(date +%Y%m%d-%H%M%S)"
  ditto "$APP" "$BACKUP"
fi

pkill -x MeetCapture 2>/dev/null || true

# Remove the retired Python daemon before replacing the bundle. Its launch agent
# otherwise keeps executing deleted legacy code from the previous installation.
LEGACY_LABEL="com.maatwork.meetcapture.daemon"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
launchctl bootout "gui/$(id -u)/$LEGACY_LABEL" 2>/dev/null || true
rm -f "$LEGACY_PLIST" /tmp/meetcapture.sock
pkill -f '/MeetCapture.app/Contents/Resources/server.py' 2>/dev/null || true

for _ in {1..20}; do
  pgrep -x MeetCapture >/dev/null || break
  sleep 0.1
done

# Copy completely before replacing the live bundle.
ditto "$STAGE/MeetCapture.app" "$NEW_APP"
rm -rf "$APP"
mv "$NEW_APP" "$APP"

# Keep only the three newest verified backups.
if [ -d "$BACKUP_DIR" ]; then
  find "$BACKUP_DIR" -maxdepth 1 -type d -name 'MeetCapture-*' -print0 \
    | xargs -0 ls -dt 2>/dev/null \
    | tail -n +4 \
    | xargs -r rm -rf
fi

open "$APP"
for _ in {1..50}; do
  pgrep -x MeetCapture >/dev/null && break
  sleep 0.1
done

if ! scripts/app-smoke-test.sh; then
  rollback
  exit 1
fi

printf '%s\n' "MeetCapture v5.0.0 installed, launched, and verified."
