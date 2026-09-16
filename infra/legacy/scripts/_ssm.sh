#!/usr/bin/env bash
# Shared SSM helper. Source this; do not execute it.
set -euo pipefail
INSTANCE_ID="${RC_INSTANCE_ID:-i-0268c831a241111fe}"
REGION="${RC_REGION:-eu-west-1}"
PROFILE="${RC_PROFILE:-godson}"

# Guard: refuse to ever send a command that could disturb the production service.
_ssm_guard() {
  local cmd="$1"
  local -a forbidden=(
    '/opt/gptc' 'gptc-api' 'gptc-cloudflared'
    'system prune' 'volume prune' 'image prune' 'container prune' 'network prune'
    'systemctl restart docker' 'systemctl stop docker' 'daemon.json'
    'shutdown' 'reboot' 'mkfs' 'rm -rf /'
  )
  for f in "${forbidden[@]}"; do
    if [[ "$cmd" == *"$f"* ]]; then
      echo "REFUSED: command touches protected resource: '$f'" >&2
      echo "  command was: $cmd" >&2
      return 1
    fi
  done
  return 0
}

# Read-only guard: for probes that must MENTION protected paths but never change them.
# Blocks every mutating verb outright, so a read probe cannot be turned into a write.
_ssm_guard_ro() {
  local cmd="$1"
  local -a mutating=(
    'docker compose' 'docker-compose' 'docker run' 'docker start' 'docker stop'
    'docker rm' 'docker rmi' 'docker kill' 'docker restart' 'docker build'
    'docker exec' 'docker prune' 'docker cp' 'docker load' 'docker pull'
    'systemctl' 'service ' 'apt' 'snap ' 'pip install' 'reboot' 'shutdown'
    'rm ' 'rmdir' 'mv ' 'cp ' 'chmod' 'chown' 'ln -s' 'truncate' 'dd '
    'sed -i' 'tee ' 'kill' 'pkill' 'mkfs' 'mount' 'umount' 'crontab'
    '>' '>>'
  )
  for m in "${mutating[@]}"; do
    if [[ "$cmd" == *"$m"* ]]; then
      echo "REFUSED (read-only context): command contains mutating token: '$m'" >&2
      return 1
    fi
  done
  return 0
}

# ssm_run_ro "<read-only probe>" -> for inspecting protected resources. No writes possible.
ssm_run_ro() {
  _ssm_guard_ro "$1" || return 1
  _ssm_exec "$1"
}

# ssm_run "<shell command>"  -> prints stdout, exits non-zero on remote failure
ssm_run() {
  local cmd="$1"
  _ssm_guard "$cmd" || return 1
  _ssm_exec "$cmd"
}

_ssm_exec() {
  local cmd="$1" payload cid status
  payload=$(python3 -c 'import json,sys; print(json.dumps({"commands":[sys.argv[1]]}))' "$cmd")
  cid=$(aws ssm send-command \
        --instance-ids "$INSTANCE_ID" --region "$REGION" --profile "$PROFILE" \
        --document-name AWS-RunShellScript \
        --cli-input-json "{\"Parameters\":$payload}" \
        --query Command.CommandId --output text)
  for _ in $(seq 1 60); do
    status=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
             --region "$REGION" --profile "$PROFILE" --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    sleep 2
  done
  aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
      --region "$REGION" --profile "$PROFILE" --query StandardOutputContent --output text
  if [[ "$status" != "Success" ]]; then
    echo "--- remote stderr ---" >&2
    aws ssm get-command-invocation --command-id "$cid" --instance-id "$INSTANCE_ID" \
        --region "$REGION" --profile "$PROFILE" --query StandardErrorContent --output text >&2
    return 1
  fi
}
