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
| `terraform/data_volume.tf` | The separate encrypted gp3 volume the two SQLite files live on, and its attachment. `prevent_destroy` is on it |
| `terraform/bootstrap-state/` | A root module of its own, with local state: the state bucket, its KMS key and the DynamoDB lock table, and nothing else. Applied once, before the stack |
| `terraform/iam.tf` | The instance role: `AmazonSSMManagedInstanceCore`, its own SSM parameters, `kms:Sign` on one key, its own three S3 prefixes, its own log group, one metric namespace |
| `terraform/kms.tf` | The `ECC_NIST_P256` / `SIGN_VERIFY` key for the device-ID certificate signer, with a key policy that lets only the instance role sign |
| `terraform/ssm.tf` | Eleven `SecureString` parameters, created holding a placeholder |
| `terraform/cognito.tf` | The user pool (email sign-in), its free sign-in domain, the public app client with no secret, and the Apple and Google providers |
| `terraform/backups.tf` | The backup bucket and its four lifecycle rules |
| `terraform/audit.tf` | The audit bucket, the CloudTrail management-events trail, its CloudWatch Logs copy and delivery role, and the metric filter and alarm on `kms:Sign` against the id-cert key |
| `terraform/session_logging.tf` | The `SSM-SessionManagerRunShell` session preferences, the log group transcripts stream to, and that group's KMS key |
| `terraform/modules/hardened-bucket/` | The settings both buckets share — ACLs disabled, public access blocked, versioned, encrypted, TLS-only. Lifecycle rules and extra policy statements stay with the caller, because that is where the two differ |

The backup bucket moved into that module after this stack was written but **before** it was
ever applied, so there is nothing to migrate. If you are replaying these commits onto a state
file that already holds `aws_s3_bucket.backups`, do **not** apply: Terraform reads a moved
address as a destroy-and-create, and that bucket holds the `claims/` snapshots that must never
be lost. Move the six addresses first and then apply —

```
cd infra/aws/terraform
for r in aws_s3_bucket aws_s3_bucket_ownership_controls aws_s3_bucket_public_access_block \
         aws_s3_bucket_versioning aws_s3_bucket_server_side_encryption_configuration \
         aws_s3_bucket_policy; do
  terraform state mv "$r.backups" "module.backups.$r.this"
done
```

`aws_s3_bucket_lifecycle_configuration.backups` keeps its address and must not be moved.
| `terraform/observability.tf` | The 30-day log group, the SNS topic, and the seven alarms |
| `cloud-init/` | The bootstrap the instance runs, the backup script, the CloudWatch agent configuration |
| `systemd/` | `rc-api.service`, `rc-signal.service`, the two backup timers, a drop-in over `rc-api` that makes the data mount a hard requirement, and drop-ins over the `caddy` and `coturn` units Ubuntu ships |
| `Caddyfile` | TLS over HTTP-01, the reverse proxies, and the `X-Forwarded-For` rule |
| `coturn/turnserver.conf` | `use-auth-secret`, the relay range, and the peer deny list |
| `deploy.sh` | Builds both binaries for `linux/arm64`, uploads, swaps, restarts, verifies |

The security group's whole inbound surface is `80/tcp`, `443/tcp`, `3478/tcp`, `3478/udp` and
`49160-49200/udp`. There is no SSH rule: a shell comes from `aws ssm start-session`, which
the instance reaches over its own outbound connection. That makes Session Manager the entire
administrative path to the box, which is why every session is recorded — see "The audit
trail" below.

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
3. The state backend, once ever — see "State" for why it is a module of its own:

   ```
   cd terraform/bootstrap-state
   terraform init && terraform apply
   terraform output -raw backend_config > ../backend.hcl
   ```
4. `cd .. && terraform init -backend-config=backend.hcl`, then
   `terraform plan -out=tfplan` — read the plan — then `terraform apply tfplan`.
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
| `root_volume_gb` | `20` | The OS, the two binaries and the logs. No database |
| `data_volume_gb` | `20` | The volume both SQLite files live on. Growing it is a resize plus `resize2fs`, not a replacement |
| `turn_user_quota`, `turn_total_quota` | `12`, `200` | `docs/PHASE5.md` §7: the 1:1 values were 6 and 12 |
| `enable_social_idp` | `false` | See "Secrets" |
| `cognito_domain_prefix` | `""` (means `skipperdesk`) | The label must be unique across the region, so an apply that fails on it needs a different value, not a retry |
| `cognito_managed_login_version` | `1` | 2 is managed login, which renders from the branding designer and so needs an `aws_cognito_managed_login_branding` resource alongside it |
| `extra_cognito_callback_urls` | `[]` | A local origin while the sign-in page is being worked on |
| `enable_endpoint_health_check` | `false` | Needs the `A` records first |
| `monthly_budget_usd` | `50` | The alarm that protects the owner |
| `id_cert_sign_threshold` | `60` | Sized on fleet size, not taste: roughly 6 × expected hosts. "The audit trail" has the arithmetic |
| `enable_session_log_cmk` | `true` | Off saves $1/month and drops the session log group to CloudWatch's own default encryption. It also flips `CloudWatchEncryptionEnabled`, which is the point of it being one variable |
| `session_idle_timeout_minutes` | `20` | How long an abandoned root shell stays open |
| `cloudtrail_multi_region` | `true` | Off records only `aws_region`. The free copy covers either |

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
| `hardware-salt` | `EnvironmentFile`, `0600`, root-owned | `RC_API_HARDWARE_SALT` |
| `token-secret` | `EnvironmentFile`, `0600`, root-owned | `RC_TOKEN_SECRET` |
| `apple-services-id`, `apple-team-id`, `apple-key-id`, `apple-private-key` | Terraform, into the Cognito provider | — |
| `google-client-id`, `google-client-secret` | Terraform, into the Cognito provider | — |

### Reading a parameter takes two permissions, and each one is scoped on its own

`iam.tf` grants the instance role `ssm:GetParameter*` on `…:parameter/skipperdesk/prod/*`
and `kms:Decrypt` separately, because SSM does not decrypt a `SecureString` itself — it
calls KMS on the caller's behalf. Both halves are scoped to our prefix, and neither relies
on the other:

| Half | How it is bounded |
|---|---|
| `ssm:GetParameter`, `GetParameters`, `GetParametersByPath` | `Resource` is the parameter-ARN prefix |
| `kms:Decrypt` | `kms:ViaService = ssm.<region>.amazonaws.com`, **and** `StringLike` on `kms:EncryptionContext:PARAMETER_ARN` matching the same prefix |

The `Resource` on the `kms:Decrypt` statement has to stay `*`. These are standard-tier
`SecureString`s under the account's AWS-managed `alias/aws/ssm` key, whose ARN carries a key
id this configuration never sees and cannot name without an API call. `kms:ViaService` alone
is the pattern usually shown for that key, and it is not enough: it says "only SSM may use
this role's credentials against KMS", which still covers **every** `SecureString` in the
region encrypted under that same account-wide key — that is, every parameter anyone in the
account creates. The encryption-context condition is what reduces it to ours.

**The verification.** This was checked against AWS's published behaviour before being relied
on, because a wrong guess here fails closed: the bootstrap could not read its secrets and the
first deploy would be an outage.

- Parameter Store supplies exactly one encryption-context pair, key `PARAMETER_ARN`, value
  the full parameter ARN, and the AWS KMS developer guide gives the format as
  `"PARAMETER_ARN":"arn:aws:ssm:<region-id>:<account-id>:parameter/<parameter-name>"`. A
  parameter in a hierarchy carries its path, documented with the worked example
  `arn:aws:ssm:us-east-2:111122223333:parameter/ReadableParameters/MyParameter` — so our
  `/skipperdesk/prod/turn-secret` resolves under the `…:parameter/skipperdesk/prod/*` pattern
  the policy matches, with the same single slash the `ssm:GetParameter` resource already uses.
- It is supplied on both operations, not just one: the guide's standard-tier workflow says
  `PutParameter` sends `Encrypt` "with the KMS key that you chose, and the Parameter Store
  encryption context", and a `GetParameter` with `WithDecryption` sends `Decrypt` "with the
  encrypted SecureString parameter value and the Parameter Store encryption context".
- `kms:EncryptionContext:context-key` is documented with condition type **String** and lists
  `Decrypt` among its API operations, and the guide states the operator is the author's
  choice — "the case sensitivity of the condition value is determined by the policy condition
  operator that you use" — linking to the IAM condition-operators reference, where
  `StringLike` is a string operator whose values "can include multi-character match wildcards
  (\*)". A prefix match is therefore expressible. The same page carries AWS's own example of
  this exact pairing, a scoped `ssm:GetParameter*` statement beside a `kms:Decrypt` statement
  conditioned on `kms:EncryptionContext:PARAMETER_ARN`.
- Two fail-open shapes are avoided deliberately. `StringLikeIfExists` would permit a `Decrypt`
  carrying **no** encryption context, which is the hole being closed. A set operator is worse
  and AWS rejects it outright: "Do not use a set operator with the
  `kms:EncryptionContext:context-key` condition key. If you create a policy statement with an
  `Allow` action, the `kms:EncryptionContext:context-key` condition key, and the
  `ForAllValues` set operator, the condition allows requests with no encryption context."

Because this worked, no customer-managed key was introduced. The alternative — our own CMK
for the `SecureString`s, `key_id` on each parameter and `kms:Decrypt` scoped to that key ARN —
would have reached the same place and cost **$1/month** more. It stays the fallback if a
future tier change makes the context unreliable; note that the advanced tier would also
require `kms:GenerateDataKey` on write, which nothing here has.

The device-id certificate signing key is **not** in this table, and that is the point. It is
the `ECC_NIST_P256` KMS key in `terraform/kms.tf`; `rc-api` is given its ARN with
`-id-cert-kms-key-id` and calls `kms:Sign`, so the private half never exists outside KMS and
there is no parameter, no file and nothing to rotate out of Parameter Store. The ARN is not a
secret — it is an identifier, and `kms.tf`'s key policy plus `iam.tf`'s `kms:Sign` statement
are what decide who may use it. Every signature is a CloudTrail event
(`docs/PHASE5.md` §1.2).

`rc-api.env` therefore also carries `AWS_REGION`, so the SDK does not have to ask IMDS where
it is on every start.

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
- The moment it is turned on, the state is as sensitive as the secrets themselves. That is
  why the state backend below exists and why it is set up *first*: the state lives in a
  versioned, SSE-KMS bucket with a customer-managed key, and no state file is written beside
  the configuration at all.
- Rotating either secret means rotating the parameter *and* re-applying.

## State

Remote, encrypted and locked, and that is true before the first apply rather than after it.
The reason is the paragraph above: `aws_cognito_identity_provider` takes the Apple `.p8` and
the Google client secret as literal arguments, so the state file is as sensitive as the
secrets in it the moment `enable_social_idp` goes on. Local state cannot be locked, cannot
be read by a second person, and a lost laptop loses the only record of what exists.

The bucket cannot be created by the configuration that uses it as a backend, so
`terraform/bootstrap-state/` is a separate root module with local state that creates exactly
three things: a customer-managed KMS key (rotation on — symmetric KMS rotation keeps old key
versions, so old state stays readable), the state bucket, and the DynamoDB lock table. The
bucket is versioned, SSE-KMS with that key, public-access-blocked, TLS-only, denies a
`PutObject` that asks for the wrong encryption or the wrong key, and expires superseded
versions after 90 days — each one is a copy of every secret the state held at the time.

Its own state stays local on purpose. It holds no secret, and the three things it describes
are named rather than discovered, so losing that file costs three `terraform import`
commands.

### The first run, exactly

```
cd infra/aws/terraform/bootstrap-state
terraform init
terraform apply
terraform output -raw backend_config > ../backend.hcl

cd ..
terraform init -backend-config=backend.hcl
terraform plan -out=tfplan
```

`backend.hcl` is gitignored, and it has to be: the bucket name and the KMS key ARN both
carry the account id, which is not written down anywhere in this repository. That is also
why `versions.tf` holds a bare `backend "s3" {}` — a backend block cannot interpolate, so
the parts that vary come from the file. Every later `terraform init` in this directory needs
the same `-backend-config=backend.hcl`; the other commands do not, because `init` records it
under `.terraform/`.

### Why a DynamoDB table and not `use_lockfile`

Recent Terraform locks state with an S3 object and deprecates the table. This repository
pins Terraform `1.9.8` (`.terraform.lock.hcl`, and the binary the work was done with), and
its S3 backend does not have that argument at all. Checked rather than assumed, with the S3
endpoint pointed at `http://127.0.0.1:1` so no AWS call was possible:

```
# backend "s3" { ... use_lockfile = true }
Error: Unsupported argument
  on main.tf line 17, in terraform:
  17:     use_lockfile                = true
An argument named "use_lockfile" is not expected here.

# backend "s3" { ... definitely_not_an_arg = true }   <- the control
Error: Unsupported argument
An argument named "definitely_not_an_arg" is not expected here.

# backend "s3" { ... dynamodb_table = "example-lock" }
Error: Failed to get existing workspaces: ... dial tcp 127.0.0.1:1: connect: connection refused
```

`use_lockfile` fails identically to an argument that was invented for the control case;
`dynamodb_table` passes the schema and gets as far as the socket. Note that
`terraform init -backend=false` does **not** check the backend schema — it accepted the
invented argument too — so a check that uses it proves nothing.

`use_lockfile` arrived in Terraform 1.10. When this repo moves to 1.10 or later: add
`use_lockfile = true` to `backend.hcl`, `terraform init -reconfigure`, confirm a lock is
taken, then drop `dynamodb_table` and the table. Until then the table is the only mechanism
this version has.

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

`aws_instance.app` has `user_data_replace_on_change = false`, because a changed bootstrap must
never silently replace the box. The databases would now survive that — they are on their own
volume, which reattaches — but the ACME certificate and `/opt/skipperdesk/releases` would not,
so a surprise replacement still means a cold start and a fresh Let's Encrypt issuance. After a
`terraform apply` that changes `cloud-init/` or any file under `systemd/`, `Caddyfile` or
`coturn/`, re-run the bootstrap deliberately:

```
aws ssm send-command --profile <p> --region eu-west-2 \
  --instance-ids "$(cd terraform && terraform output -raw instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["cloud-init clean --logs && cloud-init init && cloud-init modules --mode=final"]'
```

### Shipping the fifth review's configuration changes, in order

There is still **no deploy path for a configuration change** — `docs/ROADMAP.md` carries it
as a known gap: `deploy.sh` ships binaries only, and changing `turnserver.conf`, the
Caddyfile, a unit or a logrotate rule means `terraform apply` to update the S3 object, then
installing it on the box and restarting the service by hand. Until that is a script, this is
the order for the H1/H5/H6 work, and nothing here is automatic:

1. **`terraform apply`** in `infra/aws/terraform`. This alone does three things: rewrites the
   `config/` objects in S3 (`turnserver.conf` with the new caps and `verbose`, the claims
   timer, `backup.sh`, `skipperdesk-backup@.service`, `logrotate/coturn`), creates the eight
   new alarms and the `runcommand` log group, and updates the IAM, KMS and bucket policies.
   **The policies and alarms take effect here. The files on the box do not** — the instance
   only reads `config/` at bootstrap.
2. **Re-run the bootstrap** with the `cloud-init` command above. This installs the new
   `backup.sh`, the claims timer, the service unit and `/etc/logrotate.d/coturn`, rewrites
   `/etc/turnserver.conf`, and **restarts Caddy and coturn**.
   **This kills every live relay.** Check `GET /internal/sessions/live` first — a redeploy
   drops WebSockets but sessions resume, whereas a coturn restart drops the media itself.
3. **Confirm the timers re-armed**, since step 2's whole point is that the claims timer no
   longer waits for midnight:
   ```
   systemctl list-timers 'skipperdesk-backup-*' --all
   ```
   `skipperdesk-backup-claims.timer` must show a `NEXT` within 15 minutes, not `00:00`.
4. **Confirm the first claims object exists**, which is the one fact that was false before:
   ```
   aws s3 ls s3://<backup bucket>/claims/
   ```
   Empty 20 minutes after step 2 means the fix did not take; `/var/log/skipperdesk/backup.log`
   will now say why, because the script no longer exits 0 silently.
5. **Confirm coturn took the caps and is accounting**:
   ```
   grep -E '^(max-bps|bps-capacity|verbose)' /etc/turnserver.conf
   grep -cE 'usage:|rb=|sb=' /var/log/turnserver/turnserver.log
   ```
   The second was `0` before. It stays `0` until a session actually relays, so drive one —
   `scripts/verify-relay.sh` — and re-check.

If only the Terraform-side resources are wanted and the relay must not be interrupted, stop
after step 1: the alarms, the log group and every policy change are live, and only the coturn
caps, the accounting and the backup fix need step 2. Note that **the backup fix needs step 2**
— the alarms from step 1 will correctly start firing about a claims prefix that is still
empty.

## Backups, and restoring the claims database

`skipperdesk-backup-db.timer` snapshots `rc-api.db` every 15 minutes, and
`skipperdesk-backup-claims.timer` snapshots `rc-api-claims.db` on the **same** 15-minute
cadence. Both use `sqlite3 .backup`, gzip, and `aws s3 cp` into two separate prefixes with
two separate lifecycle rules. `db/` transitions to Standard-IA and then expires;
**`claims/` never expires**, because losing a claim lets a Device ID be reissued to a
second key (`API.md` §6.1).

`API.md` §6.1 asks for a separate prefix, a separate schedule and a separate retention. It
does **not** ask for a worse RPO: the requirement is about never restoring the two together,
and the claims database is the one unrecoverable asset in the design. It had the 24-hour
cadence and the main database the 15-minute one, which was the inversion exactly backwards.

### Why `claims/` was empty, and what stops it recurring

The fifth security review found `claims/` with **zero objects and zero versions** for the
life of the bucket, while the unit reported `Result=success`. Four things lined up:

1. `bootstrap.sh` ran `systemctl enable --now` on the backup timers **before**
   `systemctl start rc-api.service`, and rc-api is what creates the database files.
2. The claims timer was `OnCalendar=daily` with `Persistent=true`. A fresh root volume has
   no `/var/lib/systemd/timers/stamp-*` file, so systemd treated the daily elapse as missed
   and fired the catch-up the instant the timer was enabled — 08:45:02 on the box reviewed.
3. `rc-api-claims.db` did not exist yet. Its mtime was 10:31:25, **1h46m later**.
4. `backup.sh` exited 0 on that path, so nothing failed — and the stamp systemd then wrote
   suppressed every retry until the next midnight.

So it was never one unlucky boot. **Every fresh instance reproduced it**, and an instance
replaced more than once in a day — the ordinary deploy-iteration pattern — never backed the
claims database up at all. The box reviewed had also rebooted at 12:43:37 without re-firing
the timer, correctly: the stamp said 08:45:02 and the next elapse was still in the future.
That is what made the gap invisible.

Four changes, each closing one of the four:

- `backup.sh` exits **non-zero** on a missing or empty source, on a `sqlite3 .backup` that
  produces nothing, and on an upload it cannot then list back out of the bucket. There is
  no longer any path that reports success without an object existing. The read-back uses
  `list-objects-v2`, not `head-object`, because the instance role deliberately holds
  `s3:ListBucket` and **not** `s3:GetObject` on these prefixes — the box must not be able to
  read the backups it writes.
- the claims timer is `OnBootSec`/`OnUnitActiveSec`, which has no calendar elapse to miss,
  so there is no catch-up to mis-fire and a failure is retried in 15 minutes, not a day.
- `skipperdesk-backup@.service` is ordered `After=rc-api.service`, and `bootstrap.sh`
  enables the timers after rc-api rather than before it. Neither is a `Requires`: a backup
  must still run when rc-api is down, because the data is still there.
- two `-backup-stale-*` alarms, one per prefix. They count the `ok` line `backup.sh` prints
  **only after the object reads back**, so they measure objects that exist rather than
  invocations that returned — the one check a unit exiting 0 cannot fool. Their
  `treat_missing_data` is `breaching`: this alarm fires on absence, and `notBreaching` would
  reproduce the original failure at the alarm layer.

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

### The volume the databases are on

Neither database is on the root volume. `terraform/data_volume.tf` creates a separate
encrypted gp3 volume, the bootstrap mounts it at `/var/lib/skipperdesk`, and the root volume
is back to `delete_on_termination = true` because it now holds nothing that matters. So:

- Replacing the instance **reattaches** this volume. The previous arrangement — a root volume
  kept past termination — left an orphan holding live data that nothing reattached.
- `prevent_destroy` is set on `aws_ebs_volume.data`, so `terraform destroy` fails, and so does
  an apply that would remove the volume. That is the point. To genuinely remove it, delete the
  `lifecycle` block in a commit of its own, so the intent is reviewable.
- The mount is in `/etc/fstab` **by filesystem UUID**, never by device name: on Nitro the
  `/dev/nvme*n1` names are assigned in attachment order and are not stable across a reboot,
  and `/dev/sdf` — the name EC2 is asked for — is not a name Linux uses at all. The bootstrap
  finds the disk through `/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_<volume id>`.
- The entry carries `nofail`, so a volume that is missing or late leaves the box booted and
  reachable over `aws ssm start-session` instead of dropping it into emergency mode. The
  services do not start in that state: `rc-api`, `rc-signal` and the backup units all name the
  path with `RequiresMountsFor=`, which systemd turns into `Requires=` plus `After=` on the
  mount unit it generates from the fstab line. The failure is therefore "rc-api is down and
  says why", not "rc-api opened an empty database on the root volume and started issuing
  Device IDs the claims file has never heard of".
- The bootstrap formats the volume **only** when `blkid` exits with its "not found" code and
  names neither a filesystem nor a partition table, **and** `wipefs` succeeds and recognises
  no signature. Any other outcome, including a probe that failed to answer, mounts the volume
  untouched. A re-run of the bootstrap, and a replaced instance, therefore read the databases
  that are already there.

Growing it: `data_volume_gb`, apply, then `sudo resize2fs /dev/<device>` on the box. An EBS
volume cannot be shrunk.

## Alarms

| Alarm | Metric | Where it comes from |
|---|---|---|
| `-api-5xx` | log metric filter `{ $.msg = "request" && $.status >= 500 }` | rc-api logs one JSON object per request with its status |
| `-id-cert-signs` | log metric filter over the CloudTrail log group on `kms:Sign` against the id-cert key | Bulk Device-ID minting. "The audit trail" below has the arithmetic behind the threshold |
| `-signal-healthz` | `AWS/Route53 HealthCheckStatus` | A health check probes `https://<api domain>/signal/healthz`, which Caddy rewrites to rc-signal's `/healthz`. The alarm lives in `us-east-1` because that is the only region those metrics exist in |
| `-host-unreachable` | `AWS/EC2 StatusCheckFailed` | coturn has no probeable endpoint; the relay is down whenever the host is |
| `-disk-used-root` | `disk_used_percent` from the CloudWatch agent, `path=/` | The root volume still carries the logs and the release directories |
| `-disk-used-data` | `disk_used_percent` from the CloudWatch agent, `path=/var/lib/skipperdesk` | The volume that must not fill: SQLite stops writing while the box keeps answering. The metric's dimensions include the filesystem type, which is why `filesystem_type` is a variable |
| `-network-out` | `AWS/EC2 NetworkOut`, `Sum` over 300 s, two consecutive periods | Relay egress, which nothing watched. "Relay bandwidth" below has the threshold arithmetic. `period` is 300 because the instance runs `monitoring = false`, so EC2 publishes at five-minute resolution |
| `-backup-stale-db`, `-backup-stale-claims` | log metric filter on `backup.sh`'s `ok` line, one per prefix | The check a unit exiting 0 cannot fool. `treat_missing_data` is `breaching`, the opposite of every other alarm here, because these fire on absence |
| `-trail-stopped` | log metric filter over the CloudTrail log group on `StopLogging`/`DeleteTrail`/`UpdateTrail`/`PutEventSelectors` | The account stopped recording itself |
| `-id-cert-key-at-risk` | the same group, on `ScheduleKeyDeletion`/`DisableKey`/`PutKeyPolicy` against the id-cert key | A scheduled deletion can still be cancelled inside the 30-day window, so this alarm genuinely saves the key |
| `-audit-objects-deleted` | the same group, on bucket-policy and versioning changes to the audit or backup bucket | The evidence being made deletable |
| `-admin-shell` | the same group, on `ssm:SendCommand` | CloudTrail hides the payload, so this records that the administrative path was used and by whom. "Run Command is the path that is actually used" below |
| budget | AWS Budgets, actual at 80% and forecast at 100% | `docs/PHASE5.md` §4 step 3 also sets one in the management account; this one is scoped to this account and is in code |

The last four fire on **existence**, not volume: each is a single API call whose effect is
irreversible or unrecoverable, so the threshold is 1. They cannot prevent anything — see
"What an account admin can still do" — they make it arrive as mail.

The CloudWatch agent is configured to read exactly three files —
`/var/log/skipperdesk/{rc-api,rc-signal,backup}.log` — and one disk metric on each of the two
mount points. It is not a
general log scraper, and nothing is added that could capture a request or WebSocket body
(`API.md` §9, `PROTOCOL.md` §8). Caddy's access log is switched off for the same reason.

## The audit trail

Two things were unrecorded until now: what the signing key was used for, and what anyone did
in a shell on the box. Both are in code.

### The trail

`aws_cloudtrail.management` records **management events only** and delivers them to the audit
bucket and to a CloudWatch Logs group. The account's first copy of management events is free;
everything below is about keeping it that way.

- **No `data_resource` block anywhere.** S3 object-level and KMS data events are billed per
  event, and the 15-minute backup `PutObject` alone would turn that into a standing bill for
  something this trail is not for. It would also record more than `API.md` §9 allows.
- **`read_write_type` is `All`, and must stay so.** `kms:Sign` is logged with
  `"readOnly": true`. A write-only trail would record no signature at all, and the alarm
  would read zero forever while certificates were being minted — coverage that looks like
  coverage and is not.
- **Log file validation is on**, so the digest files make after-the-fact tampering detectable.
- **Multi-region by default** (`cloudtrail_multi_region`). The free copy covers it, and
  activity in a region this product never uses is itself a signal.

### Its own bucket, not a prefix of the backup bucket

The instance role holds `s3:PutObject` on the backup bucket's `db/` and `claims/` prefixes.
The scenario the sign alarm exists to catch is somebody holding that role. An audit log is
worth what it is worth precisely because it sits outside the reach of the identity it audits,
and a bucket boundary keeps that true through a later widening of the `WriteBackups`
statement rather than only today. S3 charges per byte, not per bucket, so the separation
costs nothing. The trail's bucket policy grants `cloudtrail.amazonaws.com` `s3:GetBucketAcl`
and `s3:PutObject` under `AWSLogs/<account id>/` only, both conditioned on
`aws:SourceArn` being this one trail — without that condition any trail in any account could
be pointed at the bucket. The trail ARN is built in `locals` rather than read off the trail
resource, because the bucket policy and the delivery role both have to exist before it.

Encryption is SSE-S3, like the backup bucket. A CMK here would add **$1/month** and buy
little: tamper *evidence* comes from log file validation, and tamper *prevention* from the
bucket policy and versioning, neither of which a key changes. The one thing a CMK would add
is making a reader need a second permission, which matters when the bucket is shared — and
it is not.

### The threshold on `-id-cert-signs`

The number has to come from expected volume, because signatures here are not rare.
`server/internal/hub/handle.go` calls `Registry.Certify` on every authenticated `hello`, and
`registry.Local.Certify` re-signs through `Authority.Issue` rather than returning a stored
certificate. **So signs track reconnections, not new devices.** A device that connects ten
times signs ten certificates; a fleet that never grows still signs all day.

The default is `id_cert_sign_threshold = 60`, over a five-minute period, derived at the
10-host launch line `docs/PHASE5.md` §3.2 prices:

- Steady state: 10 hosts × 24 reconnections/day ÷ 288 five-minute periods = **0.83 signs per
  period**. The 24 is the assumption worth naming — a personal Mac that sleeps, wakes, roams
  between networks and gets relaunched, which is about hourly.
- The real floor is not steady state but the **fleet-wide reconnect**: a `deploy.sh` run drops
  every live WebSocket (see "Redeploying"), so all 10 devices re-`hello` inside one period.
  That is 10 signs from an ordinary deploy, and it must not page.
- Allow each device up to six reconnect rounds inside those five minutes — a flapping uplink
  backing off, or a deploy followed by a restart — and the legitimate worst case is
  10 × 6 = **60**.

So 60 is about 70× steady state and 6× an ordinary deploy burst: ordinary noise cannot reach
it. Above it, at a 10-host fleet, either the fleet grew or something is minting in bulk.
**The rule for raising it: roughly 6 × expected hosts, floor 60.** At the 500-host line that
is 3000. Raising it is a one-line variable change, and leaving it at 60 past about 10 hosts
turns the alarm into noise, which is the same as not having it.

### What CloudWatch Logs ingest costs

Priced because it is the one term here that scales with traffic. At the 10-host line:

| Source | Events/day | Bytes |
|---|---:|---:|
| `kms:Sign` — 10 hosts × 24 reconnections | 240 | ~0.29 MB |
| SSM Agent `UpdateInstanceInformation`, roughly every 5 minutes | 288 | ~0.35 MB |
| Everything else: parameter reads at boot, applies, describes | ~200 | ~0.24 MB |
| **Total** | | **~0.9 MB/day ≈ 27 MB/month** |

A CloudTrail management event is roughly 1.2 KB. At the $0.57/GB ingest figure
`docs/PHASE5.md` §3.2 carries (still **unverified**), 0.027 GB is **$0.015/month**, and
storage at $0.0315/GB-month is another tenth of a cent. **It is not material** — about two
cents a month, and still under a quarter at ten times the volume — so there is no cheaper
shape to propose. The term that would change that is data events, which is exactly why there
are none. Note the backup `PutObject` and the relay traffic do **not** appear above: both are
data-plane, and a management-events trail does not see them.

## Session Manager sessions are recorded

`session_logging.tf` creates the account-level preferences document Session Manager reads.
The name `SSM-SessionManagerRunShell` is fixed by AWS — a document called anything else is
never consulted, which is the quiet way this feature fails. Sessions stream to their own log
group with their own retention, separate from the application group so a transcript is never
mixed in with service logs.

`cloudWatchStreamingEnabled` is `true`: output is written as it happens rather than uploaded
when the session ends, so a session that is killed — or that kills the agent — still leaves
behind everything it did.

Terraform **creates** this document, so a first apply fails with `DocumentAlreadyExists` in an
account where anyone has ever saved Session Manager preferences in the console — the console
creates the same document under the same fixed name. This account is empty, so it does not
arise here; if it ever does, the fix is `terraform import`, not a second document.

**`cloudWatchEncryptionEnabled` and the log group's key are driven from one variable**,
`enable_session_log_cmk`, and that is deliberate. The preference does not mean "encrypt if
you can"; it means "refuse to log unless the group is KMS-encrypted". Set it against a group
with no CMK and logging stops rather than degrades. One variable makes them unable to
disagree. On by default, **$1/month** for the key: a root-shell transcript is the most
sensitive log in the account, and it can contain whatever the operator typed or printed.
The key policy grants only `logs.<region>.amazonaws.com`, conditioned on
`kms:EncryptionContext:aws:logs:arn` being this one log group.

Two inputs are deliberately absent:

- **No `s3BucketName`.** A second copy of the same transcript for a second bill. CloudTrail
  already holds the tamper-evident record of which sessions existed and who opened them; the
  transcript is the detail, and one searchable copy with a retention is enough.
- **No `kmsKeyId`.** That input is end-to-end encryption of the live stream, not of the logs,
  and it additionally requires every operator who starts a session to hold permissions on
  that key. Getting it wrong locks the owner out of the only shell this box has. The stream
  is already inside TLS.

### What the instance role needed for it to actually work

Session logging is written by SSM Agent on the instance, under the instance role — so
`AmazonSSMManagedInstanceCore` is not sufficient, and a missing permission here shows up as
logging that silently never writes. AWS documents four actions; `iam.tf` grants exactly
those, and no more:

| Action | Scope here |
|---|---|
| `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` | Added to the existing `ShipOwnLogs` statement, resource-scoped to the session log group alongside the app group |
| `logs:DescribeLogGroups` | `*`, in its own statement |

`logs:DescribeLogGroups` is the one that cannot be scoped. The agent calls it to confirm the
configured group exists before streaming, and a resource-scoped grant makes an unfiltered
call fail outright instead of returning a filtered list — which lands exactly in the
silently-not-writing state. It reads group names and no log content. It is called out for the
fifth security review as the only `*` resource left in the instance policy that is not
bounded by a condition.

No KMS action was added, and none is needed: CloudWatch Logs encrypts on the writer's behalf
using the grant in the key policy, so the instance role never touches the key itself.

### Run Command is the path that is actually used

`PHASE5.md` §1 calls Session Manager "the *entire* administrative path". It is not. Both
automated callers — `infra/aws/deploy.sh` and `scripts/publish-release.sh` — use
`ssm send-command`, and CloudTrail records that call as:

```
"documentName":"AWS-RunShellScript","parameters":"HIDDEN_DUE_TO_SECURITY_REASONS"
```

The session preferences document cannot cover it: its `sessionType` is `Standard_Stream`
and Run Command is not a session. There is also no account setting that forces a caller to
ask for output — `cloudWatchOutputConfig` is a per-call parameter.

What *was* missing is the half that makes asking work. SSM Agent writes Run Command output
under the **instance role**, and `ShipOwnLogs` named only the app and session groups — so a
caller who had passed `--cloud-watch-output-enabled` would have been denied and the output
would have gone nowhere, silently. `/skipperdesk/prod/runcommand` now exists, the grant
includes it, and both callers pass it, printing a `note` rather than failing if the stack
predates the group.

That covers the automated path. An operator typing `aws ssm send-command` by hand still
chooses whether to be logged; the `-admin-shell` alarm records that they did it either way.
Closing that choice means denying `ssm:SendCommand` on `AWS-RunShellScript` to the admin
principal, which cannot be done from this account — see below.

## What an account admin can still do

State this plainly, because it bounds everything above. There is exactly one human identity
with access to this account: an Identity Center permission set granting
`AdministratorAccess`, whose every CloudTrail record carries `"mfaAuthenticated":"false"`,
with no SCP above it. `OrganizationAccountAccessRole` additionally trusts
`arn:aws:iam::521831014979:root` with no MFA or `ExternalId` condition, so control of the
management account is control of this one.

**Nothing this configuration denies can stop that identity**, because it can rewrite the
denial first. Every control added for the fifth security review's H6 is therefore a
*detection* control plus a second logged call, not a prevention:

| What it would take | What now stands in the way |
|---|---|
| Stop the audit trail | `-trail-stopped` fires on the call |
| Delete audit object versions | The bucket policy denies both delete actions, so the policy must be removed first — two calls, and `-audit-objects-deleted` fires on the first |
| Destroy the id-cert signing key | The key policy no longer grants `kms:ScheduleKeyDeletion`, so `PutKeyPolicy` must come first — `-id-cert-key-at-risk` fires on either, and `kms_deletion_window_days` is already the 30-day maximum, so there is a month to `CancelKeyDeletion` |
| Run an unlogged root shell | `-admin-shell` records every `SendCommand`; the payload stays hidden |

### What the owner must do at the organization level

These are the only real fixes, and none of them can be applied from inside account
`388699643285`. Confirmed by attempt: `aws organizations list-policies` returns
`AccessDeniedException` with the `skipperdesk` profile. The organization is
`o-li53etmhxk`, management account `521831014979`, `FeatureSet: ALL`, and
`SERVICE_CONTROL_POLICY` is **already enabled** — so the lever exists and is one level up.

1. **Require MFA on the `SkipperDeskAdmin` permission set.** Every record today says
   `mfaAuthenticated: false`. This is the single highest-value change on the list.
2. **Attach an SCP** to this account denying `cloudtrail:StopLogging`,
   `cloudtrail:DeleteTrail`, `s3:DeleteObjectVersion` on the audit bucket,
   `s3:PutBucketPolicy` on the audit bucket, `kms:ScheduleKeyDeletion` on the id-cert key,
   and `ssm:SendCommand` on `AWS-RunShellScript`. An SCP is the only control an
   account-local `AdministratorAccess` cannot lift.
3. **Add an MFA condition** to `OrganizationAccountAccessRole`'s trust policy (also `L10`).
4. **Make the trail an organization trail** delivering into the management account, so the
   evidence does not live in the account it is evidence about.
5. **Enable S3 Object Lock on the audit bucket**, in governance or compliance mode. This is
   deliberately **not** in Terraform: `aws_s3_bucket`'s `object_lock_enabled` forces
   replacement, and replacing these two buckets would destroy the audit trail and the
   backups. Versioning is already on, so it can be enabled out of band with
   `aws s3api put-object-lock-configuration`, or on a new bucket the trail is re-pointed at.

## Relay bandwidth

`bps-capacity` and `max-bps` were both absent, so relay egress had no ceiling but the NIC:
roughly 28.8 GB/hour of billed egress, about $62/day, against a $50 monthly budget that
only emails at 80% with up to a day of lag.

**Both options are BYTES per second, not bits, and coturn meters the input and output
streams separately.** This is the detail everything below turns on, and it is confirmed
against the installed build's own man page (coturn 4.6.1-1build4):

> `-s, --max-bps` Max bytes-per-second bandwidth a TURN session is allowed to handle (input
> and output network streams are treated separately).

A limit of *N* therefore permits *N* in and *N* out, which is exactly one relayed direction,
so both values are sized per direction.

### `max-bps` — what a legitimate session actually needs

The binding fact is that the **shipped** client asks for 8 Mbps in *every* quality mode,
including `auto`. `QualityProfile.profile(for:…)` sets `maxBitrateBps = burstBitrateBps =
8_000_000` and only `maximumWidth` varies between modes — which is `BETA.md` §2.3's point,
that quality is not a bandwidth control today. `BETA.md` §2 *proposes* capping `auto` at
2 Mbps, but that is unshipped client work. **So a legitimate session at the `auto` ceiling
needs 8 Mbps, not 2**, and a cap derived from the proposal would clip real sessions.

| Term | Value | Source |
|---|---:|---|
| Video ceiling, every mode including `auto` | 8,000,000 bit/s | `QualityProfile.swift` `burstBitrateBps`; `PLAN.md` §5's "8 Mbps burst" |
| `ctrl` + `hi` data channels | 100,000 bit/s | Allowance for input events and clipboard |
| Payload subtotal | 8,100,000 bit/s | |
| × 1.05 framing | 8,505,000 bit/s | 48 B per 1200 B packet (RTP 12 + SRTP tag 4 + UDP 8 + IPv4 20 + TURN ChannelData 4 = 4.0%), plus RTCP and RFC 7675 consent refreshes |
| × 1.15 queueing margin | 9,780,750 bit/s | Stated allowance, so a transient does not meet coturn's drop behaviour |
| **`max-bps`** | **1,222,600 B/s** | 9.78 Mbps per direction |

That is **1.22×** what the client can request, so it cannot break a session at the quality
ceiling, and **25×** the 383–391 kbps `VERIFY.md` actually measured. Because every mode
shares the 8 Mbps ceiling today, this one value covers `smooth`, `auto` and `sharp` alike,
and it only gains headroom if `BETA.md` §2's tiering ever ships.

### `bps-capacity` — the box-wide ceiling

Derived from the NIC, because the NIC is what the money followed:

- t4g.small sustained network baseline: **0.128 Gbps** = 128 Mbps (burst higher on credits).
- × 0.90, reserving a tenth for Caddy's TLS, both Go services, the WebSocket traffic, the
  15-minute backup upload, the CloudWatch and SSM agents: 115.2 Mbps.
- Split across the two directions coturn meters separately: **57.6 Mbps per direction**.
- **`bps-capacity` = 7,200,000 B/s.**

Cross-checks: that is 5 concurrent sessions at the full 8 Mbps ceiling, against `PHASE5.md`
§3's 4–6 concurrent relayed sessions at peak for this shape; or about **147** concurrent at
the measured bitrate. So it is generous for real traffic and bites only on simultaneous
worst-case abuse, which is the intent.

### The cap is not a cost control — the alarm is

Say this out loud, because it is the easy mistake: **a rate cap bounds the blast radius per
instant, and only an alarm bounds the month.** 57.6 Mbps sustained is 25.92 GB/h, $2.33/h,
**$56/day** — still ruinous against a $50 monthly budget. Sizing the cap at the
budget-affordable *average* instead would mean about 1.08 Mbps, which would throttle a
single legitimate 8 Mbps session to an eighth. That trade is not available.

So the money is bounded by `-network-out`:

- Fixed monthly cost: **$26.83** = `PHASE5.md` §3.2's ten-host column ($26.13) + $0.70 for
  the seven alarms this review adds.
- Egress headroom under the $50 budget: **$23.17** → 257 GB at $0.09/GB, plus the 100 GB
  free tier = **357 GB/month**.
- The rate which, sustained for 24 hours, spends all of that: 357.4e9 ÷ 24 ÷ 12 =
  **1,241,200,000 bytes per five-minute period**.

That threshold is **3.5×** `PHASE5.md` §3's legitimate peak for this shape, so real load
cannot reach it, and **57%** of what `bps-capacity` now permits, so it fires *before* the
cap saturates rather than after. Two consecutive periods are required, so a backup upload
or one spike cannot trip it. It arrives long before the budget email, which lags up to 24
hours and only sends at 80% of $50.

**Still missing, and the owner's call:** nothing *stops* the spend. `PHASE5.md` §3's
suggestion of a budget action or an SNS-triggered Lambda that halts coturn is not here,
because stopping the relay is a decision about an outage and should not be taken by default
on a threshold derived from an unmeasured model. The alarm now makes it a choice rather than
a discovery.

### The relay log exception

`verbose` is now set, and it is a **deliberate, bounded exception** to `API.md` §9 and
`PROTOCOL.md` §8.

It is the only lever available. coturn 4.6.1 gates its `usage:` lines on
`TURN_LOG_LEVEL_INFO`, which only `verbose` admits; the Ubuntu build has no prometheus
exporter; and the admin CLI stays shut under `no-cli` — re-opening it would trade a disk log
for a listening admin port *and* give no historical record, which is the whole point. With
`simple-log` and no `verbose`, `grep -cE 'usage:|rb=|sb=|allocat'` over the entire live log
returned **0**.

**Exactly what now lands on disk:**

| Line | Contents | Permitted by `API.md` §9 / `PROTOCOL.md` §8? |
|---|---|---|
| `usage:` per session | realm, TURN username, `rp`/`rb`/`sp`/`sb` packet and byte counters | **Yes.** The username is `<expiry>:<sessionId>`, and `sessionId` and byte counts are both on the allowed list |
| allocation, `CreatePermission`, `ChannelBind` | the **peer address** | **No.** This is the exception |
| session `closed` | local and remote addresses | **No.** This is the exception |

So the exception is narrow and specific: **peer IP addresses** — a user's public address,
which §8 covers under ICE candidates. The TURN *password* is never logged; only the
username, which the peer already knows and which is useless without the HMAC.

**Containment, and the retention:**

- `infra/aws/logrotate/coturn` keeps **7 days**, compressed, with `copytruncate`. The coturn
  package ships no logrotate rule at all, so before this the log was unrotated — harmless
  with only startup lines in it, not harmless with a usage line and an address per session.
  `copytruncate` rather than a reload because the alternative, restarting coturn, kills
  every live relay.
- `cloudwatch-agent.json` deliberately does **not** collect `turnserver.log`. It still reads
  exactly the three `/var/log/skipperdesk/*.log` files. The addresses stay on the instance's
  own encrypted volume, never reach a log group or its 30-day retention, and never leave the
  account.
- `/var/log/turnserver` is `0750 turnserver:turnserver`.

**What this buys:** bytes become attributable. The username carries the session id, which
joins to `/v1/sessions` and hence to an account, so relay abuse can be traced to who did it.

**What it does not buy, and who owes it:** nothing *parses* those lines. `PHASE5.md` §8.2's
debt — making `bytesRelayed` a server-side fact rather than a client's claim — needs a
reader in `server/`, which is outside this change. The data now exists on the box; turning
it into the `bytesRelayed` column is server work still outstanding.

## Sign-in, and the website

This stack owns the identity half: the user pool, its free sign-in domain
(`<prefix>.auth.<region>.amazoncognito.com`) and the public app client. The authentication
itself is Cognito's hosted sign-in — no password, no verification code and no social token
passes through a page we wrote. The client has **no secret** and **no `ALLOW_USER_SRP_AUTH`**:
the hosted flow does not use the `InitiateAuth` flows, so leaving SRP on would publish a
password-guessing surface on a client that has no password form of its own. The authorization
code is bound to the browser with PKCE instead.

The page that drives it, and everything else on `skipperdesk.app`, is **not here**. It is a
separate stack with its own state — `infra/web` — so a landing-page change can never roll this
box. `cognito_callback_urls` and `cognito_logout_urls` are gone as variables; the callback is
derived from `web_base_url`, which already names the site, and `extra_cognito_callback_urls`
is there for a local origin. Only `https://<web domain>/link` is registered: CloudFront sends
`www` to the apex before any script runs.

**Caddy serves `api.skipperdesk.app` and nothing else.** The apex and `www` never reach this
instance, and the site files do not travel through the S3 `config/` prefix.

## Caddy

`caddy` and `coturn` both come from the distribution's own archive, so no third-party apt
repository is added. If a future image drops the `caddy` package, the bootstrap fails loudly
rather than silently; the replacement is the official static `linux/arm64` release, verified
against its published checksum, plus a unit of our own — and it becomes a named dependency in
the PR that does it.

## What is deliberately not here yet

- **No key rotation.** KMS cannot rotate an asymmetric key, and the contract has no verifier
  that accepts two signing keys at once. The `TODO:` is in `terraform/kms.tf`.
- **No DynamoDB claims table.** `API.md` §6.1 and `docs/PHASE5.md` §2 both say the claims
  database moves to DynamoDB with point-in-time recovery and deletion protection, early and on
  its own. It has not moved; it is a file on the data volume with its own backup schedule.
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
`t4g.small`, the public IPv4 address, the two 20 GB gp3 volumes, the three KMS keys, the
seven alarms, the log groups, the two buckets and the state bucket's lock table — about
**$26/month** before any relay egress, which is the term that actually grows.

The separate data volume is $1.86/month more than keeping the databases on the root volume,
and the state backend is about $1.10 (the customer-managed key is $1 of it). Both are priced
into `docs/PHASE5.md` §3.2.

Audit and session logging add about **$1.15/month**, and only $0.15 of it is unavoidable:

| Item | Monthly |
|---|---:|
| CloudTrail, first copy of management events | $0 |
| Audit bucket: ~27 MB/month of trail objects, SSE-S3 | ~$0.01 |
| CloudWatch Logs ingest and storage for the trail | ~$0.02 |
| The `-id-cert-signs` alarm | $0.10 |
| Session transcripts: sporadic, a few MB | ~$0.01 |
| Session log group CMK (`enable_session_log_cmk`) | $1.00 |
| **Total** | **~$1.15** |
