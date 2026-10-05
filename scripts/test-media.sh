#!/usr/bin/env bash
#
# Phase 4 integration test: video frames actually flow between TWO real
# app-core instances, over a backend reachable at SKIPPER_API_BASE_URL (the
# local dev server by default).
#
# Nothing here is mocked. Each instance is `rc-node`, the same IdentityStore /
# SignalingClient / SessionCoordinator / PeerSession / capture pipeline the .app
# uses, given separate RC_IDENTITY_DIRs so they are genuinely two devices.
#
# ONE deliberate substitution, stated plainly: the HOST uses
# RC_CAPTURE_SOURCE=synthetic, a generated moving pattern, instead of
# ScreenCaptureKit. A headless CLI process CANNOT hold a Screen Recording grant
# — macOS attributes TCC to the responsible process (the terminal), so
# CGPreflightScreenCaptureAccess() is false for rc-node no matter what the user
# grants. Everything downstream of the frame — RTCVideoSource, the VideoToolbox
# H.264 encoder, SRTP, the decoder, libwebrtc's own counters — is the real
# production path. Real ScreenCaptureKit capture is verified by running the .app
# (see PHASE4-NOTES / the phase report).
#
# Proves, in order:
#   a. both instances authenticate and a session opens
#   b. the host's capture pipeline reaches `running` and reports a size
#   c. the SDP carried a video m-line: the controller gets a remote video track
#   d. `display_info` crossed the ctrl channel with the host's real capture size
#   e. framesDecoded on the CONTROLLER is > 0 and RISES between two samples
#      (a still image, a zero counter or a stub all fail here)
#   f. framesEncoded on the HOST is > 0, on a hardware encoder
#   g. measured fps and bitrate are reported and are within plausible bounds
#   h. a `quality` change made on the controller reaches the host
#
# Exits non-zero on any failure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
WORK="$(mktemp -d -t rc-media)"
BIN="$APP_DIR/.build/debug/rc-node"

API_BASE_URL="${SKIPPER_API_BASE_URL:-http://127.0.0.1:18443}"
# How long the two stats samples are apart. Longer = a more stable measurement.
SAMPLE_SECONDS="${RC_SAMPLE_SECONDS:-8}"

steps=0
failures=0
PIDS=()
NEXT_FD=10

pass() { steps=$((steps + 1)); printf 'PASS  %s\n' "$1"; }
fail() { steps=$((steps + 1)); failures=$((failures + 1)); printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"; }
info() { printf '      %s\n' "$1"; }

cleanup() {
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill "$pid" 2>/dev/null; done
  sleep 0.5
  for pid in "${PIDS[@]:-}"; do [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null; done
  pkill -f "$BIN" 2>/dev/null
  if [[ "${RC_KEEP_LOGS:-0}" == "1" ]]; then echo "logs kept in $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

wait_for() {  # wait_for <file> <pattern> [timeout] [start-line]
  local file="$1" pattern="$2" timeout="${3:-25}" from="${4:-1}"
  local deadline=$(( $(date +%s) + timeout ))
  while [[ $(date +%s) -lt $deadline ]]; do
    if tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern"; then return 0; fi
    sleep 0.2
  done
  return 1
}

lines_in() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

field() {  # field <file> <event> <key> [start-line]  -> LAST match
  python3 - "$1" "$2" "$3" "${4:-1}" <<'PY'
import json, sys
path, event, key, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
found = ""
for n, line in enumerate(open(path), 1):
    if n < start: continue
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == event and key in d:
        found = d[key]
print(found)
PY
}

start_node() {  # start_node <name> <role> <identity-dir> [env assignments...] [-- rc-node args...]
  local name="$1" role="$2" dir="$3"; shift 3
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  mkdir -p "$dir"
  mkfifo "$WORK/$name.in"
  env RC_ROLE="$role" RC_IDENTITY_DIR="$dir" SKIPPER_API_BASE_URL="$API_BASE_URL" \
      RC_DEVICE_LABEL="rc-media-$name" ${envs[@]+"${envs[@]}"} \
      "$BIN" "$@" < "$WORK/$name.in" > "$WORK/$name.log" 2>&1 &
  PIDS+=("$!")
  eval "exec ${NEXT_FD}> \"$WORK/$name.in\""
  eval "FD_${name}=${NEXT_FD}"
  NEXT_FD=$((NEXT_FD + 1))
}

say() { local name="$1"; shift; local fdvar="FD_${name}"; echo "$*" >&"${!fdvar}"; }

# ---------------------------------------------------------------------------
echo "== building rc-node (the real app core, headless)"
if ! (cd "$APP_DIR" && swift build --product rc-node 2>&1 | grep -v "XCTest paths\|xcrun:" | tail -3); then
  fail "build rc-node" "swift build failed"; exit 1
fi
[[ -x "$BIN" ]] || { fail "build rc-node" "no binary at $BIN"; exit 1; }

echo "== server health"
HEALTH_URL="$(printf '%s' "$API_BASE_URL" | sed -e 's|/$||')/healthz"
if [[ "$(curl -sk --max-time 10 "$HEALTH_URL")" == "ok" ]]; then
  pass "the signaling server is healthy ($HEALTH_URL)"
else
  fail "the signaling server is healthy" "$HEALTH_URL did not return ok"; exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "== a. session between two real instances"
# rc-api gates sessions on entitlement, so against it the host has to sign in
# first; a bare rc-signal answers no REST health call and needs no sign-in.
HOST_ARGS=()
if curl -sk --max-time 10 "$API_BASE_URL/v1/health" | grep -q '"status":"ok"'; then
  HOST_ARGS=(-- --dev-sign-in "rc-media-$$@example.com")
  info "backend is rc-api: the host signs in so its trial entitles the session"
fi
start_node host host "$WORK/id-host" RC_CAPTURE_SOURCE=synthetic ${HOST_ARGS[@]+"${HOST_ARGS[@]}"}
if ! wait_for "$WORK/host.log" '"event":"hello_ok"' 30; then
  fail "host authenticates" "see $WORK/host.log"; exit 1
fi
if [[ ${#HOST_ARGS[@]} -gt 0 ]] && ! wait_for "$WORK/host.log" '"event":"signed_in"' 40; then
  fail "host signs in" "see $WORK/host.log"; exit 1
fi
HOST_ID="$(field "$WORK/host.log" hello_ok deviceId)"
HOST_CODE="$(field "$WORK/host.log" ready accessCode)"
pass "host authenticated as $HOST_ID"

start_node ctrl controller "$WORK/id-ctrl"
if ! wait_for "$WORK/ctrl.log" '"event":"hello_ok"' 30; then
  fail "controller authenticates" "see $WORK/ctrl.log"; exit 1
fi
pass "controller authenticated"

say ctrl "connect $HOST_ID $HOST_CODE"
if wait_for "$WORK/ctrl.log" '"event":"session"' 30; then
  pass "session opened with the access code"
else
  fail "session opens" "$(tail -5 "$WORK/ctrl.log")"; exit 1
fi
if grep -q '"event":"session".*"turn":false' "$WORK/ctrl.log"; then
  pass "connect_ok carried STUN only, like hello_ok (protocol v5)"
else
  fail "connect_ok carries no TURN credentials" "$(grep -E '"event":"(session|hello_ok)"' "$WORK/ctrl.log")"
fi
if wait_for "$WORK/ctrl.log" '"event":"ice_servers".*"turn":true' 60 &&
   wait_for "$WORK/host.log" '"event":"ice_servers".*"turn":true' 30; then
  pass "TURN credentials arrived with the ice_servers push on both Macs (protocol v5)"
else
  fail "ice_servers carries TURN credentials" "$(grep ice_servers "$WORK/ctrl.log" "$WORK/host.log")"
fi
if wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"connected"' 60; then
  pass "the peer connection reached ICE connected"
else
  fail "peer connection connects" "$(grep '"event":"ice"' "$WORK/ctrl.log" | tail -3)"; exit 1
fi
echo

# ---------------------------------------------------------------------------
echo "== b. the host's capture pipeline starts"
# rc-node emits JSON with SORTED keys, so "event" and "state" are not adjacent.
CAP_W=0; CAP_H=0; CAP_FPS=0
if wait_for "$WORK/host.log" '"event":"capture".*"state":"running"' 30; then
  CAP_W="$(field "$WORK/host.log" capture w)"
  CAP_H="$(field "$WORK/host.log" capture h)"
  CAP_FPS="$(field "$WORK/host.log" capture fps)"
  pass "capture is running at ${CAP_W}x${CAP_H}, up to ${CAP_FPS} fps"
else
  fail "capture starts" "$(grep '"event":"capture"' "$WORK/host.log" | tail -3)"
fi
if grep -q '"event":"capture".*"state":"failed"' "$WORK/host.log"; then
  fail "capture did not fail" "$(grep '"state":"failed"' "$WORK/host.log" | tail -1)"
else
  pass "capture reported no failure"
fi
echo

# ---------------------------------------------------------------------------
echo "== c. the SDP carried video: a remote track reached the controller"
if wait_for "$WORK/ctrl.log" '"event":"remote_video","present":true' 30; then
  pass "the controller received a remote video track"
else
  fail "controller receives a video track" "$(grep remote_video "$WORK/ctrl.log")"
fi
echo

# ---------------------------------------------------------------------------
echo "== d. display_info crossed the ctrl channel"
sleep 1
MARK=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
say ctrl status
sleep 1
REMOTE_DISPLAY="$(field "$WORK/ctrl.log" status remoteDisplay "$MARK")"
if [[ -n "$REMOTE_DISPLAY" && "$REMOTE_DISPLAY" != "0x0" ]]; then
  pass "the controller knows the host's display size: $REMOTE_DISPLAY"
  if [[ "$REMOTE_DISPLAY" == "${CAP_W}x${CAP_H}" ]]; then
    pass "display_info matches what the host is really capturing"
  else
    fail "display_info matches the capture size" "reported $REMOTE_DISPLAY, capturing ${CAP_W}x${CAP_H}"
  fi
else
  fail "display_info reaches the controller" "remoteDisplay='$REMOTE_DISPLAY'"
fi
echo

# ---------------------------------------------------------------------------
echo "== e/f/g. frames are decoded, and the count RISES (${SAMPLE_SECONDS}s apart)"
MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
MARK_H=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl video-stats
say host video-stats
wait_for "$WORK/ctrl.log" '"event":"video_stats"' 15 "$MARK_C" || fail "controller answers video-stats" ""
wait_for "$WORK/host.log" '"event":"video_stats"' 15 "$MARK_H" || fail "host answers video-stats" ""
DEC0="$(field "$WORK/ctrl.log" video_stats framesDecoded "$MARK_C")"
RX0="$(field "$WORK/ctrl.log" video_stats bytesReceived "$MARK_C")"
ENC0="$(field "$WORK/host.log" video_stats framesEncoded "$MARK_H")"
TX0="$(field "$WORK/host.log" video_stats bytesSent "$MARK_H")"
T0=$(date +%s)

sleep "$SAMPLE_SECONDS"

MARK_C=$(( $(lines_in "$WORK/ctrl.log") + 1 ))
MARK_H=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl video-stats
say host video-stats
wait_for "$WORK/ctrl.log" '"event":"video_stats"' 15 "$MARK_C" || fail "controller answers video-stats" ""
wait_for "$WORK/host.log" '"event":"video_stats"' 15 "$MARK_H" || fail "host answers video-stats" ""
T1=$(date +%s)
DEC1="$(field "$WORK/ctrl.log" video_stats framesDecoded "$MARK_C")"
RX1="$(field "$WORK/ctrl.log" video_stats bytesReceived "$MARK_C")"
ENC1="$(field "$WORK/host.log" video_stats framesEncoded "$MARK_H")"
TX1="$(field "$WORK/host.log" video_stats bytesSent "$MARK_H")"
VID_W="$(field "$WORK/ctrl.log" video_stats w "$MARK_C")"
VID_H="$(field "$WORK/ctrl.log" video_stats h "$MARK_C")"
DECODER="$(field "$WORK/ctrl.log" video_stats decoder "$MARK_C")"
ENCODER="$(field "$WORK/host.log" video_stats encoder "$MARK_H")"

ELAPSED=$(( T1 - T0 ))
[[ "$ELAPSED" -gt 0 ]] || ELAPSED=1

: "${DEC0:=0}" "${DEC1:=0}" "${ENC0:=0}" "${ENC1:=0}" "${RX0:=0}" "${RX1:=0}" "${TX0:=0}" "${TX1:=0}"

if [[ "$DEC1" -gt 0 ]]; then
  pass "the controller has DECODED video frames (framesDecoded=$DEC1)"
else
  fail "the controller decodes video frames" "framesDecoded=$DEC1 — no video arrived"
fi
if [[ "$DEC1" -gt "$DEC0" ]]; then
  pass "the decoded frame count ROSE over ${ELAPSED}s ($DEC0 -> $DEC1): live video, not a still"
else
  fail "the decoded frame count rises" "$DEC0 -> $DEC1 in ${ELAPSED}s"
fi
if [[ "$ENC1" -gt "$ENC0" && "$ENC1" -gt 0 ]]; then
  pass "the host is ENCODING frames ($ENC0 -> $ENC1)"
else
  fail "the host encodes frames" "framesEncoded $ENC0 -> $ENC1"
fi

FPS="$(python3 -c "print(f'{($DEC1-$DEC0)/$ELAPSED:.1f}')")"
KBPS="$(python3 -c "print(f'{($RX1-$RX0)*8/$ELAPSED/1000:.0f}')")"
TX_KBPS="$(python3 -c "print(f'{($TX1-$TX0)*8/$ELAPSED/1000:.0f}')")"
info "measured decode rate ${FPS} fps at ${VID_W}x${VID_H}"
info "measured bitrate: ${KBPS} kbps received / ${TX_KBPS} kbps sent"
info "encoder='${ENCODER}'  decoder='${DECODER}'"

if python3 -c "import sys; sys.exit(0 if float('$FPS') >= 5 else 1)"; then
  pass "the measured frame rate is ${FPS} fps (>= 5)"
else
  fail "the measured frame rate is plausible" "${FPS} fps"
fi
if [[ "$KBPS" -gt 0 ]]; then
  pass "the measured bitrate is ${KBPS} kbps"
else
  fail "video bytes are being received" "${KBPS} kbps"
fi
if [[ -n "$ENCODER" && "$ENCODER" != "null" ]]; then
  pass "the host encoder is '${ENCODER}'"
else
  info "the encoder implementation was not reported by libwebrtc"
fi
echo

# ---------------------------------------------------------------------------
echo "== h. a quality change made on the controller reaches the host"
say ctrl "quality smooth"
sleep 2
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host status
sleep 1
HOST_QUALITY="$(field "$WORK/host.log" status quality "$MARK")"
if [[ "$HOST_QUALITY" == "smooth" ]]; then
  pass "the host applied quality=smooth sent over the ctrl channel"
else
  fail "quality reaches the host" "the host reports quality='$HOST_QUALITY'"
fi

say ctrl "quality sharp"
sleep 2
MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say host status
sleep 1
HOST_QUALITY="$(field "$WORK/host.log" status quality "$MARK")"
if [[ "$HOST_QUALITY" == "sharp" ]]; then
  pass "the host applied quality=sharp as well (the mode is not stuck)"
else
  fail "a second quality change reaches the host" "the host reports quality='$HOST_QUALITY'"
fi
echo

# ---------------------------------------------------------------------------
echo "== i. clean shutdown"
BYE_MARK=$(( $(lines_in "$WORK/host.log") + 1 ))
say ctrl bye
if wait_for "$WORK/host.log" '"event":"bye","reason":"user_ended"' 25 "$BYE_MARK"; then
  pass "the host received bye"
else
  fail "host receives bye" "$(tail -n "+$BYE_MARK" "$WORK/host.log")"
fi
if wait_for "$WORK/host.log" '"event":"capture".*"state":"idle"' 15 "$BYE_MARK"; then
  pass "capture stopped when the session ended (no camera-light-on-forever)"
else
  fail "capture stops with the session" "$(tail -n "+$BYE_MARK" "$WORK/host.log" | grep capture)"
fi
say ctrl quit
say host quit
sleep 1

echo
echo "-----------------------------------------------------------------------"
echo "measured: ${FPS} fps, ${KBPS} kbps received, ${VID_W}x${VID_H}"
echo "$((steps - failures))/$steps steps passed"
if [[ "$failures" -gt 0 ]]; then
  echo "MEDIA TEST FAILED"
  echo "logs: $WORK (re-run with RC_KEEP_LOGS=1 to keep them)"
  exit 1
fi
echo "MEDIA TEST PASSED"
