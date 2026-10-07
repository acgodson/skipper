# infra/aws — the Phase 5 backend, Shape A

Terraform for the deployment `docs/PHASE5.md` §2(a) chose: one VPC, one public subnet, one
`t4g.small` behind an Elastic IP, Caddy terminating TLS in front of `rc-api` and `rc-signal`
on loopback, coturn on the same box. One region, one availability zone, no redundancy.

Nothing here provisions on its own and nothing here is applied yet.

## What it creates

| Where | What |
|---|---|
| `terraform/network.tf` | VPC, one public subnet, internet gateway, route table, the security group, the Elastic IP and its association |
| `terraform/instance.tf` | The `t4g.small`, its encrypted gp3 root volume, IMDSv2-only metadata, the user data, and the instance's configuration files as S3 objects |
| `terraform/iam.tf` | The instance role: `AmazonSSMManagedInstanceCore`, its own SSM parameters, `kms:Sign` on one key, its own three S3 prefixes, its own log group, one metric namespace |
| `terraform/kms.tf` | The `ECC_NIST_P256` / `SIGN_VERIFY` key for the device-ID certificate signer, with a key policy that lets only the instance role sign |
| `terraform/ssm.tf` | Eleven `SecureString` parameters, created holding a placeholder |
| `terraform/cognito.tf` | The user pool (email sign-in), the public app client with no secret and no hosted-UI domain, and the Apple and Google providers |
| `terraform/backups.tf` | The backup bucket: versioned, SSE-S3, public access blocked, TLS-only, four lifecycle rules |
| `terraform/observability.tf` | The 30-day log group, the SNS topic, and the five alarms |
| `cloud-init/` | The bootstrap the instance runs, the backup script, the CloudWatch agent configuration |
| `systemd/` | `rc-api.service`, `rc-signal.service`, the two backup timers, and drop-ins over the `caddy` and `coturn` units Ubuntu ships |
| `Caddyfile` | TLS over HTTP-01, the reverse proxies, and the `X-Forwarded-For` rule |
| `coturn/turnserver.conf` | `use-auth-secret`, the relay range, and the peer deny list |
| `deploy.sh` | Builds both binaries for `linux/arm64`, uploads, swaps, restarts, verifies |

The security group's whole inbound surface is `80/tcp`, `443/tcp`, `3478/tcp`, `3478/udp` and
`49160-49200/udp`. There is no SSH rule: a shell comes from `aws ssm start-session`, which
the instance reaches over its own outbound connection.

### DNS is not ours

`skipperdesk.app` is registered elsewhere and its nameservers stay there. This stack creates
no hosted zone and no record. `terraform output dns_records_to_create` prints the two `A`
records the owner adds by hand. Caddy therefore validates over **HTTP-01** — the stock binary
has no DNS provider module compiled in, and the `acme` issuer here also disables the
TLS-ALPN challenge, so HTTP-01 is the only path. That is why `80/tcp` is open.

## Order to run it

1. The owner finishes `docs/PHASE5.md` §4 steps 1–7. The CLI profile must resolve to the new
   account; `deploy.sh` refuses to run without `--profile` and refuses the two profiles that
   belong to other accounts (`scripts/aws-profile-guard.sh`).
2. `cp terraform/terraform.tfvars.example terraform/terraform.tfvars` and set `acme_email`
   and `alarm_email`. Leave `enable_social_idp` and `enable_endpoint_health_check` off.
3. `cd terraform && terraform init && terraform plan -out=tfplan` — read the plan.
4. `terraform apply tfplan`.
5. Write the real secrets into the parameters created in step 4 (below), then
   `aws ssm send-command` the bootstrap again, or simply reboot, so the files are rewritten.
6. Add the two `A` records at the registrar from `terraform output dns_records_to_create`.
7. `./deploy.sh --profile <profile>` from the repository root's `infra/aws`.
8. Set `enable_endpoint_health_check = true` and apply again; the Route 53 health check needs
   the records from step 6 to exist.
9. Confirm the alarm subscription e-mail.

## Variables

Every id is a variable or a lookup; nothing is hardcoded. `terraform/variables.tf` is the
list, with a description on each. The ones worth setting deliberately:

| Variable | Default | Why you would change it |
|---|---|---|
| `aws_region` | `eu-west-2` | `docs/PHASE5.md` §0 settles this |
| `acme_email` | — | Required; Let's Encrypt sends expiry warnings there |
| `alarm_email` | `""` | Empty means the alarms have nowhere to go |
| `api_domain`, `turn_domain` | `api.`/`turn.skipperdesk.app` | A staging name |
| `instance_type` | `t4g.small` | coturn's CPU and packet rate is what gives first |
| `root_volume_gb` | `20` | Both SQLite files live here |
| `turn_user_quota`, `turn_total_quota` | `12`, `200` | `docs/PHASE5.md` §7: the 1:1 values were 6 and 12 |
| `enable_social_idp` | `false` | See "Secrets" |
| `enable_endpoint_health_check` | `false` | Needs the `A` records first |
| `monthly_budget_usd` | `50` | The alarm that protects the owner |

The AMI is not a variable but a lookup: `ami_ssm_parameter` names a public SSM parameter that
resolves to the current Ubuntu 24.04 arm64 image. `aws_instance.app` ignores later changes to
it, so a new Canonical image does not replace the box behind your back.

## Secrets

Every secret lives in SSM Parameter Store as a `SecureString` under
`terraform output ssm_parameter_prefix` (`/skipperdesk/prod` by default). Terraform creates
each parameter holding the literal `placeholder-set-out-of-band` and then
`ignore_changes = [value]`, so it never generates a secret and never overwrites yours. The
bootstrap refuses to continue while any parameter it reads still holds that placeholder, so a
box can never come up serving with a TURN secret and a hardware salt that are a public
string:

```
aws ssm put-parameter --profile <p> --region eu-west-2 --overwrite \
  --type SecureString --name /skipperdesk/prod/<name> --value "<value>"
```

| Parameter | How the process receives it | Flag or variable |
|---|---|---|
| `turn-secret` | file `0600`, owned by the service user | `-turn-secret-file` |
| `internal-token` | file `0600`, owned by the service user | `-internal-token-file`, both services |
| `id-cert-key` | file `0600`, owned by the service user | `-id-cert-key-file` |
| `hardware-salt` | `EnvironmentFile`, `0600`, root-owned | `RC_API_HARDWARE_SALT` |
| `token-secret` | `EnvironmentFile`, `0600`, root-owned | `RC_TOKEN_SECRET` |
| `apple-services-id`, `apple-team-id`, `apple-key-id`, `apple-private-key` | Terraform, into the Cognito provider | — |
| `google-client-id`, `google-client-secret` | Terraform, into the Cognito provider | — |

No secret reaches either binary on the command line. The command line is readable by every
local user through `ps`, which is why the deprecated `-internal-token` flag is never used and
why `deploy.sh` asserts both units are free of it. `coturn` is the one exception in spirit: it
reads `static-auth-secret` only from its configuration file, so cloud-init appends the value
to `/etc/turnserver.conf` and leaves that file `0640 root:turnserver`. It is still a file, not
a flag.

The two `EnvironmentFile`s are root-owned rather than service-user-owned on purpose: systemd
reads them as root before it drops privileges, so the service user never needs to.

**Where Terraform cannot avoid holding a secret.** `aws_cognito_identity_provider` takes the
Apple `.p8` key and the Google client secret as literal arguments, so creating those two
providers makes Terraform read the parameters and write them into state. There is no way
around it in the provider. Consequences, plainly:

- `enable_social_idp` is `false` by default, so a first apply holds no secret at all.
- The moment it is turned on, `terraform.tfstate` is as sensitive as the secrets themselves.
  Treat it that way: it is gitignored here, and the move to an encrypted S3 backend below is
  what makes it tolerable long-term.
- Rotating either secret means rotating the parameter *and* re-applying.

## State

Local, deliberately, for now — one operator, no locking to coordinate. It cannot stay that
way: local state cannot be locked, cannot be read by a second person, and a lost laptop loses
the only record of what exists. The `TODO:` is in `terraform/versions.tf`. The move is a
versioned, SSE-KMS S3 bucket plus a DynamoDB table for the lock, created in a tiny separate
root module (it cannot create the bucket it stores itself in), then
`terraform init -migrate-state`. Do it the day a second person can deploy.

## The trusted proxy, and why `X-Forwarded-For` is safe here

`PROTOCOL.md` §3.3 and `API.md` §8 bucket by client address. Get it wrong one way and every
client lands in one bucket keyed on Caddy; get it wrong the other way and any client sets its
own address and evades every per-IP limit.

Both Go processes run with `-trusted-proxies 127.0.0.1/32`, and the only header they honour is
`X-Forwarded-For` (`protocol/api.go`, `server/internal/clientip`). That is safe for exactly
one reason: the Caddyfile **overwrites** the header rather than appending to it —
`header_up X-Forwarded-For {remote_host}` — so whatever a client sent is discarded and the
value the Go processes read is the TCP peer Caddy saw. Caddy itself trusts no upstream proxy,
because there is none; if an ALB or a CDN is ever put in front of this box, the Caddyfile and
these two flags both have to change in the same commit.

The loopback half matters too. Caddy and the two services share a machine, so `127.0.0.1` is
the only address that can present that header, and the public listeners are bound to loopback
so nothing else can reach them. Behind anything other than a same-host proxy,
`127.0.0.1/32` would be wrong.

## Redeploying

```
./deploy.sh --profile <profile>
```

It builds `rc-api` and `rc-signal` for `linux/arm64` with `CGO_ENABLED=0` (SQLite here is
`modernc.org/sqlite`, pure Go, so there is nothing to cross-compile), asserts the units carry
`-idp cognito` and no `-internal-token` flag, uploads a tarball to `releases/`, and runs the
swap as an SSM command: verify the sha256, unpack into `/opt/skipperdesk/releases/<stamp>`,
install into `/opt/skipperdesk/bin`, restart both units, wait for `/healthz` on loopback.
Then it checks `https://<api domain>/v1/health` from your machine.

A redeploy drops live WebSockets. Sessions survive it — `PROTOCOL.md` §4.1 resume — but the
socket reconnects. coturn is not restarted; it only needs one when its configuration changes,
and a restart kills live relays, so check `GET /internal/sessions/live` first.

Rolling back is the previous directory under `/opt/skipperdesk/releases`:

```
aws ssm start-session --profile <p> --target "$(cd terraform && terraform output -raw instance_id)"
sudo install -m 0755 /opt/skipperdesk/releases/<stamp>/rc-api /opt/skipperdesk/bin/rc-api
sudo install -m 0755 /opt/skipperdesk/releases/<stamp>/rc-signal /opt/skipperdesk/bin/rc-signal
sudo systemctl restart rc-api rc-signal
```

### Changing the bootstrap

`aws_instance.app` has `user_data_replace_on_change = false`, because this box holds the only
copy of both SQLite files and a changed bootstrap must never silently replace it. After a
`terraform apply` that changes `cloud-init/` or any file under `systemd/`, `Caddyfile` or
`coturn/`, re-run the bootstrap deliberately:

```
aws ssm send-command --profile <p> --region eu-west-2 \
  --instance-ids "$(cd terraform && terraform output -raw instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init clean --logs && cloud-init init && cloud-init modules --mode=final"]'
```

## Backups, and restoring the claims database

`skipperdesk-backup@db.timer` snapshots `rc-api.db` every 15 minutes;
`skipperdesk-backup@claims.timer` snapshots `rc-api-claims.db` once a day. Both use
`sqlite3 .backup`, gzip, and `aws s3 cp` into two separate prefixes with two separate
lifecycle rules. `db/` transitions to Standard-IA and then expires; **`claims/` never
expires**, because losing a claim lets a Device ID be reissued to a second key
(`API.md` §6.1).

Restoring is deliberately asymmetric. The two databases are **never** restored together.

To restore the claims database alone — the newest copy is always a superset, because the
table only ever grows:

```
aws ssm start-session --profile <p> --target <instance id>
sudo systemctl stop rc-api rc-signal
NEWEST=$(aws s3 ls s3://<bucket>/claims/ | sort | tail -1 | awk '{print $4}')
aws s3 cp "s3://<bucket>/claims/$NEWEST" /tmp/claims.gz
gunzip -c /tmp/claims.gz | sudo tee /var/lib/skipperdesk/rc-api-claims.db >/dev/null
sudo chown skipperdesk:skipperdesk /var/lib/skipperdesk/rc-api-claims.db
sudo chmod 0600 /var/lib/skipperdesk/rc-api-claims.db
sudo systemctl start rc-api rc-signal
```

Restoring `rc-api.db` from an older snapshot is safe **only if the claims file is left
alone**. Devices then re-register with their certificates and get their own ids back, and
nobody else can obtain them. Wiping both together is the one unrecoverable operation in this
system.

The root volume has `delete_on_termination = false`, so terminating the instance leaves the
volume behind rather than the databases with it. Delete the orphan once a restore is proven.

## Alarms

| Alarm | Metric | Where it comes from |
|---|---|---|
| `-api-5xx` | log metric filter `{ $.msg = "request" && $.status >= 500 }` | rc-api logs one JSON object per request with its status |
| `-signal-healthz` | `AWS/Route53 HealthCheckStatus` | A health check probes `https://<api domain>/signal/healthz`, which Caddy rewrites to rc-signal's `/healthz`. The alarm lives in `us-east-1` because that is the only region those metrics exist in |
| `-host-unreachable` | `AWS/EC2 StatusCheckFailed` | coturn has no probeable endpoint; the relay is down whenever the host is |
| `-disk-used` | `disk_used_percent` from the CloudWatch agent | Its dimensions include the filesystem type, which is why `root_filesystem_type` is a variable |
| budget | AWS Budgets, actual at 80% and forecast at 100% | `docs/PHASE5.md` §4 step 3 also sets one in the management account; this one is scoped to this account and is in code |

The CloudWatch agent is configured to read exactly three files —
`/var/log/skipperdesk/{rc-api,rc-signal,backup}.log` — and one disk metric. It is not a
general log scraper, and nothing is added that could capture a request or WebSocket body
(`API.md` §9, `PROTOCOL.md` §8). Caddy's access log is switched off for the same reason.

## Caddy

`caddy` and `coturn` both come from the distribution's own archive, so no third-party apt
repository is added. If a future image drops the `caddy` package, the bootstrap fails loudly
rather than silently; the replacement is the official static `linux/arm64` release, verified
against its published checksum, plus a unit of our own — and it becomes a named dependency in
the PR that does it.

## What is deliberately not here yet

- **Done:** the id-cert key is now used — `rc-api` signs through `-id-cert-kms-key-id` and no PEM reaches the volume.
- **No key rotation.** KMS cannot rotate an asymmetric key, and the contract has no verifier
  that accepts two signing keys at once. The `TODO:` is in `terraform/kms.tf`.
- **No DynamoDB claims table.** `API.md` §6.1 and `docs/PHASE5.md` §2 both say the claims
  database moves to DynamoDB with point-in-time recovery and deletion protection, early and on
  its own. It has not moved; it is a file on the gp3 volume with its own backup schedule.
- **No remote state.** See "State".
- **No mTLS on the internal listeners.** They are loopback plain HTTP with a bearer, which is
  what `API.md` §6 specifies for a single box. The `TODO:` there comes due with Shape B.
- **No second instance, no second AZ, no load balancer, no zero-downtime deploy.** That is
  Shape B, and `docs/PHASE5.md` §2 lists the four conditions that trigger it.
- **No shared rate-limit store.** The buckets are in-process and correct for one instance
  only (`PROTOCOL.md` §3.3). A second instance makes them wrong, which is a blocker for
  Shape B rather than a nice-to-have.
- **No EBS snapshot schedule.** `docs/PHASE5.md` §1 also asks for a daily EBS snapshot
  alongside the S3 `sqlite3 .backup` copies. Only the S3 half is here; a Data Lifecycle
  Manager policy is the missing piece and is free apart from snapshot storage.
- **No payment path.** `API.md` §7.4.
- **No `turn.skipperdesk.app` TLS.** `tls-listening-port=0`: TURN here is plain `3478`
  udp and tcp. TURNS would need Caddy's certificate handed to coturn, which is new surface.

## Costs

`docs/PHASE5.md` §3.2 computes the whole bill. The fixed part of this stack is the
`t4g.small`, the public IPv4 address, the 20 GB gp3 volume, the KMS key, the alarms, the log
group and the bucket — about **$22/month** before any relay egress, which is the term that
actually grows.
