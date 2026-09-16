#!/usr/bin/env bash
#
# Phase 4 acceptance for the half that a script cannot fake: REAL
# ScreenCaptureKit capture out of the real .app bundle, measured.
#
# scripts/test-media.sh proves the media pipeline with a synthetic frame source,
# because a headless CLI process can never hold a Screen Recording grant (TCC
# attributes it to the terminal). This script covers the other half: it runs the
# actual RemoteControl.app as the HOST, so the grant applies to the bundle that
# has it, and connects a headless controller to measure what comes out.
#
# Reports, from libwebrtc's own counters and from `ps`:
#   * the captured resolution and backing scale (i.e. display_info)
#   * the NEGOTIATED CODEC and the encoder/decoder implementation
#   * decoded frames per second and bitrate at the controller
#   * host CPU while the screen is IDLE      (PLAN.md §5 budget: < 5%)
#   * host CPU while the screen is CHANGING  (for contrast; not budgeted)
#
# CPU MEASUREMENT BASIS. `ps -o %cpu` on macOS reports **percent of ONE core**:
# a process saturating a single core reads 100.0 however many cores the machine
# has, and a process using two cores reads 200.0. PLAN.md 5's "idle CPU < 5%" is
# interpreted here in that same unit -- 5% of one core -- which is the strict
# reading. The equivalent percent-of-machine figure is printed alongside it
# (divided by the core count) purely as context; PASS/FAIL is on percent-of-one-
# core.
#
# WHAT THIS SCRIPT IS FOR. Phase 4 shipped failing its own efficiency budget
# because the only automated media test used a 1280x720 synthetic frame source.
# libwebrtc advertises H.264 at level 3.1, whose maximum frame is exactly
# 1280x720, so the synthetic test encoded on VideoToolbox and passed while the
# real 1920x1200 desktop silently fell back to SOFTWARE VP8 and pinned a core.
# Hence the codec assertion below: a software codec now fails this script.
#
# Prerequisite: RemoteControl.app must have Screen Recording permission. If it
# does not, this script says so and stops — it does not pretend.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${ROOT}/dist/RemoteControl.app"
APP="${APP_BUNDLE}/Contents/MacOS/RemoteControl"
NODE="${ROOT}/apps/macos/.build/debug/rc-node"
W="$(mktemp -d -t rc-verify)"
IDLE_SECONDS="${RC_IDLE_SECONDS:-15}"

cleanup() {
  pkill -f "RemoteControl.app/Contents/MacOS/RemoteControl" 2>/dev/null
  pkill -f "$NODE" 2>/dev/null
  [[ "${RC_KEEP_LOGS:-0}" == "1" ]] && echo "logs kept in $W" || rm -rf "$W"
}
trap cleanup EXIT

[[ -x "$APP" ]] || { echo "build the app first: ./scripts/build.sh" >&2; exit 1; }
[[ -x "$NODE" ]] || (cd "$ROOT/apps/macos" && swift build --product rc-node >/dev/null)

field() {
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
    if d.get("event") == event and key in d: found = d[key]
print(found)
PY
}
lines_in() { wc -l < "$1" 2>/dev/null | tr -d ' '; }

echo "== starting RemoteControl.app as the HOST"
pkill -f "RemoteControl.app/Contents/MacOS/RemoteControl" 2>/dev/null; sleep 1
mkdir -p "$W/id-app"
# A separate identity + preferences domain so this never touches a real install.
defaults write com.godson.remotecontrol.verify rc.role host
# MUST launch through LaunchServices (`open`), NOT by exec'ing the inner binary.
# macOS attributes a TCC grant to the *responsible process*. Running
# .../Contents/MacOS/RemoteControl straight from a shell makes the TERMINAL the
# responsible process, so the app's own Screen Recording grant does not apply and
# CGPreflightScreenCaptureAccess() returns false no matter what the user granted.
# `open` gives the app its own responsibility, so its real grant is honoured.
RC_APP_LOG="$W/app.log" ; : > "$RC_APP_LOG"
open -n "$APP_BUNDLE" \
  --env RC_IDENTITY_DIR="$W/id-app" \
  --env RC_SETTINGS_SUITE=com.godson.remotecontrol.verify \
  --env RC_DEBUG=1 \
  --env RC_LOG_FILE="$RC_APP_LOG"
sleep 10

ID="$(python3 -c "import json;print(json.load(open('$W/id-app/identity.json'))['deviceId'])" 2>/dev/null)"
CODE="$(python3 -c "import json;print(json.load(open('$W/id-app/identity.json'))['accessCode'])" 2>/dev/null)"
[[ -n "$ID" ]] || { echo "the app did not create an identity; see $W/app.log" >&2; exit 1; }
echo "   host device $ID"

echo "== connecting a headless controller"
mkdir -p "$W/id-ctrl"; mkfifo "$W/c.in"
RC_ROLE=controller RC_IDENTITY_DIR="$W/id-ctrl" RC_DEVICE_LABEL=verify-ctrl RC_DEBUG=1 \
  "$NODE" < "$W/c.in" > "$W/c.log" 2>&1 &
exec 9> "$W/c.in"
sleep 6
echo "connect $ID $CODE" >&9
# Wait for the host to actually attempt capture before judging the grant: the
# session has to be up first, and how long that takes depends on ICE.
for _ in $(seq 1 40); do
  grep -q "starting capture" "$W/app.log" && break
  sleep 1
done

if ! grep -q "starting capture" "$W/app.log"; then
  echo "the host never attempted capture — the session did not come up." >&2
  tail -5 "$W/app.log" >&2
  exit 1
fi

if grep -q "screenRecordingGranted=false" "$W/app.log"; then
  echo
  echo "SCREEN RECORDING IS NOT GRANTED to RemoteControl.app."
  echo
  echo "  1. System Settings > Privacy & Security > Screen & System Audio Recording"
  echo "  2. Add / enable RemoteControl.app (${ROOT}/dist/RemoteControl.app)"
  echo "  3. Run this script again."
  echo
  echo "If you have granted it before and it keeps coming back, the build was"
  echo "ad-hoc signed: every rebuild then looks like a different app to macOS."
  echo "Run ./scripts/make-signing-cert.sh once, rebuild, and grant one more time."
  exit 1
fi

APP_PID="$(pgrep -f "RemoteControl.app/Contents/MacOS/RemoteControl" | head -1)"
CORES="$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || python3 -c 'import os;print(os.cpu_count())')"

# `ps -o %cpu` is percent of ONE core (see the header). Sampled once a second so
# a single scheduling spike cannot dominate the average.
sample_cpu() {   # sample_cpu <seconds> -> "avg peak"
  local n="$1" samples=""
  for _ in $(seq 1 "$n"); do
    sleep 1
    samples="$samples $(ps -o %cpu= -p "$APP_PID" | tr -d ' ')"
  done
  python3 -c "
v=[float(x) for x in \"\"\"$samples\"\"\".split() if x]
print(f'{sum(v)/len(v):.1f} {max(v):.1f}' if v else '0 0')"
}

# The host's own count of frames ScreenCaptureKit reported as genuinely dirty.
# This is what tells us whether the screen was actually still during the window.
last_changed_frames() {
  grep -o 'changed frames [0-9]*' "$W/app.log" | tail -1 | awk '{print $3}'
}

dirty_rate_during_idle_window() {
  python3 -c "print(f'{max(0,${DIRTY1:-0}-${DIRTY0:-0})/$IDLE_SECONDS:.1f}')"
}

echo "== measuring (leave the screen ALONE for ${IDLE_SECONDS}s)"
MARK=$(( $(lines_in "$W/c.log") + 1 ))
echo "video-stats" >&9
sleep 3
DEC0="$(field "$W/c.log" video_stats framesDecoded "$MARK")"; DEC0="${DEC0:-0}"
RX0="$(field "$W/c.log" video_stats bytesReceived "$MARK")"; RX0="${RX0:-0}"
T0=$(date +%s)

# CPU while nothing on screen changes: the number PLAN.md 5 budgets at < 5% of
# one core.
DIRTY0="$(last_changed_frames)"; DIRTY0="${DIRTY0:-0}"
read -r IDLE_CPU_AVG IDLE_CPU_PEAK <<<"$(sample_cpu "$IDLE_SECONDS")"
DIRTY1="$(last_changed_frames)"; DIRTY1="${DIRTY1:-0}"

MARK=$(( $(lines_in "$W/c.log") + 1 ))
echo "video-stats" >&9
sleep 3
T1=$(date +%s)
DEC1="$(field "$W/c.log" video_stats framesDecoded "$MARK")"; DEC1="${DEC1:-0}"
RX1="$(field "$W/c.log" video_stats bytesReceived "$MARK")"; RX1="${RX1:-0}"
VW="$(field "$W/c.log" video_stats w "$MARK")"
VH="$(field "$W/c.log" video_stats h "$MARK")"
DEC="$(field "$W/c.log" video_stats decoder "$MARK")"
CODEC="$(field "$W/c.log" video_stats codec "$MARK")"
HWH264="$(field "$W/c.log" video_stats hwH264 "$MARK")"
ELAPSED=$(( T1 - T0 )); [[ "$ELAPSED" -gt 0 ]] || ELAPSED=1

# ACTIVE contrast: churn the screen for real. Writing to the controlling
# terminal is the one way a script with no Accessibility grant can make the
# display genuinely repaint. Not budgeted by PLAN.md -- reported for contrast.
echo "== measuring while the screen is CHANGING"
( for i in $(seq 1 600); do
    printf '\033[7m %04d %s \033[0m\n' "$i" "$(date +%T)" > /dev/tty
    sleep 0.02
  done ) >/dev/null 2>&1 &
CHURN=$!
MARK=$(( $(lines_in "$W/c.log") + 1 ))
echo "video-stats" >&9
sleep 1
ADEC0="$(field "$W/c.log" video_stats framesDecoded "$MARK")"; ADEC0="${ADEC0:-0}"
ARX0="$(field "$W/c.log" video_stats bytesReceived "$MARK")"; ARX0="${ARX0:-0}"
AT0=$(date +%s)
read -r ACTIVE_CPU_AVG ACTIVE_CPU_PEAK <<<"$(sample_cpu 8)"
MARK=$(( $(lines_in "$W/c.log") + 1 ))
echo "video-stats" >&9
sleep 2
AT1=$(date +%s)
kill "$CHURN" 2>/dev/null
ADEC1="$(field "$W/c.log" video_stats framesDecoded "$MARK")"; ADEC1="${ADEC1:-0}"
ARX1="$(field "$W/c.log" video_stats bytesReceived "$MARK")"; ARX1="${ARX1:-0}"
AELAPSED=$(( AT1 - AT0 )); [[ "$AELAPSED" -gt 0 ]] || AELAPSED=1
ACTIVE_FPS="$(python3 -c "print(f'{max(0,$ADEC1-$ADEC0)/$AELAPSED:.1f}')")"
ACTIVE_KBPS="$(python3 -c "print(f'{max(0,$ARX1-$ARX0)*8/$AELAPSED/1000:.0f}')")"

CAPTURE="$(grep -o 'capture started [0-9]*x[0-9]* @[0-9.]*x' "$W/app.log" | tail -1)"
IDLE_FPS="$(python3 -c "print(f'{max(0,$DEC1-$DEC0)/$ELAPSED:.1f}')")"
IDLE_KBPS="$(python3 -c "print(f'{max(0,$RX1-$RX0)*8/$ELAPSED/1000:.0f}')")"
# Proof the adaptive frame-rate policy actually engaged on the REAL capture
# path: a "capture fps 30 -> N" line with N < 30. Phase 4 had this logic and it
# never once ran, because every unchanged frame was counted as activity.
FPS_STEPS="$(grep -o 'capture fps [0-9]* -> [0-9]*' "$W/app.log" | tail -4 | tr '\n' ';')"
FPS_DOWN="$(grep -o 'capture fps 30 -> [0-9]*' "$W/app.log" | awk '{print $5}' | sort -n | head -1)"
FPS_DOWN="${FPS_DOWN:-30}"
CAPCOUNTS="$(grep -o 'changed frames [0-9]*, unchanged dropped [0-9]*' "$W/app.log" | tail -1)"

IDLE_CPU_MACHINE="$(python3 -c "print(f'{$IDLE_CPU_AVG/$CORES:.2f}')")"

echo
echo "-----------------------------------------------------------------------"
echo "REAL ScreenCaptureKit capture, out of the real .app"
echo "  ${CAPTURE:-capture size not logged}"
echo "  decoded at the controller: ${VW}x${VH}"
echo "  negotiated codec:          ${CODEC:-unknown}, decoder '${DEC}'"
echo "  frames decoded so far:     ${DEC1}"
echo "  adaptive capture fps:      ${FPS_STEPS:-no change logged}"
echo "  capture frames:            ${CAPCOUNTS:-not logged}"
echo "  IDLE screen:               ${IDLE_FPS} fps, ${IDLE_KBPS} kbps"
echo "  ACTIVE screen:             ${ACTIVE_FPS} fps, ${ACTIVE_KBPS} kbps"
echo "  HOST CPU while idle:       ${IDLE_CPU_AVG} avg, ${IDLE_CPU_PEAK} peak   <- percent of ONE core"
echo "                             (= ${IDLE_CPU_MACHINE}% of this ${CORES}-core machine)"
echo "  HOST CPU while active:     ${ACTIVE_CPU_AVG} avg, ${ACTIVE_CPU_PEAK} peak   (one core; not budgeted)"
echo "-----------------------------------------------------------------------"

FAILED=0
check() {  # check <ok:0|1> <message>
  if [[ "$1" == "0" ]]; then echo "PASS  $2"; else echo "FAIL  $2"; FAILED=1; fi
}
# Numeric comparison without bc: 0 when $1 <= $2.
le() { python3 -c "import sys;sys.exit(0 if float('$1') <= float('$2') else 1)"; echo $?; }

if [[ "$DEC1" -gt 0 ]]; then
  check 0 "real screen frames were decoded at the far end"
else
  check 1 "no frames were decoded"
fi

# 1. THE CODEC. A software codec (libvpx, OpenH264) fails here by design: it is
#    the single thing that made Phase 4 miss its budget, and neither a stub nor
#    a software fallback can satisfy this.
case "$CODEC" in
  video/H264|video/h264) check 0 "the negotiated codec is H.264 (${CODEC})" ;;
  *) check 1 "the negotiated codec is '${CODEC:-none}', not H.264 -- that means a SOFTWARE encoder" ;;
esac
case "$DEC" in
  *VideoToolbox*) check 0 "the decoder implementation is VideoToolbox (hardware)" ;;
  *) check 1 "the decoder implementation is '${DEC:-none}', not VideoToolbox" ;;
esac
if [[ "$HWH264" == "True" || "$HWH264" == "true" ]]; then
  check 0 "libwebrtc's own stats report hardware H.264"
else
  check 1 "libwebrtc's own stats do not report hardware H.264"
fi

# 2. RESOLUTION. PLAN.md targets ~1080p effective, not the native Retina grid.
if [[ -n "$VW" && "$VW" -le 1920 && "$VW" -ge 640 ]]; then
  check 0 "the encoded width is ${VW}px (capped at 1920, PLAN.md ~1080p)"
else
  check 1 "the encoded width is '${VW}' -- outside the 640..1920 cap"
fi

# 3/4. THE ADAPTIVE FRAME RATE.
#
# This can only be judged if the captured screen was ACTUALLY IDLE during the
# measurement window. It frequently is not: a terminal caret, a progress
# spinner, a running build's output or a menu-bar clock are all genuine screen
# changes, and ScreenCaptureKit correctly reports dirty rects for them. The
# throttle is then behaving properly by staying at the active rate.
#
# Reporting FAIL for a condition the run never created sends you hunting a bug
# that is not there — so measure whether the screen was idle first, and say so.
# The policy's own thresholds (2s -> 5fps, 10s -> 1fps) are exact-value unit
# tested in CaptureTests.swift; this check is about the real capture path.
DIRTY_PER_SEC="$(dirty_rate_during_idle_window)"

if [[ "$(le "$DIRTY_PER_SEC" 3)" == "0" ]]; then SCREEN_WAS_IDLE=1; else SCREEN_WAS_IDLE=0; fi

if [[ "$SCREEN_WAS_IDLE" == "1" ]]; then
  # The screen really was still: the throttle MUST have engaged.
  if [[ "$FPS_DOWN" -le 5 ]]; then
    check 0 "the capture rate dropped to ${FPS_DOWN} fps once the screen stopped changing"
  else
    check 1 "the screen was idle (${DIRTY_PER_SEC} changed frames/s) but the capture rate never dropped below 30 fps -- the idle policy is NOT engaging"
  fi
  check "$(le "$IDLE_FPS" 8)" "idle decode rate ${IDLE_FPS} fps is within the static-screen budget (<= 8)"
else
  echo "SKIP  idle-throttle checks: the captured screen was NOT idle"
  echo "      (${DIRTY_PER_SEC} genuinely-changed frames/s during the window --"
  echo "       a caret, spinner or animating window was on screen)."
  echo "      Observed ${IDLE_FPS} fps / ${IDLE_KBPS} kbps, which is correct behaviour"
  echo "      for a CHANGING screen. To exercise the throttle, leave the captured"
  echo "      display genuinely still (no terminal output, no animation) and re-run."
fi

# Bitrate is meaningful either way: even an actively-changing desktop must
# compress to far less than a video stream.
check "$(le "$IDLE_KBPS" 800)" "bitrate ${IDLE_KBPS} kbps is a trickle (<= 800)"

# 5. THE HEADLINE BUDGET.
#
# PLAN.md §5 budgets CPU "idle, host, session open". Like the frame-rate checks
# above, that is only judgeable if the captured screen WAS idle during the
# window -- and it frequently is not, because a terminal caret or a running
# build is a genuine screen change and SCK correctly reports it. Encoding a
# 15 fps stream costs more than encoding a 1 fps one, so a number measured over
# a changing screen is not the budgeted number and reporting FAIL for it sends
# you hunting a throttle bug that is not there. Same idle test, same treatment.
if [[ "$SCREEN_WAS_IDLE" == "1" ]]; then
  if [[ "$(le "$IDLE_CPU_AVG" 5)" == "0" ]]; then
    check 0 "host CPU ${IDLE_CPU_AVG}% of one core is within the 5% budget"
  else
    check 1 "host CPU ${IDLE_CPU_AVG}% of one core EXCEEDS the 5% budget"
  fi
else
  echo "SKIP  the 5%-of-one-core CPU budget: the captured screen was NOT idle"
  echo "      (${DIRTY_PER_SEC} changed frames/s, ${IDLE_FPS} fps encoded), so"
  echo "      ${IDLE_CPU_AVG}% is the cost of encoding a CHANGING screen, which"
  echo "      PLAN.md §5 does not budget. Leave the display genuinely still and"
  echo "      re-run to measure the budgeted figure."
fi

echo
if [[ "$FAILED" == "0" ]]; then
  echo "CAPTURE VERIFICATION PASSED"
else
  echo "CAPTURE VERIFICATION FAILED"
fi
exit "$FAILED"
