#!/usr/bin/env bash
# Snapshots one SQLite database to S3.
#
#   backup.sh db      -> rc-api.db        -> s3://$SKIPPER_BACKUP_BUCKET/db/
#   backup.sh claims  -> rc-api-claims.db -> s3://$SKIPPER_BACKUP_BUCKET/claims/
#
# The two run on their own timers with their own retentions, and a restore never brings
# them back together (API.md §6.1). Configuration comes from /etc/skipperdesk/backup.env,
# so nothing in this file is rendered or environment-specific.
#
# Every path out of this script that did not put an object in S3 exits non-zero. An earlier
# version returned 0 when the source file was absent, which is how the claims database went
# unbacked-up for the life of the bucket while the unit reported Result=success: the one
# scheduled run landed before rc-api had created the file, said so quietly, and the timer
# stamp then suppressed any retry for 24 hours. A backup script that exits 0 having backed
# nothing up is worse than no backup script, because it also produces a green light.
set -euo pipefail

WHICH="${1:?usage: backup.sh db|claims}"
BUCKET="${SKIPPER_BACKUP_BUCKET:?SKIPPER_BACKUP_BUCKET is not set}"
DATA="${SKIPPER_DATA_DIR:?SKIPPER_DATA_DIR is not set}"
REGION="${AWS_REGION:?AWS_REGION is not set}"

case "$WHICH" in
  db) SOURCE="$DATA/rc-api.db"; PREFIX="db" ;;
  claims) SOURCE="$DATA/rc-api-claims.db"; PREFIX="claims" ;;
  *) echo "FAIL  unknown database '$WHICH': want db or claims" >&2; exit 2 ;;
esac

if [[ ! -s "$SOURCE" ]]; then
  echo "FAIL  $SOURCE is missing or empty, so nothing was backed up. If this instance has" >&2
  echo "FAIL  only just booted, rc-api has not created it yet and the next run in 15" >&2
  echo "FAIL  minutes will succeed; if it keeps failing, the service or the data volume is" >&2
  echo "FAIL  not there. The backup-stale-${PREFIX} alarm fires either way." >&2
  exit 1
fi

NAME="$(basename "$SOURCE")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
KEY="$PREFIX/$STAMP-$NAME.gz"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sqlite3 "$SOURCE" ".backup '$WORK/$NAME'"
if [[ ! -s "$WORK/$NAME" ]]; then
  echo "FAIL  sqlite3 .backup of $SOURCE produced nothing; no object was written" >&2
  exit 1
fi

gzip -9 "$WORK/$NAME"
aws s3 cp --region "$REGION" --only-show-errors "$WORK/$NAME.gz" "s3://$BUCKET/$KEY"

# The upload is confirmed against the bucket rather than by trusting the exit status of the
# command that wrote it. This is the one check that distinguishes "the backup happened"
# from "the backup command returned", and it is the fact the backup-stale alarm keys on,
# because the `ok` line below is only printed if it passes.
#
# Listed, not read: the instance role holds s3:PutObject and s3:ListBucket on this prefix
# and deliberately not s3:GetObject, so that a compromise of the box cannot read the
# backups it writes (PHASE5 §1). head-object would need GetObject and would have to widen
# that grant, so the size comes out of the listing instead.
SIZE="$(aws s3api list-objects-v2 --region "$REGION" --bucket "$BUCKET" --prefix "$KEY" \
  --query 'Contents[0].Size' --output text)"
if [[ ! "$SIZE" =~ ^[0-9]+$ ]] || [[ "$SIZE" -le 0 ]]; then
  echo "FAIL  s3://$BUCKET/$KEY does not read back as a non-empty object" >&2
  exit 1
fi

echo "ok    $KEY bytes=$SIZE"
