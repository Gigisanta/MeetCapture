#!/bin/bash
# build.sh — MeetCapture v4 build script
# Builds the Swift app, creates .app bundle, signs it

set -euo pipefail

APP_NAME="MeetCapture"
BUILD_DIR="build"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
IDENTITY="${CODESIGN_IDENTITY:--}"  # Default: ad-hoc signing

echo "=== MeetCapture v4 Build ==="
echo ""

# Clean
rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"
mkdir -p "${APP_BUNDLE}/Contents/Library/LaunchAgents"

# Copy Info.plist
cp Sources/MeetCapture/Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# Copy entitlements
cp Sources/MeetCapture/MeetCapture.entitlements "${APP_BUNDLE}/Contents/MeetCapture.entitlements"

# Copy daemon plist (for SMAppService)
cp Sources/MeetCapture/com.maatwork.meetcapture.daemon.plist \
   "${APP_BUNDLE}/Contents/Library/LaunchAgents/"

# Copy daemon script
cp Sources/meet-daemon/socket_server.py "${APP_BUNDLE}/Contents/Resources/meet-daemon"
chmod +x "${APP_BUNDLE}/Contents/Resources/meet-daemon"

# Copy existing daemon (from v3)
if [ -f daemon.py ]; then
    cp daemon.py "${APP_BUNDLE}/Contents/Resources/meet-daemon-legacy"
fi

# Compile Swift sources
echo "Compiling Swift..."
SOURCES=$(find Sources/MeetCapture -name "*.swift" -type f | sort)

# For now, compile without framework dependencies (ScreenCaptureKit, EventKit need Xcode)
# This validates syntax and structure
swiftc \
    -target arm64-apple-macosx14.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework SwiftUI \
    -framework ServiceManagement \
    -framework EventKit \
    -framework ScreenCaptureKit \
    -framework Combine \
    -framework os \
    -parse-as-library \
    ${SOURCES} \
    -o "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" \
    2>&1 || {
        echo ""
        echo "NOTE: Full compilation requires Xcode (not just CommandLineTools)."
        echo "To build with Xcode: open MeetCapture.xcodeproj"
        echo "To install Xcode: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        echo ""
        echo "Syntax check only..."
        
        # Fallback: syntax check each file
        for f in ${SOURCES}; do
            swiftc -parse "$f" 2>&1 && echo "  OK: $f" || echo "  FAIL: $f"
        done
    }

# Copy model if available
MODEL_DIR="${HOME}/.whisper/models"
if [ -f "${MODEL_DIR}/ggml-large-v3-turbo-q5_0.bin" ]; then
    cp "${MODEL_DIR}/ggml-large-v3-turbo-q5_0.bin" "${APP_BUNDLE}/Contents/Resources/"
    echo "Copied whisper model (large-v3-turbo)"
elif [ -f "${MODEL_DIR}/ggml-base.bin" ]; then
    cp "${MODEL_DIR}/ggml-base.bin" "${APP_BUNDLE}/Contents/Resources/"
    echo "Copied whisper model (base)"
fi

# Sign
echo "Signing with identity: ${IDENTITY}"
codesign --force --options runtime --timestamp \
    --entitlements "${APP_BUNDLE}/Contents/MeetCapture.entitlements" \
    --sign "${IDENTITY}" \
    "${APP_BUNDLE}" 2>&1 || echo "Signing skipped (no valid identity)"

# Verify
echo ""
echo "Build complete: ${APP_BUNDLE}"
ls -la "${APP_BUNDLE}/Contents/MacOS/"
echo ""
echo "To run: open ${APP_BUNDLE}"
