#!/bin/bash
# deploy-site.sh: publish site/ to Vercel as a production deployment.
# Requires the Vercel CLI logged in and site/ linked to the project
# (`vercel link --cwd site`). Maintainers only; nothing here runs in CI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SITE="$ROOT/site"

command -v vercel >/dev/null || { echo "vercel CLI not found (npm i -g vercel)"; exit 1; }
[ -f "$SITE/index.html" ] || { echo "missing $SITE/index.html"; exit 1; }
[ -s "$SITE/assets/popover.png" ] || { echo "missing $SITE/assets/popover.png"; exit 1; }

if grep -qE $'—|–' "$SITE/index.html"; then
    echo "index.html contains an em or en dash"; exit 1
fi
[ "$(grep -c '<h1' "$SITE/index.html")" = 1 ] || { echo "index.html must have exactly one <h1>"; exit 1; }

vercel deploy --prod --yes --cwd "$SITE" "$@"
