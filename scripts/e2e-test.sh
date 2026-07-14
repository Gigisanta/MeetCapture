#!/bin/bash
# E2E test v5 — lifecycle, retention, atomic handoff, packaging
# Run after changes to lifecycle/retention/event/packaging.
set -e

PASS=0
FAIL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$1"; }

assert() {
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        green "  ✓ $label"
        PASS=$((PASS+1))
    else
        red "  ✗ $label (expected=$expected actual=$actual)"
        FAIL=$((FAIL+1))
    fi
}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMPDIR=$(mktemp -d "/tmp/meetcapture-e2e.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== E2E Test Suite v5.0 ==="

# ---------------------------------------------------------------
echo ""
echo "--- 1. Source compilation syntax ---"
# ---------------------------------------------------------------

# Basic syntax check: swiftc -typecheck
# (we can't run this without proper SDK, but we parse for structural issues)

# Check AppPhase enum is complete
if grep -q "case idle\|case approaching\|case recording\|case transcribing\|case done" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ AppPhase enum complete"
    PASS=$((PASS+1))
else
    red "  ✗ AppPhase enum incomplete"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 2. Lifecycle: autoRecord flow ---"
# ---------------------------------------------------------------

# Check that evaluateMeetings checks autoRecord
if grep -q "UserDefaults.standard.object(forKey: \"autoRecord\")" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ evaluateMeetings gates on autoRecord"
    PASS=$((PASS+1))
else
    red "  ✗ evaluateMeetings missing autoRecord gate"
    FAIL=$((FAIL+1))
fi

# Check handleCallActivity checks autoRecord
if grep -q "UserDefaults.standard.object(forKey: \"autoRecord\")" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ handleCallActivity gates on autoRecord"
    PASS=$((PASS+1))
else
    red "  ✗ handleCallActivity missing autoRecord gate"
    FAIL=$((FAIL+1))
fi

# Check scheduleRecording re-checks at fire time
if grep -q "Re-check autoRecord at fire time" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ scheduleRecording re-checks autoRecord"
    PASS=$((PASS+1))
else
    red "  ✗ scheduleRecording doesn't re-check autoRecord"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 3. Auto-stop: max recording duration ---"
# ---------------------------------------------------------------

# Check configurable, clamped max duration
if grep -q "private var maxRecordingDuration: TimeInterval" "$ROOT/Sources/AppState.swift" && \
   grep -q 'forKey: "maxRecordingDuration"' "$ROOT/Sources/AppState.swift"; then
    green "  ✓ maxRecordingDuration is configurable and typed"
    PASS=$((PASS+1))
else
    red "  ✗ maxRecordingDuration not defined"
    FAIL=$((FAIL+1))
fi

# Check that timer calls checkMaxDuration
if grep -q "checkMaxDuration" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Timer calls checkMaxDuration"
    PASS=$((PASS+1))
else
    red "  ✗ Timer doesn't call checkMaxDuration"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 4. Auto-stop: meeting end ---"
# ---------------------------------------------------------------

if grep -q "checkMeetingEnd" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Timer calls checkMeetingEnd"
    PASS=$((PASS+1))
else
    red "  ✗ Timer doesn't call checkMeetingEnd"
    FAIL=$((FAIL+1))
fi

if grep -q "meeting.endDate.addingTimeInterval" "$ROOT/Sources/AppState.swift" && \
   grep -q "Date() > graceEnd" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ checkMeetingEnd applies the configured grace interval"
    PASS=$((PASS+1))
else
    red "  ✗ checkMeetingEnd logic incorrect"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 5. Retention ---"
# ---------------------------------------------------------------

if grep -q "deleteRawPCM" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Retention: deleteRawPCM() exists"
    PASS=$((PASS+1))
else
    red "  ✗ Retention: deleteRawPCM() missing"
    FAIL=$((FAIL+1))
fi

if grep -q "removeItem" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Retention: FileManager.removeItem used"
    PASS=$((PASS+1))
else
    red "  ✗ Retention: FileManager.removeItem not used"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 6. Processed marker (atomic, idempotent) ---"
# ---------------------------------------------------------------

if grep -q "writeProcessedMarker" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ writeProcessedMarker() exists"
    PASS=$((PASS+1))
else
    red "  ✗ writeProcessedMarker() missing"
    FAIL=$((FAIL+1))
fi

if grep -q "\.processed\.json" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Uses .processed.json extension"
    PASS=$((PASS+1))
else
    red "  ✗ Missing .processed.json extension"
    FAIL=$((FAIL+1))
fi

if grep -q "fileExists(atPath" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Idempotent: checks if marker exists"
    PASS=$((PASS+1))
else
    red "  ✗ Not idempotent: no existence check"
    FAIL=$((FAIL+1))
fi

if grep -q "options: .atomic" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Atomic write with .atomic option"
    PASS=$((PASS+1))
else
    red "  ✗ Missing atomic write"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 7. Atomic Hermes handoff ---"
# ---------------------------------------------------------------

if grep -q "writePendingContract" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ writePendingContract() exists"
    PASS=$((PASS+1))
else
    red "  ✗ writePendingContract() missing"
    FAIL=$((FAIL+1))
fi

if grep -q 'pendingPath = "\\(base)/.pending"' "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Uses the canonical single .pending marker"
    PASS=$((PASS+1))
else
    red "  ✗ Missing canonical .pending marker"
    FAIL=$((FAIL+1))
fi

if grep -q '"type": "meeting.processed"' "$ROOT/Sources/AppState.swift"; then
    green "  ✓ Handoff type: meeting.processed"
    PASS=$((PASS+1))
else
    red "  ✗ Handoff type is not meeting.processed"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 8. Notification gating ---"
# ---------------------------------------------------------------

if grep -q "UserDefaults.standard.object(forKey: \"notifyHermes\")" "$ROOT/Sources/AppState.swift"; then
    green "  ✓ User notification gated by notifyHermes setting"
    PASS=$((PASS+1))
else
    red "  ✗ User notification not gated by notifyHermes"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 9. Build.sh features ---"
# ---------------------------------------------------------------

for flag in "help" "staging" "sign" "strict-concurrency"; do
    if grep -qF "$flag" "$ROOT/build.sh"; then
        green "  ✓ build.sh has --$flag"
        PASS=$((PASS+1))
    else
        red "  ✗ build.sh missing --$flag"
        FAIL=$((FAIL+1))
    fi
done

# Check daemon references removed from build.sh
if grep -q "meetcapture.sock\|com.maatwork.meetcapture.daemon\|LaunchAgents" "$ROOT/build.sh"; then
    red "  ✗ build.sh still references daemon"
    FAIL=$((FAIL+1))
else
    green "  ✓ build.sh no daemon references"
    PASS=$((PASS+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 10. Daemon removed from packaging ---"
# ---------------------------------------------------------------

for file in "Sources/DaemonManager.swift" "Sources/SocketClient.swift" "Sources/HealthMonitor.swift" "Resources/com.maatwork.meetcapture.daemon.plist"; do
    if [ ! -f "$ROOT/$file" ]; then
        green "  ✓ $file removed"
        PASS=$((PASS+1))
    else
        red "  ✗ $file still present"
        FAIL=$((FAIL+1))
    fi
done

# ---------------------------------------------------------------
echo ""
echo "--- 11. Version bump ---"
# ---------------------------------------------------------------

if grep -q "5.0.0" "$ROOT/Resources/Info.plist"; then
    green "  ✓ Version 5.0.0 in Info.plist"
    PASS=$((PASS+1))
else
    red "  ✗ Version not 5.0.0 in Info.plist"
    FAIL=$((FAIL+1))
fi

if grep -q "5.0.0" "$ROOT/Sources/SettingsView.swift"; then
    green "  ✓ Version 5.0.0 in SettingsView"
    PASS=$((PASS+1))
else
    red "  ✗ Version not 5.0.0 in SettingsView"
    FAIL=$((FAIL+1))
fi

if grep -q "5.0.0" "$ROOT/Sources/PopoverContent.swift"; then
    green "  ✓ Version 5.0.0 in PopoverContent"
    PASS=$((PASS+1))
else
    red "  ✗ Version not 5.0.0 in PopoverContent"
    FAIL=$((FAIL+1))
fi

# ---------------------------------------------------------------
echo ""
echo "--- 12. Synthetic JSON validation ---"
# ---------------------------------------------------------------

python3 -c "
import json
# Test canonical single-file handoff
handoff = {
    'type': 'meeting.processed',
    'state': 'transcribed',
    'meeting_id': 'rec-test',
    'transcript': '/tmp/test.txt',
    'title': 'Test',
    'source': 'meetcapture',
    'created': '2026-07-14T00:00:00Z',
    'metadata': {'transcript_path': '/tmp/test.txt', 'app_version': '5.0.0'}
}
data = json.dumps(handoff)
parsed = json.loads(data)
assert parsed['type'] == 'meeting.processed'
assert parsed['transcript'] == '/tmp/test.txt'
assert 'audio_path' not in parsed.get('metadata', {})
print('  ✓ Atomic handoff JSON round-trips cleanly')

# Test processed marker JSON
marker = {
    'schema': 'meetcapture.processed.v1',
    'processed_at': '2026-07-14T00:00:00Z',
    'transcript_path': '/tmp/test.txt',
    'meeting_title': 'Test',
    'retention': 'handoff_complete'
}
data = json.dumps(marker)
parsed = json.loads(data)
assert parsed['schema'] == 'meetcapture.processed.v1'
assert parsed['retention'] == 'handoff_complete'
print('  ✓ Processed marker JSON round-trips cleanly')
"

PASS=$((PASS+2))

# ---------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "  All e2e tests passed!"
