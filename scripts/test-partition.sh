#!/usr/bin/env bash
#
# Phase 3 acceptance: a REAL network partition, with pfctl.
#
#   1. 20-second UDP blackout  -> the session must SURVIVE, show Reconnecting,
#      and recover WITHOUT the access code being re-entered.
#   2. 2-minute UDP blackout   -> the session must close CLEANLY (ICE failed
#      plus the 45 s grace window) and leave no stuck state behind.
#
# WHY THIS IS A SEPARATE SCRIPT
# -----------------------------
# It needs root for `pfctl`, so it cannot run unattended alongside
# scripts/test-transport.sh. It refuses to run without root rather than
# "skipping": a partition test that quietly does nothing is worse than no test,
# because it reports success for the one behaviour this whole phase exists for.
#
# WHY IT FORCES TURN RELAY
# ------------------------
# Both instances run on this Mac, so their best ICE candidates are on loopback,
# and macOS's default pf configuration contains `set skip on lo0` -- no firewall
# rule can cut a loopback path. Running with RC_ICE_POLICY=relay pushes every
# media packet through the TURN server over UDP/3478, which IS blockable, and
# which is the same path a real pair of Macs falls back to when P2P fails.
# The partition is therefore genuine: after the rule loads, zero media packets
# can reach the peer.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
BIN="$APP_DIR/.build/debug/rc-node"
ANCHOR="rc-partition"

SERVER_URL="${RC_SERVER_URL:-wss://54.246.73.81:8443/ws}"
CERT_PIN="${RC_CERT_PIN:-E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=}"
SERVER_HOST="$(printf '%s' "$SERVER_URL" | sed -e 's|^wss\{0,1\}://||' -e 's|:.*$||')"

SHORT_BLACKOUT="${RC_SHORT_BLACKOUT:-20}"
LONG_BLACKOUT="${RC_LONG_BLACKOUT:-120}"

# ---------------------------------------------------------------------------
# Root check -- loud, never silent
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  cat >&2 <<EOF
================================================================================
scripts/test-partition.sh needs root.

It installs a temporary pf rule that blocks UDP to the TURN server, so it can
cut the media path out from under a live session and watch it recover. pfctl
cannot do that as an ordinary user, and this script will NOT pretend to have
tested something it did not test.

Re-run with:

    sudo ./scripts/test-partition.sh

What it will do, and undo:
  * pfctl -a $ANCHOR -f -     (adds ONE anchor: block udp to $SERVER_HOST)
  * pfctl -E / -X             (enables pf for the run, restores the previous
                               enabled/disabled state on exit)
  * flushes and removes the anchor on exit, including on Ctrl-C

It touches no other pf rule and no other anchor. Your existing pf configuration
is left exactly as it was.
================================================================================
EOF
  exit 2
fi

if ! command -v pfctl >/dev/null 2>&1; then
  echo "error: pfctl not found; this script is macOS-only." >&2
  exit 2
fi

WORK="$(mktemp -d -t rc-partition)"
steps=0
failures=0
PIDS=()
NEXT_FD=10
PF_WAS_ENABLED=0
PF_TOKEN=""

pass() { steps=$((steps + 1)); printf 'PASS  %s\n' "$1"; }
fail() { steps=$((steps + 1)); failures=$((failures + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
info() { printf '      %s\n' "$1"; }

unpartition() {
  pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1
  # Remove the anchor reference we added to the main ruleset.
  if [[ -f "$WORK/pf.conf.orig" ]]; then
    pfctl -f "$WORK/pf.conf.orig" >/dev/null 2>&1
  fi
}

cleanup() {
  unpartition
  if [[ "$PF_WAS_ENABLED" -eq 0 ]]; then
    [[ -n "$PF_TOKEN" ]] && pfctl -X "$PF_TOKEN" >/dev/null 2>&1
  fi
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  sleep 0.5
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null; done
  pkill -f "$BIN" 2>/dev/null
  if [[ "${RC_KEEP_LOGS:-0}" == "1" ]]; then echo "logs kept in $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT INT TERM

wait_for() {
  local file="$1" pattern="$2" timeout="${3:-25}" from="${4:-1}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern"; then return 0; fi
    sleep 0.3
  done
  return 1
}
must_not_appear() { ! tail -n "+${3:-1}" "$1" 2>/dev/null | grep -q -- "$2"; }
lines_in() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

field() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, key = sys.argv[1:4]
for line in open(path):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == event and key in d:
        print(d[key]); break
PY
}

start_node() {
  local name="$1" role="$2" dir="$3"
  mkdir -p "$dir"
  mkfifo "$WORK/$name.in"
  env RC_ROLE="$role" RC_IDENTITY_DIR="$dir" RC_SERVER_URL="$SERVER_URL" \
      RC_CERT_PIN="$CERT_PIN" RC_DEVICE_LABEL="rc-part-$name" \
      RC_ICE_POLICY=relay \
      "$BIN" < "$WORK/$name.in" > "$WORK/$name.log" 2>&1 &
  PIDS+=("$!")
  eval "exec ${NEXT_FD}> \"$WORK/$name.in\""
  eval "FD_${name}=${NEXT_FD}"
  NEXT_FD=$((NEXT_FD + 1))
}
say() { local name="$1"; shift; local fdvar="FD_${name}"; echo "$*" >&"${!fdvar}"; }

partition_on() {
  printf 'block drop quick proto udp from any to %s\nblock drop quick proto udp from %s to any\n' \
    "$SERVER_HOST" "$SERVER_HOST" > "$WORK/anchor.rules"
  pfctl -a "$ANCHOR" -f "$WORK/anchor.rules" >/dev/null 2>&1
}
partition_off() { pfctl -a "$ANCHOR" -F rules >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
echo "== building rc-node"
(cd "$APP_DIR" && swift build --product rc-node 2>&1 | grep -v "XCTest paths\|xcrun:" | tail -2)
[[ -x "$BIN" ]] || { fail "build rc-node" "no binary at $BIN"; exit 1; }

echo "== preparing pf"
if pfctl -s info 2>/dev/null | head -1 | grep -q "Status: Enabled"; then
  PF_WAS_ENABLED=1
  info "pf was already enabled; it will be left enabled"
else
  PF_TOKEN="$(pfctl -E 2>&1 | awk '/Token/ {print $3}')"
  info "pf enabled for this run (token $PF_TOKEN); it will be disabled again on exit"
fi

# Add our anchor to the main ruleset without disturbing anything else.
pfctl -sr > "$WORK/pf.rules.orig" 2>/dev/null
cp /etc/pf.conf "$WORK/pf.conf.orig" 2>/dev/null || : > "$WORK/pf.conf.orig"
{ cat "$WORK/pf.conf.orig"; printf '\nanchor "%s"\n' "$ANCHOR"; } > "$WORK/pf.conf.rc"
if pfctl -f "$WORK/pf.conf.rc" >/dev/null 2>&1; then
  pass "pf anchor '$ANCHOR' installed (additive; the original ruleset is restored on exit)"
else
  fail "install the pf anchor" "pfctl -f failed"
  exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "== bringing up a real session, forced through the TURN relay"
start_node bootstrap host "$WORK/id-host"
wait_for "$WORK/bootstrap.log" '"event":"hello_ok"' 40 || { fail "host registers" "see $WORK/bootstrap.log"; exit 1; }
HOST_ID="$(field "$WORK/bootstrap.log" hello_ok deviceId)"
HOST_CODE="$(field "$WORK/bootstrap.log" ready accessCode)"
say bootstrap quit
sleep 2

start_node host host "$WORK/id-host"
start_node ctrl controller "$WORK/id-ctrl"
wait_for "$WORK/host.log" '"event":"hello_ok"' 40 || { fail "host authenticates" ""; exit 1; }
wait_for "$WORK/ctrl.log" '"event":"hello_ok"' 40 || { fail "controller authenticates" ""; exit 1; }

say ctrl "connect $HOST_ID $HOST_CODE remember"
if wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"connected"' 90 &&
   wait_for "$WORK/ctrl.log" '"allOpen":true,"event":"datachannel"' 30; then
  pass "session is live over the TURN relay (both data channels open)"
else
  fail "session goes live over TURN" "$(tail -5 "$WORK/ctrl.log")"
  exit 1
fi
say ctrl ping
wait_for "$WORK/ctrl.log" '"event":"pong"' 20 && info "relayed RTT confirmed"
echo

# ---------------------------------------------------------------------------
echo "== 1. ${SHORT_BLACKOUT}s UDP blackout: the session must SURVIVE"
MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
partition_on
info "UDP to/from $SERVER_HOST is blocked"
sleep "$SHORT_BLACKOUT"
partition_off
info "UDP restored"

if wait_for "$WORK/ctrl.log" '"event":"phase","phase":"reconnecting"' 30 "$MARK_C"; then
  pass "the UI went to Reconnecting, not Disconnected"
else
  fail "the blackout is detected as Reconnecting" \
       "$(tail -n "+$MARK_C" "$WORK/ctrl.log" | grep '"event":"phase"')"
fi
if wait_for "$WORK/ctrl.log" '"event":"ice_restart"' 30 "$MARK_C"; then
  pass "an ICE restart was started (3 s after ICE went disconnected)"
else
  fail "an ICE restart is started" "no ice_restart event"
fi
if must_not_appear "$WORK/ctrl.log" '"event":"access_code_required"' "$MARK_C"; then
  pass "the access code was NOT requested"
else
  fail "no access-code prompt" "$(tail -n "+$MARK_C" "$WORK/ctrl.log" | grep access_code)"
fi
if wait_for "$WORK/ctrl.log" '"event":"phase","phase":"live"' 90 "$MARK_C"; then
  pass "the session RECOVERED by itself and is live again"
else
  fail "the session recovers" "$(tail -n "+$MARK_C" "$WORK/ctrl.log" | tail -10)"
fi
MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl ping
if wait_for "$WORK/ctrl.log" '"event":"pong"' 30 "$MARK_C"; then
  pass "data flows again after the blackout"
else
  fail "data flows after recovery" "no pong"
fi
if must_not_appear "$WORK/ctrl.log" '"event":"phase","phase":"closed'; then
  pass "the session was never closed during the short blackout"
else
  fail "session survives the short blackout" "$(grep 'closed' "$WORK/ctrl.log")"
fi
echo

# ---------------------------------------------------------------------------
echo "== 2. ${LONG_BLACKOUT}s UDP blackout: the session must close CLEANLY"
MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
MARK_H=$(( $(lines_in "$WORK/host.log") + 1 ))
partition_on
info "UDP blocked; expecting ICE failed, then the 45 s grace window to expire"
sleep "$LONG_BLACKOUT"

if wait_for "$WORK/ctrl.log" '"event":"phase","phase":"closed' 5 "$MARK_C"; then
  pass "the controller closed the session after ICE failed + the grace window"
else
  fail "the session closes after a sustained blackout" \
       "$(tail -n "+$MARK_C" "$WORK/ctrl.log" | grep -E '"event":"(ice|phase)"' | tail -6)"
fi
partition_off
info "UDP restored"
sleep 8

# No stuck state: the peer connection is gone, the UI is back to a state the
# user can act on, and the client is NOT still trying to resume a dead session.
say ctrl status
sleep 2
STATUS_LINE="$(grep '"event":"status"' "$WORK/ctrl.log" | tail -1)"
if python3 - "$STATUS_LINE" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
ok = (not d.get("channels")) and d.get("sessionId", "") == "" and d.get("phase","").startswith("closed")
sys.exit(0 if ok else 1)
PY
then
  pass "no stuck state: no session id, no open channels, phase is closed"
else
  fail "no stuck state after the blackout" "status = $STATUS_LINE"
fi

# And the client must still be usable: a fresh connect works.
MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl "connect $HOST_ID $HOST_CODE"
if wait_for "$WORK/ctrl.log" '"event":"session"' 60 "$MARK_C"; then
  pass "a fresh session can be opened afterwards (the 1:1 slot was freed)"
else
  fail "a fresh session opens afterwards" "$(tail -n "+$MARK_C" "$WORK/ctrl.log" | tail -5)"
fi

say ctrl quit
say host quit
sleep 1

echo
echo "-----------------------------------------------------------------------"
echo "$((steps - failures))/$steps steps passed"
if [[ "$failures" -gt 0 ]]; then
  echo "PARTITION TEST FAILED"
  echo "logs: $WORK (re-run with RC_KEEP_LOGS=1 to keep them)"
  exit 1
fi
echo "PARTITION TEST PASSED"
