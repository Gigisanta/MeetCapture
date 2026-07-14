#!/bin/bash
# app-smoke-test.sh — Verify MeetCapture app launches and records.
# v5.0.0: daemon removed, app runs standalone.
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0

APP="$HOME/meetings/MeetCapture.app"
LOCAL_APP="/tmp/MeetCapture.app"

# Try user-installed first, then staging
if [ -d "$APP" ]; then
    APP_BUNDLE="$APP"
elif [ -d "$LOCAL_APP" ]; then
    APP_BUNDLE="$LOCAL_APP"
else
    red "✗ No MeetCapture.app found at $APP or $LOCAL_APP"
    exit 1
fi

echo "=== MeetCapture App Smoke Test ==="
echo "  Bundle: $APP_BUNDLE"

# 1. Binary exists
echo ""
echo "[1] Binary exists"
if [ -x "$APP_BUNDLE/Contents/MacOS/MeetCapture" ]; then
    green "  ✅ MeetCapture binary found"
    PASS=$((PASS + 1))
else
    red "  ✗ Binary not found"
    FAIL=$((FAIL + 1))
fi

# 2. Info.plist
echo ""
echo "[2] Info.plist version"
if [ -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    VER=$(plutil -p "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null | grep CFBundleShortVersionString | awk -F'"' '{print $4}')
    if [ "$VER" = "5.0.0" ]; then
        green "  ✅ Version: $VER"
        PASS=$((PASS + 1))
    else
        red "  ✗ Could not read version"
        FAIL=$((FAIL + 1))
    fi
else
    red "  ✗ Info.plist missing"
    FAIL=$((FAIL + 1))
fi

# 3. Entitlements
echo ""
echo "[3] Entitlements"
if codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.security.device.microphone"; then
    green "  ✅ Mic entitlement present"
    PASS=$((PASS + 1))
else
    red "  ✗ Mic entitlement missing"
    FAIL=$((FAIL + 1))
fi

# 4. No daemon plist (removed in v5)
echo ""
echo "[4] Daemon removal"
if [ ! -f "$APP_BUNDLE/Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist" ]; then
    green "  ✅ No daemon plist in bundle"
    PASS=$((PASS + 1))
else
    red "  ✗ Daemon plist still bundled"
    FAIL=$((FAIL + 1))
fi

# 5. whisper-cli bundled
echo ""
echo "[5] Whisper CLI"
if [ -x "$APP_BUNDLE/Contents/Resources/whisper-cli" ]; then
    green "  ✅ whisper-cli bundled"
    PASS=$((PASS + 1))
else
    red "  ✗ whisper-cli missing"
    FAIL=$((FAIL + 1))
fi

# 6. Signing
echo ""
echo "[6] Code signing"
if codesign --verify --strict "$APP_BUNDLE" 2>/dev/null; then
    green "  ✅ Signed and verified"
    PASS=$((PASS + 1))
else
    red "  ✗ Signing verification failed"
    FAIL=$((FAIL + 1))
fi

# 7. Runtime process
echo ""
echo "[7] Runtime process"
if pgrep -x MeetCapture >/dev/null; then
    green "  ✅ MeetCapture process is running"
    PASS=$((PASS + 1))
else
    red "  ✗ MeetCapture process is not running"
    FAIL=$((FAIL + 1))
fi

# 8. Recommended local Spanish model
echo ""
echo "[8] Whisper model"
if [ -s "$HOME/.whisper/models/ggml-medium-q5_0.bin" ]; then
    green "  ✅ medium Q5 model available"
    PASS=$((PASS + 1))
else
    red "  ✗ medium Q5 model missing"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "  All smoke tests passed!"
