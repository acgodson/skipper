#!/usr/bin/env bash
# Phase 5 milestone 5.3 scaffolding: prove we can SEE which route media took, and
# prove that relay-only really excludes every other route.
#
# A "forced relay" proof is only worth something if two things are true, and neither
# of them was true in this repo before this script:
#
#   a. we can read, from libwebrtc's own statistics, the candidate pair the media
#      actually used — not the policy we asked for. `ICEPathStatistics` does that and
#      `rc-node ice-path` reports it.
#   b. `RC_ICE_POLICY=relay` genuinely removes host and server-reflexive candidates,
#      so a relay-only session that connects CANNOT have gone peer-to-peer. If
#      relay-only still fell back to a host candidate, a later "it relayed" claim
#      would be unfalsifiable.
#
# So: section A connects two real instances with no policy and asserts the path is
# observed and is NOT relayed; section B forces relay-only at a TURN server that can
# never allocate and asserts the session does NOT connect and NO pair is selected.
# Section C reads the live relay read-only and says what the relay side can and
# cannot corroborate.
#
# What this script deliberately does NOT claim: it does not prove media over the
# live relay. That needs a TURN credential, which means production signaling and a
# metered session, which means two entitled devices. See docs/VERIFY.md
# "Forced relay through the live London coturn" and docs/PHASE5.md §8.2.
#
# Read-only against AWS; section C runs read-only commands over SSM and can be
# skipped with --skip-ssm. No secret is read and none is printed.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
APP_DIR="$ROOT/apps/macos"
SERVER_DIR="$ROOT/server"
BIN="$APP_DIR/.build/debug/rc-node"
WORK="$(mktemp -d -t rc-relay)"

AWS_PROFILE="${SKIPPER_AWS_PROFILE:-skipperdesk}"
AWS_REGION="${SKIPPER_AWS_REGION:-eu-west-2}"
INSTANCE="${SKIPPER_INSTANCE_ID:-i-00fa1625fdade0a87}"
TURN_HOST="${SKIPPER_TURN_HOST:-turn.skipperdesk.app}"
export AWS_PROFILE AWS_REGION

# How long section B waits before concluding relay-only did not connect.
RELAY_FAIL_SECONDS="${RC_RELAY_FAIL_SECONDS:-25}"
SAMPLE_SECONDS="${RC_SAMPLE_SECONDS:-6}"

SKIP_SSM=0

source "$ROOT/scripts/ports.sh"

steps=0
failures=0
PIDS=()
SERVER_PID=""
NEXT_FD=10

pass() {
    steps=$((steps + 1))
    printf 'PASS  %s\n' "$1"
}
fail() {
    steps=$((steps + 1))
    failures=$((failures + 1))
    printf 'FAIL  %s\n      %s\n' "$1" "${2:-}"
}
info() { printf '      %s\n' "$1"; }
step() {
    echo
    echo "== $*"
}

# Each rc-node is reaped with `wait` right after its own signal, so the shell never
# reports the job as having terminated abnormally in the middle of the output.
stop_nodes() {
    for pid in "${PIDS[@]:-}"; do
        [[ -n "$pid" ]] || continue
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    PIDS=()
}

trap 'stop_nodes
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    if [[ "${RC_KEEP_LOGS:-0}" == "1" ]]; then echo "logs kept in $WORK"; else rm -rf "$WORK"; fi' EXIT

for arg in "$@"; do
    case "$arg" in
        --skip-ssm) SKIP_SSM=1 ;;
        -h | --help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $arg" >&2
            exit 2
            ;;
    esac
done

wait_for() { # wait_for <file> <pattern> [timeout] [start-line]
    local file="$1" pattern="$2" timeout="${3:-25}" from="${4:-1}" deadline
    deadline=$(($(date +%s) + timeout))
    while [[ $(date +%s) -lt $deadline ]]; do
        if tail -n "+$from" "$file" 2>/dev/null | grep -q -- "$pattern"; then return 0; fi
        sleep 0.2
    done
    return 1
}

lines_in() { wc -l <"$1" 2>/dev/null | tr -d ' '; }

field() { # field <file> <event> <key> [start-line] -> LAST match
    python3 - "$1" "$2" "$3" "${4:-1}" <<'PY'
import json, sys
path, event, key, start = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
found = ""
for n, line in enumerate(open(path), 1):
    if n < start: continue
    line = line.strip()
    if not line.startswith('{'): continue
    try: d = json.loads(line)
    except Exception: continue
    if d.get("event") == event and key in d:
        found = d[key]
print(found)
PY
}

start_node() { # start_node <name> <role> [env assignments...]
    local name="$1" role="$2"
    shift 2
    local envs=("$@")
    mkdir -p "$WORK/id-$name"
    mkfifo "$WORK/$name.in"
    env RC_ROLE="$role" RC_IDENTITY_DIR="$WORK/id-$name" \
        SKIPPER_API_BASE_URL="$API_BASE_URL" \
        RC_DEVICE_LABEL="rc-relay-$name" ${envs[@]+"${envs[@]}"} \
        "$BIN" <"$WORK/$name.in" >"$WORK/$name.log" 2>&1 &
    PIDS+=("$!")
    eval "exec ${NEXT_FD}> \"$WORK/$name.in\""
    eval "FD_${name}=${NEXT_FD}"
    NEXT_FD=$((NEXT_FD + 1))
}

say() {
    local name="$1"
    shift
    local fdvar="FD_${name}"
    echo "$*" >&"${!fdvar}"
}

# ---------------------------------------------------------------------------
step "building rc-node and rc-signal"
if ! (cd "$APP_DIR" && swift build --product rc-node >"$WORK/build.log" 2>&1); then
    fail "rc-node builds" "see $WORK/build.log"
    exit 1
fi
[[ -x "$BIN" ]] || {
    fail "rc-node builds" "no binary at $BIN"
    exit 1
}
if ! (cd "$SERVER_DIR" && go build -o "$WORK/rc-signal" ./cmd/rc-signal >>"$WORK/build.log" 2>&1); then
    fail "rc-signal builds" "see $WORK/build.log"
    exit 1
fi
info "rc-node (debug, development hooks compiled in) and rc-signal"

# ---------------------------------------------------------------------------
step "starting a local rc-signal that mints no TURN credentials"
PORT="${RC_RELAY_PORT:-0}"
if [[ "$PORT" == "0" ]]; then PORT="$(any_free_port)"; fi
require_port_free "$PORT" "set RC_RELAY_PORT to a free port" || exit 1
API_BASE_URL="http://127.0.0.1:$PORT"

if ! (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
    -out "$WORK/id-cert-key.pem" 2>/dev/null); then
    fail "a throwaway device-id certificate key is generated" "openssl failed"
    exit 1
fi

# -entitlement static allows any host, so no account and no sign-in is involved; and
# no -turn-secret-file means rc-signal cannot mint a TURN entry at all. Section A
# must therefore go peer-to-peer, and section B's relay-only has nothing but the
# dead TURN URL the node is given directly.
"$WORK/rc-signal" \
    -insecure-http \
    -listen "127.0.0.1:$PORT" \
    -entitlement static \
    -db "$WORK/relay.db" \
    -claims-db "$WORK/relay-claims.db" \
    -id-cert-key-file "$WORK/id-cert-key.pem" \
    -register-per-ip-hour 1000 \
    -connect-per-ip-min 1000 \
    -log-level warn \
    >"$WORK/server.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 100); do
    if curl -fsS "$API_BASE_URL/healthz" >/dev/null 2>&1; then
        ready=1
        break
    fi
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then break; fi
    sleep 0.1
done
if [[ "$ready" -ne 1 ]]; then
    fail "the local rc-signal becomes healthy" "$(tail -5 "$WORK/server.log")"
    exit 1
fi
still_running "$SERVER_PID" "the rc-signal this script started" || exit 1
pass "rc-signal is healthy on 127.0.0.1:$PORT with no TURN secret"

# ---------------------------------------------------------------------------
step "A. the path media took is observed, and it is not the relay"
start_node host host RC_CAPTURE_SOURCE=synthetic
if ! wait_for "$WORK/host.log" '"event":"hello_ok"' 30; then
    fail "the host authenticates" "$(tail -5 "$WORK/host.log")"
    exit 1
fi
HOST_ID="$(field "$WORK/host.log" hello_ok deviceId)"
HOST_CODE="$(field "$WORK/host.log" ready accessCode)"
start_node ctrl controller
if ! wait_for "$WORK/ctrl.log" '"event":"hello_ok"' 30; then
    fail "the controller authenticates" "$(tail -5 "$WORK/ctrl.log")"
    exit 1
fi
pass "two real instances authenticated as separate devices"

say ctrl "connect $HOST_ID $HOST_CODE"
if ! wait_for "$WORK/ctrl.log" '"event":"ice","role":"controller","state":"connected"' 60; then
    fail "an unforced session reaches ICE connected" "$(grep '"event":"ice"' "$WORK/ctrl.log" | tail -3)"
    exit 1
fi
pass "an unforced session reached ICE connected"

if grep -q '"event":"ice_servers"' "$WORK/ctrl.log"; then
    if grep -q '"event":"ice_servers".*"turn":true' "$WORK/ctrl.log"; then
        fail "a server with no TURN secret mints no TURN entry" \
            "$(grep '"event":"ice_servers"' "$WORK/ctrl.log" | tail -1)"
    else
        pass "the ice_servers push arrived carrying no TURN entry, as a server with no secret must"
    fi
else
    info "no ice_servers push (this server mints none); the session is unmetered"
fi

sleep "$SAMPLE_SECONDS"
MARK_C=$(($(lines_in "$WORK/ctrl.log") + 1))
MARK_H=$(($(lines_in "$WORK/host.log") + 1))
say ctrl ice-path
say host ice-path
wait_for "$WORK/ctrl.log" '"event":"ice_path"' 15 "$MARK_C" || fail "the controller answers ice-path" ""
wait_for "$WORK/host.log" '"event":"ice_path"' 15 "$MARK_H" || fail "the host answers ice-path" ""

C_LOCAL="$(field "$WORK/ctrl.log" ice_path local "$MARK_C")"
C_REMOTE="$(field "$WORK/ctrl.log" ice_path remote "$MARK_C")"
C_RELAY="$(field "$WORK/ctrl.log" ice_path usesRelay "$MARK_C")"
C_RX="$(field "$WORK/ctrl.log" ice_path bytesReceived "$MARK_C")"
H_LOCAL="$(field "$WORK/host.log" ice_path local "$MARK_H")"
H_TX="$(field "$WORK/host.log" ice_path bytesSent "$MARK_H")"
: "${C_RX:=0}" "${H_TX:=0}"

if [[ -n "$C_LOCAL" && -n "$C_REMOTE" ]]; then
    pass "the controller reports the selected candidate pair: local=$C_LOCAL remote=$C_REMOTE"
else
    fail "the selected candidate pair is reported" "$(grep '"event":"ice_path"' "$WORK/ctrl.log" | tail -1)"
fi
if [[ -n "$H_LOCAL" ]]; then
    pass "the host reports the selected candidate pair too: local=$H_LOCAL"
else
    fail "the host reports a selected candidate pair" "$(grep '"event":"ice_path"' "$WORK/host.log" | tail -1)"
fi
if [[ "$C_RELAY" == "False" || "$C_RELAY" == "false" ]]; then
    pass "that pair is NOT relayed, so the observation distinguishes the two routes"
else
    fail "an unforced loopback session is not relayed" "usesRelay=$C_RELAY, and this server has no TURN"
fi
if [[ "$C_RX" -gt 0 && "$H_TX" -gt 0 ]]; then
    pass "bytes moved on that pair (host sent $H_TX, controller received $C_RX)"
else
    fail "bytes moved on the selected pair" "host bytesSent=$H_TX, controller bytesReceived=$C_RX"
fi
stop_nodes

# ---------------------------------------------------------------------------
step "B. relay-only really excludes every other route"
# Two fresh instances against the same server, the only change being the policy. This
# rc-signal holds no TURN secret, so it mints no TURN entry and a relay-only peer
# connection has no candidate of any kind. If this still connects, relay-only is not
# in force and no forced-relay proof anywhere could be trusted.
start_node rhost host RC_CAPTURE_SOURCE=synthetic RC_ICE_POLICY=relay
if ! wait_for "$WORK/rhost.log" '"event":"hello_ok"' 30; then
    fail "the relay-only host authenticates" "$(tail -5 "$WORK/rhost.log")"
    exit 1
fi
RHOST_ID="$(field "$WORK/rhost.log" hello_ok deviceId)"
RHOST_CODE="$(field "$WORK/rhost.log" ready accessCode)"
start_node rctrl controller RC_ICE_POLICY=relay
if ! wait_for "$WORK/rctrl.log" '"event":"hello_ok"' 30; then
    fail "the relay-only controller authenticates" "$(tail -5 "$WORK/rctrl.log")"
    exit 1
fi
MARK=$(($(lines_in "$WORK/rhost.log") + 1))
say rhost status
wait_for "$WORK/rhost.log" '"event":"status"' 15 "$MARK" || fail "the host answers status" ""
RELAY_ONLY="$(field "$WORK/rhost.log" status relayOnly "$MARK")"
if [[ "$RELAY_ONLY" == "True" || "$RELAY_ONLY" == "true" ]]; then
    pass "RC_ICE_POLICY=relay reached RCConfig.forceTURNRelay: the host is relay-only"
else
    fail "RC_ICE_POLICY=relay puts the host in relay-only mode" "relayOnly=$RELAY_ONLY"
fi

say rctrl "connect $RHOST_ID $RHOST_CODE"
info "waiting ${RELAY_FAIL_SECONDS}s; this server mints no TURN entry, so relay-only has no candidate"
if wait_for "$WORK/rctrl.log" '"event":"ice","role":"controller","state":"connected"' "$RELAY_FAIL_SECONDS"; then
    fail "relay-only must NOT connect when no TURN server can allocate" \
        "it reached ICE connected anyway, so host/srflx candidates were not excluded"
else
    pass "relay-only did not connect: with no usable TURN there is no candidate at all"
fi

MARK=$(($(lines_in "$WORK/rctrl.log") + 1))
say rctrl ice-path
sleep 2
R_SELECTED="$(field "$WORK/rctrl.log" ice_path selected "$MARK")"
R_LOCAL="$(field "$WORK/rctrl.log" ice_path local "$MARK")"
if [[ -z "$R_LOCAL" && ("$R_SELECTED" == "False" || "$R_SELECTED" == "false") ]]; then
    pass "and it reports no selected candidate pair, rather than inventing one"
else
    fail "relay-only with no TURN reports no selected pair" "selected=$R_SELECTED local=$R_LOCAL"
fi
stop_nodes

# ---------------------------------------------------------------------------
step "C. the live relay, read-only: what it can and cannot corroborate"
if [[ "$SKIP_SSM" -eq 1 ]]; then
    info "skip  --skip-ssm"
else
    probe="$WORK/probe.sh"
    cat >"$probe" <<'BOX'
echo "coturn-active=$(systemctl is-active coturn 2>/dev/null)"
echo "deny-any-ipv6-line=$(sudo grep -c '^denied-peer-ip=::$' /etc/turnserver.conf 2>/dev/null || echo unknown)"
echo "verbose=$(sudo grep -cE '^[[:space:]]*verbose' /etc/turnserver.conf 2>/dev/null || echo unknown)"
echo "no-cli=$(sudo grep -cE '^[[:space:]]*no-cli' /etc/turnserver.conf 2>/dev/null || echo unknown)"
echo "prometheus=$(sudo grep -cE '^[[:space:]]*prometheus' /etc/turnserver.conf 2>/dev/null || echo unknown)"
echo "allocation-log-lines=$(sudo grep -cE 'usage:|rb=|sb=|allocat' /var/log/turnserver/turnserver.log 2>/dev/null || echo unknown)"
BOX
    params=$(python3 -c 'import json,sys; print(json.dumps({"commands":[open(sys.argv[1]).read()]}))' "$probe")
    cmd_id=$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
        --timeout-seconds 300 --parameters "$params" --query Command.CommandId --output text 2>/dev/null)
    if [[ -z "$cmd_id" ]]; then
        fail "the live relay can be asked over SSM" "send-command failed; is the $AWS_PROFILE profile signed in?"
    else
        status=InProgress
        for _ in $(seq 1 60); do
            sleep 3
            status=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
                --query Status --output text 2>/dev/null || echo Pending)
            case "$status" in InProgress | Pending | Delayed) ;; *) break ;; esac
        done
        out=$(aws ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE" \
            --query StandardOutputContent --output text 2>/dev/null)
        printf '%s\n' "$out" >"$WORK/box.out"
        said() { grep -qx "$1" "$WORK/box.out"; }

        if said "coturn-active=active"; then
            pass "coturn is running on $TURN_HOST"
        else
            fail "coturn is running" "$(grep '^coturn-active=' "$WORK/box.out")"
        fi
        if said "deny-any-ipv6-line=0"; then
            pass "the deployed config has no bare 'denied-peer-ip=::' (the PHASE5 §8.1 regression)"
        else
            fail "the deployed config has no bare 'denied-peer-ip=::'" \
                "$(grep '^deny-any-ipv6-line=' "$WORK/box.out") -- coturn 4.6.1 matches it against every IPv4 peer"
        fi
        if said "verbose=0" && said "no-cli=1" && said "allocation-log-lines=0"; then
            info "coturn logs no allocation and no byte counters: simple-log, no 'verbose', 'no-cli' set,"
            info "no prometheus. The relay side therefore cannot corroborate any session's bytes."
            info "This is a deploy-side gap, recorded in docs/PHASE5.md §8.2. Not a failure of this gate."
        else
            info "coturn observability: $(tr '\n' ' ' <"$WORK/box.out")"
        fi
    fi
fi

# ---------------------------------------------------------------------------
echo
if [[ "$failures" -eq 0 ]]; then
    echo "RELAY SCAFFOLDING VERIFIED — $steps checks, 0 failures"
    echo "This proves the forced-relay switch is real and the route is observable."
    echo "It does NOT prove media over the live relay: see docs/VERIFY.md."
    exit 0
fi
echo "RELAY SCAFFOLDING FAILED — $steps checks, $failures failures"
exit 1
