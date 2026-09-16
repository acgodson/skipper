FROZEN legacy deployment — see docs/SCOPE.md §8. No changes.

# infra — rc-signal + coturn on the shared t2.medium

## Hard isolation rule

This instance also runs a **production service** (`gptc-api`). Read this before touching anything.

- Instance `i-0268c831a241111fe`, region `eu-west-1`, account `219702648416`, AWS profile
  `godson` (IAM user). Reached **only via SSM** — no SSH.
- Our entire world is `/opt/rc-signal`, Docker Compose project `rc`
  (containers `rc-signal`, `rc-coturn`).
- **Never** touch `/opt/gptc`, `gptc-api-1` / `gptc-cloudflared-1`, their images, their compose
  file, or port 8001.
- **Never** run `docker system/volume prune`, `docker image prune -a`, or `docker compose` outside
  `/opt/rc-signal`. Never restart dockerd, edit `/etc/docker/daemon.json`, or reboot.
- Every deploy runs `preflight.sh` before and after, and fails loudly if gptc changed.
  `scripts/_ssm.sh` enforces this: `ssm_run` refuses gptc/prune/restart/reboot commands, and
  `ssm_run_ro` refuses anything that mutates.

## The box

| | |
|---|---|
| OS / size | Ubuntu 24.04, t2.medium, 2 vCPU, 3.9 GB RAM, 29 GB disk |
| Public IP | `54.246.73.81` — **dynamic, no Elastic IP** (deliberate) |
| Security group | `sg-03d49848dcbe73f40` (`gptc-prod-api-sg`). Inbound rules are ours alone: `8443/tcp`, `3478/tcp+udp`, `49160-49200/udp`. gptc has no inbound dependency (it egresses via a cloudflared tunnel) |
| No domain | TLS is a self-signed P-256 cert (SAN = IP, expires 2036-08-16), pinned in the app |

Ad-hoc command pattern (read-only examples — prefer the scripts):

```sh
CID=$(aws ssm send-command --instance-ids i-0268c831a241111fe --region eu-west-1 \
  --profile godson --document-name AWS-RunShellScript \
  --parameters 'commands=["docker ps"]' --query Command.CommandId --output text) \
&& sleep 10 && aws ssm get-command-invocation --command-id "$CID" \
  --instance-id i-0268c831a241111fe --region eu-west-1 --profile godson \
  --query StandardOutputContent --output text
```

## What runs

| | |
|---|---|
| `rc-signal` | `wss://54.246.73.81:8443/ws`, `/healthz`. 256 MB / 0.3 CPU. DB at `/opt/rc-signal/data/rc.db` |
| `rc-coturn` | `coturn/coturn:4.6-alpine`, host networking, `3478` udp+tcp, relay `49160-49200/udp`. 512 MB / 0.5 CPU |
| Cert pin | `E30xoxEp9t658+TJEVdaGb8Ooi7HGGMWp1kxVpeSpgk=` (SHA-256 of the DER cert; compiled into `Config.swift`) |
| `.env` | `RC_TURN_SECRET`, `RC_TURN_URLS` (`RC_TOKEN_SECRET` unset → tokens reset on restart) |

**TURN is not a proxy.** `turnserver.conf` denies RFC1918, loopback, link-local and reserved peers,
and disables TCP relay and multicast. Quotas are by allocation count (`user-quota=6`,
`total-quota=12`). Bandwidth quotas were removed because they broke allocation (error 486).

## Runbook

```sh
./scripts/preflight.sh          # snapshot + assert gptc healthy (read-only) -> .baseline.txt
./scripts/aws-setup.sh          # SG rules (+ optional EIP prompt). Additive, idempotent
./scripts/gen-cert.sh <IP>      # self-signed cert, prints the app pin
./scripts/deploy.sh             # tar over SSM -> /opt/rc-signal, build, compose up, assert /healthz + restarts
./scripts/preflight.sh --verify # gptc must match the snapshot exactly
go run ./cmd/smokeclient -addr 54.246.73.81:8443 -tls   # from server/: live 28-step protocol check
```

**If the public IP ever changes** (the instance was stopped):
```sh
IP=<new ip>
./scripts/gen-cert.sh "$IP"                       # the cert SAN is bound to the IP
sed -i '' "s|54\.246\.73\.81|$IP|g" .env          # TURN URLs
./scripts/deploy.sh
# then update Config.swift (URL + pin) and rebuild/reinstall BOTH Macs
```

## Live state (checked 2026-09-16)

- Instance running since 2026-07-14; the IP is unchanged. Load is about 0.1, with about 2.7 GB RAM free.
- `rc-signal` has been up since 2026-08-26 (0 restarts, about 61 MB). `rc-coturn` has been up since 2026-08-23 (about 19 MB).
  gptc is healthy.
- `/healthz` returns `ok`, and hosts are authenticating. **However, Docker reports `rc-signal` as
  `unhealthy`** (a failing streak of more than 55k checks). The healthcheck's busybox `wget` fails with
  `fork: Resource temporarily unavailable`, and each attempt logs a harmless `TLS handshake error ... EOF`
  every 30 s. Nothing acts on the health status (`restart: unless-stopped` ignores it), so the service
  works. The healthcheck itself is broken and needs a fix (for example a built-in `-healthcheck`
  flag in the Go binary, or a curl-less probe) at the next deploy.

## Deploy history

2026-08-19: first deploy. Fixed along the way:
- The Docker build context (see `replace` in `go.mod`).
- A healthcheck flag that didn't exist.
- uid-10001 ownership, which caused `SQLITE_CANTOPEN`.
- `deploy.sh` reporting success over a crash loop.
- coturn bandwidth quotas.

Verified at the time:
- 28/28 live smoke steps.
- The pin matched.
- TURN relayed 8/8 packets.
- gptc was byte-identical before and after.

The `rc-signal` container was last (re)started on 2026-08-26.
