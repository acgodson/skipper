# Beta — a deployed product on a second Mac, with a trial that is credit and metering that works

Planning only. Nothing here is provisioned. Read `docs/SCOPE.md` §7 and `docs/PHASE5.md` §3 and
§8 first; this document decides what those two leave open and corrects them where they are wrong.

**The goal.** A complete, deployed beta with a free trial, installable on real remote Macs, so the
owner can find out whether it works as expected. Payments stay last. Apple and Google sign-in stay
post-launch (email only). The placeholder app icon ships as-is. None of those three re-open here.

**What is live** (read-only checks, 2026-10-07, account `388699643285`, `eu-west-2`):
`api.skipperdesk.app` + `turn.skipperdesk.app` on one t4g.small, `skipperdesk.app` on CloudFront
`E9V8GS26I6JON`, two $50 budgets, four buckets, one real Mac linked and holding a KMS-signed
id-cert, `verify-turn.sh` green. `GET /v1/app/releases/latest?platform=macos&arch=arm64` → **404**:
no release has ever been published. ~$26/month.

## 0. Where this plan contradicts the documents it follows

| Document | What it says | What this plan says | Why |
|---|---|---|---|
| `policy.go:14` | `TrialDays = 7` | There is no trial *period*. A trial is **50 cents of credit (5 hours), expiring 14 days after it is granted** | §1. 7 was never derived from anything |
| `policy.go:15` | `RateCentsPerMinute = 1` — i.e. **60¢/hour**, $5 buys 8 h 20 m | **10¢/hour**, $5 buys 50 hours | `PHASE5.md` §3.3 recommends 5–10¢/h and the code is 6–12× it. One of the two is wrong and it is the code |
| `PHASE5.md` §3.3 | "Everything needed has a **column**" | The columns are dead. **Relay is not priced at launch** | §3.2. §8.2 already says the values are never written; this is the pricing decision §3.3 defers |
| `PHASE5.md` §8, 5.3 | acceptance requires `relayUsed: true` and non-zero `bytesRelayed` | Not achievable as written; replaced by a client-reported `relayUsed` recorded **for measurement only** | §3.2, and §8.2 says the same |
| `SCOPE.md` §7 | "Free trial: per host device, duration/hours TBD" | Resolved: hours, not duration | §1 |
| `SCOPE.md` §11 | Phase 6 "Business logic" is after Phase 5 closes | §1–§4 of this plan land **inside** Phase 5, before 5.5 | A beta with 60¢/hour metering and a negative-balance bug is not a beta |
| `QualityProfile.swift` | every mode's `maxBitrateBps` is `burstBitrateBps` = 8 Mbps | each mode gets its own ceiling | §2. Today "quality" caps encode *width* only, so it is not a bandwidth control at all |

---

## 1. The trial becomes expiring hours

### 1.1 The arithmetic

Every input is from `PHASE5.md` §3, named where it is unverified.

| Step | Value | Source |
|---|---|---|
| Egress price | $0.09/GB | §3.1, verified |
| Measured session bitrate | 383–391 kbps ⇒ 0.176 GB/h | `VERIFY.md` one-Mac runs |
| §3's planning line | 0.70 GB/h ⇒ $0.063 per relayed hour | §3.1 |
| §3's conservative line | 1.00 GB/h ⇒ $0.090 per relayed hour | SCOPE §8 |
| **Encoder ceiling, `auto` capped at 2 Mbps (§2)** | 0.90 GB/h ⇒ **$0.081 per relayed hour** | this plan; the true worst case a trial can reach |
| Relay fraction *f* | 15%, range 10–20% — **unverified for our population** | §3.1 |
| Launch rate | **10¢/hour** (§1.2) | §3.3's safe end |

Expected margin on one $5 top-up, at *f* = 15% and the conservative 0.090:

```
50 hours bought · 0.15 relayed · $0.090 = $0.675 egress
$5.00 − $0.675 = $4.325 expected margin per top-up
```

A trial pays for itself when its worst case is covered by the margin on the top-ups it converts.
At a deliberately pessimistic beta conversion of **10%**:

```
N × $0.081  ≤  0.10 × $4.325 = $0.4325
N           ≤  5.34 hours
```

**N = 5 hours.** In credit at 10¢/hour that is **50 cents**.

| Case | Per trial device | 10 trial devices | 50 | 500 |
|---|---:|---:|---:|---:|
| Worst case — every hour relayed at the `auto` ceiling | **$0.405** | $4.05 | $20.25 | $202.50 |
| Conservative — every hour relayed at 1 GB/h | $0.450 | $4.50 | $22.50 | $225.00 |
| Expected — *f* = 15%, 0.70 GB/h | **$0.047** | $0.47 | $2.36 | $23.60 |
| At the measured 0.39 Mbps, *f* = 15% | $0.012 | $0.12 | $0.59 | $5.90 |

The first 100 GB/month of egress is free account-wide, so at beta scale the trial is very likely
to cost **$0** in cash. That free tier is **not** used in the derivation: it is shared with paying
traffic, and a budget that only works while the free tier absorbs it is not a budget.

**The expiry window.** §3.1 assumes 10 h/host/month = 0.33 h/day. Five hours is 15 days of typical
use. **14 days**, which is 4.7 hours at that rate — the window and the grant run out together, and
it spans two weekends, which matters for a Mac someone tries at home. A shorter window wastes the
grant; a longer one delays the conversion decision and leaves credit dangling.

### 1.2 The rate, and the rounding it forces

`RateCentsPerMinute = 1` is 60¢/hour. At that rate $5 buys 8 h 20 m, against AnyDesk's monthly
personal plans — the opposite of SCOPE §7's "visibly below". Set **10¢/hour**: §3.3's table shows
egress alone can never break it (break point 111%), so it is the rate that survives a measured
relay fraction we do not have yet.

10¢/hour is not expressible as integer cents per minute, and rounding each session up is a trap:
twenty 90-second sessions would cost 20 cents where one 30-minute session costs 5. Carry the
remainder on the account instead. The carry has to hold *time*, not rounded-up minutes: rounding
each session up overcharges short sessions, and discarding the remainder is review5 C1.

| | |
|---|---|
| New | `RateCentsPerHour = 10`; `accounts.unbilled_units`, integer — units of one second at the hourly rate, so a second is worth `RateCentsPerHour` and a cent is `SecondsPerHour` of them |
| Charge | `units = carry + sessionSeconds × RateCentsPerHour`; `cents = units / 3600`; `carry = units % 3600` |
| Free below 60 s | **Corrected by review5 C1.** A free window that is a property of each session is a bypass of the whole meter: 60 reconnects an hour cover 98% of the clock, and the un-charged time left no trace. The window is an allowance on the account instead — a session too short to be worth a cent charges nothing but still owes its seconds, so no session length can be repeated for free. One short session on its own still costs an honest user nothing |
| Acceptance | **twenty 90-second sessions cost the same as one 30-minute session ±1 cent**, read from `/v1/credits/ledger`; one 60-minute session costs exactly 10 cents; and **sixty 59-second sessions cost what one 59-minute session costs ±1 cent** |

### 1.3 How the grant and its expiry live in the ledger

The ledger is append-only (`API.md` §7.2) and the balance is `SUM(amount_cents)`. So:

| Event | Ledger |
|---|---|
| Trial granted | one `trial_grant` entry, `+50`, `memo` "starting credits". `type` is an open enum, so this is additive |
| Session | `session_charge`, negative, as today |
| Grant expires | one **`trial_expiry`** entry, `−min(unconsumedGrant, balance)`. `unconsumedGrant = max(0, Σ trial_grant − Σ session_charge since the grant)`. Its own ledger type, **not** an `adjustment` with a memo: money logic cannot key off free text, and an expiry has to be distinguishable from an operator correction. **Written even when it is worth 0** — the entry is what records that the window closed; without it the grant never closes and a later top-up gets clawed back |

Clawing back only the unconsumed part is what keeps a $5 top-up safe: charges consume the grant
first, so a user who topped up never loses paid credit at expiry.

**The grant key, corrected by review5 H4.** `GrantsTrial(pubkeySeen, hardwareSeen)` was keyed on two
values the *client* chooses: a fresh P-256 keypair and any `hardwareId` string. The review minted
five grants on one account with it, so it bounded nothing. The grant is keyed on the one durable
fact instead — **one grant per verified mailbox** — with the plus tag folded away so one mailbox is
not worth unlimited addresses, and a per-IP budget of 3 grants a day charged only when a grant is
otherwise due. The device rules are kept because they only ever withhold a grant further;
`hardwareHash` is a review signal, never a gate.

A withheld grant withholds *only the grant*: the link still succeeds, because the device is
legitimate either way and failing the link would punish an honest user who shares an office address
with a farm. One grant per account also makes the grant's **window** an account property — a second
device on the account spends the same starting credits, so it must report the same `trialEndsAt`.

### 1.4 Abuse ceiling, stated honestly

| | |
|---|---|
| Cost of one fresh trial, worst case | **$0.405** |
| Fresh identities needed to reach the $50 budget alarm | **124 in a month**, each relaying and saturating all 5 hours (620 relayed hours ≈ 0.85 concurrent sessions, within the t4g.small — so capacity is not the limiter). The physical path costs an OS wipe per trial, which is the deterrent `API.md` §3.2 intends |
| **Virtual path** | a macOS VM on Apple Silicon gets a fresh serial, so `hardwareHash` is per-VM, not per-Mac. **It no longer matters**: a fresh serial is no cheaper than the fresh keypair review5 H4 generated, and neither earns a grant any more. Nothing is keyed on the hardware |
| **What the cost of a farmed trial actually is, after H4** | one *verified mailbox* per 50 cents, at no more than 3 grants per IP per day. The mailbox is the price: plus tags fold to one grant, so it is a distinct mailbox each time, and it must complete Cognito's emailed confirmation |
| **The binding ceiling, and it is not ours** | Cognito's default sender is ~**50 messages/day** (`EmailConfiguration.EmailSendingAccount: COGNITO_DEFAULT`), so sign-ups cap at ~50/day whatever an attacker does — ≈ **$25/day** of granted credit, ≈ 250 hosted hours, ≈ **$20/day** of egress at the `auto` ceiling if every hour were relayed. That same ceiling caps *legitimate* public sign-ups and has no bounce handling: **move to SES before any public link**, and that move must come with a sign-up rate limit, because today the email sender is doing the rate limiting by accident |
| What bounds it beyond that, and the accepted residual | the grant is server policy (`API.md` §4.2): setting it to 0 needs no client release, and the $50 Budgets alarm already exists. Dots in a local part are **not** folded — that is a provider-specific convention and folding them would be wrong on most domains — so a Gmail user can still get a second grant with a dotted address. A signup gate (captcha, or payment-method-on-file) is a post-beta decision on a measured number |

### 1.5 What changes in the contract, the states and the strings

| Surface | Change |
|---|---|
| `API.md` §4.1 | one new optional field, **`minutesRemaining`** (int) = `balanceCents × 60 / RateCentsPerHour`, computed server-side because the client must not divide a balance by a rate (§4.2). `trialEndsAt` narrows from "end of the trial period" to "the day the starting credits expire" — same field, same type, no client release. `status` gains **no new value**: the closed enum stays `trial`/`active`/`exhausted`/`unlinked` |
| `policy.Decide` ordering | today `balance ≥ 1` wins over an unexpired trial, so the moment a grant lands the status reads `active`. New order: balance ≥ 1 **and** the whole balance is unexpired grant → `trial` (+`trialEndsAt`); balance ≥ 1 otherwise → `active`; else `exhausted` |
| `API.md` §4.3 | `trial_expired` now means "the starting credits expired or ran out and no balance remains". Same wire value |
| `API.md` §7.2 | `type` gains `trial_grant` (open enum) |
| UI (`EntitlementPresentation.statusLine`) | `trial` → "Trial · about 5 hours left" (from `minutesRemaining`, rounded down to the hour; under an hour, "less than an hour left"). `active` → "$4.30 left · about 43 hours". `exhausted` → **"No balance. Top up to keep hosting."** — the present string names a URL ("top up at skipperdesk.app"), which DESIGN §4 rule 8 forbids; the Top Up… button is the route |
| Website (`web/index.html`) | "starts with a free trial" → "starts with 5 free hours". It currently states no duration, so nothing else there changes |
| Acceptance | a fresh device's `/v1/entitlement` returns `trial`, `balanceCents: 50`, `minutesRemaining: 300`, `trialEndsAt` = grant + 14 d; after a 30-minute session, `minutesRemaining: 270` and the ledger shows one `-5` entry (5¢ of 50¢ spent leaves 45¢, which is 270 minutes — an earlier draft said 297, which contradicted its own `-5`); with the clock advanced past `trialEndsAt`, status is `exhausted`/`trial_expired` and the balance is exactly `0`, never negative |

### 1.6 What a user signed up under the old scheme sees

**One device exists** — the owner's. A one-off migration: every device with `trialEndsAt > 0` gets
a `trial_grant` of `+50` and `trialEndsAt` = migration + 14 days; every account left negative by
the §3.1 bug gets an `adjustment` bringing it to exactly 0, `memo` "corrected". **No user-facing
notice** — DESIGN §4 rule 9: the app shows the current state, and the current state is a working
trial. Acceptance: the owner's `/v1/entitlement` reads `trial`, `balanceCents: 50`, and
`/v1/credits/ledger` shows the two entries with `balanceAfterCents` self-consistent.

---

## 2. Best quality gated off during a trial, enforced by the host

### 2.1 Where quality is actually decided

| Step | File |
|---|---|
| Controller picks a mode | `AppSettings.QualityMode` (`best`/`balanced`/`lowBandwidth`), set in `HostView.QualityPicker`, `ControllerView` and `RemoteSessionView.QualityMenu` |
| Sent to the host | `SessionCoordinator.setQuality` → `PeerSession.sendQuality` → ctrl message `quality` on the data channel |
| **Host applies it** | `SessionCoordinator.peerSession(_:didReceiveCtrl:)`, `role == .host` → `applyQuality(payload.wireMode)` → `ScreenCaptureSource.apply(profile:)` |

The host owns the encoder. That is the enforcement point, and it is the only one that matters: a
patched controller can send any mode it likes, and the host simply never configures it.

### 2.2 What "gated" must mean

| | |
|---|---|
| Server states it | `API.md` §4.1 gains `limits: {"maxQuality": "auto"}` — values are the wire modes `smooth`/`auto`/`sharp`, open enum, ordered. Present always; the client renders and clamps |
| Policy | `trial` → `auto`. `active` → `sharp`. Server-side, so the tier can change with no client release (§4.2) |
| Host enforces | `applyQuality` clamps the requested mode to the cached entitlement's `maxQuality` before building the profile. A cache older than `refreshAfterSec` clamps to `auto` — fail closed |
| Controller | greys out Best Quality with the one-line reason. **Courtesy only.** Not the gate |
| Acceptance | with the host's entitlement forced to `trial`, a controller that sends `quality{sharp}` gets a stream whose encode width is ≤ 1920 and whose sender `maxBitrateBps` is ≤ 2 Mbps, read from `rc-node`'s video statistics on the host — *and* the same test passes against a controller build with the picker's gate removed |

### 2.3 This is only a cost control if bitrate is tiered — today it is not

`QualityProfile.profile(for:…)` sets `maxBitrateBps: burstBitrateBps` (8 Mbps) in **every** mode;
only `maximumWidth` differs. So gating `sharp` today caps encode width and leaves the bandwidth
ceiling untouched — and bitrate is the dominant variable cost (`PHASE5.md` §3).

| Mode | `maximumWidth` | `maxBitrateBps` today | Proposed | GB/relayed hour at the ceiling | $/relayed hour |
|---|---|---|---|---:|---:|
| `sharp` | 2560 | 8 Mbps | 8 Mbps | 3.60 | $0.324 |
| `auto` | 1920 | 8 Mbps | **2 Mbps** | 0.90 | **$0.081** |
| `smooth` | 1280 | 8 Mbps | **1.5 Mbps** | 0.675 | $0.061 |

2 Mbps for `auto` is defensible against measurement, not taste: real sessions ran at 0.39 Mbps,
SCOPE §8's budget line is ~1 GB/h, and `auto`'s own copy is "a clear picture that works on most
connections". **$0.081 is the number §1.1 derives N from** — the trial's worst case exists only
because this ceiling does. Acceptance: a `sharp` session's sender bitrate parameter reads
8 000 000 and an `auto` session's reads 2 000 000, both from the host's own `RTCRtpSender`
parameters, not from the picker.

---

## 3. Metering correctness — this blocks everything above

### 3.1 A trial session drives the balance negative while still reading as `trial`

`meter()` (`apisrv/entitlement.go:268`) appends a charge whenever `HostAccountID != ""`, with no
regard for status, and `DB.Append` (`apidb.go:844`) has no non-negative guard. `policy.Decide`
reaches the trial branch only when `balance < MinBalanceCents`, so a negative balance still reads
`trial` until `trialEndsAt` passes.

Concretely, today: 40 trial hours at 60¢/h = **−$24**. The trial then expires, the user tops up
$5, and the balance is **−$19** — still `exhausted`. The user has paid and cannot host.

**Decision.** Three changes, all server-side:

| | |
|---|---|
| Balance floor | `DB.Append` refuses an entry that would take the balance below zero on a `session_charge`; it clamps the debit to the available balance and records the clamped amount. The ledger stays self-checking because `balanceAfterCents` is still what it says |
| Metering is status-blind, correctly | keep metering every metered session — the trial **is** credit now, so a trial session must debit. §1.3's ordering makes the grant the thing it debits |
| Session cut-off | when a charge is clamped, rc-api closes the session (`POST /internal/sessions/close`) and the next `connect_req` is refused `no_balance`. A session cannot outrun the balance by more than one settlement |
| Acceptance | a device with `balanceCents: 1` runs a 30-minute session; afterwards the balance is exactly `0`, **never below**, the ledger holds one clamped `session_charge`, `/v1/entitlement` reads `exhausted`/`no_balance`, and the session was closed rather than left running. Re-run with a $5 top-up: the balance is `500`, not `500 − debt` |

### 3.2 `relayUsed` and `bytesRelayed` — recommendation: do not price relay at launch

Confirmed, not restated on trust: `hub.go:358` builds `SessionStopReport{SessionID, EndedAt,
Reason}` and nothing else; the reconciliation sweep passes `StopSession(…, false, nil, …)`
(`entitlement.go:252`); no v5 message carries either value; and the deployed
`/etc/turnserver.conf` is `simple-log` with no `verbose` and no exporter, so coturn records zero
allocations and zero bytes.

| Option | What it costs | What it risks |
|---|---|---|
| **A. v5 wire field, client-reported.** Add `relayUsed`/`bytesRelayed` to `bye` (not in the strict-decode set of `PROTOCOL.md` §0, so additive), filled from `ICEPathStatistics`. The **host** reports | small: one optional field, one plumbing change, one vector | **The host is the party that pays.** A host that under-reports under-pays, and nothing checks it. Reported by the controller instead, a controller can inflate a host's bill. Either way the number is a claim, not evidence |
| **B. Server-side from coturn.** Turn on per-session accounting and parse it | a config deploy — and ROADMAP records there is **no deploy path for a configuration change**; the deny-line fix had to go by hand over SSM. Then log volume, a parser, and the join from coturn's 5-tuple to a `sessionId` (coturn's username carries the id, so the join exists) | real work, and it is the only option that produces evidence |
| **C. Do not price relay at launch.** Record a client-reported number **for measurement only**, labelled as such | nothing | the relay fraction stays an estimate longer; a pathological all-relay user is unpriced |

**Recommend C now, B before relay is ever priced, never A as a billing input.**

Why it is safe: §3.3's own table says that at 10¢/hour egress alone can never break the unit
economics. The individual risk §3.3 raises — "$5 at 5¢/h buys 100 hours; all-relayed that is $9 of
egress against $5" — is a property of 5¢/h. At **10¢/h** the same $5 buys 50 hours, whose
all-relayed egress at the `auto` ceiling is 50 × $0.081 = **$4.05 against $5.00**. Thin, and
positive. Pricing relay is a margin improvement, not a solvency requirement, so it does not belong
on the critical path to a second Mac.

| | |
|---|---|
| What lands now | the host fills `relayUsed` (and `bytesRelayed` when the candidate pair reports it) on `bye` from `ICEPathStatistics`. `/v1/sessions` returns it. **It is not read by `policy`** and the column is documented in `API.md` §5.1 as host-reported and not billed |
| Acceptance | a forced-relay production session leaves a `/v1/sessions` row with `relayUsed: true` and non-zero `bytesRelayed`; the same session's `session_charge` is identical to a P2P session of the same length, proving nothing prices it |
| Before relay is priced | coturn accounting deployed, and at least 20 sessions where the client's claim and coturn's count agree within 10%. Until then any relay price is a price on an unverified self-report |
| Also fix | `PHASE5.md` §3.3's "Everything needed has a column" and §8's 5.3 acceptance line. §8.2 already says both; §3.3 still reads as if it were true |

### 3.3 `MaxActivePairs = 1` counted only over metered sessions — intended, with one real gap

`PROTOCOL.md` §3.4 step 3 says it outright: "An unmetered session is never reported, is never
billed, and never counts against the account's `maxActivePairs`." **Intended**, and right: an
unmetered session is one where the access code has not been proved, so counting it would let a
stranger occupy a paying account's only slot by sending `connect_req`.

Two things already cover the obvious holes: `hasLiveSessionLocked` refuses a second session on the
same host before entitlement is consulted, and `internalSessionStart` re-checks entitlement and
refuses on `concurrency`, which `PROTOCOL.md` §3.4 step 4 turns into `bye{error}`.

The residual gap is narrow and real: two **different** hosts on one account can both pass
`connect_req` (each sees `ActivePairs = 0`), and the loser is only discovered at its start report —
so a controller sees a session establish and then die. That is the correct outcome arriving
rudely.

| | |
|---|---|
| Decision | leave the counting rule alone. Change only the message: when `internalSessionStart` refuses on `concurrency`, the `bye` reason reaching the controller must render as DESIGN's existing sentence "That account is already in a session on another Mac.", not the generic `error` |
| Acceptance | two hosts on one account, both reaching their first host `sdp` within the same second: exactly one session survives, the other's controller shows that sentence, and `/v1/sessions` holds exactly one row with no `endedAt` |

---

## 4. The account link the UI does not have

Honest correction: `AccountSection.swift` is not Sign-out-only. `SignedInRow` already shows a
**Top Up…** button that opens `EntitlementPresentation.topUpURL` — but only when
`status == .exhausted`. There is no route to the web while the trial is running or the balance is
healthy, which is exactly when someone wants to look at what they have left or gift credit.

| Change | Copy |
|---|---|
| The ellipsis menu gains two items above Sign Out… | **"Account on the web…"**, **"Add credit…"** |
| Both open the browser to the website's account page | no URL is shown, no identifier is shown, nothing is appended that names a device |
| The `exhausted` Top Up… button | stays as the single primary action in that state |
| `statusLine` for `exhausted` | "No balance. Top up to keep hosting." (drops the URL — DESIGN §4 rule 8) |
| What is not added | no balance figure in the menu bar, no "credits expire in…" countdown, no session history, no sign-in state narration. DESIGN §4 rules 1, 3 and 9 |
| Acceptance | signed in with `status: trial`, the menu offers both items and each opens the account page in the default browser; no screen in the app, in any state, displays a URL, a device id outside a Details disclosure, or the word "entitlement" |

---

## 5. Distribution — the actual blocker

Everything to *build* a shippable image exists: `scripts/build.sh`, `scripts/package-dmg.sh`
(refuses anything but a hardened Developer ID build, signs and notarises the **image**, staples,
writes `dist/SkipperDesk-<v>.release.json`), and a signed self-update with rollback.

Nothing to *ship* it exists. Three gaps, in order of severity:

| Gap | Evidence |
|---|---|
| **No way to publish a release in production.** The only publisher is `POST /v1/dev/releases`, which `API.md` §6.3 serves **only** under `RC_API_IDP=dev`. Production runs `cognito` | `GET /v1/app/releases/latest?platform=macos&arch=arm64` → **404** against the live API |
| No `.dmg` served anywhere | the web bucket holds 8 objects, all site |
| No download page | `web/index.html` says "Not ready to download yet"; `infra/web/README.md` "What is deliberately not here yet" |

### 5.1 The plan

| # | Thing | Where | Decision |
|---|---|---|---|
| 1 | The image | `s3://skipperdesk-prod-web-…/assets/SkipperDesk-<version>.dmg`, behind CloudFront `E9V8GS26I6JON` | `infra/web/README.md` already decided this and gave the reasoning: a 60 MB image off EC2 is $0.09/GB on the same NIC carrying relay; through CloudFront it is inside the always-free 1 TB. Under `/assets/` it inherits the immutable cache policy, so **the filename must carry the version** |
| 2 | Upload | extend `infra/web/deploy.sh` with `--dmg <path>`, one object, `Cache-Control: immutable`, never part of the normal site sync | same guard rails `deploy.sh` already has (`--profile` required, refuses foreign profiles, asserts the account) |
| 3 | The publish step | **`scripts/publish-release.sh`**: reads `dist/SkipperDesk-<v>.release.json`, re-verifies `shasum` and `stat` against the uploaded object, then `POST /internal/releases` on rc-api's **internal** listener with the internal bearer, over SSM | replaces `API.md` §6.3's `POST /v1/dev/releases` for production. `API.md` §6 gains the call; §6.3's TODO ("replace with a signed publish step in Phase 5") is discharged. It lands on the internal surface because that surface is already loopback-only and token-authenticated — a *new public* authenticated publish endpoint would be new attack surface for one call the owner makes by hand |
| 4 | The feed is already signed where it counts | nothing to add | `API.md` §10 is explicit that the feed is never trusted to say the download is safe: the app checks hash, size, size-pinned Team ID signature, notarisation and no-downgrade itself (U2: 0/60 tampered accepted). The feed says *what*, Gatekeeper and the app say *whether*. Adding a second signature over the JSON would duplicate a check that already passed a review |
| 5 | The download page | `web/download.html` + a link in `index.html`'s hero, replacing "Not ready to download yet" | static. One "Download for Mac" button to the versioned `/assets/` object, the version and size as text, a three-line "what happens next", and the macOS minimum. No `<script>`, no inline `style=` — `infra/web/README.md` makes that the condition of having no `'unsafe-inline'` in the CSP. Bump `assets/styles.css?v=`. The CSP itself is unchanged: the page makes no network call |

Acceptance for the whole of §5, in one run: from a Mac that has never held the app,
`https://skipperdesk.app/download` offers the image over a trusted chain; the downloaded `.dmg`
opens with a plain double-click and no Gatekeeper warning (`spctl -a -t open` agrees);
`shasum -a 256` equals the `sha256` in `GET /v1/app/releases/latest`, which now returns **200**;
and `curl https://api.skipperdesk.app/internal/releases` from the internet is **404**.

### 5.2 A second Mac, from URL to working host

Order matters: the trial must not start before the Mac can actually host, or the clock runs on a
machine that cannot be evaluated.

| # | What the Mac is asked | What it sees |
|---|---|---|
| 1 | open `skipperdesk.app/download`, download, drag to Applications | the page's three lines |
| 2 | first launch | opens straight onto **Share this Mac**. Device ID and access code are already there (`register` needs no account). Status pill: offline, with a sentence saying why |
| 3 | **Sign in to SkipperDesk** → browser (Cognito hosted) → back to the app | "Continue in your browser…", then the signed-in row. **The trial is granted here**, at link, not at install — so the 14 days start when the Mac can host |
| 4 | **Screen & System Audio Recording** first, then **Accessibility** | one attention banner each, with Open Settings / Ask macOS. Screen Recording first because without it a controller connects and sees nothing, which is the most confusing failure; without Accessibility the picture arrives and nothing clicks |
| 5 | relaunch | ROADMAP, "Permissions refresh live in the UI": a grant needs a relaunch today. **Say so in the banner** — one plain sentence — rather than leaving the owner staring at a banner that will not clear |
| 6 | Launch at Login on, window closed, Unattended access on if nobody will be at that Mac | menu-bar only, which is what makes unattended access work. DESIGN's existing notes cover both |
| 7 | status pill reads online, account row reads "Trial · about 5 hours left" | — |

Not asked, and must not be: Full Disk Access, Input Monitoring, notifications before a consent
prompt needs one, and anything about networking. `check-isolation.sh` stays a release gate.

Acceptance: a Mac with no SkipperDesk history and no prior TCC grants reaches "online · Trial ·
about 5 hours left" with no terminal command, no `xattr`, and no step not in the list above; and
a controller then holds a real session with it.

---

## 6. The outstanding Phase 5 work, folded in

| Item | State | Genuinely blocks | Can run in parallel with |
|---|---|---|---|
| **5.2 remainder** — `ice_servers` observed on a real production session | needs one throwaway device **linked by the owner** (a browser sign-in no agent can do) | nothing in §1–§5. It is a confirmation, not a dependency | all of §1–§5 |
| **5.3 forced-relay run** — consent click + the host's access code | blocked on the owner. Procedure written: `VERIFY.md` "Forced relay through the live London coturn" | the measured relay fraction, hence any *relay price*. **Not** the launch rate, which §3.2 shows is solvent without it | all of §1–§5 |
| **5.3 cross-network run** (hotspot) | needs a second network — i.e. **the second Mac §5 delivers** | the only relay-fraction datum that means anything | nothing; it comes after §5 |
| **5.4 fifth security review** (ten items, `PHASE5.md` §7) | queued | **serving anyone but the owner.** §7 already calls it a gate on milestone 4 | §1–§5 development; it reviews what §1–§5 leave standing, so it runs **last** before outside testers |
| **5.5 cutover** — 7 days on the new backend, then our half of the legacy box off | queued | nothing | everything. It is a clock, not work |

Three things 5.4 must now also cover, because §1–§5 create them: the internal
`POST /internal/releases` publish path (§5.1), the ledger's clamping rule and the trial-expiry
`adjustment` (§1.3, §3.1), and the host-reported `relayUsed` field as an untrusted input that
nothing prices (§3.2).

What is **not** blocked by 5.3 and is often assumed to be: the launch rate, the trial size, the
quality gate, the download page, the publish path. Every one of them is derived from §3's cost
model and the measured bitrate already in `VERIFY.md`.

---

## 7. What the owner must do, in order

💵 costs money · 🖐 needs their hands on this Mac · 🌐 needs a browser sign-in

1. 🌐 Sign in once more on this Mac and link **one throwaway device** (second identity dir), so the 5.2 `ice_servers` capture can run. — *minutes*
2. 🖐 Turn **unattended access on** in the host app and read its **access code** off the window; hand both to the forced-relay run (`VERIFY.md`). 💵 a few cents of real entitlement. — *20 minutes*
3. 🖐 Build and notarise: `RC_SIGN_IDENTITY=… RC_NOTARY_PROFILE=rc-notary ./scripts/build.sh && ./scripts/package-dmg.sh`. Needs the signing identity and notary profile, which only this Mac holds.
4. 💵 Say "go" on the download: the image and the download page go to CloudFront and the release is published. ~$0/month at beta volume; the 1 TB free tier is ~16 000 downloads.
5. 🖐 Install on the **second Mac** from the URL and walk §5.2's seven steps without help. Report where it stuck.
6. 🖐🌐 Run the cross-network pair (second Mac on a phone hotspot, this one on Wi-Fi) — runs A, B and C of `VERIFY.md` "Cross-network traversal". This is the relay-fraction datum. 💵 a few cents.
7. Read the fifth security review's findings before any tester outside the household gets the URL.

Everything else is delegable.

---

## 8. Sequence and critical path

**Shortest route to "install on a second Mac and run a real session"** — the only path where each
step genuinely needs the one before it:

```
§3.1 balance floor  →  §1.2 rate 10¢/h + carry  →  §1.3 trial grant as credit  →  §1.5 entitlement
field + strings  →  §5.1 publish path (#3)  →  §5.1 upload + download page (#1,2,5)  →  owner #3,4
→  owner #5
```

Seven steps. Three of the four code changes are inside `server/internal/policy` and
`server/internal/apisrv`; none needs TURN, a relay measurement, or Phase 6 as SCOPE §11 frames it.

**Runs in parallel, joins before the owner installs:** §2 the quality gate (host clamp + tiered
bitrates — it is a client change and the entitlement field it reads lands in §1.5 anyway); §4 the
account menu; §3.2's unpriced `relayUsed` plumbing; the 5.2 `ice_servers` capture (owner #1).

**Deliberately after the second Mac runs:** §6's cross-network measurement (it needs that Mac);
5.4 the fifth review (it reviews finished work and gates *outside* testers, not the owner's own
second Mac); 5.5 the cutover clock. **Must not be put on the path at all:** relay pricing (§3.2);
coturn accounting (its prerequisite, and it needs a config-deploy path the repo does not have);
payments (SCOPE §9, last); Apple and Google sign-in and the app icon (both decided 2026-10-07);
the Shape B migration (`PHASE5.md` §2's triggers are nowhere near); lock screen; Windows.

### Cheap now, expensive later

| Item | Why later is materially dearer |
|---|---|
| **The rate (§1.2)** | `API.md` §4.2 says policy moves server-side with no client release — but the *strings* are in the app, and "about 5 hours left" vs "ends in 6 days" is a release. Shipping 60¢/h and correcting it later means a release plus every beta tester's balance recomputed, and the first impression is a price 6× what SCOPE §7 promises |
| **The balance floor (§3.1)** | every beta session run before it lands creates a negative balance that a later migration has to find and forgive, one account at a time. Today there is exactly **one** account |
| **The carry column (§1.2)** | added after the first `session_charge` exists, it needs a backfill decision for every charged session. Added now, the table is empty |
| **Versioned `.dmg` filename (§5.1)** | `/assets/*` is cached immutable for a year. One unversioned `SkipperDesk.dmg` and the next release is stale at every edge and in every browser that fetched it. Costs nothing now; costs an invalidation and a support thread later |
| **Trial granted at link, not install (§5.2 step 3)** | if the clock starts at first launch, every tester whose permission dance takes a day loses a day of a 14-day window, and there is no server-side way to tell those two moments apart afterwards |
| **`relayUsed` recorded unpriced (§3.2)** | the relay fraction can only be measured over sessions that happened. Every beta session run without the field is a datum that does not exist, and no later change recovers it |
