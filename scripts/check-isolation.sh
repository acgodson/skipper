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

echo "== 1. Forbidden browser/automation/proxy APIs in source"
# Word-boundary matched, comment lines excluded, so prose in docs cannot trip it.
FORBIDDEN='WKWebView|WKUserScript|JavaScriptCore|JSContext|puppeteer|playwright|selenium|chromedriver|DevToolsProtocol|CDPSession|SOCKSEnable|HTTPProxy|HTTPSProxy|kCFNetworkProxies|kSCPropNetProxies|NEVPNManager|NETunnelProvider|NEProxyProvider|NEDNSProxyProvider|NEPacketTunnelProvider|SFSafariExtension|getDisplayMedia'
hits=$(grep -rnE "$FORBIDDEN" apps/macos/Sources server protocol 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|#)' || true)
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
  HOOK_VARS='RC_IDENTITY_DIR|RC_DUMP_FRAME|RC_INPUT_SELFTEST|RC_CAPTURE_SOURCE|RC_SYNTHETIC_SIZE|RC_PASTEBOARD_NAME|RC_SETTINGS_SUITE|RC_AUTOLINK|RC_AUTOCONNECT|RC_LOG_FILE'
  present=$(strings -a "$BIN" | grep -oE "$HOOK_VARS" | sort -u || true)
  if [[ -n "$present" ]]; then
    echo "$present" | sed 's/^/        /'
    report "the binary still names the development variables above"
  else
    echo "  ok    no development variable name longer than the inline-string limit is present"
  fi
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
