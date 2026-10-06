#!/usr/bin/env bash
#
# Creates a STABLE local code-signing identity, once, so that macOS privacy
# grants survive a rebuild.
#
# THE PROBLEM THIS SOLVES
# ----------------------
# TCC (Screen Recording, Accessibility) keys a grant to the app's *designated
# requirement*. For an ad-hoc signed app that requirement is:
#
#     designated => cdhash H"c0908cbd…"
#
# — a hash of the binary itself. Every rebuild produces a different hash, so
# macOS considers the new build a DIFFERENT APP: the grant you gave five minutes
# ago no longer applies, the app is asked to prompt again, and System Settings
# accumulates several identical-looking "RemoteControl" rows that each grant a
# build that no longer exists. Toggling them does nothing, because none of them
# is the binary that is running.
#
# Signing with a certificate instead changes the requirement to:
#
#     designated => identifier "com.godson.remotecontrol" and certificate leaf = H"…"
#
# which depends on the CERTIFICATE, not on the binary. Rebuild as often as you
# like: it is the same app to TCC, and the grant sticks.
#
# This is NOT a substitute for a paid Apple Developer ID (it does nothing for
# Gatekeeper or for distribution — see PLAN.md §2.5 and build.sh). It only makes
# the identity stable on THIS machine, which is what the permission loop needs.
#
# WHAT THIS INSTALLS
# ------------------
# One self-signed code-signing certificate and its private key in YOUR login
# keychain, trusted for code signing by you only (never the system store). The
# key is usable by /usr/bin/codesign alone (-T), not by every process on the
# Mac, and `--undo` removes both the certificate and the trust setting.
#
# Run once:   ./scripts/make-signing-cert.sh
# Then:       ./scripts/build.sh          (picks the identity up automatically)
# Remove it:  ./scripts/make-signing-cert.sh --undo
#
# macOS will ask for your login password when the certificate is marked as
# trusted for code signing. That is the one-time cost.
set -euo pipefail

IDENTITY_NAME="${RC_LOCAL_IDENTITY:-RemoteControl Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d -t rc-signing)"
trap 'rm -rf "${WORK}"' EXIT

if [[ "${1:-}" == "--undo" ]]; then
    if ! security find-certificate -c "${IDENTITY_NAME}" -Z >/dev/null 2>&1; then
        echo "==> '${IDENTITY_NAME}' is not in the login keychain. Nothing to undo."
        exit 0
    fi
    echo "==> Removing the trust setting for '${IDENTITY_NAME}' (macOS may ask for your password)"
    security find-certificate -c "${IDENTITY_NAME}" -p > "${WORK}/installed.pem"
    security remove-trusted-cert "${WORK}/installed.pem" 2>/dev/null ||
        echo "    (no user trust setting to remove)"
    echo "==> Deleting the certificate and its private key"
    security delete-identity -c "${IDENTITY_NAME}" -t "${KEYCHAIN}" >/dev/null 2>&1 ||
        security delete-certificate -c "${IDENTITY_NAME}" -t "${KEYCHAIN}" >/dev/null 2>&1 || true
    if security find-certificate -c "${IDENTITY_NAME}" >/dev/null 2>&1; then
        echo "'${IDENTITY_NAME}' is still in the login keychain. Remove it in Keychain Access."
        exit 1
    fi
    echo "DONE. '${IDENTITY_NAME}' is gone; builds fall back to ad-hoc signing."
    exit 0
fi

if security find-certificate -c "${IDENTITY_NAME}" >/dev/null 2>&1; then
    echo "==> '${IDENTITY_NAME}' already exists in the login keychain."
    if security find-identity -v -p codesigning | grep -q "${IDENTITY_NAME}"; then
        echo "    It is valid for code signing. Nothing to do."
        echo "    Build with: ./scripts/build.sh"
        exit 0
    fi
    echo "    It exists but is NOT trusted for code signing; fixing the trust setting."
else
    echo "==> Generating a self-signed code-signing certificate: ${IDENTITY_NAME}"
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
        -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" \
        -subj "/CN=${IDENTITY_NAME}/O=RemoteControl/C=GB" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

    openssl pkcs12 -export -legacy \
        -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
        -out "${WORK}/identity.p12" -passout pass:remotecontrol 2>/dev/null ||
    openssl pkcs12 -export \
        -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
        -out "${WORK}/identity.p12" -passout pass:remotecontrol

    echo "==> Importing into the login keychain"
    # -T /usr/bin/codesign lets codesign, and only codesign, use the key without
    # a prompt on every build. Never -A: that lets ANY process on this Mac sign
    # with it silently.
    security import "${WORK}/identity.p12" -k "${KEYCHAIN}" \
        -P remotecontrol -T /usr/bin/codesign >/dev/null
fi

echo "==> Marking it trusted for code signing (macOS will ask for your password)"
# User-level trust only: this touches YOUR login keychain, not the system store,
# and trusts this one certificate for code signing and nothing else.
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" \
    <(security find-certificate -c "${IDENTITY_NAME}" -p) 2>/dev/null ||
security add-trusted-cert -r trustRoot -p codeSign -k "${KEYCHAIN}" "${WORK}/cert.pem"

echo
if security find-identity -v -p codesigning | grep -q "${IDENTITY_NAME}"; then
    echo "DONE. '${IDENTITY_NAME}' is ready."
    echo
    echo "Next:"
    echo "  1. ./scripts/build.sh                                  # signs with it automatically"
    echo "  2. tccutil reset ScreenCapture com.godson.remotecontrol"
    echo "     tccutil reset Accessibility com.godson.remotecontrol"
    echo "     (clears the stale duplicate rows in System Settings)"
    echo "  3. Launch the app and grant Screen Recording ONCE. It will now"
    echo "     survive every later rebuild."
else
    echo "The certificate was created but is still not listed as a valid code-signing"
    echo "identity. Open Keychain Access, find '${IDENTITY_NAME}' under login >"
    echo "Certificates, double-click it, and set Trust > Code Signing to 'Always Trust'."
    exit 1
fi
