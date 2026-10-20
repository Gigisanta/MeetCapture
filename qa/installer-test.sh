#!/bin/bash
# Exercise install.sh against disposable HOME/build/system-command fixtures.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_SOURCE="$SCRIPT_DIR/../install.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/meetcapture-installer-test.XXXXXX")"
TEST_BIN="$TEST_ROOT/bin"
SPAWNED_PIDS=""
STATUS=0

cleanup_tests() {
  local log
  local pid
  for log in "$TEST_ROOT"/*/spawned.log; do
    [ -f "$log" ] || continue
    while IFS= read -r pid; do
      [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null || true
    done <"$log"
  done
  for pid in $SPAWNED_PIDS; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  rm -rf "$TEST_ROOT"
}
trap cleanup_tests EXIT HUP INT TERM

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [ -n "${OUTPUT_FILE:-}" ] && [ -f "$OUTPUT_FILE" ]; then
    tail -n 15 "$OUTPUT_FILE" >&2
  fi
  exit 1
}

make_bundle() {
  local bundle="$1"
  local marker="$2"
  mkdir -p "$bundle/Contents/MacOS"
  cat >"$bundle/Contents/Info.plist" <<'PLIST'
CFBundleIdentifier=com.maatwork.meetcapture
CFBundleExecutable=MeetCapture
CFBundleShortVersionString=6.3.0
PLIST
  printf '#!/bin/sh\nexit 0\n' >"$bundle/Contents/MacOS/MeetCapture"
  chmod +x "$bundle/Contents/MacOS/MeetCapture"
  printf '%s\n' "$marker" >"$bundle/Contents/version-marker"
}

start_fixture_process() {
  local process_dir="$1"
  local executable_path="$2"
  /bin/sleep 120 >/dev/null 2>&1 &
  local pid=$!
  SPAWNED_PIDS="$SPAWNED_PIDS $pid"
  printf '%s\n' "$executable_path" >"$process_dir/$pid.path"
  printf '%s\n' "$pid"
}

mkdir -p "$TEST_BIN"

# GNU find (also common on macOS through Homebrew) rejects BSD's -mtime -60s.
# Preserve the real filesystem predicate: never turn an inspection error into idle.
cat >"$TEST_BIN/find" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "$INSTALL_SCENARIO" = inspection-fails ]; then exit 2; fi
for arg in "$@"; do
  [ "$arg" != -60s ] || exit 2
done
exec /usr/bin/find "$@"
MOCK

cat >"$TEST_BIN/codesign" <<'MOCK'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = --verify ] || exit 2
for bundle in "$@"; do :; done
[ -d "$bundle" ] && [ ! -e "$bundle/Contents/signature-invalid" ]
MOCK

cat >"$TEST_BIN/plutil" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "${1:-}" = -lint ]; then
  plist="$2"
  [ -f "$plist" ] \
    && grep -q '^CFBundleIdentifier=' "$plist" \
    && grep -q '^CFBundleExecutable=' "$plist" \
    && grep -q '^CFBundleShortVersionString=' "$plist"
  exit $?
fi
if [ "${1:-}" = -extract ] && [ "${3:-}" = raw ] && [ "${4:-}" = -o ] && [ "${5:-}" = - ]; then
  key="$2"
  plist="$6"
  value="$(awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$plist")"
  [ -n "$value" ] || exit 1
  printf '%s\n' "$value"
  exit 0
fi
exit 2
MOCK

cat >"$TEST_BIN/ditto" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "$#" -eq 5 ] && [ "$1 $2 $3" = "-c -k --keepParent" ]; then
  # Backup archive: the real ditto zips the bundle.
  [ -e "$4" ] && [ ! -e "$5" ]
  /usr/bin/ditto -c -k --keepParent "$4" "$5"
  set -- "$4" "$5"
else
  [ "$#" -eq 2 ] && [ -e "$1" ] && [ ! -e "$2" ]
  /bin/cp -R "$1" "$2"
fi
if [ "$INSTALL_SCENARIO" = backup-fails ] \
  && [ "$1" = "$(cd "$HOME/meetings" && pwd -P)/MeetCapture.app" ]; then
  exit 7
fi
MOCK

cat >"$TEST_BIN/pgrep" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ "$#" -ne 2 ] || [ "$1" != -x ] || [ "$2" != MeetCapture ]; then
  printf 'unexpected pgrep invocation\n' >>"$COMMAND_LOG"
  exit 2
fi
for record in "$FIXTURE_PROCESS_DIR"/*.path; do
  [ -f "$record" ] || continue
  pid="${record##*/}"
  pid="${pid%.path}"
  if kill -0 "$pid" 2>/dev/null; then
    printf '%s\n' "$pid"
  else
    rm -f "$record"
  fi
done
MOCK

cat >"$TEST_BIN/lsof" <<'MOCK'
#!/bin/bash
set -euo pipefail
pid=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = -p ] && [ "$#" -gt 1 ]; then
    pid="$2"
    shift
  fi
  shift
done
[ -n "$pid" ] || exit 2
record="$FIXTURE_PROCESS_DIR/$pid.path"
[ -f "$record" ] && kill -0 "$pid" 2>/dev/null || exit 1
printf 'p%s\nftxt\nn%s\n' "$pid" "$(cat "$record")"
if [ "$INSTALL_SCENARIO" = many-mappings ]; then
  for ((index = 0; index < 2000; index++)); do
    printf 'ftxt\nn/system/library/mapping-%04d\n' "$index"
  done
fi
MOCK

cat >"$TEST_BIN/open" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"$OPEN_LOG"
[ "$#" -eq 2 ] && [ "$1" = -n ] || exit 2
case "$INSTALL_SCENARIO" in
  open-fails) exit 42 ;;
esac
/bin/sleep 120 >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" >>"$SPAWNED_LOG"
if [ "$INSTALL_SCENARIO" = homonym ]; then
  printf '%s\n' "$HOME/Other.app/Contents/MacOS/MeetCapture" >"$FIXTURE_PROCESS_DIR/$pid.path"
else
  printf '%s\n' "$2/Contents/MacOS/MeetCapture" >"$FIXTURE_PROCESS_DIR/$pid.path"
fi
if [ "$INSTALL_SCENARIO" = process-dies ]; then
  printf '%s\n' "$pid" >"$DIE_ON_SLEEP"
fi
MOCK

cat >"$TEST_BIN/sleep" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [ -f "$DIE_ON_SLEEP" ]; then
  pid="$(cat "$DIE_ON_SLEEP")"
  kill -TERM "$pid" 2>/dev/null || true
  rm -f "$DIE_ON_SLEEP" "$FIXTURE_PROCESS_DIR/$pid.path"
fi
exit 0
MOCK

for command_name in launchctl pkill killall git chmod; do
  cat >"$TEST_BIN/$command_name" <<'MOCK'
#!/bin/bash
printf '%s %s\n' "${0##*/}" "$*" >>"$COMMAND_LOG"
exit 91
MOCK
  chmod +x "$TEST_BIN/$command_name"
done

for command_name in codesign plutil ditto pgrep lsof open sleep find; do
  chmod +x "$TEST_BIN/$command_name"
done

setup_case() {
  CASE_NAME="$1"
  INSTALL_SCENARIO="$2"
  CASE_DIR="$TEST_ROOT/$CASE_NAME"
  REPO="$CASE_DIR/repo"
  HOME="$CASE_DIR/home"
  MEETINGS="$HOME/meetings"
  APP="$MEETINGS/MeetCapture.app"
  PROCESS_DIR="$CASE_DIR/processes"
  TMP_DIR="$CASE_DIR/tmp"
  OUTPUT_FILE="$CASE_DIR/install.out"
  OPEN_LOG="$CASE_DIR/open.log"
  BUILD_LOG="$CASE_DIR/build.log"
  SPAWNED_LOG="$CASE_DIR/spawned.log"
  COMMAND_LOG="$CASE_DIR/forbidden-commands.log"
  DIE_ON_SLEEP="$CASE_DIR/die-on-sleep"

  mkdir -p "$REPO/qa" "$HOME/Library/LaunchAgents" "$MEETINGS/Meeting A" \
    "$PROCESS_DIR" "$TMP_DIR" "$REPO/.git/refs/codex"
  MEETINGS="$(cd "$MEETINGS" && pwd -P)"
  APP="$MEETINGS/MeetCapture.app"
  cp "$INSTALL_SOURCE" "$REPO/install.sh"
  chmod +x "$REPO/install.sh"
  cat >"$REPO/build.sh" <<'BUILD'
#!/bin/bash
set -euo pipefail
printf 'build invoked\n' >>"$BUILD_LOG"
[ "$#" -eq 2 ] && [ "$1" = --staging-dir ] || exit 2
stage="$2/MeetCapture.app"
mkdir -p "$stage/Contents/MacOS"
cat >"$stage/Contents/Info.plist" <<'PLIST'
CFBundleIdentifier=com.maatwork.meetcapture
CFBundleExecutable=MeetCapture
CFBundleShortVersionString=6.3.0
PLIST
if [ "$INSTALL_SCENARIO" != invalid-bundle ]; then
  printf '#!/bin/sh\nexit 0\n' >"$stage/Contents/MacOS/MeetCapture"
  /bin/chmod +x "$stage/Contents/MacOS/MeetCapture"
fi
/bin/mkdir -p "$stage/Contents/Resources"
/bin/cp "$FIXTURE_ICON" "$stage/Contents/Resources/AppIcon.icns"
printf 'new\n' >"$stage/Contents/version-marker"
if [ "$INSTALL_SCENARIO" = recording-during-build ]; then
  mkdir -p "$HOME/meetings/transcripts"
  printf 'pcm\n' >"$HOME/meetings/transcripts/recording-late.pcm"
fi
BUILD
  chmod +x "$REPO/build.sh"

  make_bundle "$APP" old
  printf 'meeting data stays\n' >"$MEETINGS/Meeting A/recording.wav"
  printf 'agent sentinel\n' >"$HOME/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
  printf 'other agent stays\n' >"$HOME/Library/LaunchAgents/other-agent.plist"
  printf 'keep-this-ref\n' >"$REPO/.git/refs/codex/keep"
  : >"$OPEN_LOG"
  : >"$BUILD_LOG"
  : >"$SPAWNED_LOG"
  : >"$COMMAND_LOG"
}

run_installer() {
  if env \
    HOME="$HOME" \
    TMPDIR="$TMP_DIR" \
    PATH="$TEST_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    FIXTURE_PROCESS_DIR="$PROCESS_DIR" \
    INSTALL_SCENARIO="$INSTALL_SCENARIO" \
    OPEN_LOG="$OPEN_LOG" \
    BUILD_LOG="$BUILD_LOG" \
    SPAWNED_LOG="$SPAWNED_LOG" \
    COMMAND_LOG="$COMMAND_LOG" \
    DIE_ON_SLEEP="$DIE_ON_SLEEP" \
    FIXTURE_MEETINGS="$MEETINGS" \
    FIXTURE_CASE_DIR="$CASE_DIR" \
    FIXTURE_REPO="$REPO" \
    FIXTURE_ICON="$SCRIPT_DIR/../Resources/AppIcon.icns" \
    /bin/bash -c '
      if [ "$INSTALL_SCENARIO" = stale-rollback ]; then
        rollback_path="$FIXTURE_MEETINGS/.MeetCapture.rollback.$$"
        mkdir -p "$rollback_path"
        printf "previous recovery copy\n" >"$rollback_path/sentinel"
        printf "%s\n" "$rollback_path" >"$FIXTURE_CASE_DIR/collision-path"
      fi
      exec "$FIXTURE_REPO/install.sh"
    ' >"$OUTPUT_FILE" 2>&1; then
    STATUS=0
  else
    STATUS=$?
  fi
}

assert_preserved_state() {
  [ "$(cat "$MEETINGS/Meeting A/recording.wav")" = 'meeting data stays' ] \
    || fail "$CASE_NAME removed or changed meeting data"
  [ "$(cat "$HOME/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist")" = 'agent sentinel' ] \
    || fail "$CASE_NAME removed or changed the legacy agent file"
  [ "$(cat "$HOME/Library/LaunchAgents/other-agent.plist")" = 'other agent stays' ] \
    || fail "$CASE_NAME removed or changed another agent file"
  [ "$(cat "$REPO/.git/refs/codex/keep")" = 'keep-this-ref' ] \
    || fail "$CASE_NAME removed or changed a git ref"
  [ ! -s "$COMMAND_LOG" ] || fail "$CASE_NAME invoked a forbidden process/service/git command"
}

backup_marker() {
  unzip -p "$1" 'MeetCapture.app/Contents/version-marker' 2>/dev/null
}

assert_restored_old_app() {
  [ -d "$APP" ] || fail "$CASE_NAME did not restore the previous app directory"
  [ "$(cat "$APP/Contents/version-marker")" = old ] \
    || fail "$CASE_NAME left the replacement installed after failure"
  local backup
  for backup in "$MEETINGS"/.backups/MeetCapture-*.app.zip; do
    [ -f "$backup" ] || continue
    [ "$(backup_marker "$backup")" = old ] \
      || fail "$CASE_NAME did not retain a usable old-app backup"
    return 0
  done
  fail "$CASE_NAME did not retain the backup"
}

# Successful update must ignore a same-name process from another bundle.
setup_case positive success
HOMONYM_PID="$(start_fixture_process "$PROCESS_DIR" "$HOME/Other.app/Contents/MacOS/MeetCapture")"
run_installer
[ "$STATUS" -eq 0 ] || fail 'positive update unexpectedly failed'
NEW_PID="$(cat "$SPAWNED_LOG")"
[ "$NEW_PID" != "$HOMONYM_PID" ] || fail 'fixture did not create a distinct LaunchServices PID'
grep -F "PID $NEW_PID)." "$OUTPUT_FILE" >/dev/null \
  || fail 'installer did not verify the newly launched PID'
[ "$(cat "$APP/Contents/version-marker")" = new ] || fail 'new app was not installed'
kill -0 "$HOMONYM_PID" 2>/dev/null || fail 'installer terminated a same-name process from another bundle'
backup_count=0
for backup in "$MEETINGS"/.backups/MeetCapture-*.app.zip; do
  [ -f "$backup" ] || continue
  backup_count=$((backup_count + 1))
  [ "$(backup_marker "$backup")" = old ] || fail 'successful update backup is not the previous app'
done
[ "$backup_count" -eq 1 ] || fail 'successful update did not retain exactly one backup'
[ "$(cat "$OPEN_LOG")" = "-n $APP" ] || fail 'installer did not open the installed app through LaunchServices'
assert_preserved_state
printf 'PASS: successful update verifies the new installed PID and preserves backup/data/agents/refs\n'

setup_case many_mappings many-mappings
run_installer
[ "$STATUS" -eq 0 ] || fail 'installer rejected a valid app with many mapped libraries'
[ "$(cat "$APP/Contents/version-marker")" = new ] || fail 'many-mappings case did not install the new app'
assert_preserved_state
printf 'PASS: many mapped libraries do not break exact-PID verification\n'

setup_case old_process_close_failure close-fails
OLD_PID="$(start_fixture_process "$PROCESS_DIR" "$(printf '%s/Contents/MacOS/MeetCapture' "$APP")")"
run_installer
[ "$STATUS" -ne 0 ] \
  || fail "installer succeeded while old installed-app PID $OLD_PID remained alive"
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'active old process case changed the installed bundle'
[ ! -e "$MEETINGS/.backups" ] || fail 'active old process case created a backup before aborting'
[ ! -s "$OPEN_LOG" ] || fail 'active old process case opened a second app instance'
[ ! -s "$BUILD_LOG" ] || fail 'active old process case built a replacement before the preflight abort'
grep -F "$OLD_PID" "$OUTPUT_FILE" >/dev/null || fail 'active old process abort did not identify the blocking PID'
grep -F 'Quit MeetCapture manually' "$OUTPUT_FILE" >/dev/null || fail 'active old process abort gave no safe next step'
kill -0 "$OLD_PID" 2>/dev/null || fail 'installer stopped the active old app process'
assert_preserved_state
printf 'PASS: active old installed-app PID causes a pre-swap abort without closing it\n'

setup_case symlink_parent close-fails
mv "$MEETINGS" "$CASE_DIR/physical-meetings"
ln -s "$CASE_DIR/physical-meetings" "$HOME/meetings"
MEETINGS="$(cd "$HOME/meetings" && pwd -P)"
APP="$MEETINGS/MeetCapture.app"
OLD_PID="$(start_fixture_process "$PROCESS_DIR" "$APP/Contents/MacOS/MeetCapture")"
run_installer
[ "$STATUS" -ne 0 ] || fail 'installer replaced an active app reached through a parent symlink'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'symlink case changed the active old app'
[ ! -s "$BUILD_LOG" ] || fail 'symlink case started a build before rejecting the active process'
grep -F "$OLD_PID" "$OUTPUT_FILE" >/dev/null || fail 'symlink case did not identify the active PID'
kill -0 "$OLD_PID" 2>/dev/null || fail 'symlink case stopped the active process'
assert_preserved_state
printf 'PASS: parent symlink resolves to the physical executable before PID comparison\n'

setup_case stale_rollback stale-rollback
rm -rf "$APP"
run_installer
[ "$STATUS" -ne 0 ] || fail 'clean install overwrote an existing recovery bundle'
ROLLBACK_PATH="$(cat "$CASE_DIR/collision-path")"
[ "$(cat "$ROLLBACK_PATH/sentinel")" = 'previous recovery copy' ] \
  || fail 'clean install removed or changed the previous recovery bundle'
[ ! -s "$BUILD_LOG" ] || fail 'clean install started a build despite a recovery collision'
[ ! -e "$APP" ] || fail 'clean install wrote an app despite a recovery collision'
assert_preserved_state
printf 'PASS: clean install preserves a colliding recovery bundle\n'

setup_case open_failure open-fails
run_installer
[ "$STATUS" -ne 0 ] || fail 'open failure unexpectedly succeeded'
assert_restored_old_app
assert_preserved_state
printf 'PASS: LaunchServices open failure rolls back\n'

setup_case process_dies process-dies
run_installer
[ "$STATUS" -ne 0 ] || fail 'startup process death unexpectedly succeeded'
assert_restored_old_app
assert_preserved_state
printf 'PASS: exact installed PID dying during startup rolls back\n'

setup_case homonym homonym
run_installer
[ "$STATUS" -ne 0 ] || fail 'same-name process from another bundle was accepted'
assert_restored_old_app
HOMONYM_PID="$(cat "$SPAWNED_LOG")"
kill -0 "$HOMONYM_PID" 2>/dev/null || fail 'installer terminated a same-name process from another bundle'
assert_preserved_state
printf 'PASS: same-name process from another bundle does not satisfy launch verification\n'

setup_case invalid_bundle invalid-bundle
run_installer
[ "$STATUS" -ne 0 ] || fail 'invalid staged bundle unexpectedly succeeded'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'invalid bundle replaced the old app'
[ ! -e "$MEETINGS/.backups" ] || fail 'invalid bundle created a replacement backup before verification'
[ ! -s "$OPEN_LOG" ] || fail 'invalid bundle reached LaunchServices'
assert_preserved_state
printf 'PASS: invalid staged bundle leaves the existing app untouched\n'

setup_case backup_failure backup-fails
run_installer
[ "$STATUS" -ne 0 ] || fail 'backup copy failure unexpectedly succeeded'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'backup copy failure changed the installed app'
for backup in "$MEETINGS"/.backups/MeetCapture-*.app; do
  [ ! -e "$backup" ] || fail 'backup copy failure left a published partial backup'
done
for backup in "$MEETINGS"/.backups/.MeetCapture.backup.*; do
  [ ! -e "$backup" ] || fail 'backup copy failure left a partial backup staging directory'
done
[ ! -s "$OPEN_LOG" ] || fail 'backup copy failure reached LaunchServices'
assert_preserved_state
printf 'PASS: backup copy failure aborts before replacing the installed app\n'

setup_case growing_recording close-fails
mkdir -p "$MEETINGS/transcripts"
printf 'pcm\n' >"$MEETINGS/transcripts/recording-1.pcm"
run_installer
[ "$STATUS" -ne 0 ] || fail 'installer ran while a recording was being written'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'growing recording case changed the installed app'
[ ! -s "$BUILD_LOG" ] || fail 'growing recording case started a build'
grep -F 'refusing to install' "$OUTPUT_FILE" >/dev/null || fail 'growing recording abort gave no reason'
assert_preserved_state
printf 'PASS: a recording written in the last minute aborts before building\n'

setup_case late_recording recording-during-build
run_installer
[ "$STATUS" -ne 0 ] || fail 'installer replaced the app after a recording started during the build'
[ -s "$BUILD_LOG" ] || fail 'late recording case did not reach the build'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'late recording case replaced the installed bundle'
[ "$(cat "$MEETINGS/transcripts/recording-late.pcm")" = pcm ] || fail 'late recording case changed the recording'
[ ! -s "$OPEN_LOG" ] || fail 'late recording case opened the replacement'
assert_preserved_state
printf 'PASS: a recording started during the build prevents the swap\n'

setup_case failed_inspection inspection-fails
run_installer
[ "$STATUS" -ne 0 ] || fail 'installer treated a failed recording inspection as idle'
[ "$(cat "$APP/Contents/version-marker")" = old ] || fail 'failed inspection changed the installed bundle'
[ ! -s "$BUILD_LOG" ] || fail 'failed inspection did not abort before building'
assert_preserved_state
printf 'PASS: a failed recording inspection prevents installation\n'

printf '%s\n' 'All installer fixture cases passed.'
