# Phase 5 — the backend on a fresh AWS account

Planning only. Nothing in this document has been provisioned. The existing account
(`219702648416`, IAM user `godson`) was read with describe/list calls only: it holds **one**
hosted zone (`uburu.ai`), **no** registered domains, **no** Cognito user pools, **no** ACM
certificates and **no** customer-managed KMS keys in `eu-west-1` or `eu-west-2`. The legacy
box is untouched and stays frozen (`infra/legacy/README.md`).

Two AWS accounts already exist locally and **neither** is the one we deploy into:
`219702648416` (profile `godson`) holds the frozen box, and `521831014979` (profile `regina`,
IAM Identity Center at `d-90667fa3fd`) is in use for something else — its `ReginaDeployRole`
carries explicit *denies* on EC2 and Cognito, so it was deliberately fenced and is not ours to
widen. SkipperDesk gets its own member account under the same organization: one bill, one Cost
Explorer, one SSO login, and a blast radius that cannot reach either of the other two.

Scope and rationale: `docs/SCOPE.md` §4, §6, §7, §8. Contracts: `protocol/API.md`,
`protocol/PROTOCOL.md`. Progress tracking: `docs/ROADMAP.md`.

**Region: `eu-west-2` (London).** Egress is priced identically to `eu-west-1`
($0.09/GB first 10 TB), compute is ~12% dearer (t4g.small $0.0188/h vs $0.0168/h — about
$1.50/month, a rounding error next to relay egress), and the user and the first hosts are in the
UK, so TURN RTT is lower where it matters. It is also a different region from the frozen box,
which makes an accidental cross-deploy harder.

All prices below were read from the AWS Pricing API on 2026-10-07 for EU (London) unless marked
**unverified**.

---

## 1. What must exist

| Thing | What it is | Where it lives | Notes / what breaks without it |
|---|---|---|---|
| Domain | `skipperdesk.app` | **Already owned — Namecheap, paid** | $0 to this phase. The client's single config value (`API.md` §0) is `api.skipperdesk.app` |
| DNS | Stays at Namecheap (`dns1/dns2.registrar-servers.com`). `A` records for `api.` and `turn.` → the Elastic IP; an `ALIAS` on `@` and a `CNAME` on `www` → the CloudFront distribution; two validation `CNAME`s for the website certificate | Namecheap Advanced DNS | $0. No Route 53 hosted zone — nothing in the design needs one, and Caddy validates over HTTP-01, not DNS-01 |
| TLS | Public CA cert for `api.skipperdesk.app` | ACM (Shape B) or Caddy + Let's Encrypt (Shape A) | ACM is free but only usable by ALB/CloudFront, not by a process on EC2. On Shape A, Caddy holds the cert and rc-api runs behind it on loopback |
| Cognito user pool | Email + Apple + Google, with **Cognito's hosted sign-in** on the free `<prefix>.auth.<region>.amazoncognito.com` domain. No client secret, and no password form of ours: the authorization code is bound to the browser with PKCE. A custom `auth.skipperdesk.app` comes with the Apple work | Cognito, `eu-west-2` | Free to 10 k MAU (**unverified** — Cognito re-tiered in 2024/25; check the console's pricing panel when creating the pool). rc-api needs `RC_API_COGNITO_ISSUER` + `RC_API_COGNITO_AUDIENCE` (app client id) |
| rc-api | REST `/v1`, the `/link` page, the `/ws` pass-through. **Two listeners**: public (`RC_API_LISTEN`) and internal (`RC_API_INTERNAL_LISTEN`, default `127.0.0.1:18081`) | ECS task or the one EC2 box | Refuses to start with the internal listener on the public port |
| rc-signal | `/ws` signaling, `/healthz`. **Two listeners**: public (`RC_LISTEN`) and internal (`RC_INTERNAL_LISTEN`, default `127.0.0.1:18444`) | same | In a deployment it holds no registry: it asks rc-api over the internal surface (`API.md` §6) |
| coturn | UDP relay, `3478` udp+tcp, relay range `49160-49200/udp`, `use-auth-secret`, anti-proxy denies from `infra/legacy/coturn/turnserver.conf` | EC2 with an Elastic IP — **always**, both shapes | Needs UDP and a stable public IP, so it cannot sit behind an ALB on Fargate. Raise `user-quota`/`total-quota` above the 1:1 values (6/12) before more than three hosts use it |
| `rc-api.db` | Main SQLite: accounts, devices, tokens, sessions, ledger, idempotency | Its own EBS gp3 volume, **never the root volume** (Shape A) | Single-writer. See §1.1 |
| `rc-api-claims.db` | `device_id_claims` — every Device ID ever assigned and the key it went to (`RC_API_CLAIMS_DB`) | **its own file, its own backup schedule** | Losing it lets an ID be reissued to a second key. Never reset or restore it with the main DB (`API.md` §6.1). `TODO` in the contract already says Phase 5 moves it to DynamoDB with PITR + deletion protection — do that |
| id-cert signing key | P-256 PEM PKCS#8, `RC_API_ID_CERT_KEY_FILE`. Signs the Device-ID ↔ pubkey binding on register and on `POST /internal/devices/{id}/cert` | **Done: KMS asymmetric ECC_NIST_P256, `SIGN_VERIFY`, key policy allowing only the rc-api role, no key material export — `-id-cert-kms-key-id`** | See §1.2 |
| TURN secret | coturn `static-auth-secret`; rc-signal mints `HMAC-SHA1` credentials from it (`RC_TURN_SECRET_FILE` — a **file**, never a flag) | Secrets Manager or SSM Parameter Store (SecureString), written to a file at boot with mode 0600 | Leak = free relay for anyone. Rotatable: write a new secret, restart coturn and rc-signal; in-flight 10-minute credentials die |
| internal bearer | Shared secret for both internal listeners (`RC_API_INTERNAL_TOKEN_FILE` / `RC_INTERNAL_TOKEN_FILE`), constant-time compared | same store, same file treatment | Holder can register devices, bump epochs, close sessions, read entitlement. The `-internal-token` flag exists and is deprecated — **never use it**, it is visible in `ps` |
| Backups | `sqlite3 .backup` to S3 (SSE-S3, versioning, lifecycle to IA at 30 d) every 15 min for the main DB; **separate prefix, separate schedule, separate retention** for the claims DB; EBS snapshot daily | S3 one-zone is enough for snapshots; the claims prefix gets object-lock-style retention (never expire) | Pennies/month at this size |
| Logs | Both binaries already emit JSON to stdout (`slog`). CloudWatch Logs, 30-day retention. `API.md` §9 and `PROTOCOL.md` §8 bound what may be logged — do not add a log agent that scrapes anything else | CloudWatch Logs | Ingest ≈$0.57/GB (**unverified**), storage $0.0315/GB-month (verified) |
| Metrics | `/healthz` + `/v1/health` probes; relay bytes from the `bytesRelayed` column (`API.md` §5.1); NAT-vs-relay ratio from `relayUsed` | CloudWatch | `relayUsed` is the number §3's whole cost model turns on. Report it from day one |
| Alarms | 7 alarms: rc-api 5xx rate, rc-signal `/healthz` fail, coturn host unreachable, **root volume >80%**, **data volume >80%**, **`kms:Sign` volume on the id-cert key**, **AWS Budgets actual + forecast** | CloudWatch, $0.10/alarm/month (verified) | The budget alarm is the one that protects the user, not the service. The two disk alarms are separate because the volumes fail differently: a full data volume stops SQLite writing while the box keeps answering. The sign alarm is sized on fleet size, because signs track reconnections rather than new devices |
| Audit trail | CloudTrail, **management events only**, log file validation on, delivered to its own bucket and to CloudWatch Logs | Its own S3 bucket — not a prefix of the backup bucket, which the instance role can write to | The account's first copy of management events is free. `kms:Sign` is logged `readOnly: true`, so the trail must capture read-only events or the sign alarm reads zero forever. No data events, ever: they are billed per event and `API.md` §9 bounds what may be recorded |
| Session logging | `SSM-SessionManagerRunShell` streaming every session to its own encrypted log group | CloudWatch Logs | With no inbound SSH rule, Session Manager is the *entire* administrative path to the box. The instance role needs four `logs:` actions for this to write at all — a logging config that silently fails looks like coverage and is not |
| Terraform state | The record of everything above | **S3, versioned, SSE-KMS with a customer-managed key, public access blocked, DynamoDB lock table** | Must exist *before* the first apply, not after: `aws_cognito_identity_provider` takes the Apple `.p8` and the Google client secret as literal arguments, so state holds both in the clear the moment social sign-in is on. Created by its own root module, `infra/aws/terraform/bootstrap-state` — a configuration cannot create the bucket it uses as its own backend |

### 1.1 Does SQLite survive this phase?

Yes, for launch, and not past it. State it plainly:

| Condition | Consequence |
|---|---|
| One rc-api process, one EBS volume | SQLite is correct and fast. Writes per session are a handful of rows |
| A second rc-api instance | SQLite **must go first**. There is no shared-write story; two instances on one file corrupt it |
| Zero-downtime redeploy | Needs two instances overlapping, so it needs the same migration |
| Multiple rc-signal instances | Does not need SQLite to move, but does need the rate-limit buckets moved to a shared store (`PROTOCOL.md` §3.3 `TODO`) and the reconciliation sweep to ask every instance (`API.md` §6.2 `TODO`) |
| Writes contend (`SQLITE_BUSY` in the logs) or the DB exceeds ~2 GB | Move |

**Triggers to move, any one of them:** a second rc-api instance is wanted; a redeploy must not drop
connections; `SQLITE_BUSY` appears; or ~500 linked hosts, whichever comes first. **Target:**
DynamoDB for `device_id_claims` (single-item reads, PITR, deletion protection — this one moves
early and on its own, as `API.md` §6.1 already specifies) and Aurora Serverless v2 PostgreSQL for
the rest. Not RDS on a fixed instance: idle cost must stay near zero (SCOPE §2, principle 5).

### 1.2 The id-cert signing key — what is lost if it is lost

This key is the root of Device-ID ownership. A device proves "this ID is mine" by presenting the
`idCert` the registry signed (`PROTOCOL.md` §2.2 step 3, §3.1.1). So:

| Event | Consequence |
|---|---|
| Key lost (no backup) | Every existing `idCert` becomes unverifiable. Devices that re-register with an old certificate under a new key are not honoured, so `preferredDeviceId` stops working and **every device that re-registers gets a new Device ID**. Users lose their saved devices. Recoverable only because the claims DB still binds ID→pubkey — so the claims DB is the second line of defence and must not be lost in the same incident |
| Key leaked | An attacker mints certificates for any Device ID, and can claim an ID whose record is gone. Combined with a claims-DB loss, that is Device-ID takeover |
| Key rotated | Needs a verifier that accepts both the old and the new key for the certificate lifetime. The contract does not describe this today — **new surface, needs a review (§7)** |

**Proposal: KMS asymmetric `ECC_NIST_P256` / `SIGN_VERIFY`.** The private key never exists outside
KMS, so it cannot be copied off a box, and every signature is a CloudTrail event. $1/key-version/month
plus $0.15/10 000 asymmetric sign requests (verified). Cost of the alternative — a PEM file on an
EBS volume — is zero dollars and a catastrophic single point of failure.

**Done.** `server/internal/idcert` now holds the private half behind a `signer` seam inside
`Authority`: `-id-cert-kms-key-id` takes a key id, alias or ARN and signs every certificate with
`kms:Sign`, so no id-cert private key exists in the process or on the volume. It is mutually
exclusive with `-id-cert-key-file`, which is unchanged, and `-insecure-http` with neither flag
keeps the throwaway local key so `dev-backend.sh` still runs offline with no AWS at all. The
public key is fetched once at startup with `kms:GetPublicKey`, and a failure there refuses the
start **deliberately**: that fetch is where misconfiguration shows up, and a loud first-deploy
failure beats a healthy-looking server that 500s on every registration. A degraded start that
served everything except the two signing calls was considered and rejected for that reason.

Signing is a network call, so it is bounded by the caller's budget rather than KMS's: `API.md`
§6.1 gives rc-signal 3 s per internal call, and 700 ms per attempt × 3 attempts plus 100 ms +
200 ms of backoff is a 2.4 s worst case, leaving 600 ms for the rest of the handler. A test pins
that arithmetic. The wire format did not change: `ECDSA_SHA_256` returns the same ASN.1 DER
encoding `ecdsa.SignASN1` produced, so there is no conversion and no vector moved.

---

## 2. Two deployment shapes

### (a) Smallest — one EC2 box

```
Namecheap DNS → EIP → t4g.small (eu-west-2)
             ├── Caddy :443        → rc-api  127.0.0.1:18080  (+ internal :18081, loopback)
             │                       rc-signal 127.0.0.1:8443 (+ internal :18444, loopback)
             └── coturn :3478 udp/tcp, 49160-49200/udp  (host networking)
         EBS gp3 20 GB root: the OS, both binaries, the logs  (dies with the instance)
         EBS gp3 20 GB data: rc-api.db, rc-api-claims.db      →  S3 snapshots
                             mounted at /var/lib/skipperdesk by UUID; outlives the box
```

| | |
|---|---|
| Cost | ~$25/month fixed (§3) |
| What it buys | One box, one deploy script, loopback-only internal listeners by construction, the shape the code already assumes. Caddy does ACME so TLS needs no ALB |
| Complexity cost | One AZ, no redundancy. A redeploy drops WebSockets (sessions survive — `PROTOCOL.md` §4.1 resume — but the socket reconnects). Caddy is one new dependency to name in the PR. No horizontal scale at all |
| What breaks first | coturn's CPU/PPS and the t4g burst credits under sustained relay — before the UDP bandwidth does. Then SQLite write contention, then the fact that there is one of everything |

### (b) Managed — ALB + ECS/Fargate, coturn on EC2

```
Namecheap DNS → ALB (ACM cert) → Fargate: rc-api task, rc-signal task  (private subnets)
                                 ↕ internal surface over the VPC, security-group pinned
         Namecheap DNS → EIP → EC2 coturn (public subnet)
         DynamoDB: device_id_claims        Aurora Serverless v2: the rest
```

| | |
|---|---|
| Cost | ~$94/month fixed before any relay (§3) — about 4× Shape A, mostly ALB + Fargate idle + Aurora's 0.5-ACU floor |
| What it buys | Rolling zero-downtime deploys, two AZs, horizontal scale, ACM instead of ACME, internal listeners reachable only inside the VPC (the `API.md` §6 `TODO`) |
| Complexity cost | VPC, subnets, NAT or VPC endpoints, task definitions, IAM task roles, a DB migration, and the three `TODO`s that multi-instance signaling opens (shared rate-limit buckets, multi-instance reconciliation, shared presence). coturn is still a hand-run EC2 box either way, so this buys managed for two thirds of the system |
| What breaks first | Nothing operational; the budget. $94/month before a single paying host is the wrong shape for a product whose principle is "near-zero at idle" |

### Recommendation

**Launch on Shape A.** It matches the code as written (single-writer SQLite, loopback internal
listeners, one TURN secret file), costs ~$25/month at idle, and the only thing it genuinely cannot
do is a deploy without a socket blip — which does not end sessions. Shape B's $69/month premium
buys redundancy for a product with no users yet.

**Trigger to move to Shape B**, any one:

1. Paying hosts > 500, or sustained concurrent metered sessions > 25.
2. `SQLITE_BUSY` appears in the rc-api logs, or the DB passes 2 GB.
3. A deploy must not interrupt signaling (i.e. the first time a redeploy is customer-visible).
4. Relay demand needs a second coturn region — at which point multi-instance signaling is
   needed anyway.

Move the claims DB to DynamoDB **before** any of these, independently: it is small, it is the
thing whose loss cannot be undone, and `API.md` §6.1 already names it.

---

## 3. Costs, computed

### 3.1 Assumptions, stated

| Assumption | Value | Why |
|---|---|---|
| Session hours per host per month | **10 h** (sensitivity at 5 h and 30 h) | Personal unattended desktop: minutes at a time, a few times a week. No measurement of our own exists — **unverified**; the `/v1/sessions` rows give the real number at milestone 3 |
| Relay bitrate, both directions | **1.5 Mbps ⇒ 0.70 GB per relayed hour**; conservative line **1 GB/h** (≈2.2 Mbps) | Measured on the one-Mac runs: 383–391 kbps (`docs/VERIFY.md`). `docs/archive/PLAN.md` §5 budget: 0.5–3 Mbps typical, 8 Mbps burst. SCOPE §8 uses ~1 GB/h. Only coturn's **egress** is charged; ingress is free, so one relayed hour costs the media bitrate once, not twice |
| Fraction of sessions that must relay | **15%**, range **10–20%** | Publicly reported WebRTC TURN-fallback rates sit around 8–20% depending on CGNAT and corporate-firewall mix — **unverified for our population**, and ours skews to home Macs on consumer ISPs, some behind CGNAT. We already record `relayUsed` per session (`API.md` §5.1), so this becomes a measured number, not an assumption, at milestone 3 |
| Free egress | First **100 GB/month** account-wide is free | AWS permanent free tier |
| Egress price | **$0.09/GB** to 10 TB, $0.085 to 50 TB (verified) | Below 10 TB in all three scenarios |

Relayed GB per month = hosts × 10 h × 0.15 × 0.70 GB = **hosts × 1.05 GB**.

### 3.2 Line items

| Line item | Unit price (verified unless noted) | 10 hosts | 500 hosts | 5 000 hosts |
|---|---|---:|---:|---:|
| Shape | | A | A | B |
| App compute | t4g.small $0.0188/h × 730 | $13.72 | $13.72 | — |
| Fargate ARM, 2 services × 2 tasks, 0.5 vCPU + 1 GB | $0.03725/vCPU-h, $0.00409/GB-h | — | — | $66.36 |
| ALB | $0.02646/h + ~$0.0084/LCU-h | — | — | $30.00 |
| coturn EC2 | t4g.small / t4g.small / 2× t4g.medium | (shared box) | (shared box) | $54.90 |
| Public IPv4 | $0.005/h each | $3.65 | $3.65 | $10.95 |
| EBS gp3 root volume, 20 GB | $0.0928/GB-month | $1.86 | $1.86 | $1.86 |
| EBS gp3 data volume, 20 GB — the two SQLite files | $0.0928/GB-month | $1.86 | $1.86 | — |
| Database | DynamoDB on-demand + Aurora SvL v2 0.5 ACU floor (**unverified**, ~$0.12/ACU-h) | — | — | $55.00 |
| DNS | Namecheap, included with the domain | $0 | $0 | $0 |
| Domain | already paid at Namecheap | $0 | $0 | $0 |
| ACM | free | $0 | $0 | $0 |
| Cognito | free ≤10 k MAU (**unverified**) | $0 | $0 | $0 |
| KMS id-cert key + signs | $1/key-month + $0.15/10 k | $1.00 | $1.23 | $3.25 |
| CloudWatch logs + 7 alarms | $0.10/alarm; ingest ~$0.57/GB (**unverified**) | $1.70 | $2.70 | $8.10 |
| CloudTrail management events, audit bucket, its Logs copy | first copy of management events free; ingest ~$0.57/GB (**unverified**) | $0.03 | $0.30 | $2.60 |
| Session Manager transcripts + their KMS key | $1/key-month; transcripts are a few MB | $1.01 | $1.01 | $1.01 |
| S3 backups | pennies | $0.20 | $0.30 | $0.50 |
| Terraform state: bucket, KMS key, lock table | $1/key-month; bucket and on-demand table are pennies | $1.10 | $1.10 | $1.10 |
| Website: S3 + CloudFront (`infra/web`) | CloudFront's 1 TB out and 10 M requests are always free; the site is a few hundred KB | $0.00 | $0.00 | $0.00 |
| **TURN egress** | GB above 100 free × $0.09 | 10.5 GB → **$0** | 525 GB → 425 × $0.09 = **$38.25** | 5 250 GB → 5 150 × $0.09 = **$463.50** |
| **Monthly total** | | **$26.13** | **$65.98** | **$699.13** |
| **Per paying host** | | **$2.61** | **$0.132** | **$0.140** |

The audit row scales with reconnections, not with hosts directly, because `kms:Sign` is
logged once per authenticated `hello` and `registry.Local.Certify` re-signs every time
(`infra/aws/README.md` "The audit trail"). At 10 hosts × 24 reconnections/day × ~1.2 KB per
CloudTrail event that is ~27 MB/month and under two cents; at 500 hosts ~450 MB/month and
about $0.26 of ingest. It stays immaterial only because the trail carries **no data events** —
adding S3 object-level events would bill the 15-minute backup `PutObject` forever.

Sanity checks on the arithmetic: 500 hosts × 10 h × 0.15 = 750 relayed hours → 750 × 0.70 GB =
525 GB. 5 000 hosts → 7 500 relayed hours → 5 250 GB, which is 10.3 concurrent relayed sessions
on average and realistically 40–60 at peak — about 90 Mbps of sustained egress, which is why
coturn is two t4g.medium at that line and not one small box.

At the conservative **1 GB per relayed hour** the relayed volume becomes hosts × 1.5 GB:
500 hosts → 750 GB, less 100 free, = $58.50 egress (total **$86.23**); 5 000 hosts → 7 500 GB,
less 100 free, = $666.00 egress (total **$901.63**). At **30 h/host/month** instead of 10, treble
the relayed volume before subtracting the free 100 GB.

For comparison, Shape A scaled to 5 000 hosts (one app box + two coturn boxes, SQLite kept) is
about **$555/month** — $140 cheaper and single-AZ with a single-writer database. That is the
honest price of Shape B's redundancy, and it is why the trigger in §2 is a condition, not a
headcount alone.

### 3.3 Does the business model hold?

Intended pricing (SCOPE §7): **$5 minimum top-up**, consumed at **cents per hour**, billed per
started minute above 60 s (`API.md` §5.2).

Variable cost of one **relayed** hour: $0.063 at 0.70 GB/h, **$0.090** at the conservative 1 GB/h.
Variable cost of one **P2P** hour: effectively zero.

Expected cost per billed hour at relay fraction *f*: *f* × $0.090 (conservative).

| Rate | Cost/billed hour at f=15% | Gross margin | Relay fraction *f* where revenue = egress |
|---|---:|---:|---:|
| $0.02/h | $0.0135 | 32% | **22%** |
| $0.05/h | $0.0135 | 73% | **56%** |
| $0.10/h | $0.0135 | 87% | **111%** (never, on egress alone) |
| $0.15/h | $0.0135 | 91% | never |

**The break point: at 5¢/hour, the unit economics stop working at about a 56% relay fraction**
(79% if the measured 0.70 GB/h budget holds rather than SCOPE's 1 GB/h). At 2¢/hour it breaks at
22%, which is inside the plausible range — **2¢/hour is not a safe rate**. At 10¢/hour egress
alone can never break it.

The real risk is not the average, it is the individual:

> A $5 top-up at 5¢/hour buys **100 hours**. A user whose sessions always relay burns
> 100 GB → **$9.00 of egress against $5.00 of revenue**. Averages do not save that account;
> the next 99 P2P users subsidise it.

So the conclusion for Phase 6 is structural, not a number: **relay must be a priced dimension.**
Everything needed is already recorded — `relayUsed` and `bytesRelayed` per session (`API.md`
§5.1), settled server-side in `server/internal/policy`. Three options, all server-side with no
client release (`API.md` §4.2): a higher per-minute rate while `relayUsed` is true; a relayed-GB
allowance per top-up; or a flat relay surcharge. Pick one in Phase 6 with the measured relay
fraction from milestone 3 in hand.

Recommended launch rate, subject to that measurement: **5–10¢/hour**, i.e. $5 buys 50–100 hours —
still visibly under AnyDesk's personal plans (SCOPE §7) with 73–87% gross margin at a 15% relay
fraction.

---

## 4. What the owner must do — in order

Nothing here can be delegated: it needs the root email, a card, or a console-only screen.
💵 marks a step that costs money.

| # | Step | Where | Cost |
|---|---|---|---|
| 1 | Sign in as the `regina` root and check whether this account already manages an AWS Organization. If it offers *Create an organization*, create one — free, and it is what keeps billing and monitoring in **one** place | `console.aws.amazon.com/organizations/v2/home` | $0 |
| 2 | Create a member account `skipperdesk-prod` inside that organization. AWS requires a globally unique root email, so use an alias of the regina inbox (`regina+skipperdesk@…`) and nothing reused elsewhere. Record the 12-digit account id | Organizations → *AWS accounts* → *Add an AWS account* → *Create an AWS account* | $0 (no card — the organization's card is used) |
| 3 | Set the billing alarm **before anything is provisioned**: monthly cost budget $50, alerts at 50% / 80% / 100% actual **and** 100% forecast, filtered to the new account id. Enable *IAM user and role access to Billing* | `console.aws.amazon.com/billing/home#/budgets` (in the management account) | $0 (first 2 budgets free) |
| 4 | Give this project a scoped identity in the new account: Identity Center → one permission set (`SkipperDeskAdmin`, AdministratorAccess **scoped to that account only**) → assign the regina user to the `skipperdesk-prod` account. **Never** reuse the `godson` profile (it reaches the frozen box) or `ReginaDeployRole` (it carries explicit denies on EC2 and Cognito) | `console.aws.amazon.com/singlesignon/home` → *Permission sets*, then *AWS accounts* | $0 |
| 5 | Add the CLI profile and confirm it resolves to the new account id, not 521831014979 and not 219702648416 | terminal — see the commands in §4.1 | $0 |
| 6 | Apple: create a **Services ID** for Sign in with Apple, a **Sign in with Apple key** (`.p8`, downloadable once), and note the key id and team id (`3UB3KZP9WH`) | `developer.apple.com/account/resources/identifiers` and → *Keys* | $0 (account already held) |
| 7 | Google: create an **OAuth 2.0 Web client** and keep the client id + secret | `console.cloud.google.com/apis/credentials` | $0 |
| 8 | 💵 Say "go". Provisioning begins — the state bucket first, then the Cognito pool, the VPC, the box, TLS and the KMS key, all Terraform, so nothing else here is yours to click | — | **≈$25/month** from this point |
| 9 | After provisioning: add two `A` records at Namecheap, `api` and `turn`, both → the Elastic IP I give you. The apex currently points at Namecheap's parking page (162.255.119.78) — leave it until there is a website | Namecheap → *Domain List* → `skipperdesk.app` → *Advanced DNS* | $0 |

### 4.1 The commands for step 5

```bash
aws configure sso --profile skipperdesk
aws sso login --profile skipperdesk
aws sts get-caller-identity --profile skipperdesk
```

`configure sso` asks for the start URL — the existing one is
`https://d-90667fa3fd.awsapps.com/start`, SSO region `us-east-1`. Choose the
`skipperdesk-prod` account and the `SkipperDeskAdmin` role, and set the CLI region to
`eu-west-2`. The third command must print the new account id.

The Cognito user pool is **not** an owner step any more: Terraform creates the pool and the
public app client, and only the Apple and Google secrets from steps 6 and 7 are pasted in (as
SSM parameters, never into a console form).

Step 3 before step 8 is deliberate: the budget alarm must exist before the first chargeable
resource. The domain is no longer a step at all — it is bought, and its DNS stays where it is.

---

## 5. What can be automated afterwards

### 5.1 Infrastructure as code — Terraform

| Option | Verdict against CLAUDE.md "minimal, audited dependencies" |
|---|---|
| **Terraform** | **Chosen.** One statically linked binary, no language runtime, no transitive package tree. Declarative, so drift is visible (`plan`), which is exactly what `infra/legacy` lacks. State in S3, versioned and SSE-KMS, locked by a DynamoDB table — Terraform 1.9.8's S3 backend has no `use_lockfile`, so the table is not optional at this version. One new dependency, named in the PR |
| CDK | Rejected. Pulls a full npm dependency tree into a repo that is about to be public and dependency-gated (`scripts/verify-deps.sh`). The security benefit of a smaller supply chain outweighs the ergonomics |
| CloudFormation | Closest to "AWS-managed first" and needs no new tool at all. Rejected on drift visibility and on how badly it handles the EC2 + userdata + coturn part. Reasonable fallback if Terraform's licence becomes a problem |
| Plain shell + AWS CLI | What `infra/legacy` did. It works and it drifted: the box's real state lives in a README, not in the repo. Keep shell only for the in-instance half (install, config render, service start), driven by Terraform userdata |

Layout: `infra/aws/` with one state per environment, plus `infra/aws/terraform/bootstrap-state`,
a separate root module with local state that creates only the backend's own bucket, key and
lock table — a configuration cannot create the bucket it stores itself in, so that first step
is a module of its own and runs once. `infra/legacy/` is not touched and not imported.

### 5.2 Secrets layout

| Secret | Store | Delivered as |
|---|---|---|
| TURN static-auth-secret | SSM Parameter Store, SecureString, `/skipperdesk/prod/turn-secret` | file, mode 0600, read via `RC_TURN_SECRET_FILE` |
| internal bearer | `/skipperdesk/prod/internal-token` | file, `RC_API_INTERNAL_TOKEN_FILE` / `RC_INTERNAL_TOKEN_FILE`. **Never the `-internal-token` flag** |
| hardware salt | `/skipperdesk/prod/hardware-salt` | env `RC_API_HARDWARE_SALT` (process-local; it must never be logged — `API.md` §9) |
| session token HMAC | `/skipperdesk/prod/token-secret` | env `RC_TOKEN_SECRET`. Set it, do not leave it random: a restart otherwise invalidates every live session token |
| id-cert signing key | **KMS**, never a parameter | KMS key id + the instance/task role. No file |
| Cognito issuer / audience | plain SSM parameters (not secret) | env |

Parameter Store over Secrets Manager: standard parameters are free, Secrets Manager is $0.40 per
secret per month, and nothing here needs managed rotation yet.

### 5.3 Zero-downtime redeploys

- **Shape A:** not truly zero-downtime, and it does not need to be. Start the new binaries on
  alternate ports, wait for `/healthz`, flip Caddy's upstream, drain, stop the old. WebSocket
  clients reconnect and `resume` (`PROTOCOL.md` §4). coturn is restarted separately and only when
  its config changes; a restart kills live relays, so do it with no metered session held
  (`GET /internal/sessions/live` answers that question).
- **Shape B:** ECS rolling deploy with a health check and `minimumHealthyPercent: 100`. Blocked
  until SQLite moves and the `PROTOCOL.md` §3.3 / `API.md` §6.2 multi-instance `TODO`s are done.

### 5.4 Dev and production run the same code

They already do, and the mechanism is worth keeping intact: `scripts/dev-backend.sh` starts the
same two binaries with the same flags, plain HTTP on loopback, `RC_ENTITLEMENT=static` or a local
rc-api, generated throwaway secrets, and `RC_API_IDP=dev`. `scripts/dev-tunnel.sh` fronts it with
a Cloudflare quick tunnel for a second Mac. Production differs in exactly these values:
`RC_API_IDP=cognito`, real TLS, real secret files, a KMS signer instead of a PEM file, and
`RC_API_SIGNAL_INTERNAL_URL` / `RC_API_INTERNAL_URL` pointing across a VPC rather than loopback.
No build tag, no `#ifdef`, no second code path. The one thing to guard: `-insecure-http` and the
`API.md` §6.3 dev-only endpoints must be impossible to enable in production — assert it in the
deploy script and in `ci-local.sh`.

---

## 6. Migration and rollback

Nobody is on the new backend, so there is almost nothing to migrate.

| | |
|---|---|
| Users to migrate | **None.** The legacy box has one user — the owner — and runs protocol **v1**. v5 is not wire-compatible with it. There is no data worth moving: no accounts, no credits, no device records that `preferredDeviceId` + an `idCert` cannot recreate |
| Rollback from the new backend | Change the app's one config value back. That is the whole rollback — this is what "backend-agnostic client" buys (SCOPE §4). A v5 app pointed at the legacy v1 box will not work, so rollback means rolling back to a v1 build, which is a release action, not an infrastructure one |
| Legacy box, during Phase 5 | Keeps running, frozen. No deploys, no config changes, no new IAM. It is the fallback *for the v1 app only* |
| Legacy box, switch-off criteria | All of: (1) two real Macs complete a session through `skipperdesk.app` including a forced relay (milestone 3 of §8); (2) the owner's own Macs run the v5 build against the new backend for 7 consecutive days with no fallback; (3) `infra/legacy/**` has been through the history-rewrite list in `docs/ROADMAP.md`; (4) `preflight.sh --verify` confirms the co-tenant `gptc` service is untouched |
| How it is switched off | Our half only: `docker compose -p rc down` in `/opt/rc-signal`, then remove the three inbound security-group rules that are ours (`8443/tcp`, `3478/tcp+udp`, `49160-49200/udp`). **The instance is not stopped or terminated** — it belongs to `gptc`, which is someone's production service |

---

## 7. Security carried over from the reviews

| Rule, and where it came from | How Phase 5 honours it |
|---|---|
| The internal listener is never public | Shape A: both internal listeners stay on `127.0.0.1`, and `RC_API_INTERNAL_LISTEN_PUBLIC` / `RC_INTERNAL_LISTEN_PUBLIC` are never set. Shape B: private subnets, security groups pinned to the peer's group only, and the `API.md` §6 mTLS `TODO` becomes due. Both binaries already refuse to start with the internal listener on the public port — keep that assertion in the smoke test |
| The internal token comes from a file, not a flag | `-internal-token-file` only. The deprecated `-internal-token` flag is visible in `ps` to every local user. Assert in the deploy script that neither binary's command line contains it |
| The TURN secret comes from a file | `RC_TURN_SECRET_FILE`, mode 0600, owned by the service user |
| The claims DB is backed up separately | Its own S3 prefix, its own schedule, never-expire retention, and it is never restored together with `rc-api.db` (`API.md` §6.1). Then move it to DynamoDB with PITR and deletion protection |
| TURN credentials are session-scoped | Unchanged in the server; infrastructure must not undo it. coturn keeps `use-auth-secret` and **no static users, ever**. Keep every anti-proxy deny from `infra/legacy/coturn/turnserver.conf`, keep `no-tcp-relay`, and raise only the quotas (`user-quota` 6, `total-quota` 12 are 1:1 values) |
| Rate limits | `PROTOCOL.md` §3.3 and `API.md` §8 are in-process token buckets. They are correct for one instance; **the moment a second instance exists they are wrong** (each instance grants the full budget). That is a blocker for Shape B, not a nice-to-have |
| Trusted proxies | Behind Caddy or an ALB, `RC_API_TRUSTED_PROXIES` / `RC_TRUSTED_PROXIES` must be set to exactly that hop's CIDR. Unset, every per-IP limit keys on the proxy and becomes global. Over-wide, anyone can spoof `X-Forwarded-For` and evade every per-IP limit |
| Dev-only endpoints | `API.md` §6.3 (`dev-topup`, `expire-trial`, `dev/releases`) exist only under `RC_API_IDP=dev`. Production runs `cognito`; assert it |
| No content on the server | `API.md` §9 and `PROTOCOL.md` §8 bound what may be logged. Do not add any log pipeline, APM agent or sidecar that captures request or WebSocket bodies |

### New in Phase 5 and never reviewed — each gets a review before it serves real users

1. KMS as the id-cert signer, and the key-rotation story that does not exist in the contract yet.
2. Cognito as a real IdP: issuer/audience validation, token lifetimes, the hosted sign-in and
   the PKCE handoff in `web/`, and the Apple/Google provider wiring. The user-session check in
   `server/internal/idp/cognito.go` requires an `email` claim and does not check `token_use`,
   which is why the website sends the ID token; both halves of that belong in this review.
5. CORS on `POST /v1/auth/link`. The website is a different origin from the API now, and rc-api
   sets no CORS headers at all — see `infra/web/README.md` and the note in `protocol/API.md` §1.2.
3. TLS termination by something other than the Go process (Caddy or an ALB), and the
   trusted-proxy/client-IP consequences above.
4. The Terraform surface itself: IAM roles, security groups, the S3 state bucket, who can assume
   what.
5. The backup and restore path, including the deliberately asymmetric claims-DB restore.
6. Any shared rate-limit store, when Shape B arrives.
7. **The `kms:Decrypt` grant on the instance role.** `Resource` is still `*` — it has to be,
   for the AWS-managed `alias/aws/ssm` key — and the whole bound is now two conditions:
   `kms:ViaService` and a `StringLike` on `kms:EncryptionContext:PARAMETER_ARN`. Confirm the
   pattern really matches only our prefix and cannot be widened by a parameter named to look
   like it; confirm no `IfExists` or set operator has crept in, either of which would allow a
   `Decrypt` carrying no encryption context at all. `infra/aws/README.md` "Secrets" records
   the verification this rests on.
8. **The audit trail as evidence.** Whether the trail can be turned off, starved or rewritten
   by anything short of account-admin: the `aws:SourceArn` conditions on the bucket policy and
   the delivery role, log file validation, the bucket being separate from the one the instance
   role writes to, and whether any later change gives that role reach into it.
9. **The sign alarm's threshold, against a measured reconnection rate.** The default is
   derived from an *assumed* 24 reconnections per host per day and a fleet-wide reconnect on
   deploy. Milestone 5.3 produces real numbers; re-derive then. Too high is silent coverage,
   too low is an alarm nobody reads — and check it is still 5-minute `Sum` with
   `treat_missing_data` that cannot mask a dead metric filter.
10. **Session logging actually writing, and the one remaining `*`.** Open a session and read
    the transcript back out of the log group — the failure mode is silence, so this must be
    observed, not assumed. Then review `logs:DescribeLogGroups` on `*`, the only unscoped,
    unconditioned action left in the instance policy, and whether
    `cloudWatchEncryptionEnabled` still agrees with the log group's key.

That is a **fifth security review**, scoped to infrastructure. It runs before the backend serves
anyone but the owner, and it is a gate on milestone 4.

---

## 8. Phased plan

Each milestone is closed by an observation, not by a passing test (`CLAUDE.md`).

| # | Milestone | What is built | Acceptance check (falsifiable) |
|---|---|---|---|
| **5.0** | Owner prerequisites | §4 steps 1–8 | `aws sts get-caller-identity` on the new profile returns the new account; `whois skipperdesk.app` shows the owner's registration; a Budgets alert e-mail has been received at least once (fire it with a $0.01 threshold, then set $50) |
| **5.1** | **Reachable and signed in** — no TURN | `bootstrap-state` first, then Terraform against it: VPC, one t4g.small, EIP, the root volume and the separate data volume, Caddy, rc-api + rc-signal, Cognito, KMS id-cert key, backups, logs, the audit trail and session logging, 7 alarms | From a Mac with no local backend: `curl https://api.skipperdesk.app/v1/health` returns `200` with a publicly trusted chain and no cert exception; one real Mac completes the §1.1 link flow in a browser, `register` mints a Device ID, `GET /v1/entitlement` returns `trial`. `curl https://api.skipperdesk.app/internal/entitlement/<id>` returns **404**. On the box, `findmnt /var/lib/skipperdesk` shows the data volume and `systemctl show -p RequiresMountsFor rc-api` names it; `terraform state pull` reads from S3, not from a local file |
| **5.2** | **TURN exists** | coturn on the same box, EIP, `turn.skipperdesk.app`, secret in SSM, anti-proxy config carried over, quotas raised | A metered session pushes `ice_servers` with a TURN entry whose `username` is `<expiry>:<sessionId>` and `expiresAt` ≈ now + 10 min (`PROTOCOL.md` §2.18); the same credential is **refused** by coturn after `bye`; a TURN allocation to an RFC1918 peer is refused |
| **5.3** | **Cross-network and relay proof** | Nothing new — the ROADMAP's queued item #1, which needed TURN. A cloud peer stands in for the second Mac | Two endpoints on two different networks hold a session through `skipperdesk.app`; then one is forced onto the relay (block UDP to the peer / `iceTransportPolicy: relay`) and the session still works, with the `/v1/sessions` row showing `relayUsed: true` and a non-zero `bytesRelayed`. **Record the relay fraction and the measured GB/hour — §3's assumptions are replaced by these numbers** |
| **5.4** | **Fifth security review** (infrastructure) | The ten items in §7 | No HIGH or CRITICAL finding outstanding |
| **5.5** | **Cutover** | Owner's Macs on the v5 build against the new backend; `relayUsed` and cost dashboards live | 7 consecutive days with no fallback to the legacy box, and the §6 switch-off criteria all true. Then our half of the legacy box is stopped and its three security-group rules removed — the instance itself is left alone |

`TODO:` revisit §3 the day milestone 5.3 produces a real relay fraction. Everything in §3.3
hangs off that one number.
