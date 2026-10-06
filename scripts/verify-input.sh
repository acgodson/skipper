#!/usr/bin/env bash
#
# Phase 5 acceptance for the half a unit test cannot reach: does injecting
# input actually MOVE THINGS on this Mac?
#
# The unit suite (`swift run rc-tests`) pins the translation — which CGEventType
# a drag becomes, which flags Cmd+Shift carries, what input_reset releases. It
# cannot prove that the events reach the window server, because it never posts
# one. This script does, and every check below observes a consequence produced
# by macOS rather than a value our code computed:
#
#   * the cursor position read back from the window server after an injected move
#   * a real NSWindow's frame after being dragged by its title bar
#     (PLAN.md §2.6 — a drag posted as a move leaves the window behind)
#   * a listen-only CGEventTap's count of leftMouseDragged vs mouseMoved
#   * scroll events carrying isContinuous=1, i.e. pixel units
#   * a key event carrying maskCommand
#   * a held button released by input_reset, and a second reset posting nothing
#   * the host ACTUALLY entering Mission Control and App Expose, read from the
#     Dock's on-screen window count rather than from the events we posted
#     (scripts/test-input.sh counts those events and so cannot see this)
#   * the Force Quit dialog ACTUALLY appearing, read from loginwindow's on-screen
#     window count, then dismissed with Escape so nothing is left on screen
#
# If injection were a no-op, or posted moves instead of drags, none of these
# could pass.
#
# WHY IT LAUNCHES THE .app AND NOT A CLI. macOS attributes a TCC grant to the
# RESPONSIBLE process. Running a binary from this shell makes Terminal
# responsible, so the app's own Accessibility grant does not apply and every
# injected event is silently discarded. `open` gives the bundle responsibility
# for itself. `open` also detaches stdio, hence RC_LOG_FILE.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT}/dist/SkipperDesk.app"
APP="${APP_BUNDLE}/Contents/MacOS/SkipperDesk"
W="$(mktemp -d -t rc-input)"
LOG="$W/app.log"

cleanup() {
  pkill -f "SkipperDesk.app/Contents/MacOS/SkipperDesk" 2>/dev/null
  [[ "${RC_KEEP_LOGS:-0}" == "1" ]] && echo "logs kept in $W" || rm -rf "$W"
}
trap cleanup EXIT

[[ -x "$APP" ]] || { echo "build the app first: ./scripts/build.sh --test-hooks" >&2; exit 1; }
/usr/libexec/PlistBuddy -c 'Print :SkipperTestHooks' "$APP_BUNDLE/Contents/Info.plist" >/dev/null 2>&1 || {
  echo "this script drives the app through development hooks, which release builds ignore." >&2
  echo "rebuild with: ./scripts/build.sh --test-hooks   (and never ship that build)" >&2
  exit 1
}

echo "== launching SkipperDesk.app with RC_INPUT_SELFTEST=1"
echo "   (it will move this Mac's cursor for a few seconds — that is the test)"
pkill -f "SkipperDesk.app/Contents/MacOS/SkipperDesk" 2>/dev/null; sleep 1
mkdir -p "$W/id"
: > "$LOG"
open -n "$APP_BUNDLE" \
  --env RC_IDENTITY_DIR="$W/id" \
  --env RC_SETTINGS_SUITE=com.godson.remotecontrol.inputverify \
  --env RC_INPUT_SELFTEST=1 \
  --env RC_DEBUG=1 \
  --env RC_LOG_FILE="$LOG"

for _ in $(seq 1 120); do
  grep -q "SELFTEST end" "$LOG" 2>/dev/null && break
  sleep 1
done

if ! grep -q "SELFTEST begin" "$LOG" 2>/dev/null; then
  echo "the app never started the self-test. Log:" >&2
  tail -20 "$LOG" >&2
  exit 1
fi

if grep -q "SELFTEST accessibility FAIL" "$LOG"; then
  echo
  echo "ACCESSIBILITY IS NOT GRANTED to SkipperDesk.app."
  echo
  echo "  1. System Settings > Privacy & Security > Accessibility"
  echo "  2. Add / enable SkipperDesk.app (${APP_BUNDLE})"
  echo "  3. Run this script again."
  echo
  echo "Without it macOS accepts every CGEvent we post and then discards it, so"
  echo "the remote Mac's screen is visible but nothing can be clicked or typed."
  echo "If you granted it before and it came back: the build was ad-hoc signed,"
  echo "so every rebuild looks like a different app. Run"
  echo "./scripts/make-signing-cert.sh once, rebuild, and grant one more time."
  exit 1
fi

echo
echo "-----------------------------------------------------------------------"
grep "SELFTEST" "$LOG" | sed 's/.*SELFTEST /  /'
echo "-----------------------------------------------------------------------"
echo

FAILED=0
require() {   # require <check-name>
  if grep -q "SELFTEST $1 PASS" "$LOG"; then
    echo "PASS  $1"
  else
    echo "FAIL  $1"
    FAILED=1
  fi
}

# Each of these fails if injection is a no-op.
require accessibility
require cursor_accuracy
require stale_seq_dropped
require drag_posts_dragged_events
require window_actually_moved
require scroll_events_reached_the_session
require scroll_is_pixel_units
require modifier_flags_reach_the_session
require input_reset_releases_the_button
require input_reset_clears_state
require input_reset_is_idempotent
require mission_control_takes_effect
require mission_control_left_cleanly
require app_expose_takes_effect
require app_expose_left_cleanly
require force_quit_takes_effect
require force_quit_left_cleanly

if grep -q "SELFTEST summary .* 0 failed" "$LOG"; then
  echo "PASS  the self-test reported no failures"
else
  echo "FAIL  the self-test reported failures"
  FAILED=1
fi

echo
if [[ "$FAILED" == "0" ]]; then
  echo "INPUT VERIFICATION PASSED — real OS-level input moves things on this Mac"
else
  echo "INPUT VERIFICATION FAILED"
fi
exit "$FAILED"
