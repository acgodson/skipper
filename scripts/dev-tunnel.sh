#!/usr/bin/env bash
#
# Two-Mac verification: runs the local backend (scripts/dev-backend.sh) and
# fronts rc-api with a Cloudflare quick tunnel, so a second Mac on a different
# network can reach it. No Cloudflare account needed.
#
# Prints the public https://<random>.trycloudflare.com URL, writes it to
# dist/tunnel-url.txt, and verifies both /healthz and a WebSocket upgrade on
# /ws succeed through the tunnel before handing control back. Ctrl-C stops
# cloudflared and the backend (and everything dev-backend.sh started).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
DATA="${RC_DEV_DATA:-${TMPDIR:-/tmp}/skipperdesk-dev-backend}"
CLOUDFLARED="${RC_CLOUDFLARED_BIN:-/opt/homebrew/bin/cloudflared}"
TUNNEL_LOG="$DATA/cloudflared.log"
BACKEND_LOG="$DATA/dev-tunnel-backend.log"

mkdir -p "$DATA" "$DIST"

command -v "$CLOUDFLARED" >/dev/null 2>&1 || { echo "FAIL  cloudflared not found at $CLOUDFLARED"; exit 1; }

port_free() {
  python3 - "$1" <<'PY'
import socket, sys
s = socket.socket()
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

if [[ -n "${RC_DEV_API_PORT:-}" ]]; then
  API_PORT="$RC_DEV_API_PORT"
  port_free "$API_PORT" || { echo "FAIL  RC_DEV_API_PORT=$API_PORT is already in use"; exit 1; }
elif port_free 18080; then
  API_PORT=18080
else
  API_PORT="$(any_free_port)"
fi

BACKEND_PID=""
TUNNEL_PID=""

stop_all() {
  [[ -n "$TUNNEL_PID" ]] && kill "$TUNNEL_PID" 2>/dev/null
  [[ -n "$BACKEND_PID" ]] && kill -INT "$BACKEND_PID" 2>/dev/null
  [[ -n "$BACKEND_PID" ]] && wait "$BACKEND_PID" 2>/dev/null
  [[ -n "$TUNNEL_PID" ]] && wait "$TUNNEL_PID" 2>/dev/null
}
trap 'echo; echo "== stopping"; stop_all; exit 0' INT TERM
trap stop_all EXIT

echo "== starting a Cloudflare quick tunnel to 127.0.0.1:$API_PORT"
: > "$TUNNEL_LOG"
"$CLOUDFLARED" tunnel --url "http://127.0.0.1:$API_PORT" >> "$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

TUNNEL_URL=""
for _ in $(seq 1 60); do
  TUNNEL_URL="$(grep -o 'https://[a-zA-Z0-9.-]*\.trycloudflare\.com' "$TUNNEL_LOG" | head -1)"
  [[ -n "$TUNNEL_URL" ]] && break
  if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "FAIL  cloudflared exited before printing a URL; see $TUNNEL_LOG"
    tail -n 30 "$TUNNEL_LOG" | sed -e 's/^/      /'
    exit 1
  fi
  sleep 1
done
[[ -n "$TUNNEL_URL" ]] || { echo "FAIL  no trycloudflare.com URL appeared within 60s; see $TUNNEL_LOG"; exit 1; }
echo "   tunnel: $TUNNEL_URL"

echo "== starting the local backend on 127.0.0.1:$API_PORT (web base = tunnel URL)"
: > "$BACKEND_LOG"
RC_DEV_API_PORT="$API_PORT" RC_DEV_WEB_BASE_URL="$TUNNEL_URL" RC_DEV_TRUSTED_PROXIES="127.0.0.1/32,::1/128" \
  "$ROOT/scripts/dev-backend.sh" >> "$BACKEND_LOG" 2>&1 &
BACKEND_PID=$!

for _ in $(seq 1 100); do
  grep -q "^Backend is up\." "$BACKEND_LOG" && break
  if ! kill -0 "$BACKEND_PID" 2>/dev/null; then
    echo "FAIL  dev-backend.sh exited before becoming healthy; see $BACKEND_LOG"
    tail -n 30 "$BACKEND_LOG" | sed -e 's/^/      /'
    exit 1
  fi
  sleep 0.2
done
grep -q "^Backend is up\." "$BACKEND_LOG" || { echo "FAIL  backend did not report healthy within 20s; see $BACKEND_LOG"; exit 1; }
echo "   backend is up locally on 127.0.0.1:$API_PORT"

echo "== verifying https://.../healthz through the tunnel"
HEALTH=""
for _ in $(seq 1 20); do
  HEALTH="$(curl -fsS --max-time 5 "$TUNNEL_URL/healthz" 2>/dev/null || true)"
  [[ "$HEALTH" == "ok" ]] && break
  sleep 1.5
done
[[ "$HEALTH" == "ok" ]] || { echo "FAIL  $TUNNEL_URL/healthz did not return ok (got '$HEALTH')"; exit 1; }
echo "   PASS  /healthz -> ok"

echo "== verifying a WebSocket upgrade on wss://.../ws through the tunnel"
WS_KEY="$(openssl rand -base64 16)"
WS_LOG="$DATA/tunnel-ws-check.log"
curl --http1.1 -s -i -N --max-time 5 \
  -H 'Connection: Upgrade' \
  -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' \
  -H "Sec-WebSocket-Key: $WS_KEY" \
  "$TUNNEL_URL/ws" > "$WS_LOG" 2>&1
if grep -q "^HTTP/1.1 101" "$WS_LOG"; then
  echo "   PASS  /ws upgraded (101)"
else
  echo "FAIL  /ws did not upgrade; see $WS_LOG"
  head -n 20 "$WS_LOG" | sed -e 's/^/      /'
  exit 1
fi

printf '%s\n' "$TUNNEL_URL" > "$DIST/tunnel-url.txt"

cat <<EOF

== tunnel is verified and up

  Public URL:  $TUNNEL_URL
  Written to:  $DIST/tunnel-url.txt

On the OTHER Mac, launch the app pointed at this backend:

  ./scripts/launch-with-backend.sh $TUNNEL_URL

Press Ctrl-C to stop the tunnel and the backend.
EOF

wait "$BACKEND_PID"
