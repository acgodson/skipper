#!/usr/bin/env bash
#
# Removes the Keychain items left behind by builds of RemoteControl from before
# it moved to file-based identity storage.
#
# WHY THIS IS A SCRIPT AND NOT PART OF THE APP
# --------------------------------------------
# The app used to store its device key and access code in the login Keychain.
# Because these builds are ad-hoc signed, the code signature — and therefore the
# Keychain ACL identity — changes on every rebuild, so macOS asked
# "RemoteControl wants to use your confidential information" over and over.
# That is the bug we removed.
#
# `SecItemDelete` can itself raise that exact prompt. Having the app clean up its
# own old items at launch would therefore reproduce the problem we are fixing.
# So cleanup is a deliberate, user-run step instead, using the `security` CLI,
# where any prompt is one the user asked for and understands.
#
# The app no longer reads or writes ANY of these items. Leaving them in place is
# harmless — this script is housekeeping, not a requirement.
#
# Safe to run repeatedly: items that are already gone are reported as such.
# NOTE: never pipe `security dump-keychain` straight into `grep -q`. grep exits
# on the first match and SIGPIPEs security, which under `pipefail` reads as a
# failed pipeline and silently inverts the check — that bug made this script
# report the old device key as absent when it was sitting right there. The dump
# is taken ONCE into a file and every check reads that file.
#
# No `set -e` either: a delete that finds nothing exits non-zero, and that is a
# normal outcome here, not a failure.
set -uo pipefail

SERVICE="com.godson.remotecontrol"
KEY_LABEL="RemoteControl Device Key"
KEY_TAG="com.godson.remotecontrol.devicekey"

removed=0
missing=0

DUMP="$(mktemp -t rc-keychain-dump)"
trap 'rm -f "${DUMP}"' EXIT

echo "RemoteControl — Keychain cleanup"
echo "Login keychain: $(security default-keychain | tr -d ' "')"
echo

# Attribute-only dump: `dump-keychain` WITHOUT -d never reads secret data, so it
# does not raise a permission prompt. Never add -d here.
if ! security dump-keychain > "${DUMP}" 2>/dev/null; then
    echo "warning: could not dump the keychain; only the exact-name deletions below will run" >&2
    : > "${DUMP}"
fi

# ---- Generic passwords ------------------------------------------------------
# These are the access code, the device ID and the controller's saved peer code.
# `delete-generic-password` matches on service (-s) and account (-a).
echo "== generic passwords under service '${SERVICE}'"
for account in access-code device-id saved-peer-access-code; do
    # Loop: there is no supported way to have created duplicates, but if an old
    # build ever did, one delete would leave the rest behind.
    deleted_any=0
    while security delete-generic-password -s "${SERVICE}" -a "${account}" >/dev/null 2>&1; do
        echo "   removed  service=${SERVICE} account=${account}"
        removed=$((removed + 1))
        deleted_any=1
    done
    if [[ "${deleted_any}" -eq 0 ]]; then
        echo "   absent   service=${SERVICE} account=${account}"
        missing=$((missing + 1))
    fi
done

# Older builds also wrote a service-only item with no account attribute.
while security delete-generic-password -s "${SERVICE}" >/dev/null 2>&1; do
    echo "   removed  service=${SERVICE} (no account attribute)"
    removed=$((removed + 1))
done

# ---- Test namespaces --------------------------------------------------------
# The old test suite created per-run services named
# com.godson.remotecontrol.tests.<uuid> and deleted them again. A test that
# crashed part-way could leave one behind. The current suite writes only to
# temporary directories and creates no Keychain items at all.
echo
echo "== leftover test namespaces (${SERVICE}.tests.*)"
# The service names contain dots (…tests.identity.<uuid>, …tests.identity.key.<uuid>),
# so the character class has to include them.
test_services="$(
    grep -o "\"${SERVICE}\.tests\.[A-Za-z0-9.-]*\"" "${DUMP}" \
        | tr -d '"' | sort -u
)"
if [[ -z "${test_services}" ]]; then
    echo "   none found"
else
    while IFS= read -r svc; do
        [[ -z "${svc}" ]] && continue
        while security delete-generic-password -s "${svc}" >/dev/null 2>&1; do
            echo "   removed  service=${svc}"
            removed=$((removed + 1))
        done
    done <<< "${test_services}"
fi

# ---- Device keypair ---------------------------------------------------------
# The old DeviceKeyStore created a kSecClassKey item (an EC private key) tagged
# com.godson.remotecontrol.devicekey[.se]. The `security` CLI has delete verbs
# for passwords, certificates and identities but NOT for bare keys, and the only
# programmatic route is SecItemDelete — which is exactly what would raise the
# prompt this whole change exists to eliminate. So this one is reported, not
# deleted, and the user removes it in the GUI if they want to.
echo
echo "== device keypair"
key_hits="$(grep -c -e "${KEY_LABEL}" -e "${KEY_TAG}" "${DUMP}")"
if [[ "${key_hits}" -gt 0 ]]; then
    cat <<EOF
   FOUND    ${key_hits} attribute line(s) matching the old device key
            (label "${KEY_LABEL}" / tag "${KEY_TAG}").

   This one cannot be removed from the command line: the 'security' tool has no
   delete verb for bare keys, and the API call that would do it (SecItemDelete)
   can raise the very permission prompt we are getting rid of.

   It is inert — the app never touches it any more. To remove it by hand:
       1. Open Keychain Access  (open -a "Keychain Access")
       2. Select the 'login' keychain, category 'Keys'
       3. Search for: ${KEY_LABEL}
       4. Delete the matching private key(s)

   The old test suite also created per-run keys tagged
   ${KEY_TAG%.devicekey}.tests.identity.key.<uuid>; the same search
   and the same manual delete apply to those. The current test suite creates no
   Keychain items at all — it writes only to temporary directories.
EOF
else
    echo "   absent   no key labelled \"${KEY_LABEL}\""
fi

# ---- Summary ----------------------------------------------------------------
echo
echo "-----------------------------------------------------------------------"
if [[ "${removed}" -eq 0 ]]; then
    echo "Nothing to remove — ${missing} item(s) were already absent."
else
    echo "Removed ${removed} Keychain item(s)."
fi
cat <<EOF

RemoteControl now keeps its Device ID in:
    ~/Library/Application Support/RemoteControl/identity.json   (0600)

and its device key, access code, remembered peer codes and trusted controllers
in the login Keychain under the service "app.skipperdesk.desktop" — which is a
different service from the one this script cleans up, and is not touched by it.

Do NOT delete either unless you intend to change this Mac's Device ID and access
code — the other Mac's saved entry would stop working.
EOF
