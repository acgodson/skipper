#!/usr/bin/env bash
#
# Builds SkipperDesk, packages the dmg, and assembles dist/verify-bundle/ —
# everything to hand to the second Mac for two-Mac verification: the dmg,
# scripts/launch-with-backend.sh, and a README.txt with install and launch
# steps. If dist/tunnel-url.txt exists (scripts/dev-tunnel.sh has already run
# on this Mac), the launch command in README.txt is filled in with that URL.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
BUNDLE_DIR="$DIST/verify-bundle"

"$ROOT/scripts/build.sh"
"$ROOT/scripts/package-dmg.sh" "$@"

DMG="$(ls -t "$DIST"/SkipperDesk-*.dmg 2>/dev/null | head -1)"
[[ -n "$DMG" ]] || { echo "FAIL  no dmg found in $DIST after package-dmg.sh" >&2; exit 1; }

TUNNEL_URL=""
[[ -f "$DIST/tunnel-url.txt" ]] && TUNNEL_URL="$(cat "$DIST/tunnel-url.txt")"
LAUNCH_URL="${TUNNEL_URL:-<paste the tunnel URL from the host Mac here>}"

echo "== assembling $BUNDLE_DIR"
rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR"
cp "$DMG" "$BUNDLE_DIR/"
cp "$ROOT/scripts/launch-with-backend.sh" "$BUNDLE_DIR/"
chmod +x "$BUNDLE_DIR/launch-with-backend.sh"

cat > "$BUNDLE_DIR/README.txt" <<TXT
SkipperDesk — two-Mac verification bundle
==========================================

This is everything needed on the SECOND Mac to verify Phase 1-2 against the
backend running on the host Mac (see docs/VERIFY.md in the repo for the full
checklist).

1. Install
   - Copy this whole folder to the second Mac (AirDrop, USB, or scp — not a
     browser download, which adds a quarantine flag).
   - Open the .dmg and drag SkipperDesk.app to Applications.
   - Once: xattr -cr /Applications/SkipperDesk.app
     (this build is not notarised; Gatekeeper otherwise blocks first launch)

2. Permissions
   Launch the app once, then in System Settings > Privacy & Security grant:
   - Screen & System Audio Recording (needed only if this Mac will HOST)
   - Accessibility (needed only if this Mac will HOST)
   A pure controller does not need either.

3. Launch pointed at the host Mac's tunnel
   From a Terminal in this folder:

       ./launch-with-backend.sh $LAUNCH_URL

   Add --debug to also set RC_DEBUG=1 and write a log
   (path printed on launch) — see docs/VERIFY.md for what to capture.

   The URL is printed by scripts/dev-tunnel.sh on the host Mac and saved to
   its dist/tunnel-url.txt. It changes every time that script restarts, so
   confirm it is current before launching here.
TXT

echo
echo "== $BUNDLE_DIR"
ls -la "$BUNDLE_DIR"
