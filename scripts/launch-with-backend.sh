#!/usr/bin/env bash
#
# Launches SkipperDesk pointed at a given backend URL (typically the
# dist/tunnel-url.txt printed by scripts/dev-tunnel.sh on the host Mac), for
# two-Mac verification. Prefers an installed /Applications/SkipperDesk.app,
# falls back to dist/SkipperDesk.app. Quits a running instance first.
#
# Usage: scripts/launch-with-backend.sh <https://backend-url> [--debug]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
URL="${1:-}"
DEBUG=0
for arg in "$@"; do
  [[ "$arg" == "--debug" ]] && DEBUG=1
done

if [[ -z "$URL" ]]; then
  echo "usage: $0 <https://backend-url> [--debug]" >&2
  exit 1
fi

INSTALLED="/Applications/SkipperDesk.app"
LOCAL="$ROOT/dist/SkipperDesk.app"

if [[ -d "$INSTALLED" ]]; then
  APP_BUNDLE="$INSTALLED"
elif [[ -d "$LOCAL" ]]; then
  APP_BUNDLE="$LOCAL"
else
  echo "FAIL  no app found at $INSTALLED or $LOCAL" >&2
  echo "      build one first: ./scripts/make-verify-bundle.sh" >&2
  exit 1
fi

echo "== quitting any running SkipperDesk"
pkill -f "SkipperDesk.app/Contents/MacOS/SkipperDesk" 2>/dev/null
sleep 1

ENV_ARGS=(--env "SKIPPER_API_BASE_URL=$URL" --env "SKIPPER_WEB_BASE_URL=$URL")
if [[ "$DEBUG" == "1" ]]; then
  LOG="${RC_LOG_FILE:-${TMPDIR:-/tmp}/skipperdesk-verify.log}"
  : > "$LOG"
  ENV_ARGS+=(--env "RC_DEBUG=1" --env "RC_LOG_FILE=$LOG")
  echo "== launching $APP_BUNDLE against $URL (RC_DEBUG=1, log: $LOG)"
else
  echo "== launching $APP_BUNDLE against $URL"
fi

open "${ENV_ARGS[@]}" "$APP_BUNDLE"
