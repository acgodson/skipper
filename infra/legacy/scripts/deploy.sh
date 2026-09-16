#!/usr/bin/env bash
# Deploy rc-signal + coturn into /opt/rc-signal on the shared instance.
# Ships SOURCE and builds in a golang container on the box, so no Go toolchain,
# no registry and no S3 bucket is ever needed. Touches nothing outside /opt/rc-signal.
set -euo pipefail
cd "$(dirname "$0")"
source ./_ssm.sh
ROOT="$(cd ../../.. && pwd)"
REMOTE=/opt/rc-signal

echo "==> Preflight: production service must be healthy first"
./preflight.sh >/dev/null

[[ -f "$ROOT/infra/legacy/.env" ]] || { echo "Missing infra/legacy/.env (RC_TURN_SECRET, RC_TURN_URLS)" >&2; exit 1; }
[[ -f "$ROOT/infra/legacy/certs/server.crt" ]] || { echo "Missing certs — run ./gen-cert.sh <IP>" >&2; exit 1; }

echo "==> Packing build context"
TMP=$(mktemp -d)
tar -czf "$TMP/ctx.tgz" \
    --exclude '.build' --exclude '*.db' --exclude '.git' \
    -C "$ROOT" server protocol \
    -C "$ROOT/infra/legacy" Dockerfile.signal compose.yml coturn certs .env
echo "    context: $(wc -c <"$TMP/ctx.tgz") bytes"
base64 -i "$TMP/ctx.tgz" | tr -d '\n' > "$TMP/ctx.b64"
split -b 48000 "$TMP/ctx.b64" "$TMP/part."

echo "==> Shipping $(ls "$TMP"/part.* | wc -l | tr -d ' ') chunks over SSM"
ssm_run "sudo mkdir -p $REMOTE && sudo chown \$(id -u):\$(id -g) $REMOTE && rm -f $REMOTE/ctx.b64" >/dev/null
for p in "$TMP"/part.*; do
  ssm_run "printf '%s' '$(cat "$p")' >> $REMOTE/ctx.b64" >/dev/null
  printf '.'
done
echo

echo "==> Unpacking on the instance"
ssm_run "cd $REMOTE && base64 -d ctx.b64 > ctx.tgz && rm -f ctx.b64 && tar xzf ctx.tgz && rm -f ctx.tgz && ls"

echo "==> Substituting real IPs into coturn config"
ssm_run "cd $REMOTE && PRIV=\$(hostname -I | awk '{print \$1}') && \
  TOK=\$(curl -sX PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 60') && \
  PUB=\$(curl -s -H \"X-aws-ec2-metadata-token: \$TOK\" --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4) && \
  . ./.env && \
  sed -i \"s|__EXTERNAL_IP__|\$PUB/\$PRIV|; s|__PRIVATE_IP__|\$PRIV|; s|__TURN_SECRET__|\$RC_TURN_SECRET|\" coturn/turnserver.conf && \
  echo external-ip=\$PUB/\$PRIV"

echo "==> Fixing ownership for the unprivileged container user (uid 10001)"
# rc-signal runs as uid 10001. The bind-mounted data dir and the TLS key must be
# readable/writable by THAT uid, not by the host user who unpacked the tarball.
# Without this SQLite fails with CANTOPEN(14), which it misreports as "out of memory".
ssm_run "cd $REMOTE && mkdir -p data && sudo chown -R 10001:10001 data certs && sudo chmod 700 data && sudo chmod 600 certs/server.key && ls -ln data certs"

echo "==> docker build + up (project 'rc', scoped to $REMOTE only)"
ssm_run "cd $REMOTE && docker build -f Dockerfile.signal -t rc-signal:local . && \
  docker compose -p rc -f compose.yml --env-file .env up -d && docker compose -p rc ps"

echo "==> Post-deploy verification"
ssm_run "docker ps --format '{{.Names}}|{{.Status}}' | sort"

# Assert OUR services are actually healthy. A crash-looping container must fail the
# deploy — printing "Done" over a restart loop is how a broken deploy gets believed.
echo "==> Asserting rc-signal is serving"
health=$(ssm_run "sleep 8; curl -sk --max-time 5 https://127.0.0.1:8443/healthz || echo UNREACHABLE; echo; docker inspect -f '{{.State.Status}} restarts={{.RestartCount}}' rc-signal rc-coturn")
echo "$health"
if echo "$health" | grep -q UNREACHABLE; then
  echo "FAIL: rc-signal is not serving /healthz. Deploy is NOT good." >&2
  ssm_run "cd $REMOTE && docker compose -p rc logs signal --tail 20" >&2 || true
  exit 1
fi

./preflight.sh --verify
echo "==> Done."
rm -rf "$TMP"
