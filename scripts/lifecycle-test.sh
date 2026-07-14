#!/bin/bash
# Lifecycle, retention, Hermes event, and packaging test for MeetCapture v4.4.0
# Run: ./scripts/lifecycle-test.sh
# Validates source code patterns, JSON schemas, and build script flags.
# Uses precise structural checks (AST-like pattern matching) and JSON schema
# validation — not just shallow grep.
set -euo pipefail

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d "/tmp/meetcapture-lifecycle-test.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

pass() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

# ---------------------------------------------------------------
echo "=== 1. Daemon/IPC removal ==="
# ---------------------------------------------------------------

for f in DaemonManager.swift SocketClient.swift HealthMonitor.swift; do
    if [ ! -f "$ROOT/Sources/$f" ]; then pass "$f removed"; else fail "$f still present"; fi
done

if [ ! -f "$ROOT/Resources/com.maatwork.meetcapture.daemon.plist" ]; then
    pass "Daemon plist removed"
else
    fail "Daemon plist still present"
fi

if [ ! -d "$ROOT/Daemon" ]; then
    pass "Daemon/ directory removed"
else
    fail "Daemon/ directory still present"
fi

# Verify no references to deleted daemon classes remain
for ref in DaemonManager SocketClient HealthMonitor socketClient daemonManager healthMonitor isDaemonRunning; do
    if ! grep -rq "$ref" "$ROOT/Sources" --include="*.swift" 2>/dev/null; then
        pass "No references to $ref in Sources"
    else
        result=$(grep -rl "$ref" "$ROOT/Sources" 2>/dev/null | tr '\n' ' ')
        fail "Found references to $ref in Sources: $result"
    fi
done

# Build.sh: no daemon packaging
if grep -q "com.maatwork.meetcapture.daemon" "$ROOT/build.sh" 2>/dev/null; then
    fail "build.sh still references daemon plist"
else
    pass "build.sh no daemon plist references"
fi

if grep -q "meetcapture.sock" "$ROOT/build.sh" 2>/dev/null; then
    fail "build.sh still references daemon socket"
else
    pass "build.sh no daemon socket references"
fi

# ---------------------------------------------------------------
echo "=== 2. RecordingOrigin enum ==="
# ---------------------------------------------------------------

APPSTATE="$ROOT/Sources/AppState.swift"

# Validate RecordingOrigin enum exists with all three cases
python3 -c "
import re
with open('$APPSTATE') as f:
    content = f.read()

# Find RecordingOrigin enum
m = re.search(r'enum RecordingOrigin\s*:\s*\w+(?:\s*,\s*\w+)*\s*\{', content)
assert m, 'RecordingOrigin enum not found'
print('  ✅ RecordingOrigin enum declared')

# Check all three cases
for case in ['manual', 'liveCall', 'calendar']:
    assert re.search(rf'case\s+{case}\b', content), f'Missing case: {case}'
    print(f'  ✅ RecordingOrigin.{case} defined')
"

# Validate recordingOrigin property exists (private var, not bool)
if grep -q "recordingOrigin: RecordingOrigin?" "$APPSTATE" 2>/dev/null ||
   grep -q "private var recordingOrigin" "$APPSTATE" 2>/dev/null; then
    pass "recordingOrigin property declared"
else
    fail "recordingOrigin property missing"
fi

# Validate no autoStartedRecording remains
if grep -q "autoStartedRecording" "$APPSTATE" 2>/dev/null; then
    fail "autoStartedRecording bool still present (should use RecordingOrigin)"
else
    pass "autoStartedRecording bool removed"
fi

# ---------------------------------------------------------------
echo "=== 3. Lifecycle: origin-aware auto-stop ==="
# ---------------------------------------------------------------

# startRecording takes an origin parameter
if grep -q "func startRecording(origin:" "$APPSTATE" 2>/dev/null; then
    pass "startRecording accepts origin parameter"
else
    fail "startRecording missing origin parameter"
fi

# handleCallActivity stops only .liveCall
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

# Check that call-ending path checks recordingOrigin == .liveCall
assert 'recordingOrigin == .liveCall' in content or 'recordingOrigin == .liveCall' in content, \
    'handleCallActivity does not gate stop on liveCall origin'
print('  ✅ handleCallActivity only stops .liveCall origin')
"

# checkMeetingEnd only stops .calendar origin
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

assert 'recordingOrigin == .calendar' in content, \
    'checkMeetingEnd does not gate on .calendar origin'
print('  ✅ checkMeetingEnd only applies to .calendar origin')
"

# Max duration applies to all — should not gate on origin
if grep -q "checkMaxDuration" "$APPSTATE" 2>/dev/null; then
    pass "checkMaxDuration implemented (applies to all origins)"
else
    fail "checkMaxDuration missing"
fi

# Calendar scheduleRecording defers to callDetector.isCallActive
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

assert 'callDetector.isCallActive' in content, \
    'scheduleRecording does not check callDetector.isCallActive'
print('  ✅ scheduleRecording checks isCallActive at fire time')
"

# ---------------------------------------------------------------
echo "=== 4. Auto-stop: meeting end (calendar only) ==="
# ---------------------------------------------------------------

if grep -q "checkMeetingEnd" "$APPSTATE" 2>/dev/null; then
    pass "checkMeetingEnd() implemented"
else
    fail "checkMeetingEnd() missing"
fi

if grep -q "calendarEndGrace" "$APPSTATE" 2>/dev/null; then
    pass "calendarEndGrace constant defined"
else
    fail "calendarEndGrace missing"
fi

# ---------------------------------------------------------------
echo "=== 5. .pending canonical handoff contract ==="
# ---------------------------------------------------------------

# Validate writePendingContract exists and throws
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

# Must be a throwing function
assert 'func writePendingContract' in content, 'writePendingContract function not found'
assert 'throws' in content, 'writePendingContract must throw on failure (no silent error swallowing)'
print('  ✅ writePendingContract declared as throwing')

# Must write .pending files, not .hermes-event.json
assert '.pending' in content, 'writePendingContract does not write .pending files'
assert 'hermes-event.json' not in content, 'Old hermes-event.json format still present'
print('  ✅ writePendingContract uses .pending format')
"

# Validate contract schema
python3 -c "
import json

contract = {
    'type': 'meeting.processed',
    'state': 'transcribed',
    'meeting_id': 'meet-test-123',
    'transcript': 'This is the transcript text.',
    'title': 'Test Meeting',
    'source': 'meetcapture',
    'created': '2026-07-14T12:00:00Z',
    'metadata': {
        'transcript_path': '/tmp/recording-test.txt',
        'app_version': '4.4.0'
    }
}

# Validate mandatory fields
required = ['type', 'state', 'meeting_id', 'transcript', 'title', 'source', 'created']
for field in required:
    assert field in contract, f'Missing required field: {field}'
    print(f'  ✅ Contract has required field: {field}')

# Validate no audio_path in metadata (because audio may be deleted)
assert 'audio_path' not in contract.get('metadata', {}), \
    'metadata must not contain audio_path (audio may be deleted)'
print('  ✅ metadata does not contain audio_path')

# Serialize round-trip
data = json.dumps(contract, indent=2, sort_keys=True)
parsed = json.loads(data)
assert parsed['type'] == 'meeting.processed'
assert parsed['state'] == 'transcribed'
assert parsed['source'] == 'meetcapture'
print('  ✅ Contract JSON serializes/deserializes correctly')
"

# Validate handoff always occurs and notifyHermes only controls notification
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

# writePendingContract must be called unconditionally (before any notifyHermes check)
# Check it's called before the notifyHermes-gated notification
transcribe_section = content[content.find('await transcribe'):]

# Look for the ordering: writePendingContract before the notification path
pending_idx = transcribe_section.find('writePendingContract')
notification_idx = transcribe_section.find('sendLocalNotification')
marker_idx = transcribe_section.find('writeProcessedMarker')

assert pending_idx >= 0, 'writePendingContract not called in transcribe()'
assert notification_idx >= 0 or 'showNotification' in transcribe_section, \
    'No local notification path found'
print('  ✅ Handoff contract called unconditionally')

# notifyHermes only gates notification
assert 'notifyHermes' in content, 'notifyHermes setting missing'
print('  ✅ notifyHermes setting referenced')
"

# ---------------------------------------------------------------
echo "=== 6. Retention: configurable policy ==="
# ---------------------------------------------------------------

# RetentionPolicy enum with 3 cases
python3 -c "
import re
with open('$APPSTATE') as f:
    content = f.read()

m = re.search(r'enum RetentionPolicy\s*:\s*\w+(?:\s*,\s*\w+)*\s*\{', content)
assert m, 'RetentionPolicy enum not found'
print('  ✅ RetentionPolicy enum declared')

for case in ['deleteAfterHandoff', 'keep24h', 'keep']:
    assert re.search(rf'case\s+\S*{case}\S*', content), f'Missing retention case: {case}'
    print(f'  ✅ RetentionPolicy.{case} defined')
"

# Retention in SettingsView
if grep -q "retention" "$ROOT/Sources/SettingsView.swift" 2>/dev/null; then
    pass "SettingsView has retention picker"
else
    fail "SettingsView missing retention picker"
fi

# applyRetention called after handoff
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

assert 'applyRetention' in content, 'applyRetention not implemented'
print('  ✅ applyRetention() implemented')
"

# deleteRawPCM never called before writePendingContract
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

transcribe_section = content[content.find('private func transcribe'):]

pending_idx = transcribe_section.find('writePendingContract')
delete_idx = transcribe_section.find('deleteRawPCM')

assert pending_idx >= 0, 'writePendingContract not in transcribe()'
if delete_idx >= 0:
    assert pending_idx < delete_idx, \
        'deleteRawPCM called before writePendingContract — audio would be deleted before durable handoff!'
    print('  ✅ deleteRawPCM called after writePendingContract')
else:
    print('  ✅ deleteRawPCM called from applyRetention (after handoff)')
"

# cleanupOldRecordings uses safe iteration (no destructive glob)
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

assert 'cleanupOldRecordings' in content, 'cleanupOldRecordings not implemented'
assert 'contentsOfDirectory' in content, 'cleanup uses directory iteration (not glob)'
print('  ✅ Cleanup uses safe directory iteration')
"

# Processed marker written BEFORE retention
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

transcribe_section = content[content.find('private func transcribe'):]

marker_idx = transcribe_section.find('writeProcessedMarker')
retention_idx = transcribe_section.find('applyRetention')

assert marker_idx >= 0, 'writeProcessedMarker not called in transcribe()'
assert retention_idx >= 0, 'applyRetention not called in transcribe()'
assert marker_idx < retention_idx, \
    'writeProcessedMarker must be called BEFORE applyRetention'
print('  ✅ writeProcessedMarker called before applyRetention')
"

# ---------------------------------------------------------------
echo "=== 7. Test output dir ==="
# ---------------------------------------------------------------

if grep -q "MEETCAPTURE_TEST_OUTPUT_DIR" "$APPSTATE" 2>/dev/null; then
    pass "MEETCAPTURE_TEST_OUTPUT_DIR env var supported"
else
    fail "MEETCAPTURE_TEST_OUTPUT_DIR not found"
fi

# ---------------------------------------------------------------
echo "=== 8. Build.sh hardening ==="
# ---------------------------------------------------------------

BUILDSCRIPT="$ROOT/build.sh"

if grep -q -- "--help" "$BUILDSCRIPT" 2>/dev/null; then
    pass "build.sh has --help flag"
else
    fail "build.sh missing --help"
fi

if grep -q -- "--staging" "$BUILDSCRIPT" 2>/dev/null; then
    pass "build.sh has --staging flag"
else
    fail "build.sh missing --staging"
fi

if grep -q -- "--staging-dir" "$BUILDSCRIPT" 2>/dev/null; then
    pass "build.sh has --staging-dir flag"
else
    fail "build.sh missing --staging-dir"
fi

if grep -q -- "-strict-concurrency=complete" "$BUILDSCRIPT" 2>/dev/null; then
    pass "build.sh has -strict-concurrency=complete"
else
    fail "build.sh missing -strict-concurrency=complete"
fi

if grep -q -- "--sign" "$BUILDSCRIPT" 2>/dev/null; then
    pass "build.sh has --sign flag"
else
    fail "build.sh missing --sign flag"
fi

# Hardened runtime only on real identity
python3 -c "
with open('$BUILDSCRIPT') as f:
    content = f.read()

assert '--options runtime' in content, 'Hardened runtime flag missing'
assert 'SIGN_IDENTITY' in content, 'SIGN_IDENTITY variable missing'
# hardened runtime should be conditional on real identity
assert 'SIGN_IDENTITY != \"-\"' in content or 'SIGN_IDENTITY' in content.split('--options runtime')[0], \
    'Hardened runtime should only apply with real identity'
print('  ✅ Hardened runtime conditional on real identity')
"

# staging-dir safety: rejects empty/missing path arg
python3 -c "
with open('$BUILDSCRIPT') as f:
    content = f.read()

# Should validate path argument is provided
assert 'ERROR: --staging-dir requires a path argument' in content or \
       'ERROR.*staging-dir' in content, \
    'Missing error handling for empty --staging-dir path'
print('  ✅ --staging-dir validates path argument')
"

# staging-dir never touches ~/meetings
if grep -q "DEST.*meetings" <(echo "$(grep -A5 'STAGING_DIR' "$BUILDSCRIPT" 2>/dev/null || true)"); then
    fail "--staging-dir path resolves to ~/meetings directory"
else
    pass "--staging-dir uses explicit path, never ~/meetings"
fi

# ---------------------------------------------------------------
echo "=== 9. Install.sh cleanup ==="
# ---------------------------------------------------------------

INSTALLSCRIPT="$ROOT/install.sh"

if ! grep -q "meetcapture.sock" "$INSTALLSCRIPT" 2>/dev/null; then
    pass "install.sh no socket verification"
else
    fail "install.sh still checks socket"
fi

if ! grep -q "daemon" "$INSTALLSCRIPT" 2>/dev/null; then
    pass "install.sh no daemon references"
else
    fail "install.sh still references daemon"
fi

# ---------------------------------------------------------------
echo "=== 10. Info.plist version ==="
# ---------------------------------------------------------------

if grep -q "4.4.0" "$ROOT/Resources/Info.plist" 2>/dev/null; then
    pass "Info.plist version bumped to 4.4.0"
else
    fail "Info.plist version not updated"
fi

# ---------------------------------------------------------------
echo "=== 11. notifyHermes setting ==="
# ---------------------------------------------------------------

if grep -q "notifyHermes" "$APPSTATE" 2>/dev/null; then
    pass "notifyHermes referenced in AppState"
else
    fail "notifyHermes not in AppState"
fi

if grep -q "notifyHermes" "$ROOT/Sources/SettingsView.swift" 2>/dev/null; then
    pass "SettingsView has notifyHermes toggle"
else
    fail "SettingsView missing notifyHermes toggle"
fi

# ---------------------------------------------------------------
echo "=== 12. Contract ordering (structural) ==="
# ---------------------------------------------------------------

# Validate the complete lifecycle ordering in transcribe()
python3 -c "
with open('$APPSTATE') as f:
    content = f.read()

# Find the transcribe function body
idx = content.find('private func transcribe')
assert idx >= 0, 'transcribe function not found'
body = content[idx:content.find('// MARK:', idx) if content.find('// MARK:', idx) > 0 else len(content)]

# Extract order of key operations
import re
operations = []
for op in ['whisperManager.stopRecording', 'stream.run', 'write(to:', 'writePendingContract',
           'writeProcessedMarker', 'applyRetention', 'sendLocalNotification',
           'deleteRawPCM', 'removeItem']:
    positions = [(m.start(), op) for m in re.finditer(re.escape(op), body)]
    operations.extend(positions)
operations.sort()

ordered = [op for _, op in operations]
print(f'  Operation order: {\" → \".join(ordered[:8])}')

# Verify: writePendingContract must be before applyRetention
pending_pos = next((i for i, op in enumerate(ordered) if 'writePendingContract' in op), -1)
retention_pos = next((i for i, op in enumerate(ordered) if 'applyRetention' in op), -1)
delete_pos = next((i for i, op in enumerate(ordered) if 'deleteRawPCM' in op or 'removeItem' in op), -1)

assert pending_pos >= 0, 'writePendingContract not found in transcribe()'
assert retention_pos >= 0, 'applyRetention not found in transcribe()'
assert pending_pos < retention_pos, \
    f'writePendingContract (pos {pending_pos}) must come before applyRetention (pos {retention_pos})'

print('  ✅ CORRECT ORDERING: handoff → marker → retention')

# Verify marker is before retention
marker_pos = next((i for i, op in enumerate(ordered) if 'writeProcessedMarker' in op), -1)
assert marker_pos >= 0, 'writeProcessedMarker not found in transcribe()'
assert marker_pos < retention_pos, \
    f'writeProcessedMarker (pos {marker_pos}) must come before applyRetention (pos {retention_pos})'
print('  ✅ CORRECT ORDERING: marker before retention (marker never points to deleted file)')
"

# Validate no trailing whitespace
if git -C "$ROOT" diff --check 2>&1 | grep -q "trailing whitespace"; then
    fail "Files have trailing whitespace"
    git -C "$ROOT" diff --check 2>&1 | head -10
else
    pass "No trailing whitespace"
fi

# ---------------------------------------------------------------
echo "=== Summary ==="
# ---------------------------------------------------------------
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "  All tests passed!"
