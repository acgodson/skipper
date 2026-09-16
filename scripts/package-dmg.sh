#!/usr/bin/env bash
# Builds RemoteControl.dmg — the thing you actually copy to the second Mac.
#
# Ad-hoc / locally signed, deliberately: there is no paid Apple Developer
# account (PLAN.md 2.5). Gatekeeper therefore needs ONE right-click > Open on
# first launch. Transferring by AirDrop/USB/scp instead of a browser download
# usually avoids even that, because no quarantine attribute is attached.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/RemoteControl.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
DMG="dist/RemoteControl-${VERSION}.dmg"
STAGE="$(mktemp -d -t rc-dmg)"
trap 'rm -rf "$STAGE"' EXIT

[[ -d "$APP" ]] || { echo "build it first: ./scripts/build.sh" >&2; exit 1; }

echo "==> Verifying the bundle before shipping it"
codesign --verify --deep --strict "$APP" || { echo "FAIL: signature invalid" >&2; exit 1; }
# A .dmg that installs an app which then cannot find its own framework is the
# single worst thing to discover on a machine you cannot debug on.
if ! otool -l "$APP/Contents/MacOS/RemoteControl" | grep -q "@executable_path/../Frameworks"; then
  echo "FAIL: no @executable_path rpath — WebRTC.framework will not resolve" >&2; exit 1
fi
[[ -d "$APP/Contents/Frameworks/WebRTC.framework" ]] || { echo "FAIL: WebRTC.framework not embedded" >&2; exit 1; }

echo "==> Staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
RemoteControl
=============

1. Drag RemoteControl.app onto the Applications folder.

2. FIRST LAUNCH. This app is not notarised by Apple (no paid Developer ID),
   so macOS blocks it once. Easiest fix - run this in Terminal:

       xattr -cr /Applications/RemoteControl.app

   Then open the app normally. No warning at all.

   Without Terminal: double-click the app and LET IT BE REFUSED, then go
   straight to System Settings > Privacy & Security, scroll to the bottom,
   and click "Open Anyway". The button only appears AFTER a blocked attempt
   and disappears after about an hour - that is why it may look missing.

3. Grant these two permissions when asked
   (System Settings > Privacy & Security):

     - Screen & System Audio Recording   -> so this Mac can share its screen
     - Accessibility                     -> so the other Mac can control it

   Without Screen Recording the other Mac connects but sees nothing.
   Without Accessibility the mouse and keyboard will not work.

4. The app shows a Device ID and an Access Code. Give BOTH to the Mac that
   will be doing the controlling. The code does not expire and does not
   rotate on its own; it changes only when you press "Refresh Access Code".

5. Leave the app running. Closing the window keeps it alive in the menu bar,
   which is what makes unattended access work. Enable "Launch at Login" so it
   comes back after a reboot.
TXT

echo "==> Building $DMG"
rm -f "$DMG"
hdiutil create -volname "RemoteControl" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Verifying the image mounts and the app inside it is intact"
MP="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | tail -1)"
codesign --verify --deep --strict "$MP/RemoteControl.app" \
  && echo "    signature OK inside the image" \
  || { hdiutil detach "$MP" >/dev/null; echo "FAIL: bad signature inside dmg" >&2; exit 1; }
hdiutil detach "$MP" >/dev/null

# ---- Developer ID: sign + notarise the IMAGE itself -------------------------
# Stapling the .app is not enough. The disk image is what gets downloaded, so it
# carries the quarantine flag and is what Gatekeeper assesses first. An unsigned
# image around a notarised app still shows "Apple could not verify...".
#
# This is DIRECT distribution, not the App Store: notarisation is an automated
# malware scan (typically 1-15 min), with no App Review and no human approval.
SIGN_IDENTITY="${RC_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${RC_NOTARY_PROFILE:-}"

if [[ "$SIGN_IDENTITY" == "Developer ID"* ]]; then
  echo "==> Signing the disk image"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"

  if [[ -n "$NOTARY_PROFILE" ]]; then
    echo "==> Notarising the disk image (automated scan; no App Store review)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> Verifying the stapled ticket"
    xcrun stapler validate "$DMG"
    spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /' || true
    echo "    This image now opens with a plain double-click, no warning."
  else
    echo "    RC_NOTARY_PROFILE unset -- signed but NOT notarised."
    echo "    Gatekeeper will still warn. See below."
  fi
else
  cat <<'NOTE'

    NOTE: ad-hoc / locally signed, so Gatekeeper will warn on first open.
    That is expected, not a failure. Recipient does ONE of:
      - right-click the app > Open > Open        (macOS 14 and earlier)
      - System Settings > Privacy & Security > "Open Anyway"   (macOS 15+)
      - xattr -c /Applications/RemoteControl.app

    To remove the warning entirely with an Apple Developer account:
      RC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
      RC_NOTARY_PROFILE=rc-notary \
        ./scripts/build.sh && ./scripts/package-dmg.sh
NOTE
fi

echo
echo "==> $DMG  ($(du -h "$DMG" | cut -f1))"
echo "    sha256 $(shasum -a 256 "$DMG" | awk '{print $1}')"
