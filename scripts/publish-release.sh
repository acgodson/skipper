#!/usr/bin/env bash
# Publishes a notarised .dmg as the latest release in PRODUCTION, so the signed
# self-update can see it. The dev-only POST /v1/dev/releases (publish-release-dev.sh)
# is 404 under the cognito identity provider and is never used here.
#
#   AWS_PROFILE=<profile> ./scripts/publish-release.sh --profile <profile>
#
# Optional: --dmg <path> (default: the newest dist/SkipperDesk-*.dmg), --arch (arm64),
# --channel (stable), --notes <text>, --critical, --region, --instance, --account,
# --url <override>, --dry-run.
#
# Why it goes over SSM rather than calling the API directly: the publish call lives on
# rc-api's INTERNAL listener, which is bound to 127.0.0.1 and authenticated with the
# internal bearer (protocol/API.md §6). That surface is reachable only from the box, which
# is the point -- a public authenticated publish endpoint would be new attack surface for
# one call the owner makes by hand a few times a year. SSM is already how infra/aws
# changes reach the instance, and the bearer never leaves the box: the remote script reads
# it from its own 0600 file and hands it to curl through a --config file, so it appears in
# no argument list, no log and nothing this script prints.
#
# What it proves before publishing, on the box rather than here: that the object the
# public CDN actually serves has the exact sha256 and byte length the app will demand. The
# app's trust rules are docs/SECURITY.md "Updates" -- the feed is never believed about
# safety, so a feed that disagrees with the bytes produces a refused update, not an unsafe
# one. Getting it wrong is an outage, which is why this re-measures the served object.
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/aws-profile-guard.sh

PROFILE=""
REGION=""
INSTANCE=""
ACCOUNT=""
DMG=""
URL=""
ARCH="arm64"
CHANNEL="stable"
NOTES=""
CRITICAL="false"
DRY_RUN=0
WEB_TF="infra/web/terraform"
AWS_TF="infra/aws/terraform"

# The client refuses anything larger before it downloads a byte
# (UpdateTrust.maximumDownloadBytes), so a bigger image would publish and never install.
MAX_BYTES=$((512 * 1024 * 1024))

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --instance) INSTANCE="${2:-}"; shift 2 ;;
    --account) ACCOUNT="${2:-}"; shift 2 ;;
    --dmg) DMG="${2:-}"; shift 2 ;;
    --url) URL="${2:-}"; shift 2 ;;
    --arch) ARCH="${2:-}"; shift 2 ;;
    --channel) CHANNEL="${2:-}"; shift 2 ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    --critical) CRITICAL="true"; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "FAIL  unknown argument '$1'"; exit 2 ;;
  esac
done

require_aws_profile "$PROFILE" || exit 2

tf_output() {
  (cd "$1" && terraform output -raw "$2" 2>/dev/null) || true
}

[[ -n "$REGION" ]] || REGION="$(tf_output "$AWS_TF" aws_region)"
[[ -n "$REGION" ]] || REGION="eu-west-2"
[[ -n "$INSTANCE" ]] || INSTANCE="$(tf_output "$AWS_TF" instance_id)"
[[ -n "$ACCOUNT" ]] || ACCOUNT="$(tf_output "$AWS_TF" aws_account_id)"
API_DOMAIN="$(tf_output "$AWS_TF" api_domain)"
SITE_URL="$(tf_output "$WEB_TF" site_url)"

require_aws_profile "$PROFILE" "$ACCOUNT" || exit 2

if [[ -z "$INSTANCE" ]]; then
  echo "FAIL  no instance: pass --instance, or export AWS_PROFILE so 'terraform output' can read the S3 backend"
  exit 2
fi

# ---- the image and the fields the app will check ---------------------------

# shellcheck disable=SC2012  # package-dmg.sh names these, so there is nothing exotic to quote
[[ -n "$DMG" ]] || DMG="$(ls -t dist/SkipperDesk-*.dmg 2>/dev/null | head -1)"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "FAIL  no image: run ./scripts/build.sh && ./scripts/package-dmg.sh"
  exit 1
fi
FIELDS="${DMG%.dmg}.release.json"
[[ -f "$FIELDS" ]] || { echo "FAIL  missing $FIELDS: re-run ./scripts/package-dmg.sh"; exit 1; }

# package-dmg.sh writes release.json last, after signing, notarising and stapling, because
# every one of those rewrites the image. Re-measuring here catches a release.json left over
# from an earlier build of the same version -- the app compares the hash it is told with the
# bytes it downloads and refuses the update on a mismatch, so a stale file is an outage.
SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
SIZE="$(wc -c <"$DMG" | tr -d ' ')"
STATED_SHA="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$FIELDS")"
STATED_SIZE="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["size"])' "$FIELDS")"
VERSION="$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$FIELDS")"

if [[ "$SHA256" != "$STATED_SHA" || "$SIZE" != "$STATED_SIZE" ]]; then
  echo "FAIL  $FIELDS does not describe $DMG; re-run ./scripts/package-dmg.sh"
  echo "      stated  $STATED_SHA  $STATED_SIZE bytes"
  echo "      actual  $SHA256  $SIZE bytes"
  exit 1
fi

if [[ "$SIZE" -gt "$MAX_BYTES" ]]; then
  echo "FAIL  $SIZE bytes is over the client's $MAX_BYTES-byte ceiling; it would publish and never install"
  exit 1
fi

# An image Gatekeeper will not open with a plain double-click is not shippable: the second
# Mac is the whole point, and that Mac has never trusted this signing identity locally.
echo "== checking the image is notarised and stapled"
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  echo "FAIL  $DMG carries no stapled notarisation ticket"
  echo "      RC_SIGN_IDENTITY=... RC_NOTARY_PROFILE=... ./scripts/package-dmg.sh"
  echo "      both live only on the owner's Mac, so this step cannot run anywhere else"
  exit 1
fi
echo "  ok    stapler validate agrees"

[[ -n "$URL" ]] || URL="${SITE_URL%/}/assets/$(basename "$DMG")"

echo
echo "== release"
echo "  image        $DMG"
echo "  version      $VERSION"
echo "  track        macos/$ARCH/$CHANNEL"
echo "  critical     $CRITICAL"
echo "  sha256       $SHA256"
echo "  size         $SIZE bytes"
echo "  url          $URL"
echo "  instance     $INSTANCE"

BODY="$(NOTES="$NOTES" /usr/bin/python3 -c '
import json, os, sys
fields = json.load(open(sys.argv[1]))
fields.update({"platform": "macos", "arch": sys.argv[2], "channel": sys.argv[3],
               "url": sys.argv[4], "critical": sys.argv[5] == "true"})
notes = os.environ.get("NOTES", "")
if notes:
    fields["notes"] = notes
print(json.dumps(fields))
' "$FIELDS" "$ARCH" "$CHANNEL" "$URL" "$CRITICAL")"

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo
  echo "== the body that would be posted to the internal listener"
  echo "$BODY" | /usr/bin/python3 -m json.tool | sed 's/^/  /'
  echo
  echo "DRY RUN  nothing was published"
  exit 0
fi

# ---- publish, from the box ---------------------------------------------------

# The body travels base64-encoded so that nothing in it -- a quote in --notes above all --
# can end the quoting of the script it is embedded in.
BODY_B64="$(printf '%s' "$BODY" | base64 | tr -d '\n')"

# The remote script verifies the SERVED object, not the local file: what the app downloads
# is whatever CloudFront hands out, and that is the only copy whose hash matters.
REMOTE_SCRIPT=$(cat <<SCRIPT
set -euo pipefail
umask 077
WORK="\$(mktemp -d)"
trap 'rm -rf "\$WORK"' EXIT

curl -fsSL --max-time 600 -o "\$WORK/image.dmg" '$URL'
echo "$SHA256  \$WORK/image.dmg" | sha256sum -c - >/dev/null
SERVED="\$(wc -c <"\$WORK/image.dmg" | tr -d ' ')"
if [ "\$SERVED" != "$SIZE" ]; then
  echo "FAIL  the served image is \$SERVED bytes, not $SIZE"
  exit 1
fi
echo "ok    the served image matches the sha256 and the byte length"
rm -f "\$WORK/image.dmg"

# The bearer goes into a --config file, never an argument: a command line is readable by
# every local user in ps, which is the same reason rc-api takes -internal-token-file.
printf 'header = "Authorization: Bearer %s"\n' "\$(cat /var/lib/skipperdesk/internal-token)" >"\$WORK/curl.cfg"
printf '%s' '$BODY_B64' | base64 -d >"\$WORK/body.json"

curl -fsS -K "\$WORK/curl.cfg" \
  -X POST http://127.0.0.1:18081/internal/releases \
  -H 'Content-Type: application/json' \
  --data-binary "@\$WORK/body.json" >"\$WORK/created.json"
echo "ok    published on the internal listener"

PUBLIC="\$(curl -fsS 'http://127.0.0.1:18080/v1/app/releases/latest?platform=macos&arch=$ARCH&channel=$CHANNEL')"
echo "\$PUBLIC" | grep -q '"sha256":"$SHA256"' || {
  echo "FAIL  the feed does not serve the release that was just published"
  echo "\$PUBLIC"
  exit 1
}
echo "ok    the feed serves it"
SCRIPT
)

echo
echo "== verifying the served image and publishing, over SSM"

# Base64 on one line and run explicitly under bash: AWS-RunShellScript uses /bin/sh, which
# is dash on this image and has no pipefail, and the CLI's shorthand parser loses newlines.
REMOTE_B64="$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\n')"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PARAMS="$WORK/ssm-params.json"
REMOTE_B64="$REMOTE_B64" /usr/bin/python3 - "$PARAMS" <<'PY'
import json, os, sys
one = ("set -e; printf '%s' '" + os.environ["REMOTE_B64"] + "'"
       " | base64 -d > /tmp/skipperdesk-publish.sh;"
       " bash /tmp/skipperdesk-publish.sh; rc=$?;"
       " rm -f /tmp/skipperdesk-publish.sh; exit $rc")
json.dump({"Parameters": {"commands": [one]}}, open(sys.argv[1], "w"))
PY

# Publishing a release is an administrative action taken over Run Command, and CloudTrail
# records the call with the payload redacted. Sending the output to the runcommand log
# group is the only account-side record of what was published and by whom.
RUNCOMMAND_LOG_GROUP="$(tf_output "$AWS_TF" runcommand_log_group)"
OUTPUT_CONFIG=()
if [[ -n "$RUNCOMMAND_LOG_GROUP" ]]; then
  OUTPUT_CONFIG=(--cloud-watch-output-config
    "CloudWatchLogGroupName=$RUNCOMMAND_LOG_GROUP,CloudWatchOutputEnabled=true")
else
  echo "note  no runcommand_log_group output; this publish will not be logged. Apply"
  echo "note  infra/aws/terraform to create the group."
fi

COMMAND_ID="$(aws ssm send-command \
  --profile "$PROFILE" --region "$REGION" \
  --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --comment "skipperdesk publish $VERSION" \
  --cli-input-json "file://$PARAMS" \
  ${OUTPUT_CONFIG[@]+"${OUTPUT_CONFIG[@]}"} \
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
  echo "FAIL  the publish finished as $STATUS; nothing was changed if the verification step failed"
  aws ssm get-command-invocation \
    --profile "$PROFILE" --region "$REGION" \
    --command-id "$COMMAND_ID" --instance-id "$INSTANCE" \
    --query 'StandardErrorContent' --output text | sed 's/^/  /'
  exit 1
fi

if [[ -n "$API_DOMAIN" ]]; then
  echo
  echo "== verifying the public feed"
  FEED="$(curl -fsS --max-time 10 \
    "https://$API_DOMAIN/v1/app/releases/latest?platform=macos&arch=$ARCH&channel=$CHANNEL" || true)"
  case "$FEED" in
    *"\"sha256\":\"$SHA256\""*)
      echo "  ok    $FEED" ;;
    *)
      echo "FAIL  https://$API_DOMAIN does not serve the new release yet"
      echo "      $FEED"
      exit 1 ;;
  esac

  echo
  echo "== verifying the download page offers this image"
  PAGE="$(curl -fsS --max-time 10 "${SITE_URL%/}/download" || true)"
  case "$PAGE" in
    *"/assets/$(basename "$DMG")"*)
      echo "  ok    the page links to $(basename "$DMG")" ;;
    *)
      echo "WARN  ${SITE_URL%/}/download does not link to $(basename "$DMG")"
      echo "      edit web/download/index.html and run infra/web/deploy.sh --profile $PROFILE"
      echo "      the release is published; only the page people arrive on is stale" ;;
  esac

  echo
  echo "== verifying the internal surface is not public"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "https://$API_DOMAIN/internal/releases" || true)"
  if [[ "$CODE" != "404" ]]; then
    echo "FAIL  POST https://$API_DOMAIN/internal/releases answered $CODE, not 404"
    exit 1
  fi
  echo "  ok    the publish path answers 404 from the internet"
fi

echo
echo "PUBLISH PASSED  $VERSION"
