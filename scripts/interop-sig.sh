#!/usr/bin/env bash
#
# Cross-language signature interop test: Swift signs, Go verifies.
#
# WHY THIS EXISTS: the Swift app and the Go signaling server have to agree
# byte-for-byte on two encodings, and neither side's own unit tests can prove it.
#
#   pubkey  base64(DER SPKI)          -- NOT the X9.63 raw point
#   sig     base64(ASN.1 DER ECDSA)   -- NOT raw r||s, over sha256(raw nonce bytes)
#
# If they disagree, Phase 3 dies at the handshake with a useless "bad_signature".
# So: Swift emits a real public key and a real signature over a nonce this script
# generates, and Go checks it with the *production* auth.VerifyDeviceSig.
#
# Both directions are asserted. A valid signature must verify AND a tampered one
# must be rejected — the positive case alone would pass against a verifier that
# always returns nil.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/apps/macos"
SERVER_DIR="$ROOT/server"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== generating a 32-byte nonce"
# Same shape as auth.NewNonce(): 32 random bytes, standard base64.
NONCE="$(head -c 32 /dev/urandom | base64)"
echo "   nonce (base64): $NONCE"

echo
echo "== Swift: minting an identity and signing the nonce"
if ! (cd "$APP_DIR" && swift build --product rc-tests >/dev/null 2>&1); then
  echo "FAIL  swift build --product rc-tests"
  (cd "$APP_DIR" && swift build --product rc-tests 2>&1 | sed 's/^/      /')
  exit 1
fi
if ! (cd "$APP_DIR" && swift run --skip-build rc-tests --emit-interop "$NONCE" > "$WORK/emitted.json" 2> "$WORK/swift.err"); then
  echo "FAIL  rc-tests --emit-interop"
  sed 's/^/      /' "$WORK/swift.err"
  exit 1
fi
echo "PASS  Swift emitted a public key and a signature"
sed 's/^/      /' "$WORK/emitted.json"

echo
echo "== Go: verifying with the production auth.VerifyDeviceSig"
if ! (cd "$SERVER_DIR" && go build -o "$WORK/interopverify" ./cmd/interopverify); then
  echo "FAIL  go build ./cmd/interopverify"
  exit 1
fi

if ! "$WORK/interopverify" < "$WORK/emitted.json"; then
  echo
  echo "INTEROP TEST FAILED"
  exit 1
fi

# Negative control on the harness itself: corrupt the emitted signature and
# confirm the verifier reports a failure. This proves interopverify's exit code
# is load-bearing and not stuck at 0.
echo
echo "== harness self-check: a corrupted payload must FAIL"
python3 - "$WORK/emitted.json" "$WORK/corrupt.json" <<'PY'
import json, base64, sys
d = json.load(open(sys.argv[1]))
raw = bytearray(base64.b64decode(d["sig"]))
raw[-1] ^= 0x01
d["sig"] = base64.b64encode(bytes(raw)).decode()
json.dump(d, open(sys.argv[2], "w"))
PY
if "$WORK/interopverify" < "$WORK/corrupt.json" >/dev/null 2>&1; then
  echo "FAIL  the verifier accepted a corrupted signature — this test proves nothing"
  exit 1
fi
echo "PASS  the verifier rejects a corrupted payload (exit code is real)"

echo
echo "INTEROP TEST PASSED"
