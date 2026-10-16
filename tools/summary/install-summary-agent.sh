#!/bin/bash
# install-summary-agent.sh: register the summary dispatcher as a per-user
# launchd agent (WatchPaths on ~/meetings + StartInterval 900 s).
#   --uninstall   remove the agent
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LABEL="ai.hermes.meetcapture-summary"
LEGACY_LABEL="com.maatwork.meetcapture-summary"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [ "${1:-}" = "--uninstall" ]; then
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "removed $LABEL"
    exit 0
fi

# A second scheduler could race the legacy dispatcher against the current
# contracts. Migrating the running service is a separate operational action.
if [ -e "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist" ] \
    || launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
    echo "ERROR: migrate the existing $LEGACY_LABEL service before installing $LABEL" >&2
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/meetings/.logs"
chmod 700 "$HOME/meetings" "$HOME/meetings/.logs"
sed -e "s|__REPO__|$ROOT|g" -e "s|__HOME__|$HOME|g" \
    "$ROOT/tools/summary/$LABEL.plist.example" > "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
launchctl print "$DOMAIN/$LABEL" | grep -E "state|program" | head -3
echo "installed $LABEL ($PLIST)"
echo "config: ~/.meetcapture/summary.json (endpoint, model, keep_audio, dry_run)"
