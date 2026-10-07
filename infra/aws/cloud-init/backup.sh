#!/usr/bin/env bash
# Snapshots one SQLite database to S3.
#
#   backup.sh db      -> rc-api.db        -> s3://$SKIPPER_BACKUP_BUCKET/db/
#   backup.sh claims  -> rc-api-claims.db -> s3://$SKIPPER_BACKUP_BUCKET/claims/
#
# The two run on their own timers with their own retentions, and a restore never brings
# them back together (API.md §6.1). Configuration comes from /etc/skipperdesk/backup.env,
# so nothing in this file is rendered or environment-specific.
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
  echo "note  $SOURCE does not exist yet; nothing to back up"
  exit 0
fi

NAME="$(basename "$SOURCE")"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sqlite3 "$SOURCE" ".backup '$WORK/$NAME'"
gzip -9 "$WORK/$NAME"
aws s3 cp --region "$REGION" --only-show-errors \
  "$WORK/$NAME.gz" "s3://$BUCKET/$PREFIX/$STAMP-$NAME.gz"
echo "ok    $PREFIX/$STAMP-$NAME.gz"
