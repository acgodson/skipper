#!/usr/bin/env bash
# Architectural guard: the remote-control path must be entirely NATIVE and must never
# touch, proxy, instrument or route the controlled machine's browser traffic.
#
# See AGENT.md "Browser and Network Isolation" and PLAN.md. This is not a style check —
# a violation here changes what the product IS. Run it in CI and before any release.
#
# Usage: check-isolation.sh [path/to/SkipperDesk.app | path/to/binary]
# With a path, exactly that artefact is checked. Without one, dist/SkipperDesk.app.
set -uo pipefail
TARGET="${1:-}"
if [[ -n "$TARGET" && "$TARGET" != /* ]]; then TARGET="$PWD/$TARGET"; fi
cd "$(dirname "$0")/.."
fail=0
report() { echo "  FAIL  $1"; fail=1; }

compiled_in_byte() {
  local bin="$1" thin="$1" scratch="" arch line address segment section
  arch=$(lipo -archs "$bin" 2>/dev/null | awk '{print $1}')
  if [[ $(lipo -archs "$bin" 2>/dev/null | wc -w) -gt 1 ]]; then
    scratch=$(mktemp -d)
    thin="$scratch/thin"
    lipo -thin "$arch" -output "$thin" "$bin" || { rm -rf "$scratch"; return; }
  fi
  line=$(nm -m "$thin" 2>/dev/null | grep -E ' _\$s17RemoteControlCore16DevelopmentHooksO13areCompiledInSbvpZ$' | head -1)
  address=$(awk '{print $1}' <<<"$line")
  segment=$(sed -nE 's/.*\(([^,]+),([^)]+)\).*/\1/p' <<<"$line")
  section=$(sed -nE 's/.*\(([^,]+),([^)]+)\).*/\2/p' <<<"$line")
  if [[ -n "$address" && ( "$section" == "__bss" || "$section" == "__common" ) ]]; then
    echo 00
  elif [[ -n "$address" ]]; then
    local symbol=$((16#$address)) name owner start size offset
    while read -r name owner start size offset; do
      [[ "$name" == "$section" && "$owner" == "$segment" ]] || continue
      if (( symbol >= start && symbol < start + size )); then
        xxd -s "$((offset + symbol - start))" -l 1 -p "$thin"
        break
      fi
    done < <(otool -l "$thin" | awk '
      $1 == "sectname" { name = $2 }
      $1 == "segname" { owner = $2 }
      $1 == "addr" { start = $2 }
      $1 == "size" { size = $2 }
      $1 == "offset" && name != "" { print name, owner, start, size, $2; name = "" }' \
      | while read -r n o a s f; do echo "$n $o $((a)) $((s)) $f"; done)
  fi
  if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi
}

echo "== 1. Forbidden browser/automation/proxy APIs in source"
# Word-boundary matched, comment lines excluded, so prose in docs cannot trip it.
FORBIDDEN='WKWebView|WKUserScript|JavaScriptCore|JSContext|puppeteer|playwright|selenium|chromedriver|DevToolsProtocol|CDPSession|SOCKSEnable|HTTPProxy|HTTPSProxy|kCFNetworkProxies|kSCPropNetProxies|NEVPNManager|NETunnelProvider|NEProxyProvider|NEDNSProxyProvider|NEPacketTunnelProvider|SFSafariExtension|getDisplayMedia'
hits=$(grep -rnIE "$FORBIDDEN" apps/macos/Sources server protocol 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|#)' || true)
if [[ -n "$hits" ]]; then echo "$hits"; report "forbidden API referenced above"; else echo "  ok    none present"; fi

echo "== 2. No WebKit/JavaScriptCore linked into the built binary"
BIN=""
if [[ -n "$TARGET" ]]; then
  if [[ -d "$TARGET" ]]; then candidate="${TARGET%/}/Contents/MacOS/SkipperDesk"; else candidate="$TARGET"; fi
  if [[ -f "$candidate" ]]; then BIN="$candidate"; else report "no SkipperDesk binary at the given path: $TARGET"; fi
elif [[ -f dist/SkipperDesk.app/Contents/MacOS/SkipperDesk ]]; then
  BIN="dist/SkipperDesk.app/Contents/MacOS/SkipperDesk"
fi
if [[ -n "$BIN" ]]; then
  echo "  bin   $BIN"
  n=$(otool -L "$BIN" | grep -ciE 'webkit|javascriptcore|safariservices' || true)
  [[ "$n" -eq 0 ]] && echo "  ok    0 WebKit/JavaScriptCore references" || report "binary links WebKit/JavaScriptCore"
  u=$(nm -u "$BIN" 2>/dev/null | grep -icE 'wkweb|jscontext|kCFNetworkProxies|NEVPN|NETunnel' || true)
  [[ "$u" -eq 0 ]] && echo "  ok    0 browser/proxy/VPN symbols" || report "binary imports browser/proxy/VPN symbols"
  if otool -L "$BIN" | grep -q '@rpath/WebRTC.framework'; then
    echo "  ok    WebRTC is the app's own embedded framework"
  else
    report "WebRTC is not the app's embedded framework -- where is it coming from?"
  fi
else
  [[ -z "$TARGET" ]] && report "no built binary in dist/ and no path given -- cannot verify the shipped artefact"
fi

echo "== 3. No system/browser proxy or VPN entitlements requested"
PLIST="${BIN%/MacOS/SkipperDesk}/Info.plist"
if [[ -n "$BIN" && -f "$PLIST" ]]; then
  if grep -qE 'NetworkExtension|com\.apple\.developer\.networking' "$PLIST"; then
    report "Info.plist requests networking-extension capabilities"
  else echo "  ok    none requested"; fi
else report "no bundle Info.plist to inspect"; fi

echo "== 3b. Signed entitlements carry no code-injection or networking-extension rights"
BUNDLE="${BIN%/Contents/MacOS/SkipperDesk}"
if [[ -n "$BIN" ]]; then
  ents=$(codesign -d --entitlements - --xml "$BUNDLE" 2>/dev/null || true)
  if [[ -z "$ents" ]]; then
    report "could not read the bundle's signed entitlements"
  else
    FORBIDDEN_ENTS='com\.apple\.security\.cs\.disable-library-validation|com\.apple\.security\.get-task-allow|get-task-allow|com\.apple\.security\.cs\.allow-jit|com\.apple\.security\.cs\.allow-unsigned-executable-memory|com\.apple\.security\.cs\.allow-dyld-environment-variables|com\.apple\.security\.cs\.disable-executable-page-protection|com\.apple\.developer\.networking|com\.apple\.developer\.system-extension|com\.apple\.security\.network\.server'
    bad=$(grep -oE "$FORBIDDEN_ENTS" <<<"$ents" | sort -u || true)
    if [[ -n "$bad" ]]; then
      echo "$bad" | sed 's/^/        /'
      report "the signed bundle requests the entitlements above"
    else
      echo "  ok    none of: disable-library-validation, get-task-allow, allow-jit, unsigned memory, dyld env, networking/system extensions, network.server"
    fi
  fi
  sig=$(codesign -dvv "$BUNDLE" 2>&1 || true)
  if grep -q '^TeamIdentifier=not set' <<<"$sig"; then
    echo "  note  no Team ID: a development build, signed without the hardened runtime; never distribute it"
  elif grep -qE '^CodeDirectory .*flags=.*runtime' <<<"$sig"; then
    echo "  ok    Team ID build runs under the hardened runtime (library validation on)"
  else
    report "a Team ID build must be signed with the hardened runtime"
  fi
fi

echo "== 3c. Development environment hooks are compiled out of the shipped binary"
if [[ -n "$BIN" ]]; then
  if /usr/libexec/PlistBuddy -c 'Print :SkipperTestHooks' "$PLIST" >/dev/null 2>&1; then
    report "this bundle was built with --test-hooks and must not ship"
  fi
  # Swift stores strings of 15 bytes or fewer inline in the code, so `strings` cannot see
  # most hook names. The gate is the symbol that reads them, which exists only in a hooks build.
  symbols=$(nm "$BIN" 2>/dev/null | swift demangle 2>/dev/null || true)
  if ! grep -q 'DevelopmentHooks\.areCompiledIn' <<<"$symbols"; then
    report "the binary has no DevelopmentHooks symbols at all (stripped?) -- cannot prove hooks are compiled out"
  else
    hook_symbols=$(grep -oE 'DevelopmentHooks\.(environmentValue|variableName)\([^)]*\)' <<<"$symbols" | sort -u || true)
    if [[ -n "$hook_symbols" ]]; then
      echo "$hook_symbols" | sed 's/^/        /'
      report "the binary contains the development hook reader symbols above"
    else
      echo "  ok    no development hook reader symbol (DevelopmentHooks.environmentValue / variableName)"
    fi
  fi
  flag=$(compiled_in_byte "$BIN")
  case "$flag" in
    00) echo "  ok    DevelopmentHooks.areCompiledIn is stored as false" ;;
    "") report "could not locate the DevelopmentHooks.areCompiledIn storage byte" ;;
    *) report "DevelopmentHooks.areCompiledIn is stored as 0x$flag, not false" ;;
  esac
  HOOK_VARS='RC_IDENTITY_DIR|SKIPPER_DEV_FILE_IDENTITY|RC_DUMP_FRAME|RC_INPUT_SELFTEST|RC_CAPTURE_SOURCE|RC_SYNTHETIC_SIZE|RC_PASTEBOARD_NAME|RC_SETTINGS_SUITE|RC_AUTOLINK|RC_AUTOCONNECT|RC_LOG_FILE|RC_DEVICE_LABEL|RC_HANDSHAKE_TIMEOUT|RC_REQUEST_TIMEOUT|RC_HEARTBEAT_SEC|RC_BACKOFF_MIN|RC_BACKOFF_MAX|RC_ICE_RESTART_DELAY|RC_ICE_FAILURE_GRACE|RC_ICE_POLICY'
  present=$(strings -a "$BIN" | grep -xE "$HOOK_VARS" | sort -u || true)
  if [[ -n "$present" ]]; then
    echo "$present" | sed 's/^/        /'
    report "the binary still names the development variables above"
  else
    echo "  ok    no development variable name longer than the inline-string limit is present as a string of its own"
  fi
fi

echo "== 3d. Only the configuration files read the process environment"
SHIPPED_SWIFT=(apps/macos/Sources/RemoteControl apps/macos/Sources/RemoteControlCore apps/macos/Sources/SkipperCore apps/macos/Sources/SkipperDesign)
CONFIG_SWIFT=apps/macos/Sources/RemoteControlCore/Config/Config.swift
HOOKS_SWIFT=apps/macos/Sources/RemoteControlCore/Config/DevelopmentHooks.swift
ENV_READ='processInfo\.environment|\b(get|set|unset|put)env\b'
strangers=$(grep -rnE "$ENV_READ" "${SHIPPED_SWIFT[@]}" --include='*.swift' | grep -vE "^($CONFIG_SWIFT|$HOOKS_SWIFT):" || true)
if [[ -n "$strangers" ]]; then
  echo "$strangers" | sed 's/^/        /'
  report "shipped Swift outside Config.swift and DevelopmentHooks.swift touches the environment"
else
  echo "  ok    no other shipped Swift file reads or writes the environment"
fi
config_reads=$(grep -nE "$ENV_READ" "$CONFIG_SWIFT" \
  | grep -vE '^[0-9]+:[[:space:]]*values\[(apiVariable|webVariable)\] = ProcessInfo\.processInfo\.environment\[\1\]$' || true)
if [[ -n "$config_reads" ]] \
  || ! grep -qE '^[[:space:]]*public static let apiVariable = "SKIPPER_API_BASE_URL"$' "$CONFIG_SWIFT" \
  || ! grep -qE '^[[:space:]]*public static let webVariable = "SKIPPER_WEB_BASE_URL"$' "$CONFIG_SWIFT"; then
  echo "$config_reads" | sed 's/^/        /'
  report "Config.swift reads something other than SKIPPER_API_BASE_URL and SKIPPER_WEB_BASE_URL"
else
  echo "  ok    Config.swift reads only SKIPPER_API_BASE_URL and SKIPPER_WEB_BASE_URL"
fi
hooks_reads=$(awk -v pattern="$ENV_READ" '
  /^#if DEBUG \|\| SKIPPER_TEST_HOOKS$/ { gated = 1; next }
  /^#else$/ { gated = 0; next }
  /^#endif$/ { gated = 0; next }
  !gated && $0 ~ /processInfo\.environment|(get|set|unset|put)env/ { print NR ": " $0 }
' "$HOOKS_SWIFT" | grep -vE '^[0-9]+: +public static let diagnosticsRequested = ProcessInfo\.processInfo\.environment\["RC_DEBUG"\] == "1"$' || true)
if [[ -n "$hooks_reads" ]]; then
  echo "$hooks_reads" | sed 's/^/        /'
  report "DevelopmentHooks.swift reads the environment outside the development-only block"
else
  echo "  ok    DevelopmentHooks.swift reads only RC_DEBUG outside the development-only block"
fi

echo "== 3e. Secret storage: the profile, the entitlements and the bundle's own claim agree"
# keychain-access-groups without an embedded.provisionprofile is a bundle macOS refuses to
# launch (POSIX 153), so the profile and the two keychain entitlements are all present or all
# absent. SKIPPERSecretStorageMode is what the build recorded; it must not contradict them.
if [[ -n "$BIN" ]]; then
  APP_IDENTIFIER_KEY='com.apple.application-identifier'
  ACCESS_GROUP_KEY='keychain-access-groups'
  ALLOWED_ENTS="com.apple.security.app-sandbox com.apple.security.network.client
com.apple.security.device.camera com.apple.security.device.microphone"
  PROFILE="${BUNDLE}/Contents/embedded.provisionprofile"
  ents_plist=$(mktemp -t rc-ents).plist
  codesign -d --entitlements - --xml "$BUNDLE" >"$ents_plist" 2>/dev/null || true
  keys=$(plutil -convert xml1 -o - "$ents_plist" 2>/dev/null | sed -nE 's|.*<key>(.*)</key>.*|\1|p' | sort -u)
  mode=$(/usr/libexec/PlistBuddy -c 'Print :SKIPPERSecretStorageMode' "$PLIST" 2>/dev/null || true)
  team=$(sed -nE 's/^TeamIdentifier=(.*)$/\1/p' <<<"$(codesign -dvv "$BUNDLE" 2>&1)")
  expected="${team}.app.skipperdesk.desktop"
  has_app_identifier=$(grep -cx "$APP_IDENTIFIER_KEY" <<<"$keys" || true)
  has_access_group=$(grep -cx "$ACCESS_GROUP_KEY" <<<"$keys" || true)
  if [[ -z "$keys" ]]; then
    report "could not read the bundle's signed entitlements"
  elif [[ -f "$PROFILE" ]]; then
    if [[ "$has_app_identifier" -ne 1 || "$has_access_group" -ne 1 ]]; then
      report "an embedded.provisionprofile is present but $APP_IDENTIFIER_KEY / $ACCESS_GROUP_KEY are not both signed in"
    elif [[ "$(/usr/libexec/PlistBuddy -c "Print :$APP_IDENTIFIER_KEY" "$ents_plist" 2>/dev/null)" != "$expected" \
         || "$(/usr/libexec/PlistBuddy -c "Print :$ACCESS_GROUP_KEY:0" "$ents_plist" 2>/dev/null)" != "$expected" ]]; then
      report "the keychain entitlements do not name exactly $expected"
    elif [[ "$mode" != "dataProtection" ]]; then
      report "SKIPPERSecretStorageMode is '${mode:-missing}' but the bundle is entitled for the data-protection keychain"
    else
      echo "  ok    profile embedded; $expected entitled; mode dataProtection"
    fi
  else
    if [[ "$has_app_identifier" -ne 0 || "$has_access_group" -ne 0 ]]; then
      report "$APP_IDENTIFIER_KEY / $ACCESS_GROUP_KEY are signed in with no embedded.provisionprofile -- this bundle cannot launch"
    elif [[ "$mode" != "login" ]]; then
      report "SKIPPERSecretStorageMode is '${mode:-missing}' but the bundle has no data-protection entitlement"
    else
      echo "  ok    no profile; neither keychain entitlement present; mode login"
    fi
  fi
  strangers=$(comm -23 <(echo "$keys") <(printf '%s\n' $ALLOWED_ENTS "$APP_IDENTIFIER_KEY" "$ACCESS_GROUP_KEY" | sort -u))
  if [[ -n "$strangers" ]]; then
    echo "$strangers" | sed 's/^/        /'
    report "the signed bundle carries entitlements outside the allowed set"
  else
    echo "  ok    no entitlement outside the allowed set"
  fi
  rm -f "$ents_plist"
fi

echo "== 4. WebRTC must be the NATIVE xcframework, never a webview's RTCPeerConnection"
# Strip comments first — a mention of WebRTC in a comment is not a dependency.
# The `[^:]` guard matters: a naive s|//.*|| also eats the "//" in
# https://github.com/stasel/WebRTC.git, which deletes the exact string this
# check is looking for and reports the native xcframework as "unrecognised".
pkg=$(sed 's|\([^:]\)//.*|\1|' apps/macos/Package.swift 2>/dev/null || true)
if grep -q 'stasel/WebRTC' <<<"$pkg"; then
  echo "  ok    native libwebrtc xcframework"
elif grep -qE 'WebRTC' <<<"$pkg"; then
  report "an unrecognised WebRTC dependency — confirm it is native, not webview-based"
else
  echo "  note  WebRTC not yet a dependency (expected before Phase 3 lands)"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "ISOLATION CHECK PASSED — transport is native; the controlled browser is untouched."
else
  echo "ISOLATION CHECK FAILED — see failures above." >&2
fi
exit $fail
