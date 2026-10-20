#!/bin/bash
# visual-test.sh: launch the app, open the popover and screenshot just that
# window. Prints SHOT_PATH=<png> for a human or vision check.
#   MEETCAPTURE_APP       bundle to launch (default ~/meetings/MeetCapture.app)
#   MEETCAPTURE_SHOT_DIR  where to write the PNG (default /tmp)
#   --headless            render the popover with synthetic data instead of
#                         driving the real menu bar (no Accessibility needed;
#                         this is how site/assets/popover.png is produced)
set -euo pipefail

APP="${MEETCAPTURE_APP:-$HOME/meetings/MeetCapture.app}"
OUT_DIR="${MEETCAPTURE_SHOT_DIR:-/tmp}"
green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }

[ -d "$APP" ] || { red "  ✗ $APP not found"; exit 1; }
echo "=== MeetCapture visual check: $APP ==="

if [ "${1:-}" = "--headless" ]; then
    mkdir -p "$OUT_DIR"
    SHOT="$OUT_DIR/meetcapture-popover-headless.png"
    TMP_OUT="$(mktemp -d)"
    MEETCAPTURE_TEST_OUTPUT_DIR="$TMP_OUT" MEETCAPTURE_SNAPSHOT_PATH="$SHOT" \
        "$APP/Contents/MacOS/MeetCapture" >/dev/null
    rm -rf "$TMP_OUT"
    [ -s "$SHOT" ] || { red "  ✗ headless render failed"; exit 1; }
    green "  ✓ $SHOT"
    echo "SHOT_PATH=$SHOT"
    exit 0
fi

# Never kill the instance Gio uses: the interactive capture needs it closed.
if pgrep -x MeetCapture >/dev/null; then
    red "  ✗ MeetCapture is already running; quit it first or use --headless"
    exit 1
fi
open "$APP"
for _ in {1..30}; do pgrep -x MeetCapture >/dev/null && break; sleep 0.5; done
pgrep -x MeetCapture >/dev/null || { red "  ✗ app did not start"; exit 1; }
green "  ✓ app running"
sleep 3

echo "[1] open popover"
osascript -e 'tell application "System Events" to tell process "MeetCapture" to click menu bar item 1 of menu bar 2' >/dev/null
sleep 2

echo "[2] capture popover window"
mkdir -p "$OUT_DIR"
SHOT="$OUT_DIR/meetcapture-popover-$(date +%Y%m%d-%H%M%S).png"
BOUNDS="$(osascript -e 'tell application "System Events" to tell process "MeetCapture"
    set p to position of window 1
    set s to size of window 1
    return ((item 1 of p) as text) & "," & ((item 2 of p) as text) & "," & ((item 1 of s) as text) & "," & ((item 2 of s) as text)
end tell' 2>/dev/null || true)"
if [ -n "$BOUNDS" ]; then
    screencapture -x -R "$BOUNDS" -t png "$SHOT"
else
    echo "  window bounds unavailable, capturing the full screen"
    screencapture -x -t png "$SHOT"
fi
[ -s "$SHOT" ] || { red "  ✗ screenshot failed"; exit 1; }
green "  ✓ $SHOT"
echo "SHOT_PATH=$SHOT"
