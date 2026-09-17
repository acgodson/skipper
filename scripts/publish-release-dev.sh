#!/usr/bin/env bash
# Publishes a packaged .dmg as the latest release on a LOCAL rc-api
# (scripts/dev-backend.sh) through the dev-only POST /v1/dev/releases.
# TODO: replace with a signed publish step in Phase 5. Nothing here talks to AWS.
#
#   RC_RELEASE_URL=http://127.0.0.1:18090/SkipperDesk-1.0.0.dmg \
#     scripts/publish-release-dev.sh [dist/SkipperDesk-<version>.dmg]
#
# RC_RELEASE_URL is where the dmg is served from (https, or http on loopback).
# Optional: RC_DEV_API_URL (default http://127.0.0.1:18080), RC_DEV_EMAIL,
# RC_RELEASE_ARCH (arm64), RC_RELEASE_CHANNEL (stable), RC_RELEASE_CRITICAL=1.
set -euo pipefail
cd "$(dirname "$0")/.."

DMG="${1:-$(ls -t dist/SkipperDesk-*.dmg 2>/dev/null | head -1)}"
[[ -f "$DMG" ]] || { echo "no dmg: run ./scripts/build.sh && ./scripts/package-dmg.sh" >&2; exit 1; }
FIELDS="${DMG%.dmg}.release.json"
[[ -f "$FIELDS" ]] || { echo "missing $FIELDS: re-run ./scripts/package-dmg.sh" >&2; exit 1; }

API="${RC_DEV_API_URL:-http://127.0.0.1:18080}"
EMAIL="${RC_DEV_EMAIL:-release@example.com}"
URL="${RC_RELEASE_URL:?set RC_RELEASE_URL to where the dmg is served}"
ARCH="${RC_RELEASE_ARCH:-arm64}"
CHANNEL="${RC_RELEASE_CHANNEL:-stable}"
CRITICAL="false"
[[ "${RC_RELEASE_CRITICAL:-}" == "1" ]] && CRITICAL="true"

BODY="$(python3 -c '
import json, sys
fields = json.load(open(sys.argv[1]))
fields.update({"platform": "macos", "arch": sys.argv[2], "channel": sys.argv[3],
               "url": sys.argv[4], "critical": sys.argv[5] == "true"})
print(json.dumps(fields))
' "$FIELDS" "$ARCH" "$CHANNEL" "$URL" "$CRITICAL")"

echo "==> POST $API/v1/dev/releases"
curl -fsS -X POST "$API/v1/dev/releases" \
  -H "Authorization: Bearer dev:$EMAIL" \
  -H 'Content-Type: application/json' \
  -d "$BODY"
echo
echo "==> GET $API/v1/app/releases/latest"
curl -fsS "$API/v1/app/releases/latest?platform=macos&arch=$ARCH&channel=$CHANNEL"
echo
