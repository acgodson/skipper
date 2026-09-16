#!/usr/bin/env bash
# Self-signed cert for rc-signal, pinned by fingerprint in the app. Usage: ./gen-cert.sh <IP>
set -euo pipefail
cd "$(dirname "$0")/.."
IP="${1:?usage: gen-cert.sh <server-ip>}"
mkdir -p certs && cd certs
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -sha256 -days 3650 -nodes \
  -keyout server.key -out server.crt -subj "/CN=rc-signal" \
  -addext "subjectAltName=IP:$IP" -addext "keyUsage=digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null
chmod 600 server.key
PIN=$(openssl x509 -in server.crt -outform der | openssl dgst -sha256 -binary | base64)
echo "Certificate written to $(pwd)/server.crt (valid for IP:$IP, 10 years)"
echo
echo "PIN THIS IN THE APP:"
echo "  RC_CERT_PIN_SHA256 = $PIN"
