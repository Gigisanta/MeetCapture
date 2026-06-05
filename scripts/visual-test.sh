#!/bin/bash
# Visual regression test: open the popover, screenshot, vision-analyze
# to confirm the UI is actually rendering as designed.
set -e

PASS=0; FAIL=0
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

echo "=================================================================="
echo "  MeetCapture Visual Regression Test"
echo "=================================================================="

# Make sure app is open
pkill -f "MeetCapture.app/Contents/MacOS" 2>/dev/null || true
sleep 2
open ~/meetings/MeetCapture.app
sleep 5
APP_PID=$(ps aux | grep "MeetCapture.app/Contents/MacOS" | grep -v grep | awk '{print $2}' | head -1)
if [ -z "$APP_PID" ]; then
    red "  ✗ App didn't start"
    exit 1
fi
green "  ✓ App running PID=$APP_PID"

# Open the popover
echo ""
echo "[1] Open popover"
osascript -e 'tell application "System Events" to tell process "MeetCapture" to click menu bar item 1 of menu bar 2' 2>&1 | head -1
sleep 2

# Take screenshot
echo ""
echo "[2] Screenshot popover"
SHOT=/tmp/visual-test-$(date +%s).png
screencapture -x -t png "$SHOT" 2>&1 | head -3
if [ ! -f "$SHOT" ]; then
    red "  ✗ Screenshot failed"
    exit 1
fi
green "  ✓ Screenshot saved: $SHOT"
echo "SHOT_PATH=$SHOT"

# Note: vision_analyze is a separate tool call from the test runner.
# The wrapper script outputs the path so the user/Hermes can analyze.
echo ""
echo "=================================================================="
green "  Visual capture complete. Path: $SHOT"
echo "  Run vision_analyze on it to confirm UI matches the design spec."
echo "=================================================================="
exit 0
