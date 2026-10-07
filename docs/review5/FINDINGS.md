# Fifth security review — infrastructure, deployment, website, authentication, relay, money

## Verdict

**No — do not send a stranger this link yet.** Three things must change first.

1. **A 59-second session is free, at any balance, forever** (`policy.go:76-82`). The connect limits
   allow 60 sessions/hour, so one 50¢ trial grant buys ~98% of every hour of relay, free, for ever.
   This defeats the entire new billing model and is live today.
2. **Relay egress is uncapped, unalarmed and unattributable.** No `bps-capacity`, no `max-bps`, no
   `NetworkOut` alarm, a $50 budget that only emails at 80% with up to 24 h of lag, and a coturn
   log holding **zero** allocation lines — so abuse is invisible and cannot be traced to an account.
3. **Account identity is the email string, not the Cognito `sub`** (`apidb.go:362-366`), and
   `email_verified` is never checked. Harmless on today's pool (I verified why) and an account
   takeover the day Apple or Google sign-in is enabled.

Reassuringly, **there is no link yet**: `/download/` is 404 and the release feed is empty, so the
window to fix these is free. Fix #1 first — it is a four-line change.

---

**Tree reviewed:** `5c4e0a6`, which was `main` when this review started.
**The money path changed under me.** Nine commits landed on `main` during the review
(`fe839f5`…`a1aaa98`): 10¢/hour with an exact carry, a non-negative ledger invariant inside a
transaction, metering that clamps to the balance and closes the session, and the trial as a 50¢
grant expiring in 14 days. I re-checked every money finding against the new `main` and have
**rewritten, re-rated or withdrawn** them accordingly; each says which tree it applies to. Three
findings the new work closed are recorded under "Closed by the money work" rather than dropped.

**Gates, on `5c4e0a6`:** `SKIPPER_TEAM_ID=3UB3KZP9WH ./scripts/ci-local.sh` → exit 0,
`PREFLIGHT PASSED`. `./scripts/check-isolation.sh` → exit 0, `ISOLATION CHECK PASSED`.

---

# CRITICAL

## C1 — A 59-second session is free at any balance, so one trial grant buys unlimited relay

**Applies to current `main`.** The new money work did not change this.

**Attack.** Anyone with an email address. Sign up (self-service), link one Mac, receive the 50¢
grant. Host sessions and tear each one down at 59 seconds. Every session is billed zero and does
not even touch the carry, so the balance never moves, the balance floor never trips, the
clamp-and-close never fires, and the grant is never consumed. Relay egress is billed to the owner
throughout.

**Evidence.** `server/internal/policy/policy.go:76-82` on `main`:

```go
// Below FreeSessionLength a session is free and does not touch the carry.
func Charge(d time.Duration, carry int64) (cents, newCarry int64) {
	if d < FreeSessionLength {
		return 0, carry
	}
```

`FreeSessionLength = time.Minute` (`policy.go:23`). The settle path returns early on a zero charge,
so no ledger row is written and the un-charged time leaves no trace at all
(`apisrv/entitlement.go:272-275` at the reviewed commit: `if charge <= 0 { return nil }`).

The connect budget permits enough sessions to cover the clock — `protocol/protocol.go:31-36`:

```
ConnectPerControllerPerMin  = 6     ConnectPerHostPerMin  = 30
ConnectPerControllerPerHour = 60    ConnectPerHostPerHour = 300
```

60 sessions/hour × 59 s = 3540 s = **98.3% of every hour, billed zero**, per controller device; a
host accepts 300/hour. The entitlement gate needs only `BalanceCents >= MinBalanceCents` (1 cent,
`policy.go:18`), which the 50¢ grant satisfies permanently because nothing ever debits it.

**Remedy.** The free window must be an allowance, not a per-session property. Either (a) carry the
un-charged duration on the account the way cents are now carried — add it to the carry instead of
returning `0, carry`, so sixty 59-second sessions cost the same as one 59-minute session; or (b)
keep a per-account daily free-seconds budget and charge from second one once it is spent. (a) is
four lines and fits the carry mechanism the money work just built.

---

# HIGH

## H1 — Relay egress is uncapped, unalarmed and unattributable

**Attack.** The holder of any TURN credential — which means any entitled host, which by C1 means
anyone with an email address — pushes arbitrary traffic between public addresses for as long as
they like. The owner pays ~$0.09/GB and cannot discover who did it.

**Evidence, from the live box.** `bps-capacity` and `max-bps` are both **absent** from
`/etc/turnserver.conf` (grep count 0 for each). `user-quota=12` and `total-quota=200` bound
*concurrent allocations*, not bytes, and the username rotates every 10 minutes (`auth.go:180`), so
`user-quota` is effectively per-session.

No alarm covers it: `aws cloudwatch describe-alarms` returns exactly 5 — `api-5xx`,
`disk-used-data`, `disk-used-root`, `host-unreachable`, `id-cert-signs`. A query for any
network/egress/relay alarm returns `[]`. The budget is **alert-only**:
`describe-notifications-for-budget --budget-name skipperdesk-prod-monthly` → `ACTUAL >80%` and
`FORECASTED >100%` of a $50 monthly budget; `describe-budget-actions-for-budget` → `{"Actions": []}`.

And nothing records it. Over the whole live `turnserver.log`:

```
$ grep -cE 'usage:|rb=|sb=|allocat' /var/log/turnserver/turnserver.log
0
```

`simple-log` with no `verbose`, `no-cli` set, and the Ubuntu build has no prometheus support
(`turnserver -h | grep -c prometheus` → 0). Server-side the columns are never written either —
`PHASE5.md` §8.2 is still current: `hub/hub.go:358-359` sets neither `RelayUsed` nor
`BytesRelayed`, and `apisrv/entitlement.go:252` passes them explicitly empty. So **every
production row reads `relayUsed: false, bytesRelayed: NULL`.**

**Worst case, computed.** A relay spends NIC capacity twice per carried byte. t4g.small baseline
network is 0.128 Gbps, so sustained carried ≈ 64 Mbps ⇒ billed egress ≈ 28.8 GB/hour ≈
**$2.59/hour ≈ $62/day**. The 100 GB free tier goes in ~3.5 h; the $50 budget's 555 GB in ~19 h. On
burst credits the opening stretch is far worse. Because Cost Explorer lags up to ~24 h and the
first email is at 80% of $50, the owner's first signal can arrive after well over $60 is spent —
and it is an email that stops nothing.

**Remedy.** Set `bps-capacity` (box-wide) and `max-bps` (per allocation) from the measured relay
rate milestone 5.3 is meant to produce; add an `AWS/EC2 NetworkOut` alarm on this instance wired to
`skipperdesk-prod-alarms`; add a budget *action* or an SNS-triggered Lambda that can stop coturn.
Turn on coturn's own session accounting and ship the allocation lines with the username — the
username already carries the session id, which joins to `/v1/sessions` and hence to an account.
That one change makes abuse attributable *and* makes `bytesRelayed` a server-side fact, which
milestone 5.3 already owes.

## H2 — Account identity is the email string, not the IdP subject; `email_verified` is unchecked

**Proved in code and by test. NOT exploitable on today's deployment — I verified exactly why.**

**Attack.** A user holding any Cognito identity whose ID token carries the victim's `email` claim
lands on the victim's SkipperDesk account: reads the ledger and balance, drains it by gift, unlinks
devices.

**Evidence.** `server/internal/apidb/apidb.go:362-366` resolves by email and **ignores the subject
entirely** when a row exists:

```go
func (d *DB) EnsureAccount(accountID, email string, now time.Time) (*Account, error) {
	email = NormaliseEmail(email)
	if a, err := d.AccountByEmail(email); err == nil {
		return a, nil
	}
```

`server/internal/idp/cognito.go:92-99` has no `email_verified` field at all, and `:81-84` requires
only that the claim be non-empty. Gift ownership is email-keyed too (`credits.go:258`:
`owns := gift.ToEmail == account.Email`). Reproduced with a second subject carrying the victim's
email through a non-dev IdP:

```
second subject, same email -> 200 {"balanceCents":5000,...}
accountId before=acct_b8fa... after=acct_b8fa..., balance seen by the second subject=5000
```

**Why it is safe today** — the live pool makes two subjects with one email impossible:

```
$ aws cognito-idp describe-user-pool --user-pool-id eu-west-2_FHPTY1QI1
"UsernameAttributes": ["email"],  "AutoVerifiedAttributes": ["email"],
"VerificationMessageTemplate": {"DefaultEmailOption": "CONFIRM_WITH_CODE"},
"UserAttributeUpdateSettings": {"AttributesRequireVerificationBeforeUpdate": ["email"]},
"LambdaConfig": {}
$ aws cognito-idp list-identity-providers --user-pool-id eu-west-2_FHPTY1QI1
{"Providers": []}
$ aws cognito-idp describe-user-pool-client ... --query 'UserPoolClient.SupportedIdentityProviders'
["COGNITO"]
```

Email is the username, so it is unique; there is no linking Lambda; no federated provider exists.
**It arms the day Apple or Google is enabled** — which `PHASE5.md` §1 plans — because a federated
sign-in creates a *separate* `sub` with the *same* email and no linking Lambda to merge them.

**Remedy.** Key the account on `sub` (unique index on `account_id`, email as a mutable attribute);
require `email_verified == true` in the verifier; resolve gift ownership through the account id
captured at acceptance rather than a live email comparison. Three small changes, all before the
first federated provider. There is no test for either half today (`idp/cognito_test.go` covers
`token_use`, issuer and expiry only).

## H3 — An orphaned gift row mints spendable credit when its debit is refused

**Applies to current `main`, and is a consequence of the new invariant. NOT reachable in production
today — see below.**

At the reviewed commit this was a clean CRITICAL: `credits.go:166-191` read the balance, decided,
then debited with no transaction, and concurrent gifts each passed the check and each debited.
Reproduced: `$5 in, $30 of spendable credit out` (`balance now = -2500 cents`,
`net system credit=500c`, 8–12 concurrent requests, fired on ~8 of 20 runs).

**`main` closed the overdraft but not the leak.** `apidb.go:937-948` now wraps the append in a
transaction and `appendTx` refuses `balance+amountCents < 0` with `ErrInsufficientBalance`, and
computes `balance_after_cents` inside the same transaction. But `createGift` still writes the gift
row **before** debiting (`credits.go:183` then `:187`), and the refusal path is a bare 500:

```go
if err := s.opt.DB.PutGift(gift); err != nil { s.internalError(w, r, err); return }
if _, err := s.opt.DB.Append(account.AccountID, protocol.LedgerGiftSent, -gift.AmountCents,
	now, "", gift.GiftID, "gift held"); err != nil { s.internalError(w, r, err); return }
```

So when two concurrent gifts both pass the stale check at `:171` and the second is refused, a
`pending` gift row survives with **no matching debit**. It becomes real credit two ways: the
recipient accepts it (`Append(+amount)`, `credits.go:299`), or — with no attacker action at all —
it expires and is refunded to the sender who never paid (`apidb.go:1241-1248` appends
`LedgerGiftRefund` for every expired pending gift, unconditionally). The idempotency wrapper
releases the key on 5xx, so it is freely retryable.

**Why it is not reachable in production today.** `MinGiftAmountCents = 500` (`protocol/api.go:61`),
the trial grant is 50¢, and the only credit source is `devTopup`, which is dev-only and **proved
404 on the live API**. No payment rail exists anywhere (a repo-wide search for a payment provider
finds nothing). No production account can hold 500 cents, so `createGift` always refuses at `:171`
with 402. **It arms the day a top-up rail lands** — API.md §7.4's planned webhook is exactly that
day.

**Remedy.** Write the gift row and its debit in one transaction (an `appendTx` sibling that also
inserts the gift), and make the expiry refund conditional on a matching `gift_sent` debit existing.
Also drop the now-redundant balance read at `credits.go:166`: it cannot gate anything the
transaction does not gate better, and leaving it invites exactly this shape again.

## H4 — Trials are unlimited: the trial gate is a client-supplied string

**Attack.** A stranger generates a fresh P-256 keypair, registers it, links it, and sends any
`hardwareId` they like. Trial granted. Repeat.

**Evidence.** `apisrv/auth.go:193` requires only that `hardwareId` be non-empty; `:242` hashes
whatever arrived; `policy.go:47` is
`GrantsTrial(pubkeySeen, hardwareSeen) { return !pubkeySeen && !hardwareSeen }` — **both inputs are
attacker-chosen.** `server.go:339-343` HMACs it with a server salt, which prevents offline
correlation but not client choice. Reproduced:

```
device 0 (888299249): status=trial ... device 4 (589192226): status=trial
TRIAL FARMING PROVEN: 5 fresh trials on one account from client-chosen hardwareIds
```

This contradicts `SCOPE.md` §5 ("made expensive by the serial hash" — nothing makes it expensive)
and §6 ("the device rules make trial farming pointless").

**Bounds, and how the money work changed them.** The old 7-day unlimited trial made each farmed
account worth unbounded hosting. The 50¢ grant at 10¢/hour caps a farmed account at 5 hours — a
genuine improvement. The practical ceiling is now Cognito's default email sender
(`EmailConfiguration.EmailSendingAccount: COGNITO_DEFAULT`, a documented ~50 messages/day) and
`RegistersPerIPPerHour = 20`. Plus-addressing yields unlimited distinct usernames from one mailbox
(`NormaliseEmail` is lowercase+trim only, `apidb.go:333`). **But C1 removes the 5-hour cap
entirely**, which is why C1 is the first fix and this is second.

**Remedy.** The trial cannot be keyed on anything the client asserts. Key the grant to a verified
account (one grant per `sub`, per H2) and make the device rule a cap on *devices per account*
rather than a second grant. Keep `hardwareHash` as a review signal only. Note separately that
`COGNITO_DEFAULT` at ~50 emails/day is also a hard ceiling on *legitimate* public sign-ups and has
no bounce handling — move to SES before any public link.

## H5 — The device-ID claims database has never been backed up, and the failure is silent

**Attack.** None needed; this is a data-loss exposure. `PHASE5.md` §1.2 makes the claims DB the
second line of defence behind the id-cert key: losing it "lets an ID be reissued to a second key",
and losing both is Device-ID takeover.

**Evidence.**

```
$ aws s3 ls s3://skipperdesk-prod-backups-388699643285/claims/ --recursive | wc -l
       0
$ aws s3 ls s3://skipperdesk-prod-backups-388699643285/db/ --recursive | wc -l
      30
$ aws s3api list-object-versions --bucket ... --prefix claims/
{ "RequestCharged": null, "Prefix": "claims/" }        # zero versions; nothing deleted either
```

The unit fired and **reported success**: `Result=success`, `ExecMainStatus=0`,
`LastTriggerUSec=Wed 2026-10-07 08:45:02 UTC`, next run 00:05 tomorrow. The cause is
`infra/aws/cloud-init/backup.sh:23-26` — `if [[ ! -s "$SOURCE" ]]; then echo "note …"; exit 0; fi`.
At 08:45 the box had been up 10 minutes and `rc-api-claims.db` did not exist yet (it is dated
10:31). Worse, `backup.log` holds one `note` line and it is for the *other* database, so the claims
run left no trace at all. Note the inversion even at steady state: the recoverable database gets a
15-minute RPO, the irreplaceable one gets 24 hours.

**Remedy.** Make "nothing to back up" a non-zero exit once the service has started, so
`Result=success` stops lying; add a CloudWatch alarm on the **age of the newest `claims/` object**
(the only check a unit exiting 0 cannot fool); put the claims DB on the same 15-minute cadence —
its "own schedule" requirement is about never restoring it *together* with the main DB, not about
being rarer; then do the API.md §6.1 move to DynamoDB with PITR and deletion protection.

## H6 — The real administrative path is unlogged, and one un-MFA'd identity can erase the evidence

Two sides of one weakness.

**Unlogged.** Session Manager is configured to stream transcripts, but the path actually used is
Run Command, which is not covered. CloudTrail deliberately redacts the payload:

```
"documentName":"AWS-RunShellScript","parameters":"HIDDEN_DUE_TO_SECURITY_REASONS",
"cloudWatchOutputConfig":{"cloudWatchLogGroupName":"","cloudWatchOutputEnabled":false}
```

The session preferences document only covers `Standard_Stream`, and the group has never held
anything: `describe-log-streams --log-group-name /skipperdesk/prod/sessions` → `{"logStreams": []}`,
`describe-sessions --state History` → `{"Sessions": []}`. `/skipperdesk/prod/app` and
`/cloudtrail` both have current streams, so CloudWatch Logs itself works. The production release
publisher uses `send-command` too (`scripts/publish-release.sh:227`), so the unlogged path is also
the documented one. This **contradicts `PHASE5.md` §1's "Session Manager is the *entire*
administrative path"**, and §7 item 10's observation would miss the path that matters.

**Un-MFA'd.** The admin session in every CloudTrail record carries `"mfaAuthenticated":"false"`, and
the role holds `AdministratorAccess` with no SCP above it. There is no Object Lock on any bucket
(`ObjectLockConfigurationNotFoundError` on audit, backups and tfstate),
`"IsOrganizationTrail": false`, and both KMS key policies grant `kms:ScheduleKeyDeletion` to the
account root. So one password can `StopLogging`, delete every object version in the audit bucket,
schedule the id-cert key for deletion, and run root shell leaving no transcript.
`OrganizationAccountAccessRole` additionally trusts `arn:aws:iam::521831014979:root` with **no** MFA
or `ExternalId` condition, so control of the management account is control of this one.

**Remedy.** Require MFA on the `SkipperDeskAdmin` permission set. Deny `ssm:SendCommand` on
`AWS-RunShellScript` so the streamed interactive path is the only ad-hoc one, and publish a narrow
customer-owned document for the one automated caller. Add an SCP in the management account denying
`cloudtrail:StopLogging|DeleteTrail`, audit-bucket policy writes and `kms:ScheduleKeyDeletion`.
Make the trail an organization trail delivering to the management account, and enable Object Lock
on the audit bucket.

## H7 — A lost start report makes a session permanently free

**Attack.** Any session whose host relays its first `sdp` while rc-api is unreachable for ~8
seconds runs for its whole life with no billing row. Not directly triggerable by a stranger, but it
couples revenue to availability, and `MaxPending = 10000` gives a farm a way to force it at volume.

**Evidence.** `reports/reports.go:165-190` retries 6 times to an 8 s cap then gives up, and
`OnDenied` — the only path that un-meters and closes the session (`hub/hub.go:335-342`) — fires
**only** for `ErrDenied`:

```go
if ev.start != nil && errors.Is(err, ErrDenied) && q.opt.OnDenied != nil {
```

A 5xx or transport failure is neither `ErrPermanent` nor `ErrDenied`, so the start is dropped while
`s.metered` stays true, relaying continues, and session-scoped TURN keeps being issued
(`handle.go:681-694`). The later stop report 404s and is discarded as permanent
(`apisrv/entitlement.go:159-162`), and reconciliation iterates `DB.OpenSessions()`, which has no
row. Reproduced:

```
starts delivered=0 stops delivered=1 onDenied=[]
SESSION HELD WITHOUT A BILLING ROW: the start was dropped, the hub never un-metered the session
```

**Remedy.** Treat a start report that exhausts its budget exactly like `ErrDenied` — call
`OnDenied` for any undelivered start — or make a delivered start a precondition for issuing
session TURN.

---

# MEDIUM

**M1 — IPv4-mapped IPv6 peers bypass the coturn deny list. SUSPECTED (source-reasoned, not
observed); would be CRITICAL if IPv6 is ever enabled.** This is the `PHASE5.md` §8.1 family of bug
the brief asked me to hunt, and it is present. coturn 4.6.1's `addr_less_eq` returns
`(family1 < family2)` when families differ, so for an AF_INET6 peer tested against an AF_INET deny
range the lower bound passes and the upper bound fails — **no IPv4 deny range matches any IPv6
peer.** `::ffff:127.0.0.1` also evades `ioa_addr_is_loopback`, whose AF_INET6 branch requires
`u[15]==1` with `u[0..14]` zero. No IPv6 deny entry covers `::ffff:0:0/96` and there is no
`allowed-peer-ip` to consult, so `good_peer_addr` returns allowed. **What saves it today is
unrelated:** the box has no global IPv6 and no `relay-ip`, so the AF_INET6 relay-socket lookup
fails and coturn answers 443. The policy does not stop this; the missing socket does. With an IPv6
relay socket, a credential holder reaches `127.0.0.1:18081` — the internal rc-api listener — and
IMDS. *Fix regardless of the check:* add `denied-peer-ip=::ffff:0:0-::ffff:ffff:ffff`. **Do not
re-add `denied-peer-ip=::`** (§8.1). *Exact check:* allocate, `CreatePermission` with
XOR-PEER-ADDRESS family `0x02` and value `::ffff:7f00:0001`, then a Send indication carrying
`GET /internal/entitlement/000000000`. Safe outcome is 443/403; any data returned is CRITICAL.
`turnprobe` cannot do this as written — `turnwire/turnwire.go:161` calls `addr.Unmap()`, rewriting
a mapped address back to family `0x01` before it reaches the wire.

**M2 — The relay will relay to itself.** `3.8.76.202` is in no denied range and the security group
opens 80, 443, 3478 and 49160-49200 to the world. Two allocations pointed at each other's relayed
addresses circulate a packet with the attacker disconnected, billing egress the whole time.
*Fix:* `denied-peer-ip=3.8.76.202` and `denied-peer-ip=10.20.1.185`. **SUSPECTED** — needs a
credential to confirm; watch `NetworkOut` for 60 s with the client disconnected.

**M3 — Cross-tenant device presence enumeration and a billing-state oracle.** The hub has no
concept of accounts: `byDevice`, `presence`, `watchers`, `devSess`, `knownPairs`
(`hub/hub.go:71-77`) are keyed on a global device id. `handleWatchLocked`
(`hub/handle.go:331-350`) accepts any 9-digit id, **charges no rate limit at all**, and answers
with presence; ids are ~29.7 bits. Worse, `connect_req` relays the *host account's* entitlement
reason to the *controller* (`handle.go:472-474`), so anyone knowing a device id learns whether that
stranger is out of credit, suspended, or in a session elsewhere — which also breaks the repo's own
rule about never showing users backend internals, applied to other people's. *Fix:* rate-limit
`watch` per controller, and collapse the controller-visible refusal to one opaque reason.

**M4 — Unknown-`kid` JWTs force a JWKS refetch per request, before any rate limit. PROVED.**
`cognito.go:123-128` gates on `if ok && fresh` — both — so an unknown kid **always** refetches even
with a warm cache, and `authLink` verifies the token (`auth.go:55`) *before* `s.allow(...)`
(`auth.go:59`). Live differential, 6 requests: `alg:none` control 0.073/0.071/0.071 s; RS256 with a
fresh random kid 0.123/0.092/0.112 s, with no speed-up on repeat. Unauthenticated outbound
amplification at 5 s per fetch; if Cognito throttles past the 10-minute TTL, real sign-ins fail.
*Fix:* negative-cache unknown kids, refetch at most once per TTL, rate-limit before verifying.

**M5 — Whoever can write one object to the web bucket owns the sign-in flow, and nothing records
it.** `link.js:234` navigates to `CONFIG.cognitoDomain` with **no allowlist** — `usable()`
(`:179-181`) only checks the values are non-empty — so a 184-byte `config.js` replacement yields a
Cognito-lookalike password prompt on the genuine HSTS-pinned origin. CSP cannot help: `connect-src`
governs `fetch`, not a navigation, and `form-action` does not govern `location.replace`. Both edge
logs are off (`Logging.Enabled: false`; `get-bucket-logging` empty), so there would be no record;
bucket versioning is on, which is the saving grace. *Fix:* in `link.js`, refuse unless
`cognitoDomain` matches `^https://[a-z0-9-]+\.auth\.[a-z0-9-]+\.amazoncognito\.com$` and `apiBase`
equals the expected origin — turning an origin write into a visible outage rather than a credential
harvest. Also enable CloudTrail S3 **write** data events on this one bucket.

**M6 — The web bucket policy pins the account, not the distribution.** The only condition is
`"AWS:SourceAccount":"388699643285"` (`infra/web/terraform/bucket.tf:30-34`), so any CloudFront
distribution in the account could read the bucket and serve the site **without** the
response-headers policy — re-opening framing of `/link` and Referer leakage. Not exploitable today
(the only principals that satisfy it are already account-admin; the instance role has no CloudFront
permissions and no reach into the web bucket). It arms with the first scoped role that gets CDN
permissions. The repo's stated reason — a Terraform cycle — is real but resolvable by moving the
policy into a standalone `aws_s3_bucket_policy` referencing the distribution ARN. *Fix:* add
`AWS:SourceArn` pinned to `distribution/E9V8GS26I6JON`.

**M7 — The instance role can read the Apple `.p8` and Google client secret it has no use for.**
`iam.tf:26-30` grants `ssm:Get*` on `parameter/skipperdesk/prod/*`, and
`simulate-principal-policy` confirms `apple-private-key` and `google-client-secret` resolve
`allowed`. The box needs four values; these are Cognito's, and the Apple key's compromise is not
contained by rebuilding the instance. MEDIUM only because all six social parameters are still
`placeholder-set-out-of-band` at `Version: 1`. **Related and real:** enabling social sign-in puts
the Apple `.p8` and the Google client secret into Terraform state in cleartext, because
`cognito.tf:138` passes `client_secret` as a literal argument — exactly the risk `PHASE5.md` §1
records. *Fix:* split `/skipperdesk/prod/instance/*` from `/skipperdesk/prod/idp/*` and narrow both
the `ssm:Get*` resource and the `kms:EncryptionContext:PARAMETER_ARN` pattern; create the social
parameters with `ignore_changes = [value]` (or the provider's write-only `value_wo`) and write the
real values out of band, so nothing lands in state.

**M8 — Systemd units and binaries come from S3 with no integrity check.** `bootstrap.sh:117-119,
208-227, 239-246` copies `config/` from the backups bucket and `install`s `rc-api.service`
(so `ExecStart=` is whatever the object says), then untars `releases/current.tar.gz` into
`/opt/skipperdesk/bin` and runs it. No checksum, no signature. The instance role cannot poison them
(`PutObject` is scoped to `db/*` and `claims/*`), so the write capability is admin-only today — but
the deploy artifact is trusted on bucket ACLs alone, and it shares a bucket with the target the box
writes to, the very coupling `PHASE5.md` §1 is careful to avoid for the audit trail. *Fix:* a
read-only bucket for `config/` and `releases/`, a detached sha256 written by `deploy.sh` and
verified by `bootstrap.sh`, and a loud boot failure on mismatch.

**M9 — `sshd` is listening on 0.0.0.0:22.** `ss -ltnp` shows `0.0.0.0:22` and `[::]:22` held by
`systemd` (`ssh.socket` enabled). The security group does not permit it — inbound is exactly 80,
443, 3478/tcp, 3478/udp, 49160-49200/udp — so "no inbound SSH" is enforced in exactly one place,
and one `AuthorizeSecurityGroupIngress` undoes it. *Fix:* `systemctl disable --now ssh.socket`;
Session Manager does not use it.

**M10 — The production SQLite databases are world-readable on the box.**
`644 skipperdesk:skipperdesk` on both `rc-api.db` and `rc-api-claims.db` (and `644 root:root` on
`rc-api.log`), while the two real secrets beside them are correctly `0600` — so the inconsistency
looks accidental. The `0750` parent directory blocks traversal today. Any service compromise
landing as `caddy` or `turnserver` would read every account, token and ledger row. *Fix:*
`umask 027` for the service, or an explicit `chmod 0640` in `bootstrap.sh`.

**M11 — Five of seven declared alarms exist, and the one that matters most can be masked.** No
rc-signal `/healthz` alarm — signaling can be down with nothing paging. The `id-cert-signs` alarm
is correctly 5-minute `Sum` at threshold 60, but `treat_missing_data: notBreaching`, so a metric
filter that stops matching leaves it `OK` for ever — the "silent coverage" §7 item 9 asks about.
*Fix:* add the rc-signal alarm; keep `notBreaching` (right polarity for an excess alarm) but add a
companion liveness alarm — `IdCertSignatures Sum < 1` over 24 h with `treat_missing_data: breaching`.

**M12 — One tenant's gift expiry sweep runs on every other tenant's request.**
`ExpirePendingGifts` (`apidb.go:1222-1251`) scans the whole table with no account filter and is
called from `GET /v1/credits`, `GET /v1/credits/gifts` and accept. On the single SQLite connection,
one tenant with many expired gifts degrades everyone. Its loop is also non-atomic: `SetGiftStatus`
then a separate `Append`, so a restart between them expires a gift and never refunds it. *Fix:*
move it to the existing `purge` goroutine and wrap status+refund in one transaction.

**M13 — The new ledger invariant relies on the connection limit, not the isolation level.**
`apidb.Append` uses `d.db.Begin()` — a *deferred* `BEGIN`, which in SQLite takes its write lock
lazily. It is safe today only because `sqlitex.go:19` sets `SetMaxOpenConns(1)`, so two
transactions cannot interleave. If that limit is ever raised — and `PHASE5.md` §1.1's move-triggers
contemplate exactly that — a deferred `BEGIN` returns `SQLITE_BUSY` rather than serialising, and
the read-then-insert in `appendTx` can interleave again. *Fix:* `BEGIN IMMEDIATE` for every
transaction that reads a balance before writing, so the guarantee is in the isolation level rather
than in a pool setting.

---

# LOW

| # | Finding | Evidence | Fix |
|---|---|---|---|
| L1 | The `www` redirect double-encodes every percent-escape, so a hand-typed `/link` dead-ends. The app's own `device=` carries `%2B`/`%3D` (`AccountLinker.swift:438-442` removes `+&=?#` from the allowed set), which `PUBKEY_PATTERN` then rejects | `foo=b%20ar` comes back as `foo=b%2520ar` in `location:`; `functions/fixup.js:18-19` re-encodes an already-encoded value. CRLF is neutralized (`%250d%250a`) — no header injection, no open redirect | Pass the value through; encode only the name. Iterate `multiValue`. Add a vector with `%2B`/`%2F`/`%3D` through `www` |
| L2 | No HSTS, `nosniff` or `X-Frame-Options` on `api.skipperdesk.app` | `curl -sSI https://api.skipperdesk.app/v1/health` → none present (TLS verifies, HTTP/2) | Add a header block to the api vhost in the Caddyfile |
| L3 | `Append` has no amount clamp and no overflow guard; a wrapped `balance_after_cents` eventually makes SQLite's own `SUM()` fail, after which `/v1/entitlement` returns 500 for that account **permanently** | `after +4611686018427387904: balanceAfterCents=-9223372036854775807`, then `SQL logic error: integer overflow (1)` | Clamp at the API edge and use checked addition. Matters the day API.md §7.4's webhook lands |
| L4 | `fixup.js` appends `/index.html` to any dotless path, so `/.well-known/acme-challenge/<token>` 404s | `functions/fixup.js:37-38` | Return early for `/.well-known/` |
| L5 | The `releases/` lifecycle expires at 30 days, including `current.tar.gz`, so an instance replaced after a quiet month boots with no binaries and only a `note` | Lifecycle rule `releases` `Expiration: {Days: 30}` vs `bootstrap.sh:239-246` | Exclude `current.tar.gz`; make a missing artifact a hard boot failure |
| L6 | `-insecure-http` disables the "no id-cert key" refusal, so production (which must pass it, Caddy terminates TLS) has that guard off; only a non-empty key id stands between prod and an ephemeral CA | `idcert.go:99-101`; not reachable today because `instance.tf:22` uses `aws_kms_key.id_cert.arn`, a resource reference that cannot render empty | Separate the concerns: require an explicit `-id-cert-ephemeral` opt-in |
| L7 | Open unauthenticated STUN responder with RFC 5780 attributes served | `secure-stun` and `no-rfc5780` both absent | Set `no-rfc5780`. `secure-stun` is not free — the product needs public STUN |
| L8 | The four per-IP buckets are shared by everyone behind one address: a NAT'd office gets 10 device links/hour in total | `ratelimit.go:17-36`; `token_ip` 10/h | Key on the device key where one exists; raise the per-IP ceilings |
| L9 | `NormaliseEmail` folds Unicode case without NFKC, collapsing distinct addresses (`U+212A` to `k`, `U+0130` to `i`). **SUSPECTED** — whether Cognito would ever issue such an email claim is unverified | `apidb.go:333` is `ToLower(TrimSpace(s))` | NFKC before folding (do it with H2) |
| L10 | `OrganizationAccountAccessRole` trusts the management account with no MFA or `ExternalId` condition | `{"Principal":{"AWS":"arn:aws:iam::521831014979:root"},"Action":"sts:AssumeRole"}` | Add an MFA condition; state the dependency in `infra/aws/README.md` |
| L11 | `publish-release.sh` only `WARN`s when the download page does not link the image being published, so a release can announce one image while the page offers another | `scripts/publish-release.sh:276-284` | Promote to `FAIL`; `--dmg` already refuses to overwrite an immutable key |
| L12 | Caddy runs with `--environ`, printing its whole environment at startup; `caddy.env` is `0644` where the other two env files are `0600`. **SUSPECTED** — I did not read the journal to confirm what was printed; the four values are believed non-secret | `/usr/bin/caddy run --environ …` | Drop `--environ`; make the mode consistent |

---

# Closed by the money work that landed during this review

Recorded so they are not re-found, and because the fixes are load-bearing for C1 and H3.

- **Concurrent debits could take a balance arbitrarily negative.** Closed: `appendTx`
  (`apidb.go:950-965`) now reads the balance and refuses `balance+amountCents < 0` **inside the
  same transaction** as the insert. Reproduced at `5c4e0a6` as `balance now = -2500 cents`; the
  invariant now prevents it. See M13 for the one caveat.
- **`balanceAfterCents` was wrong under concurrency**, so the ledger could not be used to detect a
  double-spend after the fact (API.md §7.2 promises it is self-checking). Observed at `5c4e0a6`:
  16 concurrent appends produced 9 distinct `balanceAfter` values for 17 entries. Closed: it is now
  computed inside the transaction.
- **A session was gated once and never again — 1 cent bought a 48-hour session.** Observed at
  `5c4e0a6`: `balance after a 48 h session that began with 1 cent: -2879 cents`, nothing cut it
  off. Closed: metering now clamps to the available balance and closes the session. **C1 is the
  residue**: the clamp cannot fire on a charge that is always zero.

---

# Checked and found sound

This list is evidence too — most of this system held up under attack.

**The authentication path.** The strongest area reviewed.

- **CORS is present and correct, proved live.** This resolves an open question from the website
  review, which suspected rc-api set no CORS headers at all. Exact-origin echo for the apex,
  **no** `Access-Control-Allow-Origin` for `Origin: https://evil.example`, `Vary: Origin` on both,
  no `Allow-Credentials`, and only `/v1/auth/link` and its `OPTIONS` carry it (`server.go:109-110`,
  `cors.go:60-62`).
- **The ID-token verifier is tight.** `alg` pinned to RS256 (no `none`/HS256 confusion), `kid`
  required, signature over the original encoded `parts[0].parts[1]` (no canonicalization bug),
  issuer equality, `exp` with 60 s skew, `sub` non-empty, and `token_use` pinned to `id` **and**
  `aud` equality (`cognito.go:78`). An `aud` array fails the unmarshal and is refused — fail-closed.
- **No token confusion in either direction.** `userSession` (`server.go:353-356`) refuses a device
  token presented as a user session; `deviceAuth` refuses a user session at a device endpoint.
- **The Cognito app client is configured tightly.** `AllowedOAuthFlows: ["code"]` only (no
  implicit); exactly one `CallbackURLs` entry, `https://skipperdesk.app/link`, so an off-apex origin
  — `www`, or the distribution's own `*.cloudfront.net` — has nowhere to receive a code and fails
  closed at `authorize`; `ExplicitAuthFlows: ["ALLOW_REFRESH_TOKEN_AUTH"]` only, so there is no
  `USER_PASSWORD_AUTH` credential-stuffing surface; `PreventUserExistenceErrors: ENABLED`;
  `EnableTokenRevocation: true`; public client with no secret, correct for browser PKCE;
  `DeletionProtection: ACTIVE`.
- **The browser PKCE page is careful and I could not break it.** `state` is 32 random bytes and
  actually verified (`link.js:335-338`); `recall()` consumes the attempt before returning
  (`:156-160`), so a callback is single-use; the `code_verifier` lives only in `sessionStorage`; the
  ID token is a local variable, never in storage, a cookie or a URL; both fetches use
  `credentials: "omit"`; `scrub()` strips `code`/`state` from the URL *before* any network call
  (`:329`); all user-visible text goes through `textContent`. The `/link` cache policy sets
  `query_string_behavior = "none"` and edge logging is off, so **no log anywhere records an
  authorization code**.
- **The handoff cannot be redirected.** The target is the constant `HANDOFF_SCHEME`
  (`link.js:306-308`), never reflected from a query parameter — so there is no open-redirect
  exfiltration of the link code.
- **Link fixation is blocked, and I could not find a leak path.** An attacker *can* make a victim's
  browser mint a link code for the attacker's `nonce`+`pubkey` by sending
  `/link?nonce=…&device=…`, and a live Cognito session completes `authorize` with no interaction.
  But the code returns only in the CORS-protected body, then only to `skipperdesk://link` on the
  **victim's** Mac, where `AccountLinker` rejects it (`AccountLinker.swift:214-223`: scheme and host
  check, pending attempt required, 15-minute lifetime, constant-time nonce compare). The design
  rests on the code's secrecy (24 random bytes) with the app's nonce check as defence in depth.
  *Residual, worth a line of copy:* a victim who follows such a link sees "You are signed in" while
  their own app got nothing, and the attacker-chosen `label` is stored on the victim's account
  (`link.js:202` trims to 64 but does not pattern-check it).
- **The nonce/pubkey encoding handshake across three languages is deliberately correct.**
  `freshNonce()` (`AccountLinker.swift:444-449`) base64url-encodes and strips padding → 43 chars
  matching `NONCE_PATTERN` exactly; `queryEncoded` removes `+&=?#` from the allowed set so base64
  `+` and `=` survive `URLSearchParams`, matching `PUBKEY_PATTERN`. I expected a bug here and found
  a deliberate contract.
- **Idempotency is sound against cross-tenant replay.** `BeginIdempotent` claims the key with one
  `INSERT … ON CONFLICT DO NOTHING` plus a `RowsAffected` check — a real atomic claim. The scope
  includes the caller, the body hash must match (409 otherwise), and a credential-bearing success
  stores `Replayable=false`, so a replay gets 409 and never the token. 5xx releases the slot.

**Multi-tenancy.** Better than the brief feared.

- **No cross-account read on the public surface.** Every id-addressed handler scopes by account:
  `getDevice` (`devices.go:60,76`), `ownedDevice` (`:85`) behind rename and unlink,
  `unlinkOwnDevice` (`:165`), `listSessions` (`sessions.go:30,40-50`). Tested with A's user session
  and A's device token against B's device: `404, 404, 404, 403, 403`, and B's device survived
  untouched. **I found no lookup by id alone that should have been (id, account).**
- **Gift authorization is correctly account-scoped, no IDOR.** `giftForCaller`
  (`credits.go:248-271`) requires `ToEmail == account.Email` to accept and
  `FromAccountID == account.AccountID` to cancel, and refuses a non-pending gift. `SetGiftStatus` is
  a guarded `UPDATE … WHERE status='pending'` with a `RowsAffected` check, so no double-accept.
  (H2 is the way to attack this, not an IDOR.)
- **Id generation.** Device tokens 32 bytes, link codes 24, session ids 16, entry/gift ids 16 — all
  `crypto/rand`. `device_id_claims` is a correct uniqueness ledger: a certified restore is honoured
  only for the key the claim names, and `preferredDeviceId` without a verifying `idCert` always
  yields a fresh id. **Two accounts cannot claim the same Device ID.**
- **Rate-limit keying.** Every API bucket keys on a principal — account id, device id, or code hash
  — not on nothing. The four unauthenticated routes key on client IP (see L8).

**Client-IP handling, which the rate limits all depend on.** Correct at both ends, and the §7
"Trusted proxies" row is satisfied as deployed. `-trusted-proxies 127.0.0.1/32` on **both**
processes — exactly Caddy's hop, neither unset nor over-wide. Caddy *replaces* rather than appends
(`header_up X-Forwarded-For {remote_host}` on all three routes, `Caddyfile:29,36,42`), so a
client-supplied header never survives. `clientip.go:64-85` then walks hops right-to-left and
returns the rightmost untrusted one, falling back to the peer on a malformed hop. rc-api's own WS
proxy `Set`s (not appends) the resolved IP (`server.go:515`), and Go's `Rewrite` API drops inbound
`X-Forwarded-*` first. The degradation if the flag were ever emptied is fail-closed-to-global, not
fail-open-to-spoofable.

**The internal surface.** Defence in depth at three layers: the internal mux is on a separate
loopback listener, the public mux has no `/internal` route, and `Caddyfile:23-25` 404s
`/internal/*` independently. Proved live: `/internal/entitlement/123456789` → **404**. `ss -ltnp`
confirms `127.0.0.1:18080/18081` (rc-api) and `127.0.0.1:18444/8443` (rc-signal) — loopback, not
`0.0.0.0`. Neither command line contains the deprecated `-internal-token`; both use
`-internal-token-file` at mode `0600`. `internalapi.Authorized` is a constant-time compare that
fails closed on an empty token, and rc-api refuses to start without one.

**Dev-only endpoints.** Proved live: `/v1/credits/dev-topup` and `/v1/dev/expire-trial` both
**404**. The gate `s.opt.IdP.Name() != "dev"` is the *first* statement in each handler
(`credits.go:98`, `registry.go:160`, `releases.go:76`) — before auth, per request, a positive allow
on `"dev"`, so an unexpected provider name is refused. `IdP` is set once and never mutated.

**The deployment's mechanical hardening.** I could find no path from the box to the audit trail,
the state bucket, the control plane, or deletion of its own backups.

- **IMDS:** `HttpTokens: required`, hop limit 1, IPv6 disabled. Proved on the box:
  `curl http://169.254.169.254/latest/meta-data/` → **401**. Nothing proxies it — Caddy's only
  `reverse_proxy` targets are two fixed loopback upstreams with `admin off`.
- **The `kms:Decrypt` condition (§7 item 7) is sound as written — close this item.** Live policy is
  `StringEquals kms:ViaService = ssm.eu-west-2.amazonaws.com` **and** a plain `StringLike` on
  `kms:EncryptionContext:PARAMETER_ARN`. **No `IfExists`, no `ForAnyValue`/`ForAllValues`, no set
  operator**, so a `Decrypt` carrying no encryption context is not admitted, and `ViaService` makes
  `Resource: "*"` unusable outside an SSM call. The trailing wildcard admits deeper paths, but those
  are inside the role's own `ssm:Get*` scope anyway and the prefix cannot be widened from the box
  (`ssm:PutParameter` → `implicitDeny`). The over-broad part is the prefix *contents* — M7.
- **The audit trail cannot be tampered with by anything short of account admin (§7 item 8) — close
  this item.** `LogFileValidationEnabled: true`; `IsLogging: true` with a current digest;
  `ReadWriteType: "All"`, so the `readOnly: true` `kms:Sign` events are actually captured;
  `DataResources: []`; the audit bucket is a separate bucket, not a prefix of the backups one; both
  bucket-policy statements and the delivery role's trust policy carry `aws:SourceArn` pinned to the
  exact trail ARN; and the instance role has zero reach (`implicitDeny` for
  `s3:GetObject/PutObject/DeleteObject` on the audit prefix, and for `cloudtrail:StopLogging`,
  `DeleteTrail`, `logs:DeleteLogGroup`, `logs:PutRetentionPolicy`, `kms:ScheduleKeyDeletion`). The
  problem is the admin — H6.
- **`logs:DescribeLogGroups` on `"*"` (§7 item 10) is justified** — it returns names and metadata,
  never content, and a resource-scoped grant makes SSM Agent's unfiltered call fail rather than
  return a filtered list. `cloudWatchEncryptionEnabled: true` still agrees with the group's key,
  scoped by encryption context to that one group.
- **The id-cert signing key:** `ECC_NIST_P256`, `SIGN_VERIFY`, `Origin: AWS_KMS` (nothing imported,
  nothing exportable), single-region. The key policy grants `Sign` to **only** the instance role;
  the admin statement deliberately omits `kms:Sign`, so an admin must first `PutKeyPolicy` — a
  logged, alarmable event. `KeyRotationEnabled: false` is correct and unavoidable (KMS does not
  auto-rotate asymmetric keys); the rotation *story* remains the undone contract work §1.2 flags.
- **The id-cert message framing** is domain-separated and unambiguous (`signing.go:60-69`): a
  9-digit validated deviceID and a fixed 32-byte key digest, so the concatenation cannot be
  confused. `Issue()` treats a signing failure as the registration failing rather than emitting an
  unsigned certificate.
- **Backups are write-only from the box** — `PutObject allowed`, but `GetObject`, `DeleteObject`,
  `DeleteObjectVersion`, `PutBucketPolicy`, `PutLifecycleConfiguration` all `implicitDeny`. Keys are
  timestamped, so overwrite does not arise. The box cannot read its own backups, so the asymmetric
  restore path is real, and `claims/` genuinely has no expiration and no noncurrent-version
  expiration.
- **Security group:** inbound is exactly 80, 443, 3478/tcp, 3478/udp, 49160-49200/udp. **18081 and
  18444 are not exposed; there is no SSH rule.**
- **All four buckets:** every public-access-block flag `true`, versioning `Enabled`, SSE on, and a
  `Deny s3:*` when `aws:SecureTransport=false`; tfstate additionally denies `PutObject` with the
  wrong algorithm or key. SSE-C blocked on all four.
- **No secret is committed.** Every `aws_ssm_parameter` value in the committed `tfplan` files is a
  null marker, the live TURN secret string does not appear (`grep -c` → 0), and no
  `BEGIN … PRIVATE KEY` appears; only parameter *descriptions* leak. The only hits under `infra/`
  are the `__TURN_STATIC_AUTH_SECRET__` placeholder and the Terraform reference at
  `cognito.tf:138`. No `*.tfstate` is version-controlled, and `bootstrap-state/terraform.tfstate`
  holds only the state bucket, its KMS key and the lock table — no private key, no client secret.
- **Data volume:** `findmnt /var/lib/skipperdesk` → `/dev/nvme1n1 ext4`,
  `DeleteOnTermination: false`, with `RequiresMountsFor` on both units, so the §5.1 acceptance check
  still holds. Both units carry a strong systemd sandbox (`CapabilityBoundingSet=`,
  `ProtectSystem=strict`, `NoNewPrivileges`, `RestrictAddressFamilies`, scoped `ReadWritePaths`).

**The website.** The CSP is real, not decorative, and served verbatim on every path including the
404 and the function-generated 301: `default-src 'none'` with only four directives widened, no
`'unsafe-inline'`, no `'unsafe-eval'`, no wildcard, no `data:`. **The site genuinely needs no
inline script** — confirmed by grepping the *served* bytes. The response-headers policy is attached
to **both** cache behaviours, which is the gap I went looking for and did not find. `/link` is
protected against framing twice over (`frame-ancestors 'none'` and `x-frame-options: DENY`), and
Referer leakage of the `/link` query is shut twice (`referrer-policy: no-referrer` plus a
`<meta name="referrer">`). HSTS, `nosniff`, COOP and a `permissions-policy` are all live; TLS floor
`TLSv1.2_2021`. The bucket is genuinely private (unsigned GET → 403, LIST → `AccessDenied`, website
endpoint never enabled). The deployed CloudFront function and both `/link` assets are
**byte-identical to the repo**. CloudFront rejects an unknown `Host` *before* the function runs
(`Host: evil.example.com` → 403), so `Location` cannot be poisoned — no open redirect — and every
traversal and double-encoding probe failed (`/assets/%2e%2e/config.js` → 404,
`/link/..%2f..%2fconfig.js` → 400). No secret, account id or internal hostname leaks in the served
assets, and every user-facing string is sign-in wording with no backend internals.

**The update path is not the supply-chain hole it looks like.** The feed carries no signature of its
own, but the client never treats it as an authority: `docs/SECURITY.md` "Updates" requires the
announced `size` with the download **cut off** at it, a matching `sha256`, https-only including
every redirect, `SecStaticCodeCheckValidity` against `anchor apple generic and notarized` plus the
Developer ID OIDs with **the team ID read from the app's own signature so the feed cannot choose
it**, and a strictly increasing `CFBundleVersion`. `publish-release.sh` re-downloads through
CloudFront and verifies the *served* bytes before publishing. An attacker who writes one object gets
a refused update, not an installed one. *(I did not audit the macOS client's update-trust
implementation — see below.)*

**The relay, where the config is better than §7 required.** `no-tcp-relay` **is** set and survived
the move to `infra/aws`. `use-auth-secret` with **no static users**. The full anti-proxy deny list
is present (15 IPv4 ranges + 7 IPv6), `PHASE5.md` §8.2's correction is confirmed — **no bare
`denied-peer-ip=::`** — and the live log shows all 15 ranges loading per boot and 4 real
`A peer IP … denied in the range` refusals. **No `allowed-peer-ip` exists**, which matters more
than it looks: coturn's whitelist `return 1`s *before* the blacklist is consulted, so a single such
line would silently re-open denied space. Loopback is denied twice over (the range *and*
`ioa_addr_is_loopback`, since `allow-loopback-peers` is absent); IMDS, the VPC and the box's private
address are all in denied ranges; multicast and broadcast are covered three ways. Quotas were raised
above the 1:1 values (`user-quota=12`, `total-quota=200`). coturn's admin surface is not exposed:
`no-cli` set, nothing listening on 5766, no web admin, no prometheus support in the build, and the
security group permits neither.

**TURN credential minting is sound.** The HMAC is over exactly the username
(`hmac.New(sha1.New, secret)`, `m.Write([]byte(username))`), and the username is
`<expiry>:<sessionId>` — so the session id is *inside* the HMAC input, which is why a credential for
session A is refused for session B, and why the expiry cannot be moved. The secret reaches no flag,
no process list and no log: rc-signal uses `-turn-secret-file`, `/etc/turnserver.conf` is
`0640 root:turnserver`, and `verbose` is off. **And the bar to obtain a credential is higher than
feared:** an unauthenticated caller gets nothing — the chain is registered device → device-key
challenge/response → `connect_req` against an **online** host → the host's entitlement must Allow →
and the credential is pushed only when **the host itself** sends an SDP (`handle.go:672`), which the
genuine host app does not do until its own local PAKE succeeds with the correct access code. So a
rogue controller cannot unilaterally extract one. The practical bar is "own an entitled host" —
which is C1/H4, not "be any stranger".

---

# What I could not check, and why

1. **Whether a Session Manager transcript actually writes** — the one thing §7 item 10 asks to
   *observe*. It remains unobserved: `start-session` is interactive and unusable from here, and no
   session has ever been opened, so there is no historical transcript either. *Exact check:* from a
   terminal, `aws ssm start-session --target i-00fa1625fdade0a87 --profile skipperdesk`, type `id`,
   exit, then `aws logs describe-log-streams --log-group-name /skipperdesk/prod/sessions` and
   confirm a stream named for the session id whose events contain the typed command. Note H6: even
   if it works, it does not cover the path actually used.
2. **Every live `CreatePermission` behaviour** — M1 and M2, and an end-to-end re-proof of the deny
   list. Minting a credential needs the `static-auth-secret`, and the reviewer's attempt to read it
   was refused by the harness's credential-materialization guard; I did not work around it. The
   exact checks are written out in M1 and M2. Note that `verify-turn.sh` starts throwaway loopback
   coturn processes on the box, which this review's read-only constraint forbade.
3. **The real measured relay rate**, against which every figure in H1 should be calibrated.
   `PHASE5.md` §8.2 explains why nothing produces it; my $/hour numbers derive from the t4g.small
   published baseline and are stated so they can be re-derived.
4. **Whether a second CloudFront distribution in the account can really read the web bucket**
   (M6's proof of exploitability) — requires `CreateDistribution`, a write. Settle it in a throwaway
   account configured identically, never in prod.
5. **Whether Cognito *requires* PKCE for this client** rather than merely accepting it. No API field
   exposes it, and testing means completing a sign-in. Low stakes: the single exact callback URL
   already denies an attacker anywhere to receive a code.
6. **Whether Cognito would ever issue an email claim containing `U+212A`/`U+0130`** (L9), or an
   unverified `email` (H2's second half). Both are pool-behaviour questions; the code defects are
   unconditional.
7. **Identity Center permission-set assignments and the Budgets email's delivery** — both live in
   the management account `521831014979` and are not readable with the `skipperdesk` profile. What
   is provable from here is the member-account side: one SSO role with `AdministratorAccess`, plus
   `OrganizationAccountAccessRole` (L10). Milestone 5.0 asks for a Budgets email to have been
   observed at least once; `NotificationState: OK` only means "not currently breached".
8. **Why the 08:45 claims backup left no log line** (H5) — diagnosing further means running the unit
   or writing to the box. The facts stand: `Result=success`, `ExecMainStatus=0`, zero objects, zero
   versions, no note.
9. **The macOS client's update-trust implementation** — it is the load-bearing control behind the
   release publisher's deliberately permissive URL/hash acceptance. I read what `docs/SECURITY.md`
   specifies, not the Swift that implements it. It deserves its own review.
10. **End-to-end sign-in on real hardware** — the real `nonce`/`device` round trip and the handoff
    actually firing. Per `CLAUDE.md`, that is two real Macs at the end of a phase.
11. **SecureString values** were not decrypted, per the brief.

---

# Against milestone 5.4

`PHASE5.md` §8 gates 5.4 on "No HIGH or CRITICAL finding outstanding". There is **one CRITICAL** and
**seven HIGH**, so **5.4 is not met.**

Three of the review's own flagged items close cleanly in the deployment's favour and should be
marked done: **§7 item 7** (the `kms:Decrypt` condition is correctly bounded — no `IfExists`, no set
operator), **§7 item 8** (the trail cannot be tampered with by anything short of account admin), and
the **§7 "Trusted proxies" and "Dev-only endpoints"** rows, both verified as deployed. **§7 item 9**
is answered: 5-minute `Sum`, threshold 60, and `treat_missing_data` *is* the masking variant — add a
liveness alarm. **§7 item 10** is half-answered. **§7 item 2's** Apple/Google half has nothing
deployed to review yet, and H2/M7 are both the warning that it must be reviewed *before* it is.

The shape of the risk is worth stating plainly: the *mechanical* hardening of this deployment is
genuinely good, and the parts the reviews were most worried about — the internal listeners, the
trusted-proxy value, the KMS condition, the audit trail, the coturn deny list, the PKCE page —
mostly held. What is weak is everything that decides **cost and identity**: a free session window
that defeats the new meter, a relay with no ceiling and no accounting, a trial keyed on a string the
client chooses, an account keyed on an email rather than a subject, and an administrative layer
where one un-MFA'd password can act without leaving a record.
