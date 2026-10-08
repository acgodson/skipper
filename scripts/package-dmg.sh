#!/usr/bin/env bash
# Packages dist/SkipperDesk.app into a dmg; refuses anything but a hardened Developer ID build unless --dev.
# --release (or RC_RELEASE=1) additionally refuses to produce an image that is not signed AND notarised.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOW_DEV=0
for arg in "$@"; do
  case "$arg" in
    --dev) ALLOW_DEV=1 ;;
    --release) RC_RELEASE=1 ;;
    *) echo "usage: $0 [--dev | --release]" >&2; exit 2 ;;
  esac
done

APP="dist/SkipperDesk.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo 0.0.0)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
MINIMUM_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 13.0)"
DMG="dist/SkipperDesk-${VERSION}.dmg"
RELEASE_JSON="dist/SkipperDesk-${VERSION}.release.json"
STAGE="$(mktemp -d -t rc-dmg)"
trap 'rm -rf "$STAGE"' EXIT

[[ -d "$APP" ]] || { echo "build it first: ./scripts/build.sh" >&2; exit 1; }

echo "==> Verifying the bundle before shipping it"
codesign --verify --deep --strict "$APP" || { echo "FAIL: signature invalid" >&2; exit 1; }
if ! otool -l "$APP/Contents/MacOS/SkipperDesk" | grep -q "@executable_path/../Frameworks"; then
  echo "FAIL: no @executable_path rpath — WebRTC.framework will not resolve" >&2; exit 1
fi
[[ -d "$APP/Contents/Frameworks/WebRTC.framework" ]] || { echo "FAIL: WebRTC.framework not embedded" >&2; exit 1; }

SIGN_IDENTITY="${RC_SIGN_IDENTITY:-}"
NOTARY_PROFILE="${RC_NOTARY_PROFILE:-}"
SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
if grep -q "^Authority=Developer ID Application" <<<"$SIGN_INFO"; then
  DEVELOPER_ID_APP=1
  FIRST_LAUNCH="2. FIRST LAUNCH. Open the app from Applications. macOS confirms once that
   it was downloaded from the internet; click Open."
else
  DEVELOPER_ID_APP=0
  if [[ "$ALLOW_DEV" -ne 1 ]]; then
    echo "FAIL: not signed with a Developer ID Application certificate; use --dev for a development image" >&2
    exit 1
  fi
  FIRST_LAUNCH="2. FIRST LAUNCH. This is a development build. If macOS refuses to open it,
   go to System Settings > Privacy & Security and click \"Open Anyway\"."
fi

if [[ "$DEVELOPER_ID_APP" -eq 1 ]]; then
  grep -qE '^CodeDirectory .*flags=0x[0-9a-f]*\(.*runtime' <<<"$SIGN_INFO" \
    || { echo "FAIL: Developer ID build without the hardened runtime" >&2; exit 1; }
  ./scripts/check-isolation.sh >/dev/null || { echo "FAIL: isolation check" >&2; exit 1; }
fi

echo "==> Staging"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/READ ME FIRST.txt" <<TXT
SkipperDesk
===========

1. Drag SkipperDesk.app onto the Applications folder.

${FIRST_LAUNCH}

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
hdiutil create -volname "SkipperDesk" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Verifying the image mounts and the app inside it is intact"
MP="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | tail -1)"
codesign --verify --deep --strict "$MP/SkipperDesk.app" \
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
# --release says this image is meant for strangers, so a missing identity or notary
# profile is a failure rather than a quieter build. Skipping them produced a notarised
# app inside an UNSIGNED image once: Gatekeeper assesses the image first, so it warned
# on a build that was in fact notarised. Note that `VAR=x ./build.sh && ./package-dmg.sh`
# sets VAR for build.sh ALONE, which is exactly how that happened.
if [[ "${RC_RELEASE:-0}" == "1" ]]; then
  if [[ "$SIGN_IDENTITY" != "Developer ID"* ]]; then
    echo "FAIL  --release needs RC_SIGN_IDENTITY to be a Developer ID identity; got '${SIGN_IDENTITY:-unset}'"
    echo "      export it rather than prefixing one command: export RC_SIGN_IDENTITY=... RC_NOTARY_PROFILE=..."
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "FAIL  --release needs RC_NOTARY_PROFILE; an unnotarised image warns on every Mac that downloads it"
    exit 1
  fi
fi

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
    echo "    Gatekeeper will still warn until the image is notarised."
  fi
else
  if [[ "$DEVELOPER_ID_APP" -eq 0 ]]; then
    cat <<'NOTE'

    DEVELOPER NOTE: ad-hoc / locally signed, so Gatekeeper warns on first open.
    That is expected for a development build. On your own test Mac, either:
      - System Settings > Privacy & Security > "Open Anyway"
      - xattr -cr /Applications/SkipperDesk.app

    To remove the warning entirely with an Apple Developer account:
      RC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
      RC_NOTARY_PROFILE=rc-notary \
        ./scripts/build.sh && ./scripts/package-dmg.sh
NOTE
  fi
fi

SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(stat -f %z "$DMG")"
printf '{"version":"%s","build":"%s","minimumOS":"%s","sha256":"%s","size":%s}\n' \
  "$VERSION" "$BUILD" "$MINIMUM_OS" "$SHA256" "$SIZE" > "$RELEASE_JSON"

echo
echo "==> $DMG  ($(du -h "$DMG" | cut -f1))"
echo "==> Release fields for GET /v1/app/releases/latest (protocol/API.md §10), saved to $RELEASE_JSON"
cat "$RELEASE_JSON"
