#!/usr/bin/env bash
# End-to-end smoke test for rc-signal.
#
# Boots the server in local plain-HTTP static mode on a scratch database with a
# throwaway device-id certificate key, drives real WebSocket clients through the
# v5 flow (register and certificates, presence, strict re-encoded SDP/ICE/PAKE relay,
# TURN only once a session is metered, resume, renew, code refresh, roles, bye reasons,
# per-address rate limits, auth timeout), prints
# PASS/FAIL per step and exits non-zero on any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER_DIR="$ROOT/server"
PORT="${RC_SMOKE_PORT:-18443}"
ADDR="127.0.0.1:$PORT"
WORK="$(mktemp -d)"
PID=""

cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

echo "== building rc-signal and smokeclient"
if ! (cd "$SERVER_DIR" && go build -o "$WORK/rc-signal" ./cmd/rc-signal && go build -o "$WORK/smokeclient" ./cmd/smokeclient); then
  echo "FAIL  build"
  exit 1
fi

echo "== generating a throwaway device-id certificate key and TURN secret"
if ! (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$WORK/id-cert-key.pem" 2>/dev/null); then
  echo "FAIL  openssl could not generate the device-id certificate key"
  exit 1
fi
(umask 077; printf 'smoke-turn-secret\n' > "$WORK/turn-secret")

echo "== starting rc-signal on $ADDR (plain HTTP, local only)"
"$WORK/rc-signal" \
  -insecure-http \
  -listen "$ADDR" \
  -entitlement static \
  -db "$WORK/smoke.db" \
  -claims-db "$WORK/smoke-claims.db" \
  -id-cert-key-file "$WORK/id-cert-key.pem" \
  -turn-secret-file "$WORK/turn-secret" \
  -turn-urls "turn:198.51.100.7:3478?transport=udp" \
  -log-level warn \
  > "$WORK/server.log" 2>&1 &
PID=$!

# Wait for /healthz, up to 10 seconds.
ready=0
for _ in $(seq 1 100); do
  if curl -fsS "http://$ADDR/healthz" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
  echo "FAIL  server did not become healthy"
  sed -e 's/^/      /' "$WORK/server.log"
  exit 1
fi
echo "PASS  server healthy"
echo

"$WORK/smokeclient" -addr "$ADDR"
rc=$?

echo
echo "== checking the server log for leaked secrets"
leak=0
# The access codes and TURN secret used by the smoke client must never appear.
for secret in SW7K2M9Q TQ4X8B2N CTRLCODE OTHERCOD PROBECOD NOPENOPE WRONGXXX smoke-turn-secret; do
  if grep -q -- "$secret" "$WORK/server.log"; then
    echo "FAIL  server log contains the secret '$secret'"
    leak=1
  fi
done
# SDP bodies must never be logged either.
if grep -qi "UDP/TLS/RTP/SAVPF\|candidate:" "$WORK/server.log"; then
  echo "FAIL  server log contains SDP or ICE payload"
  leak=1
fi
if [[ "$leak" -eq 0 ]]; then
  echo "PASS  no secrets or session payloads in the server log"
fi

if [[ "$rc" -ne 0 || "$leak" -ne 0 ]]; then
  echo
  echo "SMOKE TEST FAILED"
  echo "---- server log ----"
  sed -e 's/^/      /' "$WORK/server.log"
  exit 1
fi

echo
echo "SMOKE TEST PASSED"
