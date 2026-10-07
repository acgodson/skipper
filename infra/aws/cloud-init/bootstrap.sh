#!/usr/bin/env bash
# Instance bootstrap, rendered by Terraform into the instance's user data.
# It installs the two servers' surroundings — Caddy, coturn, the CloudWatch agent — lays
# out the directories, fetches every secret from SSM into a file, and enables the units.
# It never puts a secret on a command line. The two Go binaries arrive separately, through
# infra/aws/deploy.sh; the units are enabled either way, so a reboot starts them once they
# are there.
#
# This file is a Terraform template: a brace expansion below is substituted before the
# script exists, so no shell ever sees it, and a variable belonging to the script itself is
# written with a doubled dollar. That is the whole reason for the suppressions: every
# `$${name}` here reads as a literal `$` followed by text until Terraform has rendered it,
# which is why `[ -z "$${name}" ]` looks like a test on a constant. The rendered script,
# which is the one that runs, is clean without any of them.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2086,SC2034,SC2193,SC2157
set -euo pipefail
exec >>/var/log/${project}-bootstrap.log 2>&1
echo "== bootstrap $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl unzip sqlite3 coturn

# Ubuntu 24.04 dropped the awscli package, so the CLI comes from Amazon's own installer.
if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL -o /tmp/awscliv2.zip https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install --update
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

if ! apt-get install -y --no-install-recommends caddy; then
  echo "FAIL  this image's archive has no caddy package; see infra/aws/README.md 'Caddy'"
  exit 1
fi

curl -fsSL -o /tmp/amazon-cloudwatch-agent.deb \
  https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/arm64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E /tmp/amazon-cloudwatch-agent.deb
rm -f /tmp/amazon-cloudwatch-agent.deb

if ! id -u ${service_user} >/dev/null 2>&1; then
  useradd --system --home-dir ${data_dir} --shell /usr/sbin/nologin ${service_user}
fi

install -d -m 0755 ${app_dir} ${app_dir}/bin ${app_dir}/releases
install -d -m 0755 ${config_dir}
install -d -m 0750 -o ${service_user} -g ${service_user} ${log_dir}

# The databases live on their own EBS volume and never on the root volume. The disk is
# found by the volume id EBS writes into the NVMe serial number: on Nitro the kernel's
# /dev/nvme*n1 names are handed out in attachment order and are not stable across a
# reboot, and the name EC2 was asked for is not a name Linux ever uses.
DATA_LINK=/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${data_volume_serial}
for _ in $(seq 1 60); do
  [ -e "$${DATA_LINK}" ] && break
  sleep 5
done
if [ ! -e "$${DATA_LINK}" ]; then
  echo "FAIL  the data volume never appeared at $${DATA_LINK}" >&2
  exit 1
fi
DATA_DEV="$(readlink -f "$${DATA_LINK}")"

# Format only a disk that is provably blank, and treat a probe that does not answer
# cleanly as "not blank". A false "blank" here is the one operation in this system that
# destroys data irrecoverably, so the formatting branch needs three things to agree:
# blkid exits 2, which is its "nothing found" code and not its error code; blkid names
# neither a filesystem nor a partition table; and wipefs recognises no signature at all.
# Any other combination — including a probe that failed — mounts the volume untouched.
# Neither probe's exit status is read through a pipe, because a pipeline's status depends
# on pipefail and this decision must not.
PROBE="$(blkid -p -o value -s TYPE -s PTTYPE "$${DATA_DEV}" 2>/dev/null)" && PROBE_RC=0 || PROBE_RC=$?
if SIGNATURE_TABLE="$(wipefs --no-act --output TYPE "$${DATA_DEV}" 2>/dev/null)"; then
  SIGNATURES="$(printf '%s\n' "$${SIGNATURE_TABLE}" | tail -n +2)"
else
  SIGNATURES=probe-failed
fi

if [ "$${PROBE_RC}" = 2 ] && [ -z "$${PROBE}" ] && [ -z "$${SIGNATURES}" ]; then
  echo "note  $${DATA_DEV} carries no filesystem and no signature; formatting it once"
  mkfs.${filesystem_type} -L ${project}-data "$${DATA_DEV}"
elif [ "$${SIGNATURES}" = probe-failed ]; then
  echo "note  wipefs could not probe $${DATA_DEV}; refusing to format on one probe alone"
else
  echo "note  $${DATA_DEV} already carries a filesystem; mounting it untouched"
fi

DATA_UUID="$(blkid -o value -s UUID "$${DATA_DEV}")"
if [ -z "$${DATA_UUID}" ]; then
  echo "FAIL  $${DATA_DEV} has no filesystem UUID to mount by. If this volume is new, the" >&2
  echo "FAIL  probes above disagreed about whether it was blank and nothing was formatted;" >&2
  echo "FAIL  run 'blkid -p' and 'wipefs --no-act' against it and decide by hand." >&2
  exit 1
fi

# By UUID, never by device name. nofail so a volume that is missing or late leaves the
# box bootable and reachable over SSM; rc-api then refuses to start, because its unit
# names this mount as a requirement, rather than opening a fresh empty database on the
# root volume and serving from it.
install -d -m 0755 ${data_dir}
sed -i "\\#[[:space:]]${data_dir}[[:space:]]#d" /etc/fstab
printf 'UUID=%s %s %s defaults,nofail,noatime 0 2\n' \
  "$${DATA_UUID}" "${data_dir}" "${filesystem_type}" >>/etc/fstab
systemctl daemon-reload
mountpoint -q ${data_dir} || mount ${data_dir}
if ! mountpoint -q ${data_dir}; then
  echo "FAIL  ${data_dir} did not mount" >&2
  exit 1
fi
chown ${service_user}:${service_user} ${data_dir}
chmod 0750 ${data_dir}

CONFIG=/run/${project}-config
rm -rf "$${CONFIG}"
install -d -m 0700 "$${CONFIG}"
aws s3 cp --region ${aws_region} --recursive --only-show-errors \
  s3://${backup_bucket}/config/ "$${CONFIG}/"

PLACEHOLDER=placeholder-set-out-of-band

# Terraform creates every parameter holding the placeholder, so a bootstrap that runs before
# the owner has written the real values would otherwise come up serving happily with a TURN
# secret and a hardware salt that are a known public string.
param() {
  local value
  value="$(aws ssm get-parameter --region ${aws_region} --with-decryption \
    --name "${ssm_prefix}/$${1}" --query Parameter.Value --output text)"
  if [ "$${value}" = "$${PLACEHOLDER}" ]; then
    echo "FAIL  ${ssm_prefix}/$${1} still holds the placeholder; write the real value first" >&2
    return 1
  fi
  printf '%s' "$${value}"
}

secret_file() {
  local target="${data_dir}/$${2}" value
  value="$(param "$${1}")"
  ( umask 077; printf '%s\n' "$${value}" >"$${target}" )
  chown ${service_user}:${service_user} "$${target}"
  chmod 0600 "$${target}"
}

secret_file turn-secret turn-secret
secret_file internal-token internal-token

# systemd reads an EnvironmentFile as root before it drops privileges, so these are 0600
# root-owned rather than service-user-owned: one less process that can read them.
HARDWARE_SALT="$(param hardware-salt)"
TOKEN_SECRET="$(param token-secret)"
umask 077
# AWS_REGION is set rather than left to the SDK's own resolution: without it the SDK asks
# IMDS for the region on every start, which is a round-trip it does not need and a hard
# failure if the metadata service is ever restricted. rc-api needs it to reach KMS.
{
  printf 'RC_API_HARDWARE_SALT=%s\n' "$${HARDWARE_SALT}"
  printf 'AWS_REGION=%s\n' "${aws_region}"
} >${config_dir}/rc-api.env
printf 'RC_TOKEN_SECRET=%s\n' "$${TOKEN_SECRET}" >${config_dir}/rc-signal.env
chmod 0600 ${config_dir}/rc-api.env ${config_dir}/rc-signal.env
umask 022
unset HARDWARE_SALT TOKEN_SECRET

cat >${config_dir}/caddy.env <<ENV
SKIPPER_ACME_EMAIL=${acme_email}
SKIPPER_API_DOMAIN=${api_domain}
SKIPPER_API_UPSTREAM=${api_listen}
SKIPPER_SIGNAL_UPSTREAM=${signal_listen}
ENV

cat >${config_dir}/backup.env <<ENV
SKIPPER_BACKUP_BUCKET=${backup_bucket}
SKIPPER_DATA_DIR=${data_dir}
AWS_REGION=${aws_region}
ENV

chmod 0644 ${config_dir}/caddy.env ${config_dir}/backup.env

install -m 0644 "$${CONFIG}/Caddyfile" /etc/caddy/Caddyfile
install -d -m 0755 /etc/systemd/system/caddy.service.d
install -m 0644 "$${CONFIG}/caddy.service.d/override.conf" /etc/systemd/system/caddy.service.d/override.conf

# The Elastic IP is associated a moment after launch, so until it is, this instance answers
# on a different address than the one coturn is about to advertise as external-ip. Waiting
# here is cheaper than noticing it later as relays that allocate and never connect.
for _ in $(seq 1 60); do
  TOKEN="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token || true)"
  PUBLIC="$(curl -fsS -H "X-aws-ec2-metadata-token: $${TOKEN}" \
    http://169.254.169.254/latest/meta-data/public-ipv4 || true)"
  [ "$${PUBLIC}" = "${external_ip}" ] && break
  sleep 5
done
if [ "$${PUBLIC}" != "${external_ip}" ]; then
  echo "note  the Elastic IP ${external_ip} is still not this instance's address; coturn will"
  echo "note  advertise it anyway, and needs a restart if the association never lands"
fi

# coturn takes its secret only from its configuration file, never from a flag, so the
# placeholder line is dropped and the real value appended; the file is group-readable by
# the turnserver user and by nobody else.
grep -v '^static-auth-secret=' "$${CONFIG}/turnserver.conf" >/etc/turnserver.conf
TURN_SECRET="$(param turn-secret)"
printf 'static-auth-secret=%s\n' "$${TURN_SECRET}" >>/etc/turnserver.conf
unset TURN_SECRET
chown root:turnserver /etc/turnserver.conf
chmod 0640 /etc/turnserver.conf
printf 'TURNSERVER_ENABLED=1\n' >/etc/default/coturn
install -d -m 0755 /etc/systemd/system/coturn.service.d
install -m 0644 "$${CONFIG}/coturn.service.d/override.conf" /etc/systemd/system/coturn.service.d/override.conf

install -m 0755 "$${CONFIG}/backup.sh" ${app_dir}/bin/backup.sh
install -m 0644 "$${CONFIG}/rc-api.service" /etc/systemd/system/rc-api.service
install -d -m 0755 /etc/systemd/system/rc-api.service.d
install -m 0644 "$${CONFIG}/rc-api.service.d/mount.conf" /etc/systemd/system/rc-api.service.d/mount.conf
install -m 0644 "$${CONFIG}/rc-signal.service" /etc/systemd/system/rc-signal.service
install -m 0644 "$${CONFIG}/skipperdesk-backup@.service" /etc/systemd/system/skipperdesk-backup@.service
install -m 0644 "$${CONFIG}/skipperdesk-backup-db.timer" /etc/systemd/system/skipperdesk-backup-db.timer
install -m 0644 "$${CONFIG}/skipperdesk-backup-claims.timer" /etc/systemd/system/skipperdesk-backup-claims.timer

install -m 0644 "$${CONFIG}/cloudwatch-agent.json" \
  /opt/aws/amazon-cloudwatch-agent/etc/${project}.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/${project}.json

rm -rf "$${CONFIG}"

systemctl daemon-reload

# apt starts caddy and coturn the moment it installs them, before any of the configuration
# above exists, and `enable --now` does nothing to a unit that is already running. Restart,
# so what is on disk is what is actually serving.
systemctl enable caddy coturn
systemctl restart caddy coturn
systemctl enable --now skipperdesk-backup-db.timer skipperdesk-backup-claims.timer
systemctl enable rc-api.service rc-signal.service

if aws s3 cp --region ${aws_region} --only-show-errors \
    "s3://${backup_bucket}/releases/current.tar.gz" /tmp/current.tar.gz; then
  tar -xzf /tmp/current.tar.gz -C ${app_dir}/bin
  rm -f /tmp/current.tar.gz
  chmod 0755 ${app_dir}/bin/rc-api ${app_dir}/bin/rc-signal
  systemctl start rc-api.service rc-signal.service
else
  echo "note  no releases/current.tar.gz yet; run infra/aws/deploy.sh to install the binaries"
fi

echo "== bootstrap done $(date -u +%Y-%m-%dT%H:%M:%SZ)"
