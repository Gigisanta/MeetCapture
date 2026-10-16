#!/bin/bash
# Transactional local installer for MeetCapture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
# lsof reports the physical executable path even when ~/meetings is reached
# through a symlink. Resolve the parent once so process identity is stable.
mkdir -p "$HOME/meetings"
MEETINGS="$(cd "$HOME/meetings" && pwd -P)"
APP="$MEETINGS/MeetCapture.app"
APP_BUNDLE_ID="com.maatwork.meetcapture"
APP_EXECUTABLE="MeetCapture"
BACKUP_DIR="$MEETINGS/.backups"

STAGE=""
NEW_DIR=""
NEW_APP=""
ROLLBACK_APP="$MEETINGS/.MeetCapture.rollback.$$"
BACKUP=""
BACKUP_TMP=""
ORIGINAL_APP_PRESENT=0
ROLLBACK_OWNED=0
SWAP_STARTED=0
COMMITTED=0
APP_PID=""

path_exists() {
  [ -e "$1" ] || [ -L "$1" ]
}

bundle_executable_path() {
  printf '%s/Contents/MacOS/%s\n' "$1" "$APP_EXECUTABLE"
}

verify_bundle() {
  local bundle="$1"
  local plist="$bundle/Contents/Info.plist"
  local executable
  local bundle_id
  local declared_executable

  if [ ! -d "$bundle" ]; then
    printf 'Invalid app bundle: missing directory: %s\n' "$bundle" >&2
    return 1
  fi
  executable="$(bundle_executable_path "$bundle")"
  if [ ! -x "$executable" ] || [ ! -f "$plist" ]; then
    printf 'Invalid app bundle: missing executable or Info.plist: %s\n' "$bundle" >&2
    return 1
  fi
  if ! plutil -lint "$plist" >/dev/null; then
    printf 'Invalid app bundle: malformed Info.plist: %s\n' "$bundle" >&2
    return 1
  fi
  if ! bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$plist" 2>/dev/null)" \
    || [ "$bundle_id" != "$APP_BUNDLE_ID" ]; then
    printf 'Invalid app bundle: unexpected bundle identifier: %s\n' "$bundle" >&2
    return 1
  fi
  if ! declared_executable="$(plutil -extract CFBundleExecutable raw -o - "$plist" 2>/dev/null)" \
    || [ "$declared_executable" != "$APP_EXECUTABLE" ]; then
    printf 'Invalid app bundle: unexpected executable: %s\n' "$bundle" >&2
    return 1
  fi
  if [ ! -s "$bundle/Contents/Resources/AppIcon.icns" ] \
    || ! sips -g format "$bundle/Contents/Resources/AppIcon.icns" 2>/dev/null | grep -q 'format: icns'; then
    printf 'Invalid app bundle: missing or invalid AppIcon.icns: %s\n' "$bundle" >&2
    return 1
  fi
  if ! codesign --verify --deep --strict "$bundle"; then
    printf 'Invalid app bundle: code signature verification failed: %s\n' "$bundle" >&2
    return 1
  fi
}

pid_is_bundle() {
  local pid="$1"
  local bundle="$2"
  local executable_path
  local lsof_output

  kill -0 "$pid" 2>/dev/null || return 1
  if ! lsof_output="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null)"; then
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  fi
  executable_path="$(printf '%s\n' "$lsof_output" | sed -n '/^n/{s/^n//;p;q;}')"
  if [ -z "$executable_path" ]; then
    kill -0 "$pid" 2>/dev/null && return 2
    return 1
  fi
  [ "$executable_path" = "$(bundle_executable_path "$bundle")" ]
}

bundle_pids() {
  local bundle="$1"
  local candidates
  local pid
  local status

  # pgrep only supplies candidate PIDs. The executable path from lsof is the
  # identity check; a same-name process from another bundle cannot match.
  if candidates="$(pgrep -x "$APP_EXECUTABLE" 2>/dev/null)"; then
    :
  else
    status=$?
    [ "$status" -eq 1 ] && return 0
    return "$status"
  fi
  for pid in $candidates; do
    if pid_is_bundle "$pid" "$bundle"; then
      printf '%s\n' "$pid"
    else
      status=$?
      [ "$status" -eq 1 ] || return "$status"
    fi
  done
}

report_running_bundle() {
  local pids="$1"
  printf 'Cannot update while the installed MeetCapture bundle is running (PID(s)):\n%s\n' "$pids" >&2
  printf '%s\n' 'Quit MeetCapture manually, confirm any recording has finished, and rerun the installer. It did not stop the process.' >&2
}

assert_bundle_stopped() {
  local bundle="$1"
  local pids

  if ! pids="$(bundle_pids "$bundle")"; then
    printf 'Cannot safely inspect MeetCapture processes for %s; refusing to replace the app.\n' "$bundle" >&2
    return 1
  fi
  if [ -n "$pids" ]; then
    report_running_bundle "$pids"
    return 1
  fi
}

rollback() {
  local failed_app="$NEW_DIR/failed.app"
  local running_pids

  [ "$SWAP_STARTED" -eq 1 ] || return 0
  printf '%s\n' 'Install verification failed — restoring the previous app.' >&2

  if ! running_pids="$(bundle_pids "$APP")"; then
    printf 'Cannot confirm that the candidate app has stopped; preserving it at %s and recovery data at %s.\n' "$APP" "$ROLLBACK_APP" >&2
    return 1
  fi
  if [ -n "$running_pids" ]; then
    printf 'Candidate app PID(s) %s are still running; preserving the bundle and recovery data.\n' "$running_pids" >&2
    return 1
  fi

  if path_exists "$APP"; then
    if path_exists "$ROLLBACK_APP" || [ "$ORIGINAL_APP_PRESENT" -eq 0 ]; then
      if ! mv "$APP" "$failed_app"; then
        printf 'Could not move failed app aside; recovery files remain in %s\n' "$APP" >&2
        return 1
      fi
    fi
  fi

  if [ "$ROLLBACK_OWNED" -eq 1 ] && path_exists "$ROLLBACK_APP"; then
    if path_exists "$APP" || ! mv "$ROLLBACK_APP" "$APP"; then
      printf 'Could not restore the previous app; recovery copy remains at %s\n' "$ROLLBACK_APP" >&2
      return 1
    fi
  fi

  SWAP_STARTED=0
  return 0
}

cleanup() {
  local status=$?
  local rollback_ok=1
  trap - EXIT HUP INT TERM
  set +e

  if [ "$COMMITTED" -ne 1 ] && ! rollback; then
    rollback_ok=0
    status=1
  fi
  if [ -n "$STAGE" ]; then
    rm -rf "$STAGE" || status=1
  fi
  if [ -n "$BACKUP_TMP" ]; then
    rm -rf "$BACKUP_TMP" || status=1
  fi
  if [ "$rollback_ok" -eq 1 ] && [ -n "$NEW_DIR" ]; then
    rm -rf "$NEW_DIR" || status=1
  fi
  if [ "$COMMITTED" -eq 1 ] && [ "$ROLLBACK_OWNED" -eq 1 ] && path_exists "$ROLLBACK_APP"; then
    if ! rm -rf "$ROLLBACK_APP"; then
      printf 'Install succeeded; temporary old bundle remains at %s\n' "$ROLLBACK_APP" >&2
    fi
  fi
  if [ "$rollback_ok" -ne 1 ]; then
    printf 'Recovery data was preserved. Inspect %s and %s.\n' "$APP" "$ROLLBACK_APP" >&2
  fi
  exit "$status"
}

trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

printf '%s\n' '== MeetCapture local installer =='
printf 'Repo: %s\nTarget: %s\n' "$ROOT" "$APP"

if path_exists "$ROLLBACK_APP"; then
  printf 'Refusing to overwrite existing recovery bundle: %s\n' "$ROLLBACK_APP" >&2
  exit 1
fi

# Fail quickly when the installed app is already running; building can take a
# while, and no update work is useful until the user has closed that process.
if path_exists "$APP"; then
  if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    printf 'Refusing to replace a non-bundle target: %s\n' "$APP" >&2
    exit 1
  fi
  ORIGINAL_APP_PRESENT=1
  assert_bundle_stopped "$APP" || exit 1
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/meetcapture-install.XXXXXX")"
cd "$ROOT"
./build.sh --staging-dir "$STAGE"
verify_bundle "$STAGE/MeetCapture.app"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$STAGE/MeetCapture.app/Contents/Info.plist")"
if [ -z "$APP_VERSION" ]; then
  printf '%s\n' 'Invalid app bundle: missing version.' >&2
  exit 1
fi

mkdir -p "$MEETINGS"
if path_exists "$APP"; then
  if [ -L "$APP" ] || [ ! -d "$APP" ]; then
    printf 'Refusing to replace a non-bundle target: %s\n' "$APP" >&2
    exit 1
  fi
  ORIGINAL_APP_PRESENT=1
  assert_bundle_stopped "$APP" || exit 1
  mkdir -p "$BACKUP_DIR"
  # Zipped, so LaunchServices never registers old bundles under the same id.
  BACKUP="$BACKUP_DIR/MeetCapture-$(date +%Y%m%d-%H%M%S)-$$.app.zip"
  BACKUP_TMP="$BACKUP_DIR/.MeetCapture.backup.$$.zip"
  if path_exists "$BACKUP" || path_exists "$BACKUP_TMP" || path_exists "$ROLLBACK_APP"; then
    printf '%s\n' 'Refusing to overwrite an existing backup or recovery path.' >&2
    exit 1
  fi
  if ! ditto -c -k --keepParent "$APP" "$BACKUP_TMP"; then
    printf 'Could not create backup copy: %s\n' "$BACKUP" >&2
    rm -rf "$BACKUP_TMP"
    BACKUP_TMP=""
    exit 1
  fi
  if [ ! -s "$BACKUP_TMP" ] \
    || ! unzip -l "$BACKUP_TMP" 'MeetCapture.app/Contents/Info.plist' >/dev/null 2>&1; then
    printf 'Could not verify backup copy: %s\n' "$BACKUP" >&2
    rm -rf "$BACKUP_TMP"
    BACKUP_TMP=""
    exit 1
  fi
  mv "$BACKUP_TMP" "$BACKUP"
  BACKUP_TMP=""
fi

# Prepare and verify the complete replacement on the destination filesystem.
NEW_DIR="$(mktemp -d "$MEETINGS/.MeetCapture.install.XXXXXX")"
NEW_APP="$NEW_DIR/MeetCapture.app"
ditto "$STAGE/MeetCapture.app" "$NEW_APP"
verify_bundle "$NEW_APP"
if [ "$ORIGINAL_APP_PRESENT" -eq 1 ]; then
  # Catch an app launch that raced the initial preflight before the old bundle
  # is moved out of the way.
  assert_bundle_stopped "$APP" || exit 1
fi

# Keep the old bundle available for a rename-based rollback until LaunchServices
# starts and keeps the exact new executable alive.
if path_exists "$ROLLBACK_APP"; then
  printf 'Refusing to overwrite existing recovery bundle: %s\n' "$ROLLBACK_APP" >&2
  exit 1
fi
SWAP_STARTED=1
if [ "$ORIGINAL_APP_PRESENT" -eq 1 ]; then
  mv "$APP" "$ROLLBACK_APP"
  ROLLBACK_OWNED=1
  # If a process started in the short interval before the rename, restore the
  # old path and abort before the new bundle is installed.
  OLD_PATH_PIDS=""
  MOVED_PATH_PIDS=""
  if ! OLD_PATH_PIDS="$(bundle_pids "$APP")" || ! MOVED_PATH_PIDS="$(bundle_pids "$ROLLBACK_APP")"; then
    printf '%s\n' 'Cannot safely inspect MeetCapture after moving the old bundle; restoring it and aborting.' >&2
    mv "$ROLLBACK_APP" "$APP"
    SWAP_STARTED=0
    exit 1
  fi
  if [ -n "$OLD_PATH_PIDS$MOVED_PATH_PIDS" ]; then
    mv "$ROLLBACK_APP" "$APP"
    SWAP_STARTED=0
    report_running_bundle "${OLD_PATH_PIDS}${MOVED_PATH_PIDS:+$'\n'}${MOVED_PATH_PIDS}"
    exit 1
  fi
fi
mv "$NEW_APP" "$APP"
verify_bundle "$APP"

if ! open -n "$APP"; then
  printf '%s\n' 'LaunchServices could not open the installed app.' >&2
  exit 1
fi

APP_PID=""
for _ in {1..50}; do
  CANDIDATE_PIDS="$(bundle_pids "$APP")"
  for pid in $CANDIDATE_PIDS; do
    APP_PID="$pid"
    break
  done
  [ -n "$APP_PID" ] && break
  sleep 0.1
done

if [ -z "$APP_PID" ]; then
  printf '%s\n' 'LaunchServices did not leave a new MeetCapture PID for the installed bundle.' >&2
  exit 1
fi

# A PID that exits just after open is a failed launch, even if another
# same-name process remains on the host.
for _ in {1..20}; do
  sleep 0.1
  if ! pid_is_bundle "$APP_PID" "$APP"; then
    printf 'Installed MeetCapture PID %s exited during startup verification.\n' "$APP_PID" >&2
    exit 1
  fi
done

COMMITTED=1
printf 'MeetCapture v%s installed and running from the installed bundle (PID %s).\n' "$APP_VERSION" "$APP_PID"
