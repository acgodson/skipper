#!/usr/bin/env bash
# Phase 5 milestone 5.2 gate: prove the TURN relay works and prove it stops working.
#
# It checks the two halves of the shared secret agree without printing either, then drives
# a real STUN/TURN Allocate against the live coturn with a credential minted by the same
# function rc-signal uses (server/internal/auth.TurnCreds), asserting that
#
#   * a valid credential allocates,
#   * a public peer is permitted but RFC1918 and link-local peers are refused (the
#     open-relay check: a relay into our own VPC or into 169.254.169.254 is a pivot),
#   * a tampered credential, another session's credential and a past-dated one are refused,
#   * the deny list in infra/aws/coturn/turnserver.conf is parsed the way it reads by the
#     coturn build actually installed, re-checked in a throwaway loopback instance,
#   * and, with --wait-expiry, that the very same credential is refused once its own
#     ten-minute lifetime has run out.
#
# Read-only: it reads one SSM parameter and runs read-only commands plus short-lived
# loopback-only test processes on the instance. Nothing on the box is changed.
# See docs/PHASE5.md §8 and protocol/PROTOCOL.md §2.18.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

AWS_PROFILE="${SKIPPER_AWS_PROFILE:-skipperdesk}"
AWS_REGION="${SKIPPER_AWS_REGION:-eu-west-2}"
INSTANCE="${SKIPPER_INSTANCE_ID:-i-00fa1625fdade0a87}"
SECRET_PARAM="${SKIPPER_TURN_SECRET_PARAM:-/skipperdesk/prod/turn-secret}"
TURN_HOST="${SKIPPER_TURN_HOST:-turn.skipperdesk.app}"
TURN_PORT="${SKIPPER_TURN_PORT:-3478}"
TURN_REALM="${SKIPPER_TURN_REALM:-$TURN_HOST}"
TURN_CONF="infra/aws/coturn/turnserver.conf"
PUBLIC_PEER="${SKIPPER_TURN_PUBLIC_PEER:-1.1.1.1:9}"
PRIVATE_PEERS="${SKIPPER_TURN_PRIVATE_PEERS:-169.254.169.254:80,10.0.0.1:9}"
export AWS_PROFILE AWS_REGION

WAIT_EXPIRY=0
SKIP_SSM=0
for arg in "$@"; do
    case "$arg" in
        --wait-expiry) WAIT_EXPIRY=1 ;;
        --skip-ssm) SKIP_SSM=1 ;;
        -h | --help)
            sed -n '2,20p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

fail=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

step() {
    echo
    echo "== $*"
}
report() {
    echo "FAIL  $1"
    fail=1
}

# on_box runs a script file on the instance and prints its stdout indented. The exit status
# is the SSM invocation's, so a caller can distinguish "could not ask" from "the answer was
# no". Nothing it is given writes outside /tmp.
on_box() {
    local script="$1" params cmd_id status out
    params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[open(sys.argv[1]).read()]}))' "$script")
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
        --timeout-seconds 600 --parameters "$params" --query Command.CommandId --output text) || return 1
    status=InProgress
    for _ in $(seq 1 90); do
        sleep 3
        status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
            --query Status --output text 2>/dev/null || echo Pending)
        case "$status" in InProgress | Pending | Delayed) ;; *) break ;; esac
    done
    out=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
        --query StandardOutputContent --output text)
    while IFS= read -r line; do echo "  $line"; done <<<"$out"
    printf '%s' "$out" >"$WORK/on_box.out"
    [[ "$status" == "Success" ]]
}

said() { grep -qx "$1" "$WORK/on_box.out"; }

step "building turnprobe"
if ! (cd server && go build -o "$WORK/turnprobe" ./cmd/turnprobe); then
    report "turnprobe does not build"
    exit 1
fi
echo "  ok    server/cmd/turnprobe"

step "the shared secret: coturn's copy against rc-signal's"
# Both fingerprints are computed on the box and only the first 16 hex characters of a
# SHA-256 are printed, so nothing here reveals the secret itself.
if [[ "$SKIP_SSM" -eq 1 ]]; then
    echo "  skip  --skip-ssm"
else
    cat >"$WORK/fingerprint.sh" <<'REMOTE'
set -u
signal_file=/var/lib/skipperdesk/turn-secret
conf=/etc/turnserver.conf
if [ ! -r "$signal_file" ] || [ ! -r "$conf" ]; then
  echo "MISSING one of $signal_file $conf"; exit 1
fi
signal_fp=$(printf '%s' "$(cat "$signal_file")" | sha256sum | cut -c1-16)
turn_value=$(grep '^static-auth-secret=' "$conf" | tail -1 | sed 's/^static-auth-secret=//')
turn_fp=$(printf '%s' "$turn_value" | sha256sum | cut -c1-16)
echo "rc-signal fp=$signal_fp bytes=$(printf '%s' "$(cat "$signal_file")" | wc -c | tr -d ' ')"
echo "coturn    fp=$turn_fp bytes=$(printf '%s' "$turn_value" | wc -c | tr -d ' ')"
echo "static-auth-secret lines=$(grep -c '^static-auth-secret=' "$conf")"
if [ "$signal_fp" = "$turn_fp" ]; then echo "SECRETS MATCH"; else echo "SECRETS DIFFER"; fi
REMOTE
    if ! on_box "$WORK/fingerprint.sh" || ! said "SECRETS MATCH"; then
        report "coturn and rc-signal do not hold the same TURN secret"
        report "every relayed session would fail with no obvious error; fix before anything else"
    else
        echo "  ok    both services hold the same secret"
    fi
fi

step "fetching the secret for minting (never printed)"
secret_file="$WORK/turn-secret"
(
    umask 077
    aws ssm get-parameter --name "$SECRET_PARAM" --with-decryption \
        --query Parameter.Value --output text >"$secret_file"
)
if [[ ! -s "$secret_file" ]]; then
    report "could not read $SECRET_PARAM"
    exit 1
fi
echo "  ok    $SECRET_PARAM read into a 0600 file in a temporary directory"

session="$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
turn_urls="turn:${TURN_HOST}:${TURN_PORT}?transport=udp,turn:${TURN_HOST}:${TURN_PORT}?transport=tcp"
stun_urls="stun:${TURN_HOST}:${TURN_PORT}"

probe() {
    "$WORK/turnprobe" \
        -addr "${TURN_HOST}:${TURN_PORT}" -realm "$TURN_REALM" \
        -secret-file "$secret_file" -session "$session" \
        -public-peer "$PUBLIC_PEER" -denied-peers "$PRIVATE_PEERS" "$@"
}

step "Allocate against the live coturn, over udp"
probe -network udp -print-ice-servers -turn-urls "$turn_urls" -stun-urls "$stun_urls" \
    | tee "$WORK/udp.out"
[[ "${PIPESTATUS[0]}" -eq 0 ]] || report "the udp probe failed"

step "Allocate against the live coturn, over tcp"
# PROTOCOL.md's ice_servers list offers transport=tcp as well, so the same credential has to
# authenticate over the TCP listener; a TURN-over-TCP allocation is not a TCP relay, which
# turnserver.conf's no-tcp-relay forbids separately.
if ! probe -network tcp; then
    report "the tcp probe failed"
fi

step "the deny list in $TURN_CONF, as the installed coturn parses it"
# A denied-peer-ip range that the installed coturn reads differently from how it reads is
# the whole failure mode: coturn 4.6.1 compares a single address without gating on address
# family, so one IPv6 entry can deny every IPv4 peer and leave a relay that allocates and
# then carries nothing. This replays the committed list into a throwaway loopback-only
# coturn and drives it with the turnutils_uclient already on the box.
if [[ "$SKIP_SSM" -eq 1 ]]; then
    echo "  skip  --skip-ssm"
elif [[ ! -r "$TURN_CONF" ]]; then
    report "$TURN_CONF is missing"
else
    {
        echo "set -u"
        echo "DENIES=\$(cat <<'DENYLIST'"
        grep '^denied-peer-ip=' "$TURN_CONF" | sed 's/^denied-peer-ip=//'
        echo "DENYLIST"
        echo ")"
        echo "PUBLIC_PEER=${PUBLIC_PEER%%:*}"
        echo "PRIVATE_PEERS=\"$(tr ',' ' ' <<<"$PRIVATE_PEERS" | sed 's/:[0-9]*//g')\""
        cat <<'REMOTE'
W=$(mktemp -d /tmp/turnacl.XXXXXX)
trap 'rm -rf "$W"' EXIT
SECRET=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
# Each case gets its own port and its own log; verdict_for runs in a subshell, so a counter
# in the parent would not advance and every case would read the first case's log.
verdict_for() {
  local peer="$1" port="$2" conf="$W/$2.conf" log="$W/$2.log" pid
  {
    echo "listening-port=$port"
    echo "tls-listening-port=0"
    echo "listening-ip=127.0.0.1"
    echo "relay-ip=127.0.0.1"
    echo "min-port=49300"
    echo "max-port=49320"
    echo "realm=acl.invalid"
    echo "use-auth-secret"
    echo "static-auth-secret=$SECRET"
    echo "no-tcp-relay"
    echo "no-multicast-peers"
    echo "no-cli"
    echo "simple-log"
    echo "no-stdout-log"
    echo "log-file=$log"
    printf '%s\n' "$DENIES" | while IFS= read -r d; do
      [ -n "$d" ] && echo "denied-peer-ip=$d"
    done
  } >"$conf"
  turnserver -c "$conf" >/dev/null 2>&1 &
  pid=$!
  sleep 2
  timeout 12 turnutils_uclient -t -n 1 -u probe -W "$SECRET" \
    -e "$peer" -p "$port" 127.0.0.1 >/dev/null 2>&1
  sleep 1
  kill "$pid" >/dev/null 2>&1
  wait "$pid" >/dev/null 2>&1
  if grep -q "denied in the range" "$log" 2>/dev/null; then
    echo "DENIED  $(grep -m1 "denied in the range" "$log" | sed 's/.*ERROR: //')"
  elif [ ! -s "$log" ]; then
    echo "NO-ANSWER (the throwaway coturn on $port logged nothing)"
  else
    echo "ALLOWED"
  fi
}
bad=0
port=34771
v=$(verdict_for "$PUBLIC_PEER" "$port")
echo "public  $PUBLIC_PEER -> $v"
case "$v" in ALLOWED) ;; *) bad=1 ;; esac
for p in $PRIVATE_PEERS; do
  port=$((port + 1))
  v=$(verdict_for "$p" "$port")
  echo "private $p -> $v"
  case "$v" in DENIED*) ;; *) bad=1 ;; esac
done
if [ "$bad" -eq 0 ]; then echo "DENY LIST CORRECT"; else echo "DENY LIST WRONG"; fi
REMOTE
    } >"$WORK/acl.sh"
    if ! on_box "$WORK/acl.sh" || ! said "DENY LIST CORRECT"; then
        report "$TURN_CONF does not deny what it reads as denying, or allows nothing at all"
        report "a denied-peer-ip entry is matching peers outside its own address family"
    else
        echo "  ok    public peers relayable, private peers refused"
    fi
fi

if [[ "$WAIT_EXPIRY" -eq 1 ]]; then
    username=$(sed -n 's/^  \([0-9]*:[0-9a-f]*\)$/\1/p' "$WORK/udp.out" | tail -1)
    if [[ -z "$username" ]]; then
        report "could not recover the minted username from the udp probe output"
    else
        wait_for=$(("${username%%:*}" - $(date +%s) + 15))
        step "waiting ${wait_for}s for ${username} to expire, then re-presenting it"
        [[ "$wait_for" -gt 0 ]] && sleep "$wait_for"
        if ! probe -network udp -expect-expired "$username"; then
            report "the credential still worked after its lifetime"
        fi
    fi
else
    echo
    echo "  note  the ten-minute wait-out is skipped; run with --wait-expiry for it"
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "TURN GATE PASSED"
else
    echo "TURN GATE FAILED — see failures above." >&2
fi
exit "$fail"
