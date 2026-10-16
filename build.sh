#!/bin/bash
# Build a signed MeetCapture bundle in a disposable staging directory.
# Usage: ./build.sh --staging-dir <path> [--sign <identity>]
set -e

APP_NAME="MeetCapture"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="/tmp/$APP_NAME.app"
APP_ICON="$REPO_DIR/Resources/AppIcon.icns"

# Keep the build log and help text tied to the bundle metadata.  The app has
# moved beyond the v5 capture format, so a hard-coded label here can silently
# drift from the version users see in About/README.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/Resources/Info.plist")"

SIGN_IDENTITY="${MEETCAPTURE_SIGN_IDENTITY:--}"
STAGING=false
STAGING_DIR=""

# Keep the historical no-argument install entry point, but route it through
# the transactional installer instead of the removed direct-copy path.
if [ "$#" -eq 0 ]; then
    exec "$REPO_DIR/install.sh"
fi

# ---- Parse args ----
while [ $# -gt 0 ]; do
    case "$1" in
        --help)
            echo "MeetCapture v${APP_VERSION} Build Script"
            echo ""
            echo "Usage: ./build.sh --staging-dir <path> [--sign <identity>]"
            echo "       ./build.sh  # transactional local install"
            echo ""
            echo "Options:"
            echo "  --help              Show this help"
            echo "  --staging           Build to /tmp/MeetCapture.app"
            echo "  --staging-dir <path> Build to an explicit disposable directory"
            echo "  --sign <identity>   Sign with given identity (default: ad-hoc '-')"
            echo ""
            echo "Models are not downloaded here: see scripts/fetch-models.sh."
            echo ""
            echo "Examples:"
            echo "  ./build.sh                                    # use install.sh"
            echo "  ./build.sh --staging                          # build to /tmp/MeetCapture.app, no install"
            echo "  ./build.sh --staging-dir /tmp/custom          # explicit staging dir, no ~/meetings"
            echo "  ./build.sh --staging-dir /tmp/custom --sign \"Developer ID\""
            exit 0
            ;;
        --sign)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --sign requires an identity argument"; exit 1; fi
            SIGN_IDENTITY="$2"; shift 2 ;;
        --staging) STAGING=true; shift ;;
        --staging-dir)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --staging-dir requires a path argument"; exit 1; fi
            STAGING=true; STAGING_DIR="$2"; shift 2 ;;
        --install-to|--rollback)
            echo "ERROR: direct installation and rollback were removed; use ./install.sh." >&2
            exit 1 ;;
        --*) echo "Unknown flag: $1"; exit 1 ;;
        *) echo "ERROR: unexpected argument: $1" >&2; exit 1 ;;
    esac
done

if [ "$STAGING" != true ]; then
    echo "ERROR: a build destination is required; use --staging-dir or run ./install.sh." >&2
    exit 1
fi
if [ -n "$STAGING_DIR" ]; then
    APP_BUNDLE="$STAGING_DIR/MeetCapture.app"
fi
if [ ! -s "$APP_ICON" ]; then
    echo "ERROR: required app icon is missing or empty: $APP_ICON" >&2
    exit 1
fi

echo "Building $APP_NAME v${APP_VERSION}..."
echo "  Package:  $REPO_DIR/Package.swift"
echo "  Staging:  $APP_BUNDLE"
echo "  Sign:     $SIGN_IDENTITY"

# Create bundle structure from a clean staging app
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Compile with SwiftPM (release = optimized; the old swiftc call built -Onone).
# Package.swift owns targets, platform and strict-concurrency settings.
echo "  Compiling (swift build -c release)..."
swift build -c release --product "$APP_NAME" --package-path "$REPO_DIR"
BIN_PATH="$(swift build -c release --package-path "$REPO_DIR" --show-bin-path)"
cp "$BIN_PATH/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

echo "  Binary: $(du -h "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | cut -f1)"

# Copy metadata
cp "$REPO_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Bundle whisper-cli binary
WHISPER_CLI="$(command -v whisper-cli 2>/dev/null || true)"
if [ -z "$WHISPER_CLI" ]; then
    for p in "$(brew --prefix 2>/dev/null)/bin/whisper-cli" /opt/homebrew/bin/whisper-cli /usr/local/bin/whisper-cli; do
        [ -x "$p" ] && { WHISPER_CLI="$p"; break; }
    done
fi
if [ -n "$WHISPER_CLI" ] && [ -x "$WHISPER_CLI" ]; then
    python3 "$REPO_DIR/tools/packaging/bundle_macho.py" "$WHISPER_CLI" \
        "$APP_BUNDLE/Contents/Resources/whisper-cli" \
        "$APP_BUNDLE/Contents/Frameworks" --identity "$SIGN_IDENTITY"
    echo "  Bundled: whisper-cli ($WHISPER_CLI)"
else
    echo "  ⚠️  WARNING: whisper-cli not found — transcription will FAIL at runtime."
    echo "      Install it:  brew install whisper-cpp"
fi

# Bundle the three runtime python scripts (live streaming ASR, whole-file
# sherpa, diarization). The app resolves them through ToolchainResolver:
# Settings › ASR → ~/.meetcapture/config.json → $MEETCAPTURE_SCRIPTS_DIR →
# Contents/Resources/scripts (this copy).
RUNTIME_SCRIPTS=(transcribe_sherpa.py speaker_diarize.py meetcapture_stream_asr.py)
mkdir -p "$APP_BUNDLE/Contents/Resources/scripts"
for s in "${RUNTIME_SCRIPTS[@]}"; do
    cp "$REPO_DIR/scripts/$s" "$APP_BUNDLE/Contents/Resources/scripts/"
done
echo "  Bundled: ${#RUNTIME_SCRIPTS[@]} python scripts"

# Template for ~/.meetcapture/config.json (Settings › Calendario › Editar config.json)
cp "$REPO_DIR/Resources/config.example.json" "$APP_BUNDLE/Contents/Resources/"

# Sign the app
# Hardened runtime (-o runtime) is only applied when signing with a REAL identity,
# not ad-hoc ('-'). Ad-hoc signed hardened runtime breaks on macOS 15+ with
# code signing rejection even for basic entitlements.
if [ -x "$APP_BUNDLE/Contents/Resources/whisper-cli" ]; then
    "$APP_BUNDLE/Contents/Resources/whisper-cli" --help >/dev/null 2>&1 || {
        echo "ERROR: bundled whisper-cli cannot launch"
        exit 1
    }
fi

SIGN_FLAGS=(
    --force
    --sign "$SIGN_IDENTITY"
    --entitlements "$REPO_DIR/Resources/MeetCapture.entitlements"
)

# A real identity gives a stable designated requirement, so privacy grants
# survive rebuilds; ad-hoc falls back to an identifier-only requirement and
# macOS may still ask again for Microphone and System Audio after a rebuild.
if [ "$SIGN_IDENTITY" != "-" ]; then
    SIGN_FLAGS+=(--options runtime)
else
    SIGN_FLAGS+=(-r='designated => identifier "com.maatwork.meetcapture"')
    echo "  ⚠️  Ad-hoc signature: set MEETCAPTURE_SIGN_IDENTITY to keep permissions across rebuilds"
fi

codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" || {
    echo "  ⚠️  Code verification warning (non-fatal for ad-hoc)"
}
echo "  Signed: ${SIGN_IDENTITY} (bundle ID: com.maatwork.meetcapture)"

echo ""
echo "=== Staging build ready ==="
echo "  App bundle: $APP_BUNDLE"
echo "  Run with: open '$APP_BUNDLE'"
