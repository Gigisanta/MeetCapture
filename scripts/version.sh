#!/bin/bash
# version.sh: print the app version (single source: Resources/Info.plist).
# --check fails when CFBundleVersion and CFBundleShortVersionString differ.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Resources/Info.plist"
SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"

if [ "${1:-}" != "--check" ]; then
    echo "$SHORT"
    exit 0
fi

status=0
if [ "$SHORT" != "$BUILD" ]; then
    echo "Info.plist: CFBundleVersion ($BUILD) != CFBundleShortVersionString ($SHORT)" >&2
    status=1
fi

[ $status -eq 0 ] && echo "version $SHORT: consistent"
exit $status
