#!/usr/bin/env bash
# Serves web/ on localhost so the sign-in page can be exercised without deploying.
#
#   scripts/serve-web.sh [--port 8080] [--cognito-domain URL] [--client-id ID] [--api URL]
#
# It writes web/config.js — the file Terraform owns in the bucket and the repository never
# carries — from whatever is given, and leaves it in place so a reload picks it up.
#
# Reaching Cognito and the API from here needs the origin this serves on to be registered:
# http://localhost:<port>/link as a Cognito callback URL (extra_cognito_callback_urls), and
# the same origin allowed by rc-api's CORS policy. Without those the page still runs as far
# as building the authorize URL, which is what there is to check offline.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8080
COGNITO_DOMAIN="https://example.auth.eu-west-2.amazoncognito.com"
CLIENT_ID="offline-client-id"
API_BASE="http://127.0.0.1:18080"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    --cognito-domain) COGNITO_DOMAIN="${2:-}"; shift 2 ;;
    --client-id) CLIENT_ID="${2:-}"; shift 2 ;;
    --api) API_BASE="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FAIL  unknown argument '$1'"; exit 2 ;;
  esac
done

cat >web/config.js <<CONFIG
window.SKIPPER_CONFIG = {
	cognitoDomain: "${COGNITO_DOMAIN}",
	cognitoClientId: "${CLIENT_ID}",
	apiBase: "${API_BASE}"
};
CONFIG

echo "== serving web/ on http://localhost:${PORT}"
echo "  landing   http://localhost:${PORT}/"
echo "  download  http://localhost:${PORT}/download/"
echo "  sign-in   http://localhost:${PORT}/link?nonce=<43 chars>&device=<base64 pubkey>"
echo
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory web
