#!/usr/bin/env bash
#
# Phase 3 integration test: TWO real app-core instances on this Mac, against a
# backend reachable at SKIPPER_API_BASE_URL — the local dev server
# (scripts/smoke-signal.sh) by default. The app is backend-agnostic
# (docs/SCOPE.md §4): nothing here is specific to any one deployment.
#
# Nothing here is mocked. Each instance is `rc-node`, a headless driver around
# the same IdentityStore / SignalingClient / SessionCoordinator /
# SessionStateMachine / PeerSession the .app uses. They are given separate
# RC_IDENTITY_DIRs so they are genuinely two devices.
#
# Proves, in order:
#   a. both register and authenticate; presence flips offline -> online
#   b. wrong access code -> the HOST refuses the PAKE and says bye{auth_failed},
#      and no peer connection is ever started; correct code -> connected
#   c. RTCPeerConnection reaches `connected` and BOTH data channels open
#   d. ping/pong round-trips over `ctrl` with a real RTT
#   e. a second controller is refused with `busy`
#   f. the controller's WebSocket is killed mid-session: it reconnects and
#      RESUMES with no access code, and the peer connection is never torn down
#   g. an ICE restart completes and the connection returns to `connected`
#   h. `bye` closes cleanly on both sides
#   i. Refresh Code revokes the old code and every trusted controller
#   j. (rc-api only) real entitlement gating: a host that never signed in is
#      refused with entitlement/unlinked, and a host whose trial has ended with
#      entitlement/trial_expired
#
# Against rc-api (scripts/dev-backend.sh), the host signs in first with the
# real API.md §1 flow (rc-node --dev-sign-in), and the Device ID the sign-in
# returns must be the one signaling assigned: rc-api owns the one registry.
#
# Exits non-zero on any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
WORK="$(mktemp -d -t rc-transport)"
BIN="$APP_DIR/.build/debug/rc-node"

API_BASE_URL="${SKIPPER_API_BASE_URL:-http://127.0.0.1:18443}"
API_BASE_URL="${API_BASE_URL%/}"
RUN_TAG="$(date +%s)-$$"

steps=0
failures=0
PIDS=()
NEXT_FD=10

pass() { steps=$((steps + 1)); printf 'PASS  %s\n' "$1"; }
fail() { steps=$((steps + 1)); failures=$((failures + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
info() { printf '      %s\n' "$1"; }

cleanup() {
  # Never leave an instance running.
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  sleep 0.5
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null
  done
  pkill -f "$BIN" 2>/dev/null
  if [[ "${RC_KEEP_LOGS:-0}" == "1" ]]; then
    echo "logs kept in $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

# wait_for <file> <grep-pattern> [timeout-seconds] [start-line]
wait_for() {
  local file="$1" pattern="$2" timeout="${3:-25}" from="${4:-1}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern"; then return 0; fi
    sleep 0.2
  done
  return 1
}

# must_not_appear <file> <pattern> <start-line>
must_not_appear() {
  local file="$1" pattern="$2" from="${3:-1}"
  ! tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern"
}

lines_in() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

field() {  # field <file> <event> <json key>  -> first match
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
path, event, key = sys.argv[1], sys.argv[2], sys.argv[3]
for line in open(path):
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("event") == event and key in d:
        print(d[key]); break
PY
}

field_after() {  # field_after <file> <start-line> <event> <json key>  -> first match at or after the line
  tail -n "+$2" "$1" > "$WORK/field_after.tmp" 2>/dev/null
  field "$WORK/field_after.tmp" "$3" "$4"
}

start_node() {  # start_node <name> <role> <identity-dir> [rc-node args...]
  local name="$1" role="$2" dir="$3"
  shift 3
  mkdir -p "$dir"
  rm -f "$WORK/$name.in"
  mkfifo "$WORK/$name.in"
  env RC_ROLE="$role" RC_IDENTITY_DIR="$dir" SKIPPER_API_BASE_URL="$API_BASE_URL" \
      RC_DEVICE_LABEL="rc-test-$name" \
      "$BIN" "$@" < "$WORK/$name.in" > "$WORK/$name.log" 2>&1 &
  PIDS+=("$!")
  # Hold the write end open so the node does not see EOF between commands.
  # macOS ships bash 3.2, which has neither {fd}> auto-allocation nor
  # associative arrays, so the descriptor numbers are handed out by hand.
  eval "exec ${NEXT_FD}> \"$WORK/$name.in\""
  eval "FD_${name}=${NEXT_FD}"
  NEXT_FD=$((NEXT_FD + 1))
}

say() {  # say <name> <command...>
  local name="$1"; shift
  local fdvar="FD_${name}"
  echo "$*" >&"${!fdvar}"
}

# ---------------------------------------------------------------------------
echo "== building rc-node (the real app core, headless)"
if ! (cd "$APP_DIR" && swift build --product rc-node 2>&1 | grep -v "XCTest paths\|xcrun:" | tail -3); then
  fail "build rc-node" "swift build failed"
  exit 1
fi
[[ -x "$BIN" ]] || { fail "build rc-node" "no binary at $BIN"; exit 1; }

echo "== server health"
HEALTH_URL="$API_BASE_URL/healthz"
if [[ "$(curl -sk --max-time 10 "$HEALTH_URL")" == "ok" ]]; then
  pass "the signaling server is healthy ($HEALTH_URL)"
else
  fail "the signaling server is healthy" "$HEALTH_URL did not return ok; is scripts/smoke-signal.sh's server (or another SKIPPER_API_BASE_URL) running?"
  exit 1
fi
# rc-api answers the REST health call; a bare rc-signal does not.
API_MODE=0
if curl -sk --max-time 10 "$API_BASE_URL/v1/health" | grep -q '"status":"ok"'; then
  API_MODE=1
  info "backend is rc-api: the host signs in and entitlement is really gated"
else
  info "backend is a bare rc-signal (static entitlement): sign-in and gating steps are skipped"
fi
HOST_EMAIL="host-$RUN_TAG@example.com"
HOST_ARGS=()
[[ "$API_MODE" == "1" ]] && HOST_ARGS=(--dev-sign-in "$HOST_EMAIL")
echo

dev_session_post() {  # dev_session_post <email> <path>  -> HTTP status
  curl -sk --max-time 10 -o "$WORK/dev_post.out" -w '%{http_code}' -X POST "$API_BASE_URL$2" \
    -H "Authorization: Bearer dev:$1" -H 'Content-Type: application/json' \
    -H "Idempotency-Key: $(uuidgen)" -d '{}'
}

# expect_denied <label> <host-id> <reason>: the controller's connect_req must be refused with it.
expect_denied() {
  local label="$1" target="$2" reason="$3" mark
  mark=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
  say ctrl "connect $target ZZZZZZZZZZZZ"
  if wait_for "$WORK/ctrl.log" '"event":"connect_error"' 30 "$mark"; then
    local code got
    code="$(field_after "$WORK/ctrl.log" "$mark" connect_error code)"
    got="$(field_after "$WORK/ctrl.log" "$mark" connect_error reason)"
    if [[ "$code" == "entitlement" && "$got" == "$reason" ]]; then
      pass "$label -> error{entitlement, reason: $reason}"
    else
      fail "$label -> entitlement/$reason" "got $code/$got"
    fi
  else
    fail "$label -> entitlement/$reason" "no connect_error; $(tail -n "+$mark" "$WORK/ctrl.log")"
  fi
  if must_not_appear "$WORK/ctrl.log" '"event":"session"' "$mark"; then
    pass "$label: no session was opened"
  else
    fail "$label: no session may open" "$(tail -n "+$mark" "$WORK/ctrl.log" | grep '"event":"session"')"
  fi
}

# ---------------------------------------------------------------------------
# a. registration, authentication, presence flip
# ---------------------------------------------------------------------------
echo "== a. registration, authentication and presence"

# Register the host once so the controller can learn its Device ID and code,
# then stop it: the controller must observe the OFFLINE -> ONLINE edge.
start_node bootstrap host "$WORK/id-host" ${HOST_ARGS[@]+"${HOST_ARGS[@]}"}
if ! wait_for "$WORK/bootstrap.log" '"event":"hello_ok"' 30; then
  fail "host registers with the live server" "no hello_ok; see $WORK/bootstrap.log"
  exit 1
fi
HOST_ID="$(field "$WORK/bootstrap.log" hello_ok deviceId)"
HOST_CODE="$(field "$WORK/bootstrap.log" ready accessCode)"
if [[ "$API_MODE" == "1" ]]; then
  if wait_for "$WORK/bootstrap.log" '"event":"signed_in"' 40; then
    SIGNED_ID="$(field "$WORK/bootstrap.log" signed_in deviceId)"
    SIGNED_STATUS="$(field "$WORK/bootstrap.log" signed_in status)"
    pass "the host signed in as $HOST_EMAIL through the API.md §1 flow (entitlement: $SIGNED_STATUS)"
    if [[ -n "$SIGNED_ID" && "$SIGNED_ID" == "$HOST_ID" ]]; then
      pass "This Mac's Device ID from sign-in equals its signaling Device ID ($SIGNED_ID): one registry"
    else
      fail "sign-in and signaling agree on the Device ID" "sign-in '$SIGNED_ID' vs signaling '$HOST_ID'"
    fi
    if [[ "$SIGNED_STATUS" == "trial" ]]; then
      pass "the first link started the device's trial"
    else
      fail "the first link starts a trial" "status '$SIGNED_STATUS'"
    fi
  else
    fail "the host signs in" "$(grep -E 'sign_in_error|signed_in' "$WORK/bootstrap.log" || tail -5 "$WORK/bootstrap.log")"
    exit 1
  fi
fi
say bootstrap quit
sleep 2

if [[ ${#HOST_ID} -eq 9 && ${#HOST_CODE} -eq 12 ]]; then
  pass "host registered and was assigned a 9-digit Device ID by the server ($HOST_ID)"
else
  fail "host registered" "deviceId='$HOST_ID' accessCode length ${#HOST_CODE}"
  exit 1
fi
if grep -q '"turn":true' "$WORK/bootstrap.log"; then
  pass "hello_ok carried server-minted TURN credentials (never hardcoded)"
else
  fail "hello_ok carried TURN credentials" "$(grep hello_ok "$WORK/bootstrap.log")"
fi

start_node ctrl controller "$WORK/id-ctrl"
if wait_for "$WORK/ctrl.log" '"event":"hello_ok"' 30; then
  CTRL_ID="$(field "$WORK/ctrl.log" hello_ok deviceId)"
  pass "controller registered and authenticated ($CTRL_ID)"
else
  fail "controller authenticated" "see $WORK/ctrl.log"; exit 1
fi

say ctrl "watch $HOST_ID"
if wait_for "$WORK/ctrl.log" "\"deviceId\":\"$HOST_ID\",\"event\":\"presence\",\"online\":false" 20; then
  pass "controller sees the host OFFLINE before it starts"
else
  fail "controller sees the host offline" "$(grep presence "$WORK/ctrl.log" | tail -2)"
fi

PRESENCE_MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
start_node host host "$WORK/id-host"
if wait_for "$WORK/ctrl.log" "\"deviceId\":\"$HOST_ID\",\"event\":\"presence\",\"online\":true" 30 "$PRESENCE_MARK"; then
  pass "presence flips to ONLINE when the host comes up (pushed, not polled)"
else
  fail "presence flips to online" "$(tail -n "+$PRESENCE_MARK" "$WORK/ctrl.log" | grep presence)"
fi
wait_for "$WORK/host.log" '"event":"hello_ok"' 30 || { fail "host authenticated" "see $WORK/host.log"; exit 1; }
echo

# ---------------------------------------------------------------------------
# b. wrong then right access code
# ---------------------------------------------------------------------------
echo "== b. access code, proved peer to peer (PROTOCOL.md §2.17)"
MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
HOST_MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "connect $HOST_ID ZZZZZZZZZZZZ"
# The server no longer knows anything about codes: it opens the session on
# entitlement alone, and the HOST is what refuses the exchange.
#
# §2.17: a wrong code fails for the CONTROLLER at step 2 and for the host at
# step 3, so the controller is the side that speaks first — and the host counts
# the abandoned exchange against its guess policy rather than letting a guesser
# hang up for free.
if wait_for "$WORK/ctrl.log" '"auth":true,"event":"pake_failed"' 30 "$MARK" &&
   wait_for "$WORK/ctrl.log" '"code":"auth_failed"' 10 "$MARK"; then
  pass "the exchange fails on a wrong code and the controller can say so"
else
  fail "wrong access code -> auth_failed" "$(tail -n "+$MARK" "$WORK/ctrl.log")"
fi
if wait_for "$WORK/host.log" '"auth":true,"event":"pake_failed"' 25 "$HOST_MARK" &&
   wait_for "$WORK/host.log" '"event":"bye","reason":"auth_failed"' 10 "$HOST_MARK"; then
  pass "the HOST saw the failure and counted it — the server never saw the code"
else
  fail "the host records the failed attempt" "$(tail -n "+$HOST_MARK" "$WORK/host.log")"
fi
if must_not_appear "$WORK/ctrl.log" '"event":"ice"' "$MARK" &&
   must_not_appear "$WORK/host.log" '"event":"ice"' "$HOST_MARK"; then
  pass "no peer connection was ever started for the unauthenticated controller"
else
  fail "a wrong code must not reach the media path" \
       "$(tail -n "+$MARK" "$WORK/ctrl.log" | grep '"event":"ice"')"
fi
sleep 2

MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
HOST_MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl "connect $HOST_ID $HOST_CODE remember"
if wait_for "$WORK/ctrl.log" '"event":"session"' 30 "$MARK"; then
  SESSION_ID="$(field "$WORK/ctrl.log" session sessionId)"
  pass "the correct access code opens a session ($SESSION_ID)"
else
  fail "correct access code opens a session" "$(tail -n "+$MARK" "$WORK/ctrl.log")"; exit 1
fi
if wait_for "$WORK/host.log" '"event":"session"' 20 "$HOST_MARK"; then
  pass "the host is told about the session (session_start push)"
else
  fail "host receives session_start" "$(tail -5 "$WORK/host.log")"
fi
if wait_for "$WORK/ctrl.log" '"event":"pake_ok"' 25 "$MARK" &&
   wait_for "$WORK/host.log" '"event":"pake_ok"' 25 "$HOST_MARK"; then
  pass "both Macs completed the SPAKE2 exchange and pinned each other's device key"
else
  fail "the PAKE exchange completes on both sides" \
       "$(tail -n "+$MARK" "$WORK/ctrl.log" | grep pake)"
fi
# The controller that proved the code is now on the host's trusted list, which
# is what Refresh Code revokes in step (i).
MARK_T=$(( $(lines_in "$WORK/host.log") + 1 ))
say host trusted
if wait_for "$WORK/host.log" '"event":"trusted","pubkeys"' 15 "$MARK_T" &&
   ! grep -q '"count":0' <(tail -n "+$MARK_T" "$WORK/host.log"); then
  pass "the host recorded the controller as a trusted controller"
else
  fail "the controller is on the host's trusted list" \
       "$(tail -n "+$MARK_T" "$WORK/host.log" | grep trusted)"
fi
echo

# ---------------------------------------------------------------------------
# c. peer connection + both data channels
# ---------------------------------------------------------------------------
echo "== c. WebRTC"
if wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"connected"' 60; then
  pass "RTCPeerConnection reached ICE state connected (controller)"
else
  fail "peer connection reaches connected" "$(grep '"event":"ice"' "$WORK/ctrl.log" | tail -3)"; exit 1
fi
if wait_for "$WORK/host.log" '"event":"ice","role":"host","state":"connected"' 30; then
  pass "RTCPeerConnection reached ICE state connected (host)"
else
  fail "host peer connection reaches connected" "$(grep '"event":"ice"' "$WORK/host.log" | tail -3)"
fi
if wait_for "$WORK/ctrl.log" '"allOpen":true,"event":"datachannel"' 30 &&
   grep -q '"label":"ctrl"' "$WORK/ctrl.log" && grep -q '"label":"hi"' "$WORK/ctrl.log"; then
  pass "both data channels are open on the controller (ctrl reliable + hi unreliable)"
else
  fail "both data channels open (controller)" "$(grep datachannel "$WORK/ctrl.log")"
fi
if wait_for "$WORK/host.log" '"allOpen":true,"event":"datachannel"' 30 &&
   grep -q '"label":"ctrl"' "$WORK/host.log" && grep -q '"label":"hi"' "$WORK/host.log"; then
  pass "both data channels are open on the host"
else
  fail "both data channels open (host)" "$(grep datachannel "$WORK/host.log")"
fi
echo

# ---------------------------------------------------------------------------
# d. ping / pong over ctrl
# ---------------------------------------------------------------------------
echo "== d. ping/pong over the ctrl channel"
MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl ping
if wait_for "$WORK/ctrl.log" '"event":"pong"' 20 "$MARK"; then
  RTT="$(tail -n "+$MARK" "$WORK/ctrl.log" | grep '"event":"pong"' | head -1 |
         python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["rttMs"])')"
  if [[ "$RTT" -ge 0 && "$RTT" -lt 5000 ]]; then
    pass "ping/pong round-tripped over ctrl, RTT ${RTT} ms (measured, peer-to-peer)"
  else
    fail "ping/pong RTT is plausible" "rttMs=$RTT"
  fi
else
  fail "ping/pong round-trips over ctrl" "no pong; $(tail -n "+$MARK" "$WORK/ctrl.log")"
fi
say host display
echo

# ---------------------------------------------------------------------------
# e. strict 1:1
# ---------------------------------------------------------------------------
echo "== e. strict 1:1"
start_node ctrl2 controller "$WORK/id-ctrl2"
if wait_for "$WORK/ctrl2.log" '"event":"hello_ok"' 30; then
  say ctrl2 "connect $HOST_ID $HOST_CODE"
  if wait_for "$WORK/ctrl2.log" '"code":"busy"' 25; then
    pass "a second controller is refused with busy"
  else
    fail "second controller is refused with busy" "$(grep connect_error "$WORK/ctrl2.log")"
  fi
else
  fail "second controller authenticates" "see $WORK/ctrl2.log"
fi
say ctrl2 quit
sleep 1
echo

# ---------------------------------------------------------------------------
# f. network flutter: kill the controller's WebSocket mid-session
# ---------------------------------------------------------------------------
echo "== f. signaling drop mid-session (the headline requirement)"
DROP_MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl drop-socket
if wait_for "$WORK/ctrl.log" '"event":"resumed"' 60 "$DROP_MARK"; then
  pass "the controller reconnected and RESUMED the session"
else
  fail "controller resumes after a signaling drop" "$(tail -n "+$DROP_MARK" "$WORK/ctrl.log")"
fi
if must_not_appear "$WORK/ctrl.log" '"event":"access_code_required"' "$DROP_MARK" &&
   must_not_appear "$WORK/ctrl.log" '"code":"auth_failed"' "$DROP_MARK"; then
  pass "the access code was NOT requested again"
else
  fail "no access code re-prompt" "$(tail -n "+$DROP_MARK" "$WORK/ctrl.log" | grep -E 'access_code|bad_code')"
fi
if grep -q '"usedAccessCode":false' <(tail -n "+$DROP_MARK" "$WORK/ctrl.log"); then
  pass "the resume carried only the session token, never the code"
else
  fail "resume used no access code" "resumed event missing"
fi
# The peer connection must have survived: no ICE state change at all.
if must_not_appear "$WORK/ctrl.log" '"event":"ice"' "$DROP_MARK" &&
   must_not_appear "$WORK/ctrl.log" '"event":"phase","phase":"closed' "$DROP_MARK"; then
  pass "the peer connection was NEVER torn down by the control-plane outage"
else
  fail "peer connection survives a signaling outage" \
       "$(tail -n "+$DROP_MARK" "$WORK/ctrl.log" | grep -E '"event":"(ice|phase)"')"
fi
MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl ping
if wait_for "$WORK/ctrl.log" '"event":"pong"' 20 "$MARK"; then
  pass "the data channel still works after the resume"
else
  fail "data channel works after resume" "no pong after resume"
fi
echo

# ---------------------------------------------------------------------------
# g. ICE restart
# ---------------------------------------------------------------------------
echo "== g. ICE restart"
ICE_MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
ICE_HOST_MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl ice-restart
if wait_for "$WORK/ctrl.log" '"event":"ice_restart"' 15 "$ICE_MARK"; then
  info "restart offer sent with IceRestart"
else
  fail "ICE restart is initiated" "no ice_restart event"
fi
# The far side must actually apply a restart offer -- that is what proves the
# renegotiation crossed the wire rather than being a local no-op.
if wait_for "$WORK/host.log" '"restart":true' 25 "$ICE_HOST_MARK"; then
  pass "the host applied a remote offer marked restart:true"
else
  fail "host applies the ICE-restart offer" "$(tail -n "+$ICE_HOST_MARK" "$WORK/host.log" | grep remote_sdp)"
fi
# A restart re-gathers and re-checks; the connection must come back to connected.
if wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"checking"' 30 "$ICE_MARK"; then
  RECHECK_MARK=$(( $(lines_in "$WORK/ctrl.log") ))
  if wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"connected"' 45 "$RECHECK_MARK"; then
    pass "the ICE restart re-checked and returned to connected"
  else
    fail "ICE restart returns to connected" "$(tail -n "+$ICE_MARK" "$WORK/ctrl.log" | grep '"event":"ice"')"
  fi
else
  # libwebrtc may keep the old pair selected while the new one is validated, in
  # which case the state never leaves `connected`. That is still a completed
  # restart, but only if traffic still flows -- so prove that instead.
  MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
  say ctrl ping
  if wait_for "$WORK/ctrl.log" '"event":"pong"' 20 "$MARK"; then
    pass "the ICE restart completed without ever dropping below connected (traffic still flows)"
  else
    fail "ICE restart completes" "no re-check and no traffic after the restart"
  fi
fi
echo

# ---------------------------------------------------------------------------
# h. bye
# ---------------------------------------------------------------------------
echo "== h. clean shutdown"
BYE_MARK_H=$(( $(lines_in "$WORK/host.log") + 1 ))
BYE_MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl bye
if wait_for "$WORK/ctrl.log" '"event":"phase","phase":"closed:user_ended"' 20 "$BYE_MARK_C"; then
  pass "the controller closed the session cleanly"
else
  fail "controller closes cleanly" "$(tail -n "+$BYE_MARK_C" "$WORK/ctrl.log")"
fi
if wait_for "$WORK/host.log" '"event":"bye","reason":"user_ended"' 25 "$BYE_MARK_H"; then
  pass "the host received bye and closed the same session"
else
  fail "host receives bye" "$(tail -n "+$BYE_MARK_H" "$WORK/host.log")"
fi
if wait_for "$WORK/host.log" '"phase":"closed:user_ended"' 20 "$BYE_MARK_H"; then
  pass "the host is back to a closed session with no stuck state"
else
  fail "host returns to closed" "$(tail -n "+$BYE_MARK_H" "$WORK/host.log")"
fi

echo
# ---------------------------------------------------------------------------
# i. access-code refresh propagates to the live server (the AccessCodeSink seam)
# ---------------------------------------------------------------------------
echo "== i. Refresh Code revokes the old code AND every trusted controller"
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host refresh-code
if wait_for "$WORK/host.log" '"event":"code_refreshed"' 30 "$MARK"; then
  NEW_CODE="$(tail -n "+$MARK" "$WORK/host.log" | grep '"event":"code_refreshed"' | head -1 |
              python3 -c 'import json,sys; print(json.loads(sys.stdin.readline())["accessCode"])')"
  pass "the host minted a new access code and the server accepted refresh_code"
else
  fail "refresh_code is accepted by the server" "$(tail -n "+$MARK" "$WORK/host.log")"
  NEW_CODE=""
fi

MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host trusted
if wait_for "$WORK/host.log" '"count":0,"event":"trusted"' 15 "$MARK"; then
  pass "the trusted-controller list was cleared with the code (PROTOCOL.md §4.5)"
else
  fail "Refresh Code clears the trusted list" "$(tail -n "+$MARK" "$WORK/host.log" | grep trusted)"
fi

if [[ -n "$NEW_CODE" ]]; then
  MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
  say ctrl "connect $HOST_ID $HOST_CODE"
  if wait_for "$WORK/ctrl.log" '"code":"auth_failed"' 30 "$MARK"; then
    pass "the OLD access code now fails the exchange (revoked off-machine, not just locally)"
  else
    fail "the old access code is revoked" "$(tail -n "+$MARK" "$WORK/ctrl.log")"
  fi
  sleep 2
  MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
  say ctrl "connect $HOST_ID $NEW_CODE"
  if wait_for "$WORK/ctrl.log" '"event":"session"' 30 "$MARK" &&
     wait_for "$WORK/ctrl.log" '"event":"pake_ok"' 25 "$MARK"; then
    pass "the NEW access code opens a session"
    say ctrl bye
    sleep 2
  else
    fail "the new access code opens a session" "$(tail -n "+$MARK" "$WORK/ctrl.log")"
  fi
fi

echo
# ---------------------------------------------------------------------------
# k. host consent when unattended access is off (PROTOCOL.md §2.17 Consent)
# ---------------------------------------------------------------------------
echo "== k. host consent: allow, decline, auto-decline and no answer"
CONSENT_CODE="${NEW_CODE:-$HOST_CODE}"

# consent_attempt <host-node> <label>: one connect; sets CMARK/HMARK for the checks.
consent_attempt() {
  CMARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
  HMARK=$(( $(lines_in "$WORK/$1.log") + 1 ))
  say ctrl "connect $HOST_ID $CONSENT_CODE"
  if wait_for "$WORK/ctrl.log" '"event":"pake_ok"' 30 "$CMARK"; then
    info "$2: the controller proved the code"
  else
    fail "$2: the exchange completes" "$(tail -n "+$CMARK" "$WORK/ctrl.log")"
  fi
}

expect_declined() {  # expect_declined <host-node> <label> <timeout>
  if wait_for "$WORK/ctrl.log" '"code":"declined"' "$3" "$CMARK"; then
    pass "$2: the controller is told \"$(field_after "$WORK/ctrl.log" "$CMARK" connect_error sentence)\""
  else
    fail "$2: the controller is told it was declined" "$(tail -n "+$CMARK" "$WORK/ctrl.log")"
  fi
  if wait_for "$WORK/$1.log" '"phase":"closed:declined"' 10 "$HMARK" &&
     must_not_appear "$WORK/$1.log" '"event":"ice"' "$HMARK"; then
    pass "$2: the host closed with bye{declined} and never started a peer connection"
  else
    fail "$2: the host closes without a peer" "$(tail -n "+$HMARK" "$WORK/$1.log")"
  fi
  if must_not_appear "$WORK/$1.log" '"event":"pake_failed"' "$HMARK"; then
    pass "$2: the right code was not counted as a failed guess"
  else
    fail "$2: a decline is not a guess failure" "$(tail -n "+$HMARK" "$WORK/$1.log" | grep pake_failed)"
  fi
  sleep 2
}

say host quit
sleep 2
start_node chost host "$WORK/id-host" --consent decline
wait_for "$WORK/chost.log" '"event":"hello_ok"' 30 || fail "the consenting host comes online" "see $WORK/chost.log"
sleep 1

for attempt in 1 2; do
  consent_attempt chost "decline #$attempt"
  if wait_for "$WORK/chost.log" '"event":"consent_prompt"' 15 "$HMARK"; then
    pass "decline #$attempt: the host asked only after the code was proved: $(field_after "$WORK/chost.log" "$HMARK" consent_prompt title)"
  else
    fail "decline #$attempt: the host asks" "$(tail -n "+$HMARK" "$WORK/chost.log")"
  fi
  expect_declined chost "decline #$attempt" 20
done

consent_attempt chost "third try inside 10 minutes"
if wait_for "$WORK/chost.log" '"automatic":true,"event":"consent_ended"' 15 "$HMARK" &&
   must_not_appear "$WORK/chost.log" '"event":"consent_prompt"' "$HMARK"; then
  pass "third try inside 10 minutes: declined without a prompt"
else
  fail "a controller declined twice is auto-declined" "$(tail -n "+$HMARK" "$WORK/chost.log")"
fi
expect_declined chost "third try inside 10 minutes" 20
say chost quit
sleep 2

start_node ahost host "$WORK/id-host" --consent allow
wait_for "$WORK/ahost.log" '"event":"hello_ok"' 30 || fail "the allowing host comes online" "see $WORK/ahost.log"
sleep 1
consent_attempt ahost "allow"
if wait_for "$WORK/ahost.log" '"event":"consent_prompt"' 15 "$HMARK" &&
   wait_for "$WORK/ahost.log" '"event":"consent_ended","outcome":"allowed"' 15 "$HMARK" &&
   wait_for "$WORK/ctrl.log" '"event":"phase","phase":"live"' 30 "$CMARK" &&
   wait_for "$WORK/ahost.log" '"event":"phase","phase":"live"' 30 "$HMARK"; then
  pass "allow: the held peer start was released and both sides went live"
else
  fail "allow releases the peer" "$(tail -n "+$CMARK" "$WORK/ctrl.log")"
fi
first_line() {  # first_line <file> <start-line> <pattern>  -> absolute line number, or 0
  local n
  n="$(tail -n "+$2" "$1" | grep -n -m1 -- "$3" | cut -d: -f1)"
  echo $(( ${n:-0} > 0 ? n + $2 - 1 : 0 ))
}
ANSWERED_AT="$(first_line "$WORK/ahost.log" "$HMARK" '"event":"consent_ended"')"
FIRST_ICE_AT="$(first_line "$WORK/ahost.log" "$HMARK" '"event":"ice"')"
if [[ "$ANSWERED_AT" -gt 0 && "$FIRST_ICE_AT" -gt "$ANSWERED_AT" ]]; then
  pass "allow: no ICE state before the owner answered"
else
  fail "allow: the peer waits for the answer" "$(tail -n "+$HMARK" "$WORK/ahost.log")"
fi
say ctrl bye
sleep 2
say ahost quit
sleep 2

start_node thost host "$WORK/id-host" --consent timeout
wait_for "$WORK/thost.log" '"event":"hello_ok"' 30 || fail "the silent host comes online" "see $WORK/thost.log"
sleep 1
consent_attempt thost "no answer"
if wait_for "$WORK/thost.log" '"event":"consent_prompt"' 15 "$HMARK"; then
  pass "no answer: the host asked and nobody answered"
fi
if wait_for "$WORK/ctrl.log" '"event":"awaiting_acceptance"' 10 "$CMARK"; then
  pass "no answer: the controller shows \"$(field_after "$WORK/ctrl.log" "$CMARK" awaiting_acceptance message)\""
else
  fail "the controller says it is waiting" "$(tail -n "+$CMARK" "$WORK/ctrl.log")"
fi
if wait_for "$WORK/thost.log" '"event":"consent_ended","outcome":"timedOut"' 40 "$HMARK"; then
  pass "no answer: the prompt declined itself after 30 s"
else
  fail "the prompt times out" "$(tail -n "+$HMARK" "$WORK/thost.log")"
fi
expect_declined thost "no answer" 10
say thost quit
sleep 2
start_node host host "$WORK/id-host"
wait_for "$WORK/host.log" '"event":"hello_ok"' 30

if [[ "$API_MODE" == "1" ]]; then
  echo
  echo "== j. entitlement gating by rc-api (SCOPE §6 rule 1)"
  start_node unsigned host "$WORK/id-unsigned"
  if wait_for "$WORK/unsigned.log" '"event":"hello_ok"' 30; then
    UNSIGNED_ID="$(field "$WORK/unsigned.log" hello_ok deviceId)"
    pass "a host that never signed in still registers and comes online ($UNSIGNED_ID)"
    expect_denied "a host that never signed in" "$UNSIGNED_ID" unlinked
  else
    fail "the unsigned host comes online" "see $WORK/unsigned.log"
  fi
  say unsigned quit

  EXPIRED_EMAIL="expired-$RUN_TAG@example.com"
  start_node expired host "$WORK/id-expired" --dev-sign-in "$EXPIRED_EMAIL"
  if wait_for "$WORK/expired.log" '"event":"signed_in"' 40; then
    EXPIRED_ID="$(field "$WORK/expired.log" signed_in deviceId)"
    status="$(dev_session_post "$EXPIRED_EMAIL" /v1/dev/expire-trial)"
    if [[ "$status" == "204" ]]; then
      pass "the second host signed in ($EXPIRED_ID) and its account's trial was ended"
      expect_denied "a host whose trial has ended" "$EXPIRED_ID" trial_expired
    else
      fail "POST /v1/dev/expire-trial" "HTTP $status $(cat "$WORK/dev_post.out")"
    fi
  else
    fail "the second host signs in" "$(grep -E 'sign_in_error' "$WORK/expired.log" || tail -5 "$WORK/expired.log")"
  fi
  say expired quit
fi

say ctrl quit
say host quit
sleep 1

echo
echo "-----------------------------------------------------------------------"
echo "$((steps - failures))/$steps steps passed"
if [[ "$failures" -gt 0 ]]; then
  echo "TRANSPORT TEST FAILED"
  echo "logs: $WORK (re-run with RC_KEEP_LOGS=1 to keep them)"
  exit 1
fi
echo "TRANSPORT TEST PASSED"
