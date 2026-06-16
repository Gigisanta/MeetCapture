#!/bin/bash
# E2E test v2: comprehensive user pipeline test with edge cases.
# Run after any change to daemon or app.
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

send() {
    echo "$1" | nc -U /tmp/meetcapture.sock -w "$2" 2>/dev/null
}

# Wait for daemon to be ready (up to 10s)
wait_for_daemon() {
    for i in $(seq 1 30); do
        if [ -S /tmp/meetcapture.sock ]; then
            if send '{"command":"ping"}' 1 2>/dev/null | grep -q '"pong":true'; then
                return 0
            fi
        fi
        sleep 0.5
    done
    return 1
}

echo "=================================================================="
echo "  MeetCapture v4.2.0 — Comprehensive E2E Test (v2)"
echo "=================================================================="

# ============================================================
# Section 1: Daemon & Socket
# ============================================================
echo ""
echo "[1] Daemon & Socket"
DAEMON_PID=$(ps aux | grep "server\.py" | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$DAEMON_PID" ]; then
    green "  ✓ Daemon PID=$DAEMON_PID"
    PASS=$((PASS+1))
else
    red "  ✗ Daemon not running"
    FAIL=$((FAIL+1))
    yellow "  Starting daemon..."
    launchctl kickstart "gui/$(id -u)/com.maatwork.meetcapture.daemon" 2>/dev/null || true
    sleep 2
    DAEMON_PID=$(ps aux | grep "server\.py" | grep -v grep | awk '{print $2}' | head -1)
    if [ -z "$DAEMON_PID" ]; then
        red "  FATAL: cannot start daemon"
        exit 1
    fi
fi

# ============================================================
# Section 2: Public commands
# ============================================================
echo ""
echo "[2] Public commands respond"
for cmd in ping get_status health_check; do
    R=$(send "{\"command\":\"$cmd\"}" 2)
    if echo "$R" | grep -q '"success":true'; then
        green "  ✓ $cmd"
        PASS=$((PASS+1))
    else
        red "  ✗ $cmd: $R"
        FAIL=$((FAIL+1))
    fi
done

# ============================================================
# Section 3: Error handling
# ============================================================
echo ""
echo "[3] Error handling"

# Unknown command
R=$(send '{"command":"bogus_command"}' 2)
echo "$R" | grep -q '"error":"Unknown command' && {
    green "  ✓ Unknown command rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Unknown command: $R"; FAIL=$((FAIL+1)); }

# Empty command
R=$(send '{"command":""}' 2)
echo "$R" | grep -q '"success":false' && {
    green "  ✓ Empty command rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Empty command: $R"; FAIL=$((FAIL+1)); }

# Malformed JSON
R=$(send '{"command":' 2)
echo "$R" | grep -q '"Invalid JSON' && {
    green "  ✓ Malformed JSON rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Malformed JSON: $R"; FAIL=$((FAIL+1)); }

# Non-JSON
R=$(send 'this is not json' 2)
echo "$R" | grep -q '"Invalid JSON' && {
    green "  ✓ Non-JSON rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Non-JSON: $R"; FAIL=$((FAIL+1)); }

# DoS: huge payload
HUGE=$(python3 -c "print('A'*2000000)" 2>/dev/null || echo "")
if [ -n "$HUGE" ]; then
    R=$(send "{\"command\":\"ping\",\"payload\":{\"data\":\"$HUGE\"}}" 5)
    echo "$R" | grep -q '"Command too large"' && {
        green "  ✓ DoS (2MB payload) rejected"
        PASS=$((PASS+1))
    } || { red "  ✗ DoS not blocked: ${R:0:200}"; FAIL=$((FAIL+1)); }
fi

# ============================================================
# Section 4: transcribe_path edge cases
# ============================================================
echo ""
echo "[4] transcribe_path validation"

# Missing payload
R=$(send '{"command":"transcribe_path"}' 2)
echo "$R" | grep -q '"success":false' && {
    green "  ✓ Missing payload rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Missing payload: $R"; FAIL=$((FAIL+1)); }

# Empty audio_path
R=$(send '{"command":"transcribe_path","payload":{"audio_path":""}}' 2)
echo "$R" | grep -q '"audio_path missing from payload"' && {
    green "  ✓ Empty audio_path rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Empty audio_path: $R"; FAIL=$((FAIL+1)); }

# Nonexistent file
R=$(send '{"command":"transcribe_path","payload":{"audio_path":"/nonexistent.pcm","model":"base"}}' 2)
echo "$R" | grep -q '"audio_path not found' && {
    green "  ✓ Nonexistent file rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Nonexistent file: $R"; FAIL=$((FAIL+1)); }

# Directory (BUG #9)
mkdir -p /tmp/fake-audio-dir
R=$(send '{"command":"transcribe_path","payload":{"audio_path":"/tmp/fake-audio-dir","model":"base"}}' 2)
echo "$R" | grep -q 'is not a file' && {
    green "  ✓ Directory rejected (was BUG #9)"
    PASS=$((PASS+1))
} || { red "  ✗ Directory: $R"; FAIL=$((FAIL+1)); }
rmdir /tmp/fake-audio-dir

# Nonexistent model — needs a real audio file present (daemon validates the
# path arg before the model arg), so generate it here rather than relying on
# Section 5 having run first.
/opt/homebrew/bin/python3 - <<'PY' >/dev/null
import struct, math, wave
sr, dur, freq, amp = 16000, 1, 440, 16000
samples = [int(amp * 0.3 * math.sin(2*math.pi*freq*i/sr)) for i in range(sr*dur)]
with wave.open('/tmp/e2e-test.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b''.join(struct.pack('<h', s) for s in samples))
PY
R=$(send '{"command":"transcribe_path","payload":{"audio_path":"/tmp/e2e-test.wav","model":"huge-model"}}' 2)
echo "$R" | grep -q '"model not found' && {
    green "  ✓ Nonexistent model rejected"
    PASS=$((PASS+1))
} || { red "  ✗ Nonexistent model: $R"; FAIL=$((FAIL+1)); }

# ============================================================
# Section 5: Real transcription
# ============================================================
echo ""
echo "[5] Real transcription"

# Generate 5s test audio
/opt/homebrew/bin/python3 - <<'PY' >/dev/null
import struct, math, wave
sr, dur, freq, amp = 16000, 5, 440, 16000
samples = [int(amp * 0.3 * math.sin(2*math.pi*freq*i/sr)) for i in range(sr*dur)]
with wave.open('/tmp/e2e-test.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b''.join(struct.pack('<h', s) for s in samples))
PY
[ -f /tmp/e2e-test.wav ] && {
    green "  ✓ Test audio generated"
    PASS=$((PASS+1))
} || { red "  ✗ Test audio generation failed"; FAIL=$((FAIL+1)); }

# Transcribe
START=$(date +%s%N)
R=$(send '{"command":"transcribe_path","payload":{"audio_path":"/tmp/e2e-test.wav","model":"base","language":"en"}}' 30)
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
TEXT=$(echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('data') or {}).get('text',''))" 2>/dev/null)
if [ -n "$TEXT" ]; then
    green "  ✓ Transcribed in ${ELAPSED_MS}ms: \"$TEXT\""
    PASS=$((PASS+1))
else
    red "  ✗ Transcription failed: $R"
    FAIL=$((FAIL+1))
fi

# Transcribe 35s (multi-chunk equivalent for Swift streaming)
/opt/homebrew/bin/python3 - <<'PY' >/dev/null
import struct, math, wave
sr, dur, freq, amp = 16000, 35, 440, 16000
samples = [int(amp * 0.3 * math.sin(2*math.pi*freq*i/sr)) for i in range(sr*dur)]
with wave.open('/tmp/35s.wav', 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b''.join(struct.pack('<h', s) for s in samples))
PY
START=$(date +%s%N)
R=$(send '{"command":"transcribe_path","payload":{"audio_path":"/tmp/35s.wav","model":"base","language":"en"}}' 60)
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
TEXT=$(echo "$R" | python3 -c "import sys,json; d=json.load(sys.stdin); print((d.get('data') or {}).get('text',''))" 2>/dev/null)
if [ -n "$TEXT" ] && [ "$ELAPSED_MS" -lt 30000 ]; then
    green "  ✓ 35s audio transcribed in ${ELAPSED_MS}ms: \"${TEXT:0:60}...\""
    PASS=$((PASS+1))
else
    red "  ✗ 35s transcription failed or too slow (${ELAPSED_MS}ms): $R"
    FAIL=$((FAIL+1))
fi

# Transcribe with spaces in filename
cp /tmp/e2e-test.wav "/tmp/audio with spaces.wav"
R=$(send "{\"command\":\"transcribe_path\",\"payload\":{\"audio_path\":\"/tmp/audio with spaces.wav\",\"model\":\"base\"}}" 30)
echo "$R" | grep -q '"success":true' && {
    green "  ✓ Filename with spaces works"
    PASS=$((PASS+1))
} || { red "  ✗ Spaces in path: $R"; FAIL=$((FAIL+1)); }
rm -f "/tmp/audio with spaces.wav"

# ============================================================
# Section 6: Resilience
# ============================================================
echo ""
echo "[6] Resilience"

# Rapid-fire 50 pings
PASS_RAPID=0
for i in $(seq 1 50); do
    send '{"command":"ping"}' 1 | grep -q '"pong":true' && PASS_RAPID=$((PASS_RAPID+1))
done
[ "$PASS_RAPID" -eq 50 ] && {
    green "  ✓ 50 rapid pings (all 50 succeeded)"
    PASS=$((PASS+1))
} || {
    red "  ✗ Rapid pings: $PASS_RAPID/50"
    FAIL=$((FAIL+1))
}

# Daemon survives kill
DAEMON_OLD=$(ps aux | grep "server\.py" | grep -v grep | awk '{print $2}' | head -1)
kill -9 "$DAEMON_OLD" 2>/dev/null
sleep 5  # give launchd time to respawn
DAEMON_NEW=$(ps aux | grep "server\.py" | grep -v grep | awk '{print $2}' | head -1)
if [ -n "$DAEMON_NEW" ] && [ "$DAEMON_NEW" != "$DAEMON_OLD" ]; then
    green "  ✓ Daemon auto-restarted (was $DAEMON_OLD, now $DAEMON_NEW)"
    PASS=$((PASS+1))
    # Wait for new daemon to be ready
    sleep 3
    wait_for_daemon || {
        red "  ✗ New daemon not responsive"
        FAIL=$((FAIL+1))
    }
else
    red "  ✗ Daemon didn't restart (was $DAEMON_OLD, now $DAEMON_NEW)"
    FAIL=$((FAIL+1))
fi

# Post-restart ping works
R=$(send '{"command":"ping"}' 3)
echo "$R" | grep -q '"pong":true' && {
    green "  ✓ Ping works after restart"
    PASS=$((PASS+1))
} || { red "  ✗ Post-restart ping: $R"; FAIL=$((FAIL+1)); }

# Memory didn't bloat (was 22MB, should still be < 50MB)
R=$(send '{"command":"health_check"}' 2)
RSS=$(echo "$R" | python3 -c "import sys,json
try:
    d=json.load(sys.stdin)
    print((d.get('data') or {}).get('memory_rss_mb', 0))
except Exception:
    print(0)
" 2>/dev/null)
if [ -n "$RSS" ] && [ "$RSS" != "0" ] && [ "$(python3 -c "print(1 if float('$RSS') < 50 else 0)")" = "1" ]; then
    green "  ✓ Daemon RSS: ${RSS}MB (within budget)"
    PASS=$((PASS+1))
else
    red "  ✗ Daemon RSS too high: ${RSS}MB"
    FAIL=$((FAIL+1))
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "=================================================================="
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "  ✅ ALL TESTS PASSED: $PASS/$TOTAL"
else
    red "  ❌ TESTS FAILED: $FAIL/$TOTAL (passed=$PASS)"
fi
echo "=================================================================="
exit $FAIL
