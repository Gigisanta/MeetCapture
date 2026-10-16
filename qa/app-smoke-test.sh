#!/bin/bash
# app-smoke-test.sh — Verify the selected bundle and render its real UI.
# Uses synthetic data in a temporary directory; never launches recording.
set -euo pipefail

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

PASS=0
FAIL=0

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"

# An explicit bundle must exist: never silently verify a different install.
APP_BUNDLE=""
if [ -n "${MEETCAPTURE_APP:-}" ] && [ ! -d "$MEETCAPTURE_APP" ]; then
    red "✗ Requested bundle not found: $MEETCAPTURE_APP"
    exit 1
fi
for candidate in "${MEETCAPTURE_APP:-}" "$HOME/meetings/MeetCapture.app" /tmp/mc-stage/MeetCapture.app /tmp/MeetCapture.app; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then APP_BUNDLE="$candidate"; break; fi
done
if [ -z "$APP_BUNDLE" ]; then
    red "✗ No MeetCapture.app found (set MEETCAPTURE_APP or build with ./build.sh --staging-dir)"
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
echo "[2] Info.plist version and menu-bar activation"
if [ -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    VER=$(plutil -p "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null | grep CFBundleShortVersionString | awk -F'"' '{print $4}')
    UI_ELEMENT=$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)
    if [ "$VER" = "$EXPECTED_VERSION" ] && [ "$UI_ELEMENT" = true ]; then
        green "  ✅ Version: $VER; LSUIElement: true (menu-bar only)"
        PASS=$((PASS + 1))
    else
        red "  ✗ Info.plist mismatch: version=$VER expected=$EXPECTED_VERSION LSUIElement=$UI_ELEMENT"
        FAIL=$((FAIL + 1))
    fi
else
    red "  ✗ Info.plist missing"
    FAIL=$((FAIL + 1))
fi

# 2b. The bundle declares AppIcon; Finder must have an actual usable icon.
echo ""
echo "[2b] Finder icon"
if [ -s "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ] \
    && sips -g format "$APP_BUNDLE/Contents/Resources/AppIcon.icns" 2>/dev/null | grep -q 'format: icns'; then
    green "  ✅ AppIcon.icns is bundled and decodes"
    PASS=$((PASS + 1))
else
    red "  ✗ AppIcon.icns missing or invalid"
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
if [ -x "$APP_BUNDLE/Contents/Resources/whisper-cli" ] \
    && "$APP_BUNDLE/Contents/Resources/whisper-cli" --help >/dev/null 2>&1; then
    green "  ✅ whisper-cli bundled and launches"
    PASS=$((PASS + 1))
else
    red "  ✗ whisper-cli missing or unable to load its libraries"
    FAIL=$((FAIL + 1))
fi

# 5b. Runtime python scripts + config template
echo ""
echo "[5b] Bundled resources"
MISSING=""
for r in scripts/transcribe_sherpa.py scripts/speaker_diarize.py scripts/meetcapture_stream_asr.py config.example.json; do
    [ -f "$APP_BUNDLE/Contents/Resources/$r" ] || MISSING="$MISSING $r"
done
if [ -z "$MISSING" ]; then
    green "  ✅ scripts and config.example.json bundled"
    PASS=$((PASS + 1))
else
    red "  ✗ missing:$MISSING"
    FAIL=$((FAIL + 1))
fi

# 6. Signing
echo ""
echo "[6] Code signing"
if codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null; then
    green "  ✅ Signed and verified"
    PASS=$((PASS + 1))
else
    red "  ✗ Signing verification failed"
    FAIL=$((FAIL + 1))
fi

# 7. Run this exact binary with isolated synthetic data. A process with the
# same name elsewhere on the host is not evidence that this bundle works.
echo ""
echo "[7] Isolated app render"
SMOKE_DIR="$(mktemp -d /tmp/meetcapture-smoke.XXXXXX)"
SMOKE_PID=""
SMOKE_BINARY="$(realpath "$APP_BUNDLE/Contents/MacOS/MeetCapture")"
SMOKE_BEFORE=""
SMOKE_OPEN_STARTED=0
stop_open_probes() {
    [ "$SMOKE_OPEN_STARTED" -eq 1 ] || return 0
    local signal candidate command
    for signal in TERM KILL; do
        [ "$signal" = TERM ] || sleep 0.5
        while read -r candidate; do
            [ -n "$candidate" ] || continue
            grep -qx "$candidate" <<< "$SMOKE_BEFORE" && continue
            command="$(ps -p "$candidate" -o command= 2>/dev/null || true)"
            [ "$command" = "$SMOKE_BINARY" ] || continue
            kill -"$signal" "$candidate" 2>/dev/null || true
        done < <(pgrep -x MeetCapture || true)
    done
}
cleanup() {
    if [ -n "$SMOKE_PID" ] && kill -0 "$SMOKE_PID" 2>/dev/null; then
        kill -KILL "$SMOKE_PID" 2>/dev/null || true
        wait "$SMOKE_PID" 2>/dev/null || true
    fi
    # open -n is asynchronous. Even if PID discovery or an assertion fails,
    # stop only new processes from the exact bundle under test.
    stop_open_probes
    # LaunchServices registers every bundle opened by the smoke test. Remove
    # disposable stage registrations so opening "MeetCapture" by name cannot
    # resolve to a stale /tmp copy instead of the installed app.
    case "$(realpath "$APP_BUNDLE")" in
        /private/tmp/*|/private/var/folders/*/T/*)
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$APP_BUNDLE" >/dev/null 2>&1 || true ;;
    esac
    rm -rf "$SMOKE_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
MEETCAPTURE_TEST_OUTPUT_DIR="$SMOKE_DIR" \
MEETCAPTURE_SNAPSHOT_PATH="$SMOKE_DIR/popover.png" \
    "$APP_BUNDLE/Contents/MacOS/MeetCapture" >"$SMOKE_DIR/launch.log" 2>&1 &
SMOKE_PID=$!
for _ in {1..100}; do
    kill -0 "$SMOKE_PID" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$SMOKE_PID" 2>/dev/null; then
    red "  ✗ Selected bundle did not finish rendering within 10 seconds"
    kill -KILL "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    FAIL=$((FAIL + 1))
elif wait "$SMOKE_PID" && [ -s "$SMOKE_DIR/popover.png" ] \
    && sips -s format png "$SMOKE_DIR/popover.png" --out "$SMOKE_DIR/decoded.png" >/dev/null 2>&1 \
    && sips -g format -g pixelWidth -g pixelHeight "$SMOKE_DIR/popover.png" 2>/dev/null \
        | awk '
            /format: png/ { png = 1 }
            /pixelWidth:/ { width = $2 + 0 }
            /pixelHeight:/ { height = $2 + 0 }
            END { exit !(png && width >= 300 && height >= 300) }
        '; then
    green "  ✅ Selected bundle launched and rendered the popover"
    PASS=$((PASS + 1))
else
    red "  ✗ Selected bundle failed to render the popover"
    cat "$SMOKE_DIR/launch.log"
    FAIL=$((FAIL + 1))
fi
SMOKE_PID=""

# 7b. The snapshot path above bypasses the normal SwiftUI App lifecycle.
# Open the selected bundle through LaunchServices, as the installer and Finder
# do, and check this exact binary rather than any MeetCapture process.
echo ""
echo "[7b] Normal bundle launch"
SMOKE_BEFORE="$(pgrep -x MeetCapture || true)"
SMOKE_OPEN_STARTED=1
if open -n -a "$APP_BUNDLE" \
    --env "MEETCAPTURE_TEST_OUTPUT_DIR=$SMOKE_DIR" \
    --env MEETCAPTURE_LAUNCH_PROBE=1 \
    --env "MEETCAPTURE_REQUIRE_HOSTED_ICON=${MEETCAPTURE_REQUIRE_HOSTED_ICON:-0}" >"$SMOKE_DIR/open.log" 2>&1; then
    for _ in {1..30}; do
        while read -r candidate; do
            [ -n "$candidate" ] || continue
            if ! grep -qx "$candidate" <<< "$SMOKE_BEFORE" \
                && [ "$(ps -p "$candidate" -o command= 2>/dev/null)" = "$SMOKE_BINARY" ]; then
                SMOKE_PID="$candidate"
                break
            fi
        done < <(pgrep -x MeetCapture || true)
        [ -n "$SMOKE_PID" ] && break
        sleep 0.1
    done
fi
if [ -n "$SMOKE_PID" ]; then sleep 6; fi
SMOKE_STATE=""
if [ -n "$SMOKE_PID" ]; then
    SMOKE_STATE=$(ps -o stat= -p "$SMOKE_PID" 2>/dev/null | tr -d ' ' || true)
fi
if [ -n "$SMOKE_STATE" ] && [[ "$SMOKE_STATE" != Z* ]] \
    && [ -s "$SMOKE_DIR/menubar-interaction.ok" ]; then
    if [ "${MEETCAPTURE_REQUIRE_HOSTED_ICON:-0}" = 1 ]; then
        green "  ✅ On-screen menu-bar icon hosted; launch, click, and Finder reopen passed"
    else
        green "  ✅ Selected bundle: icon ready, click opens and closes, Finder reopen shows controls"
    fi
    PASS=$((PASS + 1))
else
    red "  ✗ Selected bundle failed launch or menu-bar interaction"
    cat "$SMOKE_DIR/open.log"
    if [ -f "$SMOKE_DIR/menubar-interaction.txt" ]; then
        cat "$SMOKE_DIR/menubar-interaction.txt"
        echo ""
    fi
    FAIL=$((FAIL + 1))
fi
stop_open_probes
SMOKE_PID=""

# 8. Recommended local Spanish model
echo ""
echo "[8] Whisper model"
if [ -n "${CI:-}" ]; then
    green "  ✅ Local model not required on the ephemeral CI runner"
    PASS=$((PASS + 1))
elif [ -s "$HOME/.whisper/models/ggml-medium-q5_0.bin" ]; then
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
