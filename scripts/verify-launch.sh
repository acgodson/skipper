#!/usr/bin/env bash
# The most basic property there is: the built app starts and stays started.
#
# It exists because a recursive static initialisation once trapped SkipperDesk on launch
# while all 421 tests passed — the suite builds the app but never ran it. A crash in a
# `static let` chain is invisible to anything that does not start the process.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/SkipperDesk.app"
SECONDS_UP="${RC_LAUNCH_SECONDS:-6}"

if [[ ! -d "$APP" ]]; then
    echo "FAIL  no built app at $APP; run scripts/build.sh first"
    exit 1
fi

if pgrep -x SkipperDesk >/dev/null 2>&1; then
    echo "skip  SkipperDesk is already running; not disturbing it"
    exit 0
fi

BEFORE="$(ls -t "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -c '^SkipperDesk' || true)"

open "$APP"
sleep "$SECONDS_UP"

if ! pgrep -x SkipperDesk >/dev/null 2>&1; then
    AFTER="$(ls -t "$HOME/Library/Logs/DiagnosticReports/" 2>/dev/null | grep -c '^SkipperDesk' || true)"
    echo "FAIL  the app did not stay up for ${SECONDS_UP}s"
    if [[ "$AFTER" -gt "$BEFORE" ]]; then
        REPORT="$(ls -t "$HOME"/Library/Logs/DiagnosticReports/SkipperDesk* | head -1)"
        echo "      crash report: $REPORT"
        grep -oE '"(exception|asi)":[^}]*}' "$REPORT" | head -2 || true
    fi
    exit 1
fi

osascript -e 'quit app "SkipperDesk"' >/dev/null 2>&1 || true
for _ in $(seq 1 20); do
    pgrep -x SkipperDesk >/dev/null 2>&1 || break
    sleep 0.5
done
pkill -x SkipperDesk 2>/dev/null || true

echo "  ok    the app launched and stayed up for ${SECONDS_UP}s"
