#!/usr/bin/env bash
# Architectural guard: the remote-control path must be entirely NATIVE and must never
# touch, proxy, instrument or route the controlled machine's browser traffic.
#
# See AGENT.md "Browser and Network Isolation" and PLAN.md. This is not a style check —
# a violation here changes what the product IS. Run it in CI and before any release.
set -uo pipefail
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
for candidate in dist/SkipperDesk.app/Contents/MacOS/SkipperDesk \
                 /Applications/SkipperDesk.app/Contents/MacOS/SkipperDesk; do
  [[ -f "$candidate" ]] && { BIN="$candidate"; break; }
done
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
  report "no built binary found in dist/ or /Applications -- cannot verify the shipped artefact"
fi

echo "== 3. No system/browser proxy or VPN entitlements requested"
PLIST="${BIN%/MacOS/SkipperDesk}/Info.plist"
if [[ -n "$BIN" && -f "$PLIST" ]]; then
  if grep -qE 'NetworkExtension|com\.apple\.developer\.networking' "$PLIST"; then
    report "Info.plist requests networking-extension capabilities"
  else echo "  ok    none requested"; fi
else report "no bundle Info.plist to inspect"; fi

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
