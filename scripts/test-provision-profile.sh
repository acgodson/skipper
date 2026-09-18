#!/usr/bin/env bash
# Exercises scripts/check-provision-profile.sh against hand-made profile plists.
#
# No real profile and no signing identity are needed: the validator accepts an
# already-decoded plist, which is what a signed profile becomes anyway.
set -uo pipefail
cd "$(dirname "$0")/.."
CHECK="./scripts/check-provision-profile.sh"
TEAM="3UB3KZP9WH"
BUNDLE="app.skipperdesk.desktop"
NOW=1789704458
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

fixture() {
    local name="$1" team="$2" identifier="$3" expiry="$4" path="${WORK}/${1}.plist"
    cat > "$path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Name</key><string>SkipperDesk ${name}</string>
    <key>TeamIdentifier</key>
    <array>
        <string>${team}</string>
    </array>
    <key>ExpirationDate</key><date>${expiry}</date>
    <key>Entitlements</key>
    <dict>
        <key>com.apple.application-identifier</key><string>${identifier}</string>
        <key>keychain-access-groups</key>
        <array>
            <string>${identifier}</string>
        </array>
    </dict>
</dict>
</plist>
PLIST
    echo "$path"
}

expect_accept() {
    local label="$1" path="$2" want="$3" got
    if got="$("$CHECK" "$path" "$TEAM" "$BUNDLE" --now "$NOW" 2>/dev/null)" && [[ "$got" == "$want" ]]; then
        echo "  ok    ${label}"
    else
        echo "  FAIL  ${label}: expected the expiry ${want}, got '${got:-a refusal}'"
        fail=1
    fi
}

expect_reject() {
    local label="$1" path="$2" reason="$3" output
    output="$("$CHECK" "$path" "$TEAM" "$BUNDLE" --now "$NOW" 2>&1 >/dev/null)"
    if [[ $? -eq 0 ]]; then
        echo "  FAIL  ${label}: accepted"
        fail=1
    elif ! grep -q "$reason" <<<"$output"; then
        echo "  FAIL  ${label}: refused with '${output}', which does not mention ${reason}"
        fail=1
    else
        echo "  ok    ${label}"
    fi
}

echo "== provisioning profile validation"
expect_accept "a matching, unexpired profile is accepted and its expiry printed" \
    "$(fixture good "$TEAM" "${TEAM}.${BUNDLE}" "2027-09-18T12:00:00Z")" "2027-09-18T12:00:00Z"
expect_reject "another team's profile" \
    "$(fixture other-team "AB12CD34EF" "AB12CD34EF.${BUNDLE}" "2027-09-18T12:00:00Z")" "TeamIdentifier"
expect_reject "another app's identifier" \
    "$(fixture other-app "$TEAM" "${TEAM}.app.skipperdesk.other" "2027-09-18T12:00:00Z")" "application-identifier"
expect_reject "an expired profile" \
    "$(fixture expired "$TEAM" "${TEAM}.${BUNDLE}" "2020-01-01T00:00:00Z")" "expired"
expect_reject "a file that is not a profile at all" \
    "$(printf 'not a profile' > "${WORK}/junk"; echo "${WORK}/junk")" "not a signed profile"
expect_reject "a missing file" "${WORK}/absent" "no file at"

echo
if [[ $fail -eq 0 ]]; then
    echo "PROVISION PROFILE CHECKS PASSED"
else
    echo "PROVISION PROFILE CHECKS FAILED" >&2
fi
exit $fail
