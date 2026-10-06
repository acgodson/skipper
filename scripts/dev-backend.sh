#!/usr/bin/env bash
#
# Local SkipperDesk backend: rc-signal (signaling) behind rc-api (REST, the
# /link page, and a /ws pass-through), both plain HTTP on 127.0.0.1.
# The app needs one value, the API base URL; everything else is derived from it.
# Stops both services on Ctrl-C. Nothing here talks to AWS.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT/server"
API_PORT="${RC_DEV_API_PORT:-18080}"
DEFAULT_SIGNAL_PORT=18443
DATA="${RC_DEV_DATA:-${TMPDIR:-/tmp}/skipperdesk-dev-backend}"
BIN="$DATA/bin"
PIDS=()

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", int(sys.argv[1])))
except OSError:
    sys.exit(1)
finally:
    s.close()
PY
}

any_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

if [[ -n "${RC_DEV_SIGNAL_PORT:-}" ]]; then
  SIGNAL_PORT="$RC_DEV_SIGNAL_PORT"
  port_free "$SIGNAL_PORT" || { echo "FAIL  RC_DEV_SIGNAL_PORT=$SIGNAL_PORT is already in use"; exit 1; }
elif port_free "$DEFAULT_SIGNAL_PORT"; then
  SIGNAL_PORT="$DEFAULT_SIGNAL_PORT"
else
  SIGNAL_PORT="$(any_free_port)"
  echo "== port $DEFAULT_SIGNAL_PORT is taken; rc-signal will listen on $SIGNAL_PORT"
fi
port_free "$API_PORT" || { echo "FAIL  the rc-api port $API_PORT is already in use (set RC_DEV_API_PORT)"; exit 1; }

pick_port() {
  local wanted="$1"
  if port_free "$wanted"; then echo "$wanted"; else any_free_port; fi
}
API_INTERNAL_PORT="${RC_DEV_API_INTERNAL_PORT:-$(pick_port 18081)}"
SIGNAL_INTERNAL_PORT="${RC_DEV_SIGNAL_INTERNAL_PORT:-$(pick_port 18444)}"

API_URL="http://127.0.0.1:$API_PORT"
API_INTERNAL_URL="http://127.0.0.1:$API_INTERNAL_PORT"
SIGNAL_URL="http://127.0.0.1:$SIGNAL_PORT"
SIGNAL_INTERNAL_URL="http://127.0.0.1:$SIGNAL_INTERNAL_PORT"

mkdir -p "$BIN"
KEYS="$(mktemp -d)"

secret() {
  local file="$DATA/$1"
  if [[ ! -s "$file" ]]; then
    (umask 077; openssl rand -hex 32 > "$file")
  fi
  cat "$file"
}

stop_all() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && wait "$pid" 2>/dev/null
  done
  rm -rf "$KEYS"
}
trap 'echo; echo "== stopping"; stop_all; exit 0' INT TERM
trap stop_all EXIT

wait_healthy() {
  local url="$1" name="$2" pid="$3"
  for _ in $(seq 1 100); do
    if [[ "$(curl -fsS "$url/healthz" 2>/dev/null)" == "ok" ]]; then return 0; fi
    if ! kill -0 "$pid" 2>/dev/null; then break; fi
    sleep 0.1
  done
  echo "FAIL  $name did not become healthy; see $DATA/$name.log"
  tail -n 20 "$DATA/$name.log" | sed -e 's/^/      /'
  exit 1
}

echo "== building rc-signal and rc-api"
if ! (cd "$SERVER_DIR" && go build -o "$BIN/rc-signal" ./cmd/rc-signal && go build -o "$BIN/rc-api" ./cmd/rc-api); then
  echo "FAIL  build"
  exit 1
fi

secret internal-token >/dev/null
INTERNAL_TOKEN_FILE="$DATA/internal-token"
HARDWARE_SALT="$(secret hardware-salt)"

ID_CERT_KEY="$DATA/id-cert-key.pem"
if [[ ! -s "$ID_CERT_KEY" ]]; then
  echo "== generating the dev device-id certificate key in $DATA (kept across restarts, like the real registry key)"
  if ! (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ID_CERT_KEY" 2>/dev/null); then
    echo "FAIL  openssl could not generate the device-id certificate key"
    exit 1
  fi
fi
if [[ -n "${RC_TURN_SECRET_FILE:-}" ]]; then
  TURN_SECRET_FILE="$RC_TURN_SECRET_FILE"
else
  TURN_SECRET_FILE="$KEYS/turn-secret"
  (umask 077; printf 'dev-turn-secret\n' > "$TURN_SECRET_FILE")
fi

echo "== starting rc-api on $API_URL (dev identity provider; internal surface on $API_INTERNAL_URL)"
"$BIN/rc-api" \
  -insecure-http \
  -listen "127.0.0.1:$API_PORT" \
  -internal-listen "127.0.0.1:$API_INTERNAL_PORT" \
  -db "$DATA/rc-api.db" \
  -claims-db "$DATA/rc-api-claims.db" \
  -idp dev \
  -internal-token-file "$INTERNAL_TOKEN_FILE" \
  -id-cert-key-file "$ID_CERT_KEY" \
  -hardware-salt "$HARDWARE_SALT" \
  -web-base-url "${RC_DEV_WEB_BASE_URL:-$API_URL}" \
  -signal-upstream "$SIGNAL_URL" \
  -signal-internal-url "$SIGNAL_INTERNAL_URL" \
  -trusted-proxies "${RC_DEV_TRUSTED_PROXIES:-}" \
  -log-level "${RC_DEV_LOG_LEVEL:-info}" \
  >> "$DATA/rc-api.log" 2>&1 &
PIDS+=("$!")
wait_healthy "$API_URL" rc-api "${PIDS[0]}"

echo "== starting rc-signal on $SIGNAL_URL (device registry and entitlement from rc-api)"
"$BIN/rc-signal" \
  -insecure-http \
  -listen "127.0.0.1:$SIGNAL_PORT" \
  -internal-listen "127.0.0.1:$SIGNAL_INTERNAL_PORT" \
  -entitlement http \
  -api-internal-url "$API_INTERNAL_URL" \
  -internal-token-file "$INTERNAL_TOKEN_FILE" \
  -trusted-proxies "127.0.0.1/32" \
  -register-per-ip-hour "${RC_DEV_REGISTER_PER_IP_HOUR:-1000}" \
  -connect-per-ip-min "${RC_DEV_CONNECT_PER_IP_MIN:-1000}" \
  -turn-secret-file "$TURN_SECRET_FILE" \
  -turn-urls "${RC_TURN_URLS:-turn:198.51.100.7:3478?transport=udp}" \
  -log-level "${RC_DEV_LOG_LEVEL:-info}" \
  >> "$DATA/rc-signal.log" 2>&1 &
PIDS+=("$!")
wait_healthy "$SIGNAL_URL" rc-signal "${PIDS[1]}"

cat <<EOF

Backend is up. Point the app (or scripts/test-*.sh) at it with:

  export SKIPPER_API_BASE_URL=$API_URL
  export SKIPPER_WEB_BASE_URL=$API_URL

The app derives ws://127.0.0.1:$API_PORT/ws, which rc-api passes through to rc-signal.
rc-signal:     $SIGNAL_URL (device registry and entitlement live in rc-api)
Internal:      rc-api $API_INTERNAL_URL, rc-signal $SIGNAL_INTERNAL_URL (loopback only)
Data and logs: $DATA (rc-api-claims.db holds the device-id claims; keep it when resetting rc-api.db)
Dev top-up:    curl -X POST $API_URL/v1/credits/dev-topup -H 'Authorization: Bearer dev:<email>' \\
                 -H "Idempotency-Key: \$(uuidgen)" -d '{"amountCents":500}'
Dev sign-in:   RC_ROLE=host apps/macos/.build/debug/rc-node --dev-sign-in <email>
Press Ctrl-C to stop both.
EOF

while true; do
  for pid in "${PIDS[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "FAIL  a service exited; see $DATA/rc-api.log and $DATA/rc-signal.log"
      exit 1
    fi
  done
  sleep 1
done
