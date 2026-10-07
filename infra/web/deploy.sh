#!/usr/bin/env bash
# Ships web/ to the website's bucket and invalidates the distribution. It provisions
# nothing, and it touches nothing the backend stack owns: no instance, no SSM command, no
# Caddy reload. Landing copy and a price change go out with this and an app release is not
# involved.
#
#   infra/web/deploy.sh --profile <aws profile>
#
# Optional: --region, --bucket, --distribution, --domain, --account, --dry-run. Anything not
# given is read from `terraform output` in infra/web/terraform, so that stack must exist
# first. `terraform output` reads the S3 backend, which needs AWS_PROFILE exported:
#
#   AWS_PROFILE=<profile> infra/web/deploy.sh --profile <profile>
#
# /config.js is deliberately excluded. Terraform owns it, because it is the one file that
# carries the sign-in origin and the app client id.
set -euo pipefail
cd "$(dirname "$0")/../.."

source scripts/aws-profile-guard.sh

PROFILE=""
REGION=""
BUCKET=""
DISTRIBUTION=""
DOMAIN=""
ACCOUNT=""
DRY_RUN=0
TF_DIR="infra/web/terraform"
SITE="web"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --bucket) BUCKET="${2:-}"; shift 2 ;;
    --distribution) DISTRIBUTION="${2:-}"; shift 2 ;;
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FAIL  unknown argument '$1'"; exit 2 ;;
  esac
done

require_aws_profile "$PROFILE" || exit 2

tf_output() {
  (cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null) || true
}

[[ -n "$REGION" ]] || REGION="$(tf_output aws_region)"
[[ -n "$REGION" ]] || REGION="eu-west-2"
[[ -n "$BUCKET" ]] || BUCKET="$(tf_output site_bucket)"
[[ -n "$DISTRIBUTION" ]] || DISTRIBUTION="$(tf_output distribution_id)"
[[ -n "$DOMAIN" ]] || DOMAIN="$(tf_output cloudfront_domain_name)"
[[ -n "$ACCOUNT" ]] || ACCOUNT="$(tf_output aws_account_id)"

require_aws_profile "$PROFILE" "$ACCOUNT" || exit 2

for pair in "bucket:$BUCKET" "distribution:$DISTRIBUTION"; do
  if [[ -z "${pair#*:}" ]]; then
    echo "FAIL  no ${pair%%:*}: run terraform apply in $TF_DIR, or pass --${pair%%:*}"
    echo "      terraform output reads the S3 backend, so export AWS_PROFILE as well"
    exit 2
  fi
done

echo "== target"
echo "  profile      $PROFILE"
echo "  region       $REGION"
echo "  bucket       $BUCKET"
echo "  distribution $DISTRIBUTION${DOMAIN:+ ($DOMAIN)}"

# The repository never carries config.js — Terraform writes it straight into the bucket —
# so a copy here is a local one scripts/serve-web.sh left behind. Syncing it would overwrite
# the real values with whatever that run used.
if [[ -f "$SITE/config.js" ]]; then
  echo "  note         $SITE/config.js is present locally and will not be uploaded"
fi

echo
echo "== checking the site"
for required in index.html link/index.html 404.html assets/styles.css assets/link.js; do
  if [[ ! -f "$SITE/$required" ]]; then
    echo "FAIL  $SITE/$required is missing"
    exit 1
  fi
done
echo "  ok    $(find "$SITE" -type f ! -name config.js | wc -l | tr -d ' ') files"

# Assembled rather than expanded from a may-be-empty array: "${EMPTY[@]}" under `set -u` is
# an unbound variable on the bash macOS ships, and this script runs on the owner's Mac.
SYNC=(aws s3 sync --profile "$PROFILE" --region "$REGION" --only-show-errors --delete)
[[ "$DRY_RUN" -eq 1 ]] && SYNC+=(--dryrun)

# Two passes, because the two cache policies in cloudfront.tf are only half the story: the
# object's own Cache-Control is what the browser obeys. Pages revalidate every time; an
# asset is immutable for a year and is busted by the ?v= the pages ask for.
echo
echo "== uploading /assets/ as immutable"
"${SYNC[@]}" \
  "$SITE/assets/" "s3://$BUCKET/assets/" \
  --cache-control "public, max-age=31536000, immutable"

echo "== uploading the pages as no-cache"
"${SYNC[@]}" \
  "$SITE/" "s3://$BUCKET/" \
  --exclude "assets/*" \
  --exclude "config.js" \
  --exclude "config.sample.js" \
  --exclude ".gitignore" \
  --cache-control "no-cache"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "DRY RUN  nothing was uploaded and nothing was invalidated"
  exit 0
fi

echo
echo "== invalidating /*"
INVALIDATION="$(aws cloudfront create-invalidation \
  --profile "$PROFILE" \
  --distribution-id "$DISTRIBUTION" \
  --paths '/*' \
  --query Invalidation.Id --output text)"
echo "  id    $INVALIDATION"

aws cloudfront wait invalidation-completed \
  --profile "$PROFILE" \
  --distribution-id "$DISTRIBUTION" \
  --id "$INVALIDATION"
echo "  ok    completed"

if [[ -n "$DOMAIN" ]]; then
  echo
  echo "== verifying https://$DOMAIN/"
  for _ in $(seq 1 15); do
    STATUS="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" || true)"
    if [[ "$STATUS" == "200" ]]; then
      echo "  ok    the distribution answers 200"
      echo
      echo "DEPLOY PASSED"
      exit 0
    fi
    sleep 2
  done
  echo "FAIL  https://$DOMAIN/ did not answer 200"
  exit 1
fi

echo
echo "DEPLOY PASSED"
