#!/bin/bash
# Build a signed MeetCapture bundle in a disposable staging directory.
# Usage: ./build.sh --staging-dir <path> [--sign <identity>] [--qa]
set -e

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: MeetCapture builds require macOS; Linux and Windows are not supported." >&2
    exit 1
fi

APP_NAME="MeetCapture"
APP_DISPLAY_NAME="$APP_NAME"
APP_BUNDLE_ID="com.maatwork.meetcapture"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_NAME="$APP_NAME"
APP_ICON="$REPO_DIR/Resources/AppIcon.icns"

# Keep the build log and help text tied to the bundle metadata.  The app has
# moved beyond the v5 capture format, so a hard-coded label here can silently
# drift from the version users see in About/README.
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$REPO_DIR/Resources/Info.plist")"

SIGN_IDENTITY="${MEETCAPTURE_SIGN_IDENTITY:--}"
STAGING=false
STAGING_DIR=""
QA=false

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
            echo "Usage: ./build.sh --staging-dir <path> [--sign <identity>] [--qa]"
            echo "       ./build.sh  # transactional local install"
            echo ""
            echo "Options:"
            echo "  --help              Show this help"
            echo "  --staging           Build to /tmp/MeetCapture.app"
            echo "  --staging-dir <path> Build to an explicit disposable directory"
            echo "  --sign <identity>   Sign with given identity (default: ad-hoc '-')"
            echo "  --qa                Separate ad-hoc QA identity (staging only)"
            echo ""
            echo "Supported app runtime: Apple Silicon, macOS 14.4+."
            echo "Build tools: Swift 6.0+ and a macOS SDK; the toolchain may need a newer macOS host."
            echo "Speech models download on first use (see docs/THIRD_PARTY.md)."
            echo ""
            echo "Examples:"
            echo "  ./build.sh                                    # use install.sh"
            echo "  ./build.sh --staging                          # build to /tmp/MeetCapture.app, no install"
            echo "  ./build.sh --staging-dir /tmp/custom          # explicit staging dir, no ~/meetings"
            echo "  ./build.sh --staging-dir /tmp/custom --sign \"Developer ID\""
            echo "  ./build.sh --staging-dir /tmp/mc-qa --qa      # MeetCapture QA.app, no install"
            exit 0
            ;;
        --sign)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --sign requires an identity argument"; exit 1; fi
            SIGN_IDENTITY="$2"; shift 2 ;;
        --staging) STAGING=true; shift ;;
        --staging-dir)
            if [ -z "$2" ] || [[ "$2" =~ ^-- ]]; then echo "ERROR: --staging-dir requires a path argument"; exit 1; fi
            STAGING=true; STAGING_DIR="$2"; shift 2 ;;
        --qa) QA=true; shift ;;
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
if [ "$QA" = true ]; then
    if [ "$SIGN_IDENTITY" != "-" ]; then
        echo "ERROR: --qa requires ad-hoc signing; pass --sign - to override MEETCAPTURE_SIGN_IDENTITY." >&2
        exit 1
    fi
    APP_DISPLAY_NAME="MeetCapture QA"
    BUNDLE_NAME="$APP_DISPLAY_NAME"
    APP_BUNDLE_ID="com.maatwork.meetcapture.qa"
fi
APP_BUNDLE="${STAGING_DIR:-/tmp}/$BUNDLE_NAME.app"
if [ ! -s "$APP_ICON" ]; then
    echo "ERROR: required app icon is missing or empty: $APP_ICON" >&2
    exit 1
fi

# Package.swift and the pinned FluidAudio manifest require Swift tools 6.0.
# Check before removing a staging bundle or starting dependency downloads.
if [ "$(uname -m)" != "arm64" ]; then
    echo "WARNING: Intel/Rosetta staging builds are not supported ASR installations." >&2
    echo "Use a native Apple Silicon terminal for ./install.sh." >&2
fi
MACOS_VERSION="$(sw_vers -productVersion)"
IFS=. read -r MACOS_MAJOR MACOS_MINOR MACOS_PATCH <<< "$MACOS_VERSION"
if [[ ! "$MACOS_MAJOR" =~ ^[0-9]+$ ]] || [[ ! "$MACOS_MINOR" =~ ^[0-9]+$ ]] \
    || (( MACOS_MAJOR < 14 || (MACOS_MAJOR == 14 && MACOS_MINOR < 4) )); then
    echo "ERROR: macOS 14.4 or newer is required; found $MACOS_VERSION." >&2
    exit 1
fi
for command_name in swift xcrun git codesign; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "ERROR: missing $command_name. Install compatible Xcode or Command Line Tools; see README.md." >&2
        exit 1
    fi
done
if ! SWIFT_VERSION="$(swift --version 2>&1)"; then
    echo "ERROR: Swift could not start. Complete Xcode/Command Line Tools setup; see README.md." >&2
    printf '%s\n' "$SWIFT_VERSION" >&2
    exit 1
fi
if [[ ! "$SWIFT_VERSION" =~ Swift\ version\ ([0-9]+)\.([0-9]+) ]] \
    || (( BASH_REMATCH[1] < 6 )); then
    echo "ERROR: Swift 6.0 or newer is required by Package.swift and FluidAudio." >&2
    printf '%s\n' "$SWIFT_VERSION" >&2
    echo "Select a compatible toolchain; see README.md." >&2
    exit 1
fi
if ! xcrun --sdk macosx --show-sdk-path >/dev/null; then
    echo "ERROR: no usable macOS SDK. Complete Xcode/Command Line Tools setup and check xcode-select -p." >&2
    exit 1
fi

echo "Building $APP_DISPLAY_NAME v${APP_VERSION}..."
echo "  Package:  $REPO_DIR/Package.swift"
echo "  Staging:  $APP_BUNDLE"
echo "  Sign:     $SIGN_IDENTITY"
echo "  Identity: $APP_BUNDLE_ID"

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
if [ "$QA" = true ]; then
    # Only the staged copy changes. The installer rejects this non-production ID.
    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" \
        -c "Set :CFBundleName $APP_DISPLAY_NAME" \
        -c "Set :CFBundleDisplayName $APP_DISPLAY_NAME" \
        "$APP_BUNDLE/Contents/Info.plist"
fi
cp "$APP_ICON" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Template for ~/.meetcapture/config.json (Settings › Calendario › Editar config.json)
cp "$REPO_DIR/Resources/config.example.json" "$APP_BUNDLE/Contents/Resources/"

# Sign the app
# Hardened runtime (-o runtime) is only applied when signing with a REAL identity,
# not ad-hoc ('-'). Ad-hoc signed hardened runtime breaks on macOS 15+ with
# code signing rejection even for basic entitlements.
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
    SIGN_FLAGS+=(-r="designated => identifier \"$APP_BUNDLE_ID\"")
    if [ "$QA" = true ]; then
        echo "  QA ad-hoc requirement uses only $APP_BUNDLE_ID; production grants are separate."
    else
        echo "  Ad-hoc local build: not Developer ID signed or notarized; macOS may request permissions again."
    fi
fi

codesign "${SIGN_FLAGS[@]}" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "  Signed: ${SIGN_IDENTITY} (bundle ID: $APP_BUNDLE_ID)"

echo ""
echo "=== Staging build ready ==="
echo "  App bundle: $APP_BUNDLE"
if [ "$QA" = true ]; then
    echo "  QA only: launch with MEETCAPTURE_REAL_CHECK=ui and isolated output (see qa/README.md)."
    echo "  Do not install or launch without the real-check environment."
else
    echo "  Run with: open '$APP_BUNDLE'"
fi
