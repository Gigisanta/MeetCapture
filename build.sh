#!/bin/bash
# Build MeetCapture v4 — Swift native menu bar app
# Usage: ./build.sh [--install-to ~/Applications]
set -e

APP_NAME="MeetCapture"
BUILD_DIR="/tmp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST="${1:-$HOME/meetings/$APP_NAME.app}"

echo "Building $APP_NAME v4..."
echo "  Sources:  $REPO_DIR/Sources/MeetCapture"
echo "  Output:   $DEST"

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"

# Find all Swift sources
SOURCES=$(find "$REPO_DIR/Sources/MeetCapture" -name "*.swift" | sort | tr '\n' ' ')
N_SOURCES=$(echo "$SOURCES" | wc -w | tr -d ' ')
echo "  Compiling $N_SOURCES Swift files..."

# Compile
swiftc \
    -target arm64-apple-macosx14.0 \
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
cp "$REPO_DIR/Sources/MeetCapture/Info.plist" "$APP_BUNDLE/Contents/"
cp "$REPO_DIR/Sources/MeetCapture/MeetCapture.entitlements" "$APP_BUNDLE/Contents/"
cp "$REPO_DIR/Sources/MeetCapture/com.maatwork.meetcapture.daemon.plist" \
   "$APP_BUNDLE/Contents/Library/LaunchAgents/"

# Bundle whisper-cli binary
if [ -f /opt/homebrew/bin/whisper-cli ]; then
    cp /opt/homebrew/bin/whisper-cli "$APP_BUNDLE/Contents/Resources/"
    echo "  Bundled: whisper-cli"
fi

# Bundle Python daemon scripts
cp "$REPO_DIR/Sources/meet-daemon/daemon_main.py" "$APP_BUNDLE/Contents/Resources/"
cp "$REPO_DIR/Sources/meet-daemon/socket_server.py" "$APP_BUNDLE/Contents/Resources/"

# Create daemon launcher script
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
exec "$PYTHON" "$DIR/daemon_main.py"
SCRIPT
chmod +x "$APP_BUNDLE/Contents/Resources/meet-daemon"

# Sign the app (ad-hoc, required for ScreenCaptureKit + EventKit)
codesign --force --deep --sign - \
    --entitlements "$REPO_DIR/Sources/MeetCapture/MeetCapture.entitlements" \
    "$APP_BUNDLE" 2>/dev/null

echo "  Signed: ad-hoc"

# Install to destination
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"
echo "  Installed to: $DEST"
echo ""
echo "Done. Run with: open '$DEST'"
echo "For login item: osascript -e 'tell application \"System Events\" to make login item at end with properties {path: \"$DEST\", hidden: true}'"
