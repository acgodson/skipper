#!/usr/bin/env bash
#
# Assembles a launchable SkipperDesk.app without Xcode.
#
# This machine has Command Line Tools only, so there is no `xcodebuild` and no
# .xcodeproj anywhere in this repo. SwiftPM compiles the binary; this script
# hand-assembles the bundle around it. Idempotent: safe to re-run.
#
set -euo pipefail

REPRODUCIBLE=0
TEST_HOOKS=0
for arg in "$@"; do
    case "$arg" in
        --reproducible) REPRODUCIBLE=1 ;;
        --test-hooks) TEST_HOOKS=1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "$REPRODUCIBLE" -eq 1 ]]; then
    SOURCE_DATE_EPOCH="$(git -C "${REPO_ROOT}" log -1 --format=%ct 2>/dev/null || echo 0)"
    export SOURCE_DATE_EPOCH
    echo "==> --reproducible: SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH} (from HEAD commit time)"
fi
APP_DIR="${REPO_ROOT}/apps/macos"
DIST_DIR="${REPO_ROOT}/dist"
# The SwiftPM product is still named "RemoteControl" (apps/macos/Package.swift);
# the shipped bundle and everything user-visible is "SkipperDesk".
SWIFT_PRODUCT="RemoteControl"
APP_NAME="SkipperDesk"
BUNDLE_ID="app.skipperdesk.desktop"
URL_SCHEME="skipperdesk"
VERSION="1.0.0"          # V1: phases 0-7
BUILD_NUMBER="3"
MIN_MACOS="13.0"
ARCH="arm64"
CONFIG="release"

# ---- Signing configuration --------------------------------------------------
# ONE place that decides the signing identity; nothing else in this script
# mentions one. A release build is signed with a Developer ID:
#   RC_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" ./scripts/build.sh
# and RC_NOTARY_PROFILE names a `notarytool store-credentials` profile to
# additionally notarise and staple.
LOCAL_IDENTITY="${RC_LOCAL_IDENTITY:-RemoteControl Local Signing}"
NOTARY_PROFILE="${RC_NOTARY_PROFILE:-}"

# Identity selection, in order of preference:
#   1. RC_SIGN_IDENTITY, if the caller set one (the Developer ID for releases).
#   2. The local self-signed identity from scripts/make-signing-cert.sh, if it
#      is in the keychain.
#   3. Ad-hoc.
#
# Why 2 exists at all: TCC keys Screen Recording and Accessibility grants to the
# app's designated requirement, and for an AD-HOC signature that requirement is
# `cdhash H"..."` — a hash of the binary. Every rebuild therefore looks like a
# brand-new app to macOS: the grant the user just gave stops applying, the app
# re-prompts, and System Settings fills up with identical dead "RemoteControl"
# rows. Signing with any stable certificate makes the requirement
# `identifier "app.skipperdesk.desktop" and certificate leaf = H"..."`, which
# does not move when the code does. This buys nothing for Gatekeeper or for
# distribution, but it is the difference between granting Screen Recording once
# and granting it after every local build.
if [[ -n "${RC_SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${RC_SIGN_IDENTITY}"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "${LOCAL_IDENTITY}"; then
    SIGN_IDENTITY="${LOCAL_IDENTITY}"
else
    SIGN_IDENTITY="-"
fi

if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    SIGN_DESCRIPTION="ad-hoc — privacy grants will be lost on every rebuild; run scripts/make-signing-cert.sh once to stop that"
else
    SIGN_DESCRIPTION="${SIGN_IDENTITY}"
fi

BUNDLE="${DIST_DIR}/${APP_NAME}.app"
CONTENTS="${BUNDLE}/Contents"

# The session state machine lives in Rust and the app links it statically, so
# the core is built first or there is nothing for SwiftPM to link against.
"${REPO_ROOT}/scripts/build-core.sh"

echo "==> Building ${APP_NAME} (${CONFIG}, ${ARCH})"
cd "${APP_DIR}"
SWIFT_BUILD_FLAGS=("-c" "${CONFIG}" "--arch" "${ARCH}")
if [[ "$REPRODUCIBLE" -eq 1 ]]; then
    SWIFT_BUILD_FLAGS+=("-Xswiftc" "-debug-prefix-map" "-Xswiftc" "${REPO_ROOT}=/BUILD")
fi
if [[ "$TEST_HOOKS" -eq 1 ]]; then
    SWIFT_BUILD_FLAGS+=("-Xswiftc" "-DSKIPPER_TEST_HOOKS")
    echo "==> --test-hooks: development environment hooks COMPILED IN. Never ship this build."
fi
swift build --force-resolved-versions "${SWIFT_BUILD_FLAGS[@]}"

BIN_PATH="$(swift build -c "${CONFIG}" --arch "${ARCH}" --show-bin-path)"
if [[ ! -x "${BIN_PATH}/${SWIFT_PRODUCT}" ]]; then
    echo "error: expected executable at ${BIN_PATH}/${SWIFT_PRODUCT}" >&2
    exit 1
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

cp "${BIN_PATH}/${SWIFT_PRODUCT}" "${CONTENTS}/MacOS/${APP_NAME}"
chmod +x "${CONTENTS}/MacOS/${APP_NAME}"

# SwiftPM emits the SwiftUI/Foundation resource bundles next to the binary when
# a target has resources. Copy any that exist so the bundle is self-contained.
shopt -s nullglob
for RESOURCE_BUNDLE in "${BIN_PATH}"/*.bundle; do
    cp -R "${RESOURCE_BUNDLE}" "${CONTENTS}/Resources/"
done
shopt -u nullglob

# ---- Embedded frameworks ----------------------------------------------------
# libwebrtc arrives as a binary xcframework. SwiftPM leaves the extracted
# WebRTC.framework next to the binary and links it as
# @rpath/WebRTC.framework/WebRTC, but the executable only carries an
# @loader_path rpath -- so a bundle without this step builds, signs and verifies
# perfectly and then dies at launch with "Library not loaded". It has to be
# copied in and given an rpath that points at it, and the @loader_path rpath is
# removed so the only place dyld looks is the signed Frameworks directory.
mkdir -p "${CONTENTS}/Frameworks"
FRAMEWORK_SRC="${BIN_PATH}/WebRTC.framework"
if [[ -d "${FRAMEWORK_SRC}" ]]; then
    rm -rf "${CONTENTS}/Frameworks/WebRTC.framework"
    cp -R "${FRAMEWORK_SRC}" "${CONTENTS}/Frameworks/"
    while otool -l "${CONTENTS}/MacOS/${APP_NAME}" | grep -q "path @loader_path "; do
        install_name_tool -delete_rpath "@loader_path" "${CONTENTS}/MacOS/${APP_NAME}"
    done
    if ! otool -l "${CONTENTS}/MacOS/${APP_NAME}" | grep -q "path @executable_path/../Frameworks "; then
        install_name_tool -add_rpath "@executable_path/../Frameworks" "${CONTENTS}/MacOS/${APP_NAME}"
    fi
    echo "==> Embedded WebRTC.framework"
else
    echo "error: WebRTC.framework not found at ${FRAMEWORK_SRC}" >&2
    echo "       The app would launch and immediately fail to load libwebrtc." >&2
    exit 1
fi

printf '%s' "APPL????" > "${CONTENTS}/PkgInfo"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleSignature</key>             <string>????</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${BUILD_NUMBER}</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>LSMinimumSystemVersion</key>        <string>${MIN_MACOS}</string>
    <key>NSHumanReadableCopyright</key>      <string>© 2026 SkipperDesk</string>
    <key>LSUIElement</key>                   <false/>

    <key>NSScreenCaptureUsageDescription</key>
    <string>${APP_NAME} shares this Mac's screen with a device you authorise using its Access Code.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>${APP_NAME} does not automate other apps. This key is present only so any incidental system prompt is explained.</string>

    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>   <true/>
    </dict>

    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>       <string>${BUNDLE_ID}</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>${URL_SCHEME}</string>
            </array>
        </dict>
    </array>

    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key>   <false/>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

if [[ "$TEST_HOOKS" -eq 1 ]]; then
    /usr/libexec/PlistBuddy -c "Add :SkipperTestHooks bool true" "${CONTENTS}/Info.plist" >/dev/null
fi

# ---- Icon (optional) --------------------------------------------------------
# If an iconset is present, compile it. Never fail the build over an icon.
ICONSET="${REPO_ROOT}/apps/macos/Resources/AppIcon.iconset"
if [[ -d "${ICONSET}" ]] && command -v iconutil >/dev/null 2>&1; then
    if iconutil -c icns "${ICONSET}" -o "${CONTENTS}/Resources/AppIcon.icns" 2>/dev/null; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "${CONTENTS}/Info.plist" >/dev/null 2>&1 || true
        echo "==> Icon compiled from ${ICONSET}"
    else
        echo "==> Icon compilation failed; continuing without an icon"
    fi
else
    echo "==> No apps/macos/Resources/AppIcon.iconset; using the default system icon"
fi

# ---- Entitlements + signing -------------------------------------------------
#
# The Secure Enclave is entitlement-gated. `SecureEnclave.P256.Signing.PrivateKey`
# fails with errSecMissingEntitlement (-34018) unless the binary carries
# com.apple.application-identifier, and that entitlement is only honoured under a
# Developer ID signature. Team ID comes from SKIPPER_TEAM_ID or from the selected
# identity's own "Developer ID Application: NAME (TEAMID)" suffix. Every Keychain
# item lives in the data-protection keychain under the TEAMID.app.skipperdesk.desktop
# access group, so keychain-access-groups is always added when a Team ID exists.
# Without one the build still succeeds, but the app reads no Team ID from its own
# signature and refuses to create an identity outside the dev file-identity mode.
KEYCHAIN_APP_IDENTIFIER="app.skipperdesk.desktop"
TEAM_ID="${SKIPPER_TEAM_ID:-}"
if [[ -z "${TEAM_ID}" && "${SIGN_IDENTITY}" == "Developer ID Application:"* ]]; then
    TEAM_ID="$(printf '%s' "${SIGN_IDENTITY}" | sed -n 's/.*(\([A-Z0-9]\{6,\}\))[[:space:]]*$/\1/p')"
fi

if [[ -n "${TEAM_ID}" ]]; then
    KEYCHAIN_ENTITLEMENTS="$(cat <<KC_ENTS
    <key>com.apple.application-identifier</key>
    <string>${TEAM_ID}.${KEYCHAIN_APP_IDENTIFIER}</string>
    <key>keychain-access-groups</key>
    <array>
        <string>${TEAM_ID}.${KEYCHAIN_APP_IDENTIFIER}</string>
    </array>
KC_ENTS
)"
    echo "==> Keychain access group and Secure Enclave entitlements for team ${TEAM_ID} (${TEAM_ID}.${KEYCHAIN_APP_IDENTIFIER})"
else
    KEYCHAIN_ENTITLEMENTS=""
    echo "No Developer ID identity; this build cannot store keys"
    echo "    The app refuses to create an identity unless SKIPPER_DEV_FILE_IDENTITY=1 or RC_IDENTITY_DIR is set."
    echo "    Set SKIPPER_TEAM_ID, or sign with a Developer ID Application identity, to enable it."
fi

ENTITLEMENTS="$(mktemp -t rc-entitlements).plist"
cat > "${ENTITLEMENTS}" <<ENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Not sandboxed: screen capture of the whole desktop and system-wide
         CGEvent injection are incompatible with the App Sandbox. -->
    <key>com.apple.security.app-sandbox</key>            <false/>
    <key>com.apple.security.network.client</key>         <true/>
    <key>com.apple.security.device.camera</key>          <false/>
    <key>com.apple.security.device.microphone</key>      <false/>
${KEYCHAIN_ENTITLEMENTS}
</dict>
</plist>
ENTS

echo "==> Signing (${SIGN_DESCRIPTION})"
# Only a Developer ID gets a trusted timestamp: ad-hoc signatures cannot have
# one, and a self-signed local identity has no timestamp authority behind it.
if [[ "${SIGN_IDENTITY}" != "Developer ID"* ]]; then
    TIMESTAMP_FLAG="--timestamp=none"
else
    TIMESTAMP_FLAG="--timestamp"
fi

# Library validation only admits frameworks carrying the app's Team ID, and only
# Apple-issued certificates record one. A Team ID build therefore gets the full
# hardened runtime. A local or ad-hoc build could never load its own
# WebRTC.framework under it, so it is signed without the runtime (kill,hard
# only; "restrict" would also forbid the @rpath lookup) and is never granted
# disable-library-validation. Such a build is for development, not distribution.
if [[ "${SIGN_IDENTITY}" == "Developer ID"* || "${SIGN_IDENTITY}" == "Apple Development"* ]]; then
    SIGN_OPTIONS="runtime"
else
    SIGN_OPTIONS="kill,hard"
    echo "    no Team ID: hardened runtime off (development build only; not for distribution)"
fi

codesign --force --deep --sign "${SIGN_IDENTITY}" \
    --entitlements "${ENTITLEMENTS}" \
    --options "${SIGN_OPTIONS}" \
    "${TIMESTAMP_FLAG}" \
    "${BUNDLE}" 2>&1 | sed 's/^/    /'
rm -f "${ENTITLEMENTS}"

codesign --verify --verbose=1 "${BUNDLE}" 2>&1 | sed 's/^/    /'

# ---- Launch check -----------------------------------------------------------
# codesign --verify says nothing about whether the dynamic linker can actually
# resolve the embedded framework. Ask dyld directly; this is what caught the
# missing WebRTC.framework in the first place.
echo "==> Verifying the dynamic linker can resolve every library"
if MISSING="$(otool -L "${CONTENTS}/MacOS/${APP_NAME}" | awk '/@rpath/ {print $1}')"; then
    for LIB in ${MISSING}; do
        REL="${LIB#@rpath/}"
        if [[ ! -e "${CONTENTS}/Frameworks/${REL}" && ! -e "${CONTENTS}/MacOS/${REL}" ]]; then
            echo "error: ${LIB} is not present in the bundle" >&2
            exit 1
        fi
        echo "    ok  ${LIB}"
    done
fi

# ---- Notarisation (only with a real identity) -------------------------------
if [[ "${SIGN_IDENTITY}" == "Developer ID"* && -n "${NOTARY_PROFILE}" ]]; then
    echo "==> Notarising with keychain profile '${NOTARY_PROFILE}'"
    ditto -c -k --keepParent "${BUNDLE}" "${DIST_DIR}/${APP_NAME}.zip"
    xcrun notarytool submit "${DIST_DIR}/${APP_NAME}.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${BUNDLE}"
    rm -f "${DIST_DIR}/${APP_NAME}.zip"
elif [[ "${SIGN_IDENTITY}" == "Developer ID"* ]]; then
    echo "==> Signed with a real identity but RC_NOTARY_PROFILE is unset; skipping notarisation"
fi

# -----------------------------------------------------------------------------

# The designated requirement IS the TCC identity. Printing it makes "why did my
# Screen Recording grant disappear?" a one-line answer rather than an afternoon.
if [[ "$REPRODUCIBLE" -eq 1 ]]; then
    echo "==> --reproducible: normalising file timestamps to SOURCE_DATE_EPOCH"
    find "${BUNDLE}" -exec touch -t "$(date -r "${SOURCE_DATE_EPOCH}" +%Y%m%d%H%M.%S)" {} +
    echo "    Info.plist carries no build timestamp key; nothing to strip there."
    echo "    NOT reproducible: WebRTC.framework is prebuilt by the stasel/WebRTC project from"
    echo "    Google's libwebrtc, pinned by exact version and checksum, never rebuilt here."
fi

echo "==> Designated requirement (this is what macOS ties privacy grants to)"
codesign -d -r- "${BUNDLE}" 2>&1 | grep designated | sed 's/^/    /' || true
if [[ "${SIGN_IDENTITY}" == "-" ]]; then
    echo "    ^ contains a cdhash, so THIS grant dies at the next rebuild."
    echo "      Run ./scripts/make-signing-cert.sh once to make it stable."
fi

echo
echo "==> Built: ${BUNDLE}"
echo "    Launch with: open \"${BUNDLE}\""
