#!/bin/bash
# Build MeetCapture v5 — Swift native menu bar app
# Usage: ./build.sh [--help] [--staging] [--staging-dir <path>] [--install-to <path>] [--sign <identity>] [--with-turbo] [--rollback]
set -e

APP_NAME="MeetCapture"
BUILD_DIR="/tmp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BACKUP_DIR="$HOME/meetings/.backups"
MAX_BACKUPS=3

# Defaults
DEST="$HOME/meetings/MeetCapture.app"
SIGN_IDENTITY="-"
STAGING=false
STAGING_DIR=""

# ---- Parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            echo "MeetCapture v5 Build Script"
            echo ""
            echo "Usage: ./build.sh [options] [<dest-path>]"
            echo ""
            echo "Options:"
            echo "  --help              Show this help"
            echo "  --staging           Build in staging mode (skip install, no launchd service)"
            echo "  --staging-dir <path> Build to explicit staging path, never touch ~/meetings"
            echo "  --install-to <path> Install to custom path (default: ~/meetings/MeetCapture.app)"
            echo "  --sign <identity>   Sign with given identity (default: ad-hoc '-')"
            echo "  --with-turbo        Download large-v3-turbo model (1.6GB)"
            echo "  --rollback          Restore previous backup"
            echo ""
            echo "Examples:"
            echo "  ./build.sh                                    # ad-hoc signed, ~/meetings/MeetCapture.app"
            echo "  ./build.sh --staging                          # build to /tmp/MeetCapture.app, no install"
            echo "  ./build.sh --staging-dir /tmp/custom          # explicit staging dir, no ~/meetings"
            echo "  ./build.sh --sign \"Developer ID\"              # signed for distribution"
            echo "  ./build.sh --install-to /Applications/MeetCapture.app"
            exit 0
            ;;
        --install-to)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --install-to requires a path argument"; exit 1; fi
            DEST="$2"; shift 2 ;;
        --sign)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --sign requires an identity argument"; exit 1; fi
            SIGN_IDENTITY="$2"; shift 2 ;;
        --staging) STAGING=true; shift ;;
        --staging-dir)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --staging-dir requires a path argument"; exit 1; fi
            STAGING=true; STAGING_DIR="$2"; shift 2 ;;
        --with-turbo) WANT_TURBO=1; shift ;;
        --rollback) DO_ROLLBACK=1; shift ;;
        --*) echo "Unknown flag: $1"; exit 1 ;;
        *) DEST="$1"; shift ;;
    esac
done

# Rollback support
if [ "${DO_ROLLBACK:-0}" = "1" ]; then
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

# Resolve staging output path
if [ "$STAGING" = true ] && [ -n "$STAGING_DIR" ]; then
    # Explicit staging dir — never touch ~/meetings
    APP_BUNDLE="$STAGING_DIR/MeetCapture.app"
elif [ "$STAGING" = true ]; then
    APP_BUNDLE="/tmp/MeetCapture.app"
fi

echo "Building $APP_NAME v5..."
echo "  Sources:  $REPO_DIR/Sources"
echo "  Output:   $DEST"
echo "  Staging:  $STAGING"
if [ "$STAGING" = true ] && [ -n "$STAGING_DIR" ]; then
    echo "  Staging dir: $STAGING_DIR"
fi
echo "  Sign:     $SIGN_IDENTITY"

# Create bundle structure from a clean staging app
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Find all Swift sources
SOURCES=$(find "$REPO_DIR/Sources" -name "*.swift" | sort | tr '\n' ' ')
N_SOURCES=$(echo "$SOURCES" | wc -w | tr -d ' ')
echo "  Compiling $N_SOURCES Swift files..."

# Compile
swiftc \
    -target arm64-apple-macosx14.4 \
    -sdk "$(xcrun --show-sdk-path)" \
    -strict-concurrency=complete \
    -framework SwiftUI \
    -framework EventKit \
    -framework CoreAudio \
    -framework AudioToolbox \
    -framework AVFoundation \
    -framework Combine \
    -framework UserNotifications \
    -framework AppKit \
    -parse-as-library \
    $SOURCES \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "  Binary: $(du -h "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1)"

# Copy metadata
cp "$REPO_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Bundle whisper-cli binary
WHISPER_CLI="$(command -v whisper-cli 2>/dev/null || true)"
if [ -z "$WHISPER_CLI" ]; then
    for p in "$(brew --prefix 2>/dev/null)/bin/whisper-cli" /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
        [ -x "$p" ] && { WHISPER_CLI="$p"; break; }
    done
fi
if [ -n "$WHISPER_CLI" ] && [ -x "$WHISPER_CLI" ]; then
    cp "$WHISPER_CLI" "$APP_BUNDLE/Contents/Resources/"
    echo "  Bundled: whisper-cli ($WHISPER_CLI)"
else
    echo "  ⚠️  WARNING: whisper-cli not found — transcription will FAIL at runtime."
    echo "      Install it:  brew install whisper-cpp"
fi

# Ensure the Silero VAD model exists
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

# Opt-in: download large-v3-turbo (1.6GB) for max accuracy
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

# Sign the app
# Hardened runtime (-o runtime) is only applied when signing with a REAL identity,
# not ad-hoc ('-'). Ad-hoc signed hardened runtime breaks on macOS 15+ with
# code signing rejection even for basic entitlements.
if [ -x "$APP_BUNDLE/Contents/Resources/whisper-cli" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP_BUNDLE/Contents/Resources/whisper-cli" 2>/dev/null || true
fi

SIGN_FLAGS=(
    --force
    --sign "$SIGN_IDENTITY"
    --entitlements "$REPO_DIR/Resources/MeetCapture.entitlements"
    -r='designated => identifier "com.maatwork.meetcapture"'
)

# Only apply hardened runtime when signing with a real developer identity
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--options runtime)
fi

codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || {
    echo "  ⚠️  Code verification warning (non-fatal for ad-hoc)"
}
echo "  Signed: ${SIGN_IDENTITY} (bundle ID: com.maatwork.meetcapture)"

# Staging mode: stop here, don't install or register
if [ "$STAGING" = true ]; then
    echo ""
    echo "=== Staging build ready ==="
    echo "  App bundle: $APP_BUNDLE"
    echo "  Run with: open '$APP_BUNDLE'"
    exit 0
fi

# Install to destination
if [ -d "$DEST" ]; then
    mkdir -p "$BACKUP_DIR"
    TS=$(date +%Y%m%d-%H%M%S)
    cp -R "$DEST" "$BACKUP_DIR/MeetCapture-$TS"
    ls -dt "$BACKUP_DIR"/MeetCapture-* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -rf
    echo "  Backed up previous build to $BACKUP_DIR/MeetCapture-$TS"
fi
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"
echo "  Installed to: $DEST"
echo ""
echo "Done. Run with: open '$DEST'"
echo ""
