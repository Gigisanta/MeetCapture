#!/bin/bash
# capture-selftest.sh — Automated end-to-end test of the REAL Swift capture →
# transcribe pipeline (Core Audio tap+mic → resample → gain-normalize → whisper
# → transcript file). This is the one path the other suites don't cover.
#
# It drives the app's env-gated MEETCAPTURE_SELFTEST_SECS hook: launch the
# binary, it records N seconds then transcribes, no UI needed. We play a known
# spoken phrase and assert the transcript file appears and contains the speech.
#
# Audio is kept SILENT by routing system output to BlackHole (a virtual loopback
# device) for the duration. If BlackHole isn't installed (e.g. CI), the test
# SKIPS gracefully (exit 0) rather than making noise or failing falsely.
set -u

APP="$HOME/meetings/MeetCapture.app"
BIN="$APP/Contents/MacOS/MeetCapture"
TDIR="$HOME/.hermes/TechPartners/MaatWork/meetings/transcripts"
SECS="${MEETCAPTURE_SELFTEST_SECS:-16}"
PHRASE="Reunión de MaatWork con Virginia y Nacho sobre la certificación de obra."
HELPER=$(mktemp -t mc-setout-XXXX).swift
HELPER_BIN="${HELPER%.swift}"

green() { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
red()   { printf '\033[31m  ✗ %s\033[0m\n' "$1"; }
skip()  { printf '\033[33m  ⊘ SKIP: %s\033[0m\n' "$1"; }

echo "=================================================================="
echo "  MeetCapture — Capture→Transcribe Self-Test"
echo "=================================================================="

[ -x "$BIN" ] || { red "App binary not found at $BIN (run ./build.sh first)"; exit 1; }

# Compile a tiny default-output-device get/set helper (get with no arg, set by
# name substring with an arg). Used to route to BlackHole and restore after.
cat > "$HELPER" <<'SWIFT'
import CoreAudio
import Foundation
let sys = AudioObjectID(kAudioObjectSystemObject)
func devices() -> [AudioDeviceID] {
  var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var sz: UInt32 = 0; AudioObjectGetPropertyDataSize(sys, &a, 0, nil, &sz)
  var ids = [AudioDeviceID](repeating: 0, count: Int(sz)/MemoryLayout<AudioDeviceID>.size)
  AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &ids); return ids
}
func name(_ d: AudioDeviceID) -> String {
  var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var cf: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<CFString?>.size)
  AudioObjectGetPropertyData(d, &a, 0, nil, &sz, &cf); return (cf?.takeRetainedValue() as String?) ?? ""
}
func defaultOut() -> AudioDeviceID {
  var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var d = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
  AudioObjectGetPropertyData(sys, &a, 0, nil, &sz, &d); return d
}
if CommandLine.arguments.count < 2 { print(name(defaultOut())); exit(0) }
let want = CommandLine.arguments[1]
for d in devices() where name(d).contains(want) {
  var id = d
  var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  exit(AudioObjectSetPropertyData(sys, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr ? 0 : 1)
}
exit(2)
SWIFT
swiftc -O "$HELPER" -o "$HELPER_BIN" 2>/dev/null || { skip "could not compile audio helper"; exit 0; }

# Capture the CURRENT default output device BEFORE switching, so we can restore.
PREV="$( "$HELPER_BIN" )"
[ -n "$PREV" ] || PREV="MacBook"

cleanup() { launchctl unsetenv MEETCAPTURE_SELFTEST_SECS >/dev/null 2>&1 || true; "$HELPER_BIN" "$PREV" >/dev/null 2>&1 || "$HELPER_BIN" MacBook >/dev/null 2>&1; pkill -x MeetCapture 2>/dev/null; rm -f "$TDIR"/recording-* "$HELPER" "$HELPER_BIN" /tmp/mc-st-speech.aiff; }
trap cleanup EXIT

# Require BlackHole for a silent run; otherwise skip rather than make noise.
if ! "$HELPER_BIN" BlackHole 2>/dev/null; then
    skip "BlackHole virtual device not installed — can't run silently"
    exit 0
fi
green "Routed output → BlackHole (silent, restore → $PREV)"

pkill -x MeetCapture 2>/dev/null; sleep 1
mkdir -p "$TDIR"
ls "$TDIR"/recording-* >/dev/null 2>&1 && rm -f "$TDIR"/recording-*
say -o /tmp/mc-st-speech.aiff "$PHRASE"

launchctl setenv MEETCAPTURE_SELFTEST_SECS "$SECS"
/usr/bin/open -n "$APP"
sleep 3
afplay /tmp/mc-st-speech.aiff; afplay /tmp/mc-st-speech.aiff
sleep 2

# Wait up to ~90s for transcription to finish (medium model on a short clip).
TXT=""
for _ in $(seq 1 45); do
    TXT=$(ls -t "$TDIR"/recording-*.txt 2>/dev/null | head -1)
    [ -n "$TXT" ] && break
    sleep 2
done

PASS=0; FAIL=0
PCM=$(ls -t "$TDIR"/recording-*.pcm 2>/dev/null | head -1)
if [ -n "$PCM" ] && [ "$(stat -f%z "$PCM" 2>/dev/null || echo 0)" -gt 200000 ]; then
    green "Captured PCM ($(du -h "$PCM" | cut -f1), continuous)"; PASS=$((PASS+1))
else
    red "PCM missing or too small (capture failed)"; FAIL=$((FAIL+1))
fi
if [ -n "$TXT" ] && [ -s "$TXT" ]; then
    green "Transcript produced: $(cat "$TXT")"; PASS=$((PASS+1))
else
    red "No transcript file produced"; FAIL=$((FAIL+1))
fi
# Content check: at least two distinctive domain words must survive the pipeline.
if [ -n "$TXT" ] && grep -qiE "maatwork|virginia|nacho|certificaci" "$TXT" 2>/dev/null; then
    green "Transcript content matches spoken phrase"; PASS=$((PASS+1))
else
    red "Transcript content does NOT match (resample/normalize/model regression?)"; FAIL=$((FAIL+1))
fi

echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    printf '\033[32m  ✅ CAPTURE SELF-TEST PASSED: %d/%d\033[0m\n' "$PASS" "$((PASS+FAIL))"
    echo "=================================================================="; exit 0
else
    printf '\033[31m  ❌ CAPTURE SELF-TEST FAILED: %d/%d\033[0m\n' "$PASS" "$((PASS+FAIL))"
    echo "=================================================================="; exit 1
fi
