#!/usr/bin/env bash
# Builds rc-api and rc-signal for linux/arm64, uploads them, swaps them in, restarts both
# units and then proves the public endpoint answers. It provisions nothing: Terraform owns
# every resource, and this script only moves two binaries.
#
#   infra/aws/deploy.sh --profile <aws profile>
#
# Optional: --region, --instance <id>, --bucket <name>, --api <domain>, --account <id>. Anything
# not given
# is read from `terraform output` in infra/aws/terraform, so the stack must exist first.
#
# There is no SSH anywhere in here. The swap runs as an SSM command over the instance's
# own outbound connection, which is why the security group has no inbound SSH rule.
set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/aws-profile-guard.sh

PROFILE=""
REGION=""
INSTANCE=""
BUCKET=""
API_DOMAIN=""
ACCOUNT=""
TF_DIR="infra/aws/terraform"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --bucket) BUCKET="${2:-}"; shift 2 ;;
    --api) API_DOMAIN="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    -h | --help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FAIL  unknown argument '$1'"; exit 2 ;;
  esac
done

require_aws_profile "$PROFILE" || exit 2

tf_output() {
  (cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null) || true
}

[[ -n "$REGION" ]] || REGION="$(cd "$TF_DIR" && terraform output -raw aws_region 2>/dev/null || echo eu-west-2)"
[[ -n "$INSTANCE" ]] || INSTANCE="$(tf_output instance_id)"
[[ -n "$BUCKET" ]] || BUCKET="$(tf_output backup_bucket)"
[[ -n "$API_DOMAIN" ]] || API_DOMAIN="$(tf_output api_domain)"
[[ -n "$ACCOUNT" ]] || ACCOUNT="$(tf_output aws_account_id)"

require_aws_profile "$PROFILE" "$ACCOUNT" || exit 2

for pair in "instance:$INSTANCE" "bucket:$BUCKET" "api:$API_DOMAIN"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL  no ${pair%%:*}: run terraform apply in $TF_DIR, or pass --${pair%%:*}"
    exit 2
  fi
done

echo "== target"
echo "  profile  $PROFILE"
echo "  region   $REGION"
echo "  instance $INSTANCE"
echo "  api      https://$API_DOMAIN"

# The two assertions docs/PHASE5.md §5.4 and §7 ask for, made against the units that are
# actually going to run rather than against a comment: the deprecated -internal-token flag
# puts the shared bearer in ps, and -idp dev opens the API.md §6.3 development calls.
echo
echo "== unit assertions"
UNITS=(infra/aws/systemd/rc-api.service infra/aws/systemd/rc-signal.service)
for unit in "${UNITS[@]}"; do
  if grep -qE '^[[:space:]]*-internal-token[[:space:]]' "$unit"; then
    echo "FAIL  $unit passes the deprecated -internal-token flag; use -internal-token-file"
    exit 1
  fi
done
# Anchored to a flag line, never a comment: an unanchored grep both fails on a comment that
# mentions -idp dev and passes on a comment that mentions -idp cognito.
if ! grep -qE '^[[:space:]]*-idp[[:space:]]+cognito\b' infra/aws/systemd/rc-api.service; then
  echo "FAIL  infra/aws/systemd/rc-api.service does not run -idp cognito; the development calls would be live"
  exit 1
fi
if grep -qE '^[[:space:]]*-idp[[:space:]]+dev\b' infra/aws/systemd/rc-api.service; then
  echo "FAIL  infra/aws/systemd/rc-api.service runs -idp dev; that is local only"
  exit 1
fi
echo "  ok    no -internal-token flag, -idp cognito only"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo
echo "== building rc-api and rc-signal for linux/arm64"
(cd server && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$WORK/rc-api" ./cmd/rc-api)
(cd server && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -o "$WORK/rc-signal" ./cmd/rc-signal)
tar -czf "$WORK/release.tar.gz" -C "$WORK" rc-api rc-signal
SHA="$(shasum -a 256 "$WORK/release.tar.gz" | awk '{print $1}')"
echo "  ok    $(wc -c <"$WORK/release.tar.gz" | tr -d ' ') bytes, sha256 $SHA"

echo
echo "== uploading releases/$STAMP.tar.gz"
aws s3 cp --profile "$PROFILE" --region "$REGION" --only-show-errors \
  "$WORK/release.tar.gz" "s3://$BUCKET/releases/$STAMP.tar.gz"
aws s3 cp --profile "$PROFILE" --region "$REGION" --only-show-errors \
  "$WORK/release.tar.gz" "s3://$BUCKET/releases/current.tar.gz"

REMOTE_SCRIPT=$(cat <<SCRIPT
set -euo pipefail
cd /tmp
aws s3 cp --region $REGION --only-show-errors s3://$BUCKET/releases/$STAMP.tar.gz /tmp/$STAMP.tar.gz
echo "$SHA  /tmp/$STAMP.tar.gz" | sha256sum -c -
install -d -m 0755 /opt/skipperdesk/releases/$STAMP
tar -xzf /tmp/$STAMP.tar.gz -C /opt/skipperdesk/releases/$STAMP
install -m 0755 /opt/skipperdesk/releases/$STAMP/rc-api /opt/skipperdesk/bin/rc-api
install -m 0755 /opt/skipperdesk/releases/$STAMP/rc-signal /opt/skipperdesk/bin/rc-signal
rm -f /tmp/$STAMP.tar.gz
systemctl restart rc-api.service
systemctl restart rc-signal.service
for _ in \$(seq 1 60); do
  if [ "\$(curl -fsS http://127.0.0.1:18080/healthz || true)" = "ok" ] \
     && [ "\$(curl -fsS http://127.0.0.1:8443/healthz || true)" = "ok" ]; then
    echo "ok    both services answer /healthz on loopback"
    exit 0
  fi
  sleep 1
done
echo "FAIL  a service did not answer /healthz after the restart"
exit 1
SCRIPT
)

echo
echo "== swapping and restarting over SSM"

# The script travels base64-encoded on one line and is run explicitly under bash. Passing it
# as multiple lines loses the newlines in the CLI's shorthand parser, and AWS-RunShellScript
# runs what it is given with /bin/sh, which on this image is dash and has no pipefail.
REMOTE_B64="$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')"
PARAMS="$WORK/ssm-params.json"
REMOTE_B64="$REMOTE_B64" python3 - "$PARAMS" <<'PY'
import json, os, sys
one = ("set -e; printf '%s' '" + os.environ["REMOTE_B64"] + "'"
       " | base64 -d > /tmp/skipperdesk-swap.sh;"
       " bash /tmp/skipperdesk-swap.sh; rc=$?;"
       " rm -f /tmp/skipperdesk-swap.sh; exit $rc")
json.dump({"Parameters": {"commands": [one]}}, open(sys.argv[1], "w"))
PY

COMMAND_ID="$(aws ssm send-command \
  --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --comment "skipperdesk deploy $STAMP" \
  --cli-input-json "file://$PARAMS" \
  --query Command.CommandId --output text)"

STATUS=""
for _ in $(seq 1 120); do
  STATUS="$(aws ssm get-command-invocation \
    --profile "$PROFILE" --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE" \
    --query Status --output text 2>/dev/null || echo Pending)"
  case "$STATUS" in
    Success | Failed | Cancelled | TimedOut) break ;;
  esac
  sleep 2
done

aws ssm get-command-invocation \
  --profile "$PROFILE" --region "$REGION" \
  --command-id "$COMMAND_ID" --instance-id "$INSTANCE" \
  --query 'StandardOutputContent' --output text | sed 's/^/  /'

if [[ "$STATUS" != "Success" ]]; then
  echo "FAIL  the swap finished as $STATUS; the previous binaries are still in /opt/skipperdesk/releases"
  aws ssm get-command-invocation \
    --profile "$PROFILE" --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE" \
    --query 'StandardErrorContent' --output text | sed 's/^/  /'
  exit 1
fi

echo
echo "== verifying https://$API_DOMAIN/v1/health"
for _ in $(seq 1 30); do
  BODY="$(curl -fsS --max-time 5 "https://$API_DOMAIN/v1/health" || true)"
  if [[ "$BODY" == *'"status":"ok"'* ]]; then
    echo "  ok    $BODY"
    echo
    echo "DEPLOY PASSED  $STAMP"
    exit 0
  fi
  sleep 2
done

echo "FAIL  https://$API_DOMAIN/v1/health did not answer with status ok"
exit 1
