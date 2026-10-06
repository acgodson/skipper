#!/usr/bin/env bash
#
# Power assertions, read from the system that actually holds them.
#
# SPEC "Background operation": a host Mac must not idle-sleep while it is
# reachable, and neither the Mac nor its display may sleep while a session is
# open. Unit tests can only prove the state -> assertion mapping; this script
# runs the real .app three times and reads `pmset -g assertions` each time:
#
#   1. controller role          -> no SkipperDesk assertion at all
#   2. host, online, UNATTENDED OFF -> "SkipperDesk is reachable"
#   3. host with a live session -> idle-sleep AND display-sleep, both named
#                                  "SkipperDesk remote session"
#
# It injects no input, and it never asks a display or a Mac to sleep.
#
# Needs: ./scripts/build.sh --test-hooks, and scripts/dev-backend.sh running.
# Usage: SKIPPER_API_BASE_URL=http://127.0.0.1:18080 ./scripts/verify-stay-awake.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT}/dist/SkipperDesk.app"
APP="${APP_BUNDLE}/Contents/MacOS/SkipperDesk"
NODE="${ROOT}/apps/macos/.build/debug/rc-node"
API="${SKIPPER_API_BASE_URL:-}"
SUITE_IDLE=com.godson.remotecontrol.stayawake.idle
SUITE_REACH=com.godson.remotecontrol.stayawake.reachable
SUITE_SESSION=com.godson.remotecontrol.stayawake.session
W="$(mktemp -d -t rc-stayawake)"
FAILED=0

cleanup() {
  pkill -f "SkipperDesk.app/Contents/MacOS/SkipperDesk" 2>/dev/null
  pkill -f "$NODE" 2>/dev/null
  for suite in "$SUITE_IDLE" "$SUITE_REACH" "$SUITE_SESSION"; do
    defaults delete "$suite" 2>/dev/null
  done
  [[ "${RC_KEEP_LOGS:-0}" == "1" ]] && echo "logs kept in $W" || rm -rf "$W"
}
trap cleanup EXIT

[[ -n "$API" ]] || { echo "set SKIPPER_API_BASE_URL to the running scripts/dev-backend.sh" >&2; exit 1; }
[[ -x "$APP" ]] || { echo "build the app first: ./scripts/build.sh --test-hooks" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :SkipperTestHooks' "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || {
  echo "this script drives the app through development hooks; rebuild with ./scripts/build.sh --test-hooks" >&2
  exit 1
}
[[ -x "$NODE" ]] || (cd "$ROOT/apps/macos" && swift build --product rc-node >/dev/null)

reading() {
  echo
  echo "--- pmset -g assertions  ($1)"
  local own
  own="$(pmset -g assertions | sed -n '/Listed by owning process/,$p' | grep -i skipperdesk)"
  if [[ -n "$own" ]]; then echo "$own"; else echo "   (no SkipperDesk assertion)"; fi
  echo "---"
}

skipper_assertions() {
  pmset -g assertions | sed -n '/Listed by owning process/,$p' | grep -i skipperdesk
}

check() {
  if [[ "$1" == "0" ]]; then echo "PASS  $2"; else echo "FAIL  $2"; FAILED=1; fi
}

launch_app() {   # launch_app <identity dir> <settings suite> <log>
  pkill -f "SkipperDesk.app/Contents/MacOS/SkipperDesk" 2>/dev/null; sleep 1
  mkdir -p "$1"; : > "$3"
  open -n "$APP_BUNDLE" \
    --env RC_IDENTITY_DIR="$1" \
    --env RC_SETTINGS_SUITE="$2" \
    --env RC_DEBUG=1 \
    --env RC_LOG_FILE="$3" \
    --env SKIPPER_API_BASE_URL="$API" \
    --env SKIPPER_WEB_BASE_URL="$API"
}

wait_for() {   # wait_for <file> <pattern> <seconds>
  for _ in $(seq 1 "$3"); do
    grep -q -- "$2" "$1" 2>/dev/null && return 0
    sleep 1
  done
  return 1
}

echo "== 1. the app in the CONTROLLER role holds nothing"
defaults write "$SUITE_IDLE" rc.role controller
launch_app "$W/id-controller" "$SUITE_IDLE" "$W/controller.log"
sleep 12
reading "controller role"
if [[ -z "$(skipper_assertions)" ]]; then
  check 0 "a controller holds no power assertion"
else
  check 1 "a controller is holding a power assertion"
fi

echo
echo "== 2. the app as a reachable HOST, unattended access OFF"
defaults write "$SUITE_REACH" rc.role host
defaults write "$SUITE_REACH" rc.unattendedAccess -bool false
launch_app "$W/id-reachable" "$SUITE_REACH" "$W/reachable.log"
wait_for "$W/reachable.log" "holding idleSystemSleep" 30
reading "host online, unattended OFF"
HOST_ASSERTIONS="$(skipper_assertions)"
grep -q "SkipperDesk is reachable" <<<"$HOST_ASSERTIONS" \
  && check 0 "a reachable host holds the idle-sleep assertion with unattended access OFF" \
  || check 1 "a reachable host holds NO idle-sleep assertion with unattended access OFF"
grep -q "PreventUserIdleDisplaySleep" <<<"$HOST_ASSERTIONS" \
  && check 1 "a host with no session is keeping the display awake" \
  || check 0 "a host with no session leaves the display alone"

echo
echo "== 3. a live session, driven by a headless controller"
# The host signs in first, because rc-api gates connects by entitlement. The
# sign-in runs against this identity directory and then stops; the app picks the
# same identity up. Unattended access is ON for this run only so the session can
# go live without anyone clicking Allow -- no input is injected anywhere.
mkdir -p "$W/id-session"; mkfifo "$W/s.in"
RC_ROLE=host RC_IDENTITY_DIR="$W/id-session" RC_DEVICE_LABEL=stayawake-host RC_DEBUG=1 \
  "$NODE" --dev-sign-in "stayawake-$$@example.com" < "$W/s.in" > "$W/signin.log" 2>&1 &
SIGNIN=$!
exec 8> "$W/s.in"
wait_for "$W/signin.log" "signed_in" 40 || { echo "the host could not sign in; see $W/signin.log" >&2; tail -5 "$W/signin.log" >&2; exit 1; }
exec 8>&-
kill "$SIGNIN" 2>/dev/null; wait "$SIGNIN" 2>/dev/null; sleep 1

defaults write "$SUITE_SESSION" rc.role host
defaults write "$SUITE_SESSION" rc.unattendedAccess -bool true
launch_app "$W/id-session" "$SUITE_SESSION" "$W/session-host.log"
wait_for "$W/session-host.log" "holding idleSystemSleep" 30

ID="$(python3 -c "import json;print(json.load(open('$W/id-session/identity.json'))['deviceId'])" 2>/dev/null)"
CODE="$(python3 -c "import json;print(json.load(open('$W/id-session/access-code.json')))" 2>/dev/null)"
[[ -n "$ID" && -n "$CODE" ]] || { echo "no identity for the host; see $W/session-host.log" >&2; exit 1; }
echo "   host device $ID"

mkdir -p "$W/id-ctrl"; mkfifo "$W/c.in"
RC_ROLE=controller RC_IDENTITY_DIR="$W/id-ctrl" RC_DEVICE_LABEL=stayawake-ctrl RC_DEBUG=1 \
  "$NODE" < "$W/c.in" > "$W/c.log" 2>&1 &
exec 9> "$W/c.in"
sleep 6
echo "connect $ID $CODE" >&9
if ! wait_for "$W/c.log" '"phase":"live"' 45; then
  echo "the session never went live; see $W/c.log" >&2
  tail -5 "$W/c.log" >&2
  exit 1
fi
sleep 3
reading "live session"
SESSION_ASSERTIONS="$(skipper_assertions)"
grep -q "PreventUserIdleSystemSleep.*SkipperDesk remote session" <<<"$SESSION_ASSERTIONS" \
  && check 0 "a live session keeps the Mac from idle-sleeping" \
  || check 1 "a live session does NOT keep the Mac from idle-sleeping"
grep -q "PreventUserIdleDisplaySleep.*SkipperDesk remote session" <<<"$SESSION_ASSERTIONS" \
  && check 0 "a live session keeps the display on, so capture keeps working" \
  || check 1 "a live session does NOT keep the display on"
grep -q "declared local user activity" "$W/session-host.log" \
  && check 0 "the host declared local user activity, so a dark display comes back" \
  || check 1 "the host never declared local user activity"

echo "bye" >&9
sleep 4
reading "after the session ended"
AFTER="$(skipper_assertions)"
grep -q "SkipperDesk is reachable" <<<"$AFTER" \
  && check 0 "the host drops back to the reachable assertion when the session ends" \
  || check 1 "the host did not drop back to the reachable assertion"
grep -q "PreventUserIdleDisplaySleep" <<<"$AFTER" \
  && check 1 "the display assertion outlived the session" \
  || check 0 "the display assertion was released with the session"

echo
if [[ "$FAILED" == "0" ]]; then
  echo "STAY-AWAKE VERIFICATION PASSED"
else
  echo "STAY-AWAKE VERIFICATION FAILED"
fi
exit "$FAILED"
