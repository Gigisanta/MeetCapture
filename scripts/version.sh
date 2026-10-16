#!/bin/bash
# version.sh: print the app version (single source: Resources/Info.plist).
# --check fails when CFBundleVersion and CFBundleShortVersionString differ or
# when a literal vX.Y.Z appears in tracked files outside the allowlist.
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

# Files allowed to mention released versions.
ALLOW='^(CHANGELOG\.md|RELEASING\.md|docs/RESEARCH-NOTES\.md|docs/brand/README\.md|scripts/version\.sh)$'
HITS="$(git -C "$ROOT" ls-files -z | grep -zvE "$ALLOW" | xargs -0 grep -nE '(^|[^A-Za-z0-9_-])v[0-9]+\.[0-9]+\.[0-9]+\b' 2>/dev/null || true)"
if [ -n "$HITS" ]; then
    echo "Hardcoded version literals (use Resources/Info.plist / AppInfo.version):" >&2
    echo "$HITS" >&2
    status=1
fi
[ $status -eq 0 ] && echo "version $SHORT: consistent"
exit $status
