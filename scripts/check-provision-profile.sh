#!/usr/bin/env bash
# Validates a Developer ID provisioning profile before scripts/build.sh embeds it.
#
# A profile that does not match the signing identity, the app identifier or the clock
# produces a bundle macOS refuses to launch, so this runs before anything is copied.
#
# Usage: check-provision-profile.sh <profile> <team-id> <bundle-id> [--now <epoch>]
# <profile> is a signed .provisionprofile or an already-decoded plist (both are read).
# Prints the expiry date on stdout; every diagnostic goes to stderr.
set -euo pipefail

PROFILE="${1:-}"
TEAM_ID="${2:-}"
BUNDLE_ID="${3:-}"
NOW="$(date -u +%s)"
if [[ "${4:-}" == "--now" ]]; then NOW="${5:?--now needs an epoch}"; fi

if [[ -z "$PROFILE" || -z "$TEAM_ID" || -z "$BUNDLE_ID" ]]; then
    echo "usage: check-provision-profile.sh <profile> <team-id> <bundle-id> [--now <epoch>]" >&2
    exit 2
fi

fail() { echo "provisioning profile: $1" >&2; exit 1; }

[[ -f "$PROFILE" ]] || fail "no file at ${PROFILE}"

PLIST="$(mktemp -t rc-profile).plist"
trap 'rm -f "$PLIST"' EXIT

if [[ "$(head -c 5 "$PROFILE")" == "<?xml" ]]; then
    cp "$PROFILE" "$PLIST"
elif ! security cms -D -i "$PROFILE" -o "$PLIST" 2>/dev/null; then
    fail "${PROFILE} is not a signed profile this Mac can decode"
fi
plutil -lint "$PLIST" >/dev/null 2>&1 || fail "${PROFILE} does not decode to a property list"

TEAMS="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier' "$PLIST" 2>/dev/null || true)"
if ! grep -qxE "[[:space:]]*${TEAM_ID}[[:space:]]*" <<<"$TEAMS"; then
    fail "its TeamIdentifier does not contain ${TEAM_ID}"
fi

APP_IDENTIFIER="$(/usr/libexec/PlistBuddy \
    -c 'Print :Entitlements:com.apple.application-identifier' "$PLIST" 2>/dev/null || true)"
EXPECTED="${TEAM_ID}.${BUNDLE_ID}"
if [[ "$APP_IDENTIFIER" != "$EXPECTED" ]]; then
    fail "its application-identifier is '${APP_IDENTIFIER:-missing}', not ${EXPECTED}"
fi

EXPIRY="$(plutil -extract ExpirationDate raw -o - "$PLIST" 2>/dev/null || true)"
[[ -n "$EXPIRY" ]] || fail "it has no ExpirationDate"
EXPIRY_EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$EXPIRY" +%s 2>/dev/null || true)"
[[ -n "$EXPIRY_EPOCH" ]] || fail "its ExpirationDate '${EXPIRY}' is not a date"
if (( EXPIRY_EPOCH <= NOW )); then
    fail "it expired on ${EXPIRY}"
fi

echo "$EXPIRY"
