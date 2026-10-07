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
# written with a doubled dollar. That is the whole reason for the three suppressions.
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2086,SC2034
set -euo pipefail
exec >>/var/log/${project}-bootstrap.log 2>&1
echo "== bootstrap $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl sqlite3 awscli coturn

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
install -d -m 0750 -o ${service_user} -g ${service_user} ${data_dir} ${log_dir}

CONFIG=/run/${project}-config
rm -rf "$${CONFIG}"
install -d -m 0700 "$${CONFIG}"
aws s3 cp --region ${aws_region} --recursive --only-show-errors \
  s3://${backup_bucket}/config/ "$${CONFIG}/"

param() {
  aws ssm get-parameter --region ${aws_region} --with-decryption \
    --name "${ssm_prefix}/$${1}" --query Parameter.Value --output text
}

secret_file() {
  local target="${data_dir}/$${2}"
  ( umask 077; param "$${1}" >"$${target}" )
  chown ${service_user}:${service_user} "$${target}"
  chmod 0600 "$${target}"
}

secret_file turn-secret turn-secret
secret_file internal-token internal-token
secret_file id-cert-key id-cert-key.pem

# systemd reads an EnvironmentFile as root before it drops privileges, so these are 0600
# root-owned rather than service-user-owned: one less process that can read them.
umask 077
printf 'RC_API_HARDWARE_SALT=%s\n' "$(param hardware-salt)" >${config_dir}/rc-api.env
printf 'RC_TOKEN_SECRET=%s\n' "$(param token-secret)" >${config_dir}/rc-signal.env
chmod 0600 ${config_dir}/rc-api.env ${config_dir}/rc-signal.env
umask 022

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
printf 'static-auth-secret=%s\n' "$(param turn-secret)" >>/etc/turnserver.conf
chown root:turnserver /etc/turnserver.conf
chmod 0640 /etc/turnserver.conf
printf 'TURNSERVER_ENABLED=1\n' >/etc/default/coturn
install -d -m 0755 /etc/systemd/system/coturn.service.d
install -m 0644 "$${CONFIG}/coturn.service.d/override.conf" /etc/systemd/system/coturn.service.d/override.conf

install -m 0755 "$${CONFIG}/backup.sh" ${app_dir}/bin/backup.sh
install -m 0644 "$${CONFIG}/rc-api.service" /etc/systemd/system/rc-api.service
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
systemctl enable --now caddy coturn
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
