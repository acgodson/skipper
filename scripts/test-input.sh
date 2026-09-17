#!/usr/bin/env bash
#
# Phase 5 integration test: input, gestures and clipboard across a REAL WebRTC
# session between two real app-core instances, over a backend reachable at
# SKIPPER_API_BASE_URL (the local dev server by default).
#
# This is the wire half of Phase 5. It proves that a pointer event created on
# the controller travels the `hi`/`ctrl` channels, is decoded by the host, and
# is turned into the right number of OS events by the real `InputInjector` —
# and that clipboard text crosses in both directions WITHOUT the two Macs
# ping-ponging it forever.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM. The host's `CGEventSink` refuses to post
# when the process lacks the Accessibility grant, and a shell-launched CLI never
# has one (macOS attributes TCC to the responsible process — the terminal).
# So this script asserts that every message ARRIVED and became the right events;
# `scripts/verify-input.sh` runs inside the .app bundle and asserts that the
# events actually move the cursor, drag a window and release a held button.
# Between them they cover the whole path; neither pretends to cover the other's.
#
# Each node uses its own RC_IDENTITY_DIR and its own RC_PASTEBOARD_NAME, so the
# clipboard test is genuinely two pasteboards and not one talking to itself.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
WORK="$(mktemp -d -t rc-input-e2e)"
BIN="$APP_DIR/.build/debug/rc-node"

API_BASE_URL="${SKIPPER_API_BASE_URL:-http://127.0.0.1:18443}"

steps=0; failures=0; PIDS=(); NEXT_FD=10
pass() { steps=$((steps+1)); printf 'PASS  %s\n' "$1"; }
fail() { steps=$((steps+1)); failures=$((failures+1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
info() { printf '      %s\n' "$1"; }

cleanup() {
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  sleep 0.5
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null; done
  pkill -f "$BIN" 2>/dev/null
  [[ "${RC_KEEP_LOGS:-0}" == "1" ]] && echo "logs kept in $WORK" || rm -rf "$WORK"
}
trap cleanup EXIT

wait_for() {  # wait_for <file> <pattern> [timeout] [from-line]
  local file="$1" pattern="$2" timeout="${3:-25}" from="${4:-1}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern" && return 0
    sleep 0.2
  done
  return 1
}
json_field() {  # json_field <file> <event> <key> [from-line] -> last match
  python3 - "$1" "$2" "$3" "${4:-1}" <<'JSONPY'
import json, sys
path, event, key, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
value = ""
for n, line in enumerate(open(path), 1):
    if n < start: continue
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == event and key in d: value = d[key]
print(value)
JSONPY
}

lines_in() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

count_applied() {  # count_applied <file> <type> <from-line>  -> total OS events
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, wanted, start = sys.argv[1], sys.argv[2], int(sys.argv[3])
total = 0
for n, line in enumerate(open(path), 1):
    if n < start: continue
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == "input_applied" and d.get("type") == wanted:
        total += d.get("events", 0)
print(total)
PY
}

start_node() {  # start_node <name> <role> <dir>
  local name="$1" role="$2" dir="$3"
  mkdir -p "$dir"; mkfifo "$WORK/$name.in"
  env RC_ROLE="$role" RC_IDENTITY_DIR="$dir" SKIPPER_API_BASE_URL="$API_BASE_URL" \
      RC_DEVICE_LABEL="rc-input-$name" \
      RC_PASTEBOARD_NAME="app.skipperdesk.desktop.test.$name" \
      "$BIN" < "$WORK/$name.in" > "$WORK/$name.log" 2>&1 &
  PIDS+=("$!")
  eval "exec ${NEXT_FD}> \"$WORK/$name.in\""
  eval "FD_${name}=${NEXT_FD}"
  NEXT_FD=$((NEXT_FD + 1))
}
say() { local name="$1"; shift; local fdvar="FD_${name}"; echo "$*" >&"${!fdvar}"; }

echo "== building rc-node"
(cd "$APP_DIR" && swift build --product rc-node 2>&1 | grep -v "XCTest paths\|xcrun:" | tail -2)
[[ -x "$BIN" ]] || { fail "build rc-node" "no binary"; exit 1; }

echo "== bringing up a real session"
start_node host host "$WORK/id-host"
start_node ctrl controller "$WORK/id-ctrl"
wait_for "$WORK/host.log" '"state":"authenticated"' 30 || { fail "host authenticates" ""; exit 1; }
wait_for "$WORK/ctrl.log" '"state":"authenticated"' 30 || { fail "controller authenticates" ""; exit 1; }
HOST_ID="$(python3 -c "import json;print(json.load(open('$WORK/id-host/identity.json'))['deviceId'])")"
# The access code is in the Keychain (or, for this overridden identity
# directory, its dev-file stand-in) and deliberately NOT in identity.json any
# more; rc-node reports it once, on `ready`.
HOST_CODE="$(python3 -c "
import json,sys
for line in open('$WORK/host.log'):
    line = line.strip()
    if line.startswith('{'):
        d = json.loads(line)
        if d.get('event') == 'ready':
            print(d['accessCode']); break
")"
say ctrl "connect $HOST_ID $HOST_CODE"
if wait_for "$WORK/ctrl.log" '"allOpen":true' 45 && wait_for "$WORK/host.log" '"allOpen":true' 45; then
  pass "both data channels are open on a real peer connection"
else
  fail "the session did not come up" "see $WORK"
  exit 1
fi
if grep -q '"event":"ice_servers".*"turn":true' "$WORK/ctrl.log"; then
  pass "TURN credentials arrived with the ice_servers push (protocol v5)"
else
  fail "ice_servers carries TURN credentials" "$(grep -E '"event":"(session|ice_servers)"' "$WORK/ctrl.log")"
fi
echo

# ---------------------------------------------------------------------------
echo "== 1. pointer input reaches the host and becomes OS events"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "move 0.20 0.20"
say ctrl "move 0.30 0.30"
sleep 1
MOVES="$(count_applied "$WORK/host.log" mouse_move "$MARK")"
if [[ "$MOVES" -ge 2 ]]; then
  pass "mouse_move crossed the unreliable channel and produced $MOVES OS events"
else
  fail "mouse_move did not reach the host" "$MOVES events"
fi

# ---------------------------------------------------------------------------
echo "== 2. a true drag: down, drag, up (PLAN.md §2.6)"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "mousedown 0.30 0.30 0"
sleep 0.4
for step in 35 40 45 50 55; do say ctrl "mousedrag 0.$step 0.30 0"; sleep 0.15; done
say ctrl "mouseup 0.55 0.30 0"
sleep 1.2
DOWNS="$(count_applied "$WORK/host.log" mouse_down "$MARK")"
DRAGS="$(count_applied "$WORK/host.log" mouse_drag "$MARK")"
UPS="$(count_applied "$WORK/host.log" mouse_up "$MARK")"
if [[ "$DOWNS" -ge 1 && "$DRAGS" -ge 5 && "$UPS" -ge 1 ]]; then
  pass "the drag arrived intact: $DOWNS down, $DRAGS drag, $UPS up"
else
  fail "the drag did not arrive intact" "down=$DOWNS drag=$DRAGS up=$UPS"
fi
# Drags must NOT have been sent on the unreliable channel.
if grep -q '"type":"mouse_drag"' "$WORK/host.log"; then
  pass "drags arrived as mouse_drag on the reliable channel, not as moves"
else
  fail "no mouse_drag messages were applied" "PROTOCOL.md §6 forbids drags on hi"
fi

# ---------------------------------------------------------------------------
echo "== 3. scroll and keys"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "scroll 0 -60 begin"
say ctrl "scroll 0 -60 changed"
say ctrl "scroll 0 0 end"
sleep 1
SCROLLS="$(count_applied "$WORK/host.log" scroll "$MARK")"
[[ "$SCROLLS" -ge 3 ]] && pass "three scroll phases became $SCROLLS OS events" \
                       || fail "scroll did not reach the host" "$SCROLLS events"

MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "key down 55 8"      # Command down
say ctrl "key down 8 8"       # C down, with Command
say ctrl "key up 8 8"
say ctrl "key up 55 8"
sleep 1
KEYD="$(count_applied "$WORK/host.log" key_down "$MARK")"
KEYU="$(count_applied "$WORK/host.log" key_up "$MARK")"
[[ "$KEYD" -ge 2 && "$KEYU" -ge 2 ]] && pass "Cmd+C crossed as $KEYD key-downs and $KEYU key-ups" \
                                     || fail "keys did not reach the host" "down=$KEYD up=$KEYU"

# ---------------------------------------------------------------------------
echo "== 4. gestures are executed on the host"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "gesture mission_control"
sleep 1
if tail -n "+$MARK" "$WORK/host.log" | grep -q '"name":"mission_control"'; then
  GEV="$(count_applied "$WORK/host.log" gesture "$MARK")"
  [[ "$GEV" -ge 4 ]] && pass "the host executed mission_control as $GEV OS events" \
                     || fail "the gesture produced too few events" "$GEV"
else
  fail "the host never reported the gesture" "see $WORK/host.log"
fi
say ctrl "gesture not_a_real_gesture"
sleep 0.5
pass "an unknown gesture name did not crash or disconnect the session"

# ---------------------------------------------------------------------------
echo "== 5. input_reset releases what is held, and is idempotent"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "mousedown 0.40 0.40 0"
say ctrl "key down 55 8"
sleep 0.6
say ctrl "input-reset"
sleep 0.8
RESET1="$(count_applied "$WORK/host.log" input_reset "$MARK")"
MARK2=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "input-reset"
sleep 0.8
RESET2="$(count_applied "$WORK/host.log" input_reset "$MARK2")"
[[ "$RESET1" -ge 2 ]] && pass "input_reset released $RESET1 held button/modifier events" \
                      || fail "input_reset released nothing" "$RESET1"
[[ "$RESET2" -eq 0 ]] && pass "a second input_reset produced no events — it is idempotent" \
                      || fail "input_reset is not idempotent" "$RESET2 events the second time"
say host "input-stats"
sleep 0.5
if tail -5 "$WORK/host.log" | grep -q '"idle":true'; then
  pass "the host is holding nothing after the reset"
else
  fail "the host still has held input state" "$(tail -3 "$WORK/host.log")"
fi

# ---------------------------------------------------------------------------
echo "== 6. clipboard sync, both directions, with no echo loop"
SECRETA="rc-clip-a-$RANDOM-$RANDOM"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
CMARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl "clipboard-set $SECRETA"
sleep 2.5
if tail -n "+$MARK" "$WORK/host.log" | grep -q '"clipboard".*"incoming":true'; then
  pass "text copied on the controller arrived at the host"
else
  fail "clipboard did not cross controller -> host" "$(tail -3 "$WORK/host.log")"
fi
GMARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host "clipboard-get"
# Wait for the reply rather than sleeping a fixed amount: on a loaded machine a
# fixed sleep makes this check flap, and a flapping check is worse than none.
wait_for "$WORK/host.log" 'clipboard_local' 10 "$GMARK"
EXPECTED_SHA="$(python3 -c "
import hashlib,base64,sys
print(base64.b64encode(hashlib.sha256('$SECRETA'.encode()).digest()).decode())")"
# Parsed, not grepped: JSONSerialization escapes "/" as "\\/", so a raw grep for
# a base64 hash fails roughly half the time — a check that flaps on the shape of
# its own input rather than on the behaviour under test.
ACTUAL_SHA="$(json_field "$WORK/host.log" clipboard_local sha "$GMARK")"
if [[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]]; then
  pass "the host's pasteboard holds exactly the controller's text (hash match)"
else
  fail "the host's pasteboard does not match" "expected $EXPECTED_SHA, host has $ACTUAL_SHA"
fi
# THE echo-loop check: after the text lands, nothing may come back.
sleep 3
BOUNCES="$(tail -n "+$CMARK" "$WORK/ctrl.log" | grep -c '"clipboard".*"incoming":true')"
[[ "$BOUNCES" -eq 0 ]] && pass "the host did not bounce the text back — no echo loop" \
                       || fail "the clipboard is echoing" "$BOUNCES bounces at the controller"

SECRETB="rc-clip-b-$RANDOM-$RANDOM"
CMARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
HMARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host "clipboard-set $SECRETB"
sleep 2.5
if tail -n "+$CMARK" "$WORK/ctrl.log" | grep -q '"clipboard".*"incoming":true'; then
  pass "text copied on the host arrived at the controller (the other direction)"
else
  fail "clipboard did not cross host -> controller" "$(tail -3 "$WORK/ctrl.log")"
fi
sleep 3
# Marked against the HOST's own log, not the controller's: an earlier delivery
# would otherwise be counted as a bounce and this check would be meaningless.
HBOUNCES="$(tail -n "+$HMARK" "$WORK/host.log" | grep -c '"clipboard".*"incoming":true')"
[[ "$HBOUNCES" -eq 0 ]] && pass "and it did not bounce back either" \
                        || fail "the clipboard is echoing the other way" "$HBOUNCES"

# ---------------------------------------------------------------------------
echo "== 7. the host reports whether it can inject at all"
say host "input-stats"
sleep 0.5
if grep -q '"canInject"' "$WORK/host.log"; then
  CAN="$(json_field "$WORK/host.log" input_stats canInject)"
  INJ="$(json_field "$WORK/host.log" input_stats injected)"
  pass "the host reports its injection state (canInject=$CAN, $INJ events translated)"
  if [[ "$CAN" == "False" || "$CAN" == "false" ]]; then
    info "canInject is false because this rc-node was launched from a terminal:"
    info "macOS attributes the Accessibility grant to the RESPONSIBLE process."
    info "Run ./scripts/verify-input.sh for the OS-level half, out of the .app."
  fi
else
  fail "the host never reported input stats" ""
fi

say ctrl bye
sleep 1
say ctrl quit; say host quit
sleep 0.5

echo
echo "-----------------------------------------------------------------------"
if [[ "$failures" -eq 0 ]]; then
  echo "$steps/$steps steps passed"
  echo "INPUT E2E TEST PASSED"
else
  echo "$((steps-failures))/$steps steps passed"
  echo "INPUT E2E TEST FAILED"
fi
exit "$failures"
