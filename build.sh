#!/bin/bash
# Build MeetCapture v4 — Swift native menu bar app
# Usage: ./build.sh [--install-to ~/Applications] [--rollback]
set -e

APP_NAME="MeetCapture"
BUILD_DIR="/tmp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$HOME/meetings/.backups"
MAX_BACKUPS=3

# Determine DEST: the first arg that is NOT a flag
DEST="$HOME/meetings/MeetCapture.app"
for arg in "$@"; do
    case "$arg" in
        --*) ;;  # skip flags
        *) DEST="$arg" ;;
    esac
done

# Phase 6: rollback support
if [ "${1:-}" = "--rollback" ] || [ "${2:-}" = "--rollback" ]; then
    echo "Rolling back to previous build..."
    LATEST=$(ls -dt "$BACKUP_DIR"/MeetCapture-* 2>/dev/null | head -1)
    if [ -z "$LATEST" ]; then
        echo "ERROR: No backups found in $BACKUP_DIR"
        exit 1
    fi
    echo "Restoring $LATEST → $DEST"
    pkill -x MeetCapture 2>/dev/null || true
    sleep 1
    rm -rf -- "$DEST"
    cp -R "$LATEST" "$DEST"
    echo "Rollback complete. Run: open '$DEST'"
    exit 0
fi

echo "Building $APP_NAME v4..."
echo "  Sources:  $REPO_DIR/Sources"
echo "  Output:   $DEST"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"

# Find all Swift sources
SOURCES=$(find "$REPO_DIR/Sources" -name "*.swift" | sort | tr '\n' ' ')
N_SOURCES=$(echo "$SOURCES" | wc -w | tr -d ' ')
echo "  Compiling $N_SOURCES Swift files..."

# Compile
swiftc \
    -target arm64-apple-macosx14.4 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework EventKit \
    -framework ScreenCaptureKit \
    -framework Combine \
    -framework UserNotifications \
    -framework AppKit \
    -parse-as-library \
    $SOURCES \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "  Binary: $(du -h "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1)"

# Copy metadata
cp "$REPO_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$REPO_DIR/Resources/MeetCapture.entitlements" "$APP_BUNDLE/Contents/"
cp "$REPO_DIR/Resources/com.maatwork.meetcapture.daemon.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchAgents/"

# Bundle whisper-cli binary
if [ -f /opt/homebrew/bin/whisper-cli ]; then
    cp /opt/homebrew/bin/whisper-cli "$APP_BUNDLE/Contents/Resources/"
    echo "  Bundled: whisper-cli"
fi

# Ensure the Silero VAD model exists (skips silence → faster, fewer
# hallucinations). Optional: the app runs without it, just without VAD.
VAD_MODEL="$HOME/.whisper/models/ggml-silero-v5.1.2.bin"
if [ ! -f "$VAD_MODEL" ]; then
    mkdir -p "$HOME/.whisper/models"
    if curl -fsSL -o "$VAD_MODEL" \
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin" 2>/dev/null; then
        echo "  Downloaded: Silero VAD model"
    else
        rm -f "$VAD_MODEL"
        echo "  VAD model download skipped (offline) — app runs without VAD"
    fi
fi

# Opt-in: download large-v3-turbo (1.6GB) for max accuracy. Off by default to
# honor the "few resources" goal; medium stays the default model. Enable with:
#   ./build.sh --with-turbo
for arg in "$@"; do [ "$arg" = "--with-turbo" ] && WANT_TURBO=1; done
TURBO_MODEL="$HOME/.whisper/models/ggml-large-v3-turbo.bin"
if [ "${WANT_TURBO:-0}" = "1" ] && [ ! -f "$TURBO_MODEL" ]; then
    mkdir -p "$HOME/.whisper/models"
    echo "  Downloading large-v3-turbo (1.6GB)…"
    if curl -fSL -o "$TURBO_MODEL" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"; then
        echo "  Downloaded: large-v3-turbo"
    else
        rm -f "$TURBO_MODEL"; echo "  turbo download failed — skipping"
    fi
fi

# Bundle Python daemon scripts
cp "$REPO_DIR/Daemon/server.py" "$APP_BUNDLE/Contents/Resources/"

# Create daemon launcher script
BUNDLE_DIR="$APP_BUNDLE"
# Substitute __BUNDLE_DIR__ in bundled plist with absolute path so SMAppService finds it
if [ -f "$APP_BUNDLE/Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist" ]; then
  sed -i '' "s|__BUNDLE_DIR__|$DEST|g" \
    "$APP_BUNDLE/Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
fi
cat > "$APP_BUNDLE/Contents/Resources/meet-daemon" << 'SCRIPT'
#!/bin/bash
# MeetCapture daemon launcher
DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$(cd "$DIR/../.." && pwd)"
# Try bundled Python first, then system
if [ -x "$BUNDLE/Contents/Resources/python3" ]; then
    PYTHON="$BUNDLE/Contents/Resources/python3"
elif [ -x "/opt/homebrew/bin/python3" ]; then
    PYTHON="/opt/homebrew/bin/python3"
else
    PYTHON="/usr/bin/python3"
fi
export PATH="$BUNDLE/Contents/Resources:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
exec "$PYTHON" "$DIR/server.py"
SCRIPT
chmod +x "$APP_BUNDLE/Contents/Resources/meet-daemon"

# Sign the app (ad-hoc, required for ScreenCaptureKit + EventKit)
# Set designated requirement to bundle ID (stable across builds)
codesign --force --deep --sign - \
    --preserve-metadata=identifier,entitlements \
    -r='designated => identifier "com.maatwork.meetcapture"' \
    "$APP_BUNDLE" 2>/dev/null || codesign --force --deep --sign - \
    --entitlements "$REPO_DIR/Resources/MeetCapture.entitlements" \
    "$APP_BUNDLE" 2>/dev/null

echo "  Signed: ad-hoc (stable bundle ID requirement)"

# Install to destination
# Phase 6: keep last 3 backups for rollback
if [ -d "$DEST" ]; then
    mkdir -p "$BACKUP_DIR"
    TS=$(date +%Y%m%d-%H%M%S)
    cp -R "$DEST" "$BACKUP_DIR/MeetCapture-$TS"
    # Prune old backups
    ls -dt "$BACKUP_DIR"/MeetCapture-* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -rf
    echo "  Backed up previous build to $BACKUP_DIR/MeetCapture-$TS"
fi
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"
echo "  Installed to: $DEST"
echo ""
echo "Done. Run with: open '$DEST'"
echo ""
echo "=== Post-install: Register daemon ==="
# Copy daemon plist to user's LaunchAgents with absolute paths
DAEMON_PLIST_SRC="$DEST/Contents/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"
DAEMON_PLIST_DST="$HOME/Library/LaunchAgents/com.maatwork.meetcapture.daemon.plist"

# Unload existing if present
launchctl unload "$DAEMON_PLIST_DST" 2>/dev/null || true

# Create modified plist with absolute paths
python3 -c "
import plistlib, os
home = os.path.expanduser('~')
with open('$DAEMON_PLIST_SRC', 'rb') as f:
    plist = plistlib.load(f)
plist.pop('BundleProgram', None)
plist['ProgramArguments'] = ['$DEST/Contents/Resources/meet-daemon']
plist['StandardOutPath'] = '/tmp/meetcapture-daemon.log'
plist['StandardErrorPath'] = '/tmp/meetcapture-daemon.log'
with open('$DAEMON_PLIST_DST', 'wb') as f:
    plistlib.dump(plist, f)
print('Plist written to $DAEMON_PLIST_DST')
"

# Load daemon
launchctl load "$DAEMON_PLIST_DST" 2>/dev/null && echo "Daemon loaded" || echo "Daemon load deferred (will load at next app launch)"
echo "Done."
