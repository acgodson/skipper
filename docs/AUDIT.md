# Audit — is this ready to hand to strangers?

**Verdict: no, and it breaks in two specific places.** The money *arithmetic* is sound — I could
not make `policy.Charge`, the carry, the balance floor or the clawback lose or invent a cent, and
the live account's ledger is exactly what `BETA.md` §1.6 promised. What is not sound is everything
either side of the arithmetic. **(1)** Every route the app offers out to the web — "Account on the
web…", "Add credit…", and the `exhausted` state's only primary button — lands on
`skipperdesk.app/account` or `/credits`, both of which return **404 "There is nothing here"**, and
there is no top-up endpoint in production either, so the dead end is total. **(2)** When a
stranger's credit runs out, nobody is told the truth: the host sees a stale balance and no
explanation, the controller is told the *host hung up*, and the next attempt says *"That Mac's
trial has ended"* even to someone who paid. Separately, the 10¢/hour launch rate is **not solvent
on this tree**: it was derived assuming a 2 Mbps ceiling on `auto` that does not exist yet, and at
the 8 Mbps every mode actually uses, $5 of credit can buy $16.20 of relay.

Audited at `33d72bd` ("review5: the meter cannot be outrun…"), `main` as of 2026-10-07. The
parallel quality-tier / relay-measurement work was **not** in the tree; §F says what it changes.

---

## Findings, by consequence

### 1. Every way out of the app to the web is a 404, and no top-up path exists at all

**Proven.**

| Where | Code |
|---|---|
| `AccountSection.swift:94` "Account on the web…" | → `accountURL` → `<web>/account` |
| `AccountSection.swift:97` "Add credit…" | → `topUpURL` → `<web>/credits` |
| `AccountSection.swift:88` **"Top Up…"**, the only primary action in `exhausted` | → `topUpURL` → `<web>/credits` |

`EntitlementPresentation.swift:35-41` builds both paths. The repo's `web/` holds only
`index.html`, `404.html`, `link/`, `download/` — no `account/`, no `credits/`. The CloudFront
function (`infra/web/terraform/functions/fixup.js`) rewrites a dotless path to
`<path>/index.html`, so both become missing S3 keys. Live:

```
/            -> 200
/download    -> 404      <- exists in the repo, not deployed
/account     -> 404      <- "There is nothing here / The page you asked for does not exist."
/credits     -> 404
```

And there is nothing behind them to build toward either. The only credit-minting endpoint is
`POST /v1/credits/dev-topup`, gated on `-idp dev` (`credits.go:98`); production runs
`-idp cognito` (verified in the live process arguments). Live: `dev-topup` → **404**,
`dev/expire-trial` → **404**. The internal listener has no credit endpoint. **The owner cannot
top up a beta tester's account through any interface** — only by editing SQLite on the instance.

**What a stranger experiences.** They get 50¢ = 5 hours. The status line tells them to top up. The
button goes to a page that says the page does not exist. The product is over, permanently.

**Consequence**: this is the conversion path and the support path, and it is the first thing a
tester will hit — 5 hours is one evening. `DESIGN.md` §4 rule 8 is satisfied (no URL is shown) but
rule 2's "say what happened and what to do" is not: the app says what to do and the route is dead.
`BETA.md` §4's own acceptance ("each opens the account page in the default browser") cannot pass.

**What I would do.** Do not ship the two menu items and the Top Up button against a 404. Either
add a static `web/account/index.html` that honestly states the beta position ("Your starting
credits are on this Mac. Paid top-ups are not open yet — here is where to reach us"), or remove
the three affordances until a page exists. A static page is a few hours; three dead buttons in
front of strangers is a trust problem you do not get to re-do.

---

### 2. A customer who paid and spent it is told their *trial* ended

**Proven by test** (throwaway probe against `policy.Decide`, since removed):

```
status="exhausted" reason="trial_expired"     <- balance 0, grant long spent, window a year old
grant withheld, no window ever written  -> reason="no_balance"
grant given at any point in the past    -> reason="trial_expired"
```

`policy.go:134-139` picks `no_balance` only when `TrialEndsAt == 0`. `TrialEndsAt` comes from
`TrialWindowForAccount` = `MAX(trial_ends_at)` over the account's linked devices
(`apidb.go:1284`), and that column is written once at the grant and **never cleared**. So for
every account that ever received a grant — which is every account, since the grant is automatic at
first link — the reason is `trial_expired` forever. `no_balance` is unreachable in production
except for an account whose grant was *withheld*.

The app renders that at `EntitlementPresentation.swift:66` as **"That Mac's trial has ended."**

Three things disagree with the code and with each other:
- `API.md:441` defines `no_balance` as "never had starting credits" — agrees with the code.
- `API.md:494` says a clamped session's account "is refused `no_balance`" — does not happen.
- `BETA.md` §3.1's acceptance line requires "`/v1/entitlement` reads `exhausted`/`no_balance`"
  after the balance floor clamps. **That acceptance criterion does not pass on this tree.**

**Consequence**: a paying customer at zero is told about a trial they finished weeks ago. It reads
as a billing system that has lost track of them, which is the single worst impression a prepaid
product can give. Cheap to fix and it is in one `switch`.

**What I would do.** Decide the reason from the money, not from a stale timestamp: `no_balance`
when the balance is zero and no unexpired grant remains, `trial_expired` only while the window is
the reason. Then make `API.md` §4.3 and §5 say the same thing, and add the §3.1 acceptance as a test.

---

### 3. The host — the party that pays — is never told it ran out

**Proven.** Three independent gaps compound:

**(a) The app refreshes the entitlement in exactly one place.** `refreshEntitlement` has two
callers: `AccountSection.onAppear` (`AccountSection.swift:50-53`) and `loadLinkedState` at
launch/link. No timer, no refresh on session start or end, no refresh on wake. `refreshAfterSec`
(60s, `AccountModels.swift:88`/`api.go:57`) is only a staleness *threshold* — nothing polls on it.
So the balance on screen is as of whenever the window last opened. Open the app, run a five-hour
session, and the line still reads "Trial · about 5 hours left" afterwards. The Top Up button is
gated on `status == .exhausted`, so it never appears either.

**(b) The app discards every `bye` reason.** `AppModel.apply` (`AppModel.swift:247-286`) handles
`signalingState`, `roundTrip`, `connectFailed`, `phase`, `silentReconnect`, `consentRequested`,
`consentEnded` — and `default: break`. `.bye(reason:)` is emitted
(`SessionCoordinator.swift:615`) and never read by any UI.

**(c) The server tells both sides something untrue.** When the meter clamps or the sweep finds a
spent session, `meter`/`cutOffSpentSession` call `closeDeviceSessions`
(`entitlement.go:329,356`), which hardcodes `protocol.ByeHostEnded` (`devices.go:202`) — the same
reason used for an unlink. So "your account ran out of money" is delivered as
**`bye{host_ended}`**: the controller is told the host hung up, the host is told it ended the
session itself. There is no `no_balance` in `ByeReasons` (`protocol.go:119-130`) to use.

**What a stranger experiences**: the session dies with no reason; the account card keeps showing
credit that is gone; the only honest signal is on the *other* Mac, on the next attempt, and (per
finding 2) it is the wrong reason.

**Consequence**: the moment the product has to ask for money is the moment it goes silent. Not a
crash, not data loss — but it is the difference between a tester who tops up and a tester who
concludes it is broken.

**What I would do.** Refresh the entitlement when a session ends, and render the `bye` reason.
Add a bye reason that means "the account ran out" — see §F, the parallel agent is in that frame now.

---

### 4. The 10¢/hour rate is not solvent on this tree

**Proven arithmetic, on a code fact I verified.** `QualityProfile.profile(for:)` sets
`maxBitrateBps: burstBitrateBps` — **8 Mbps — in every mode** (`QualityProfile.swift:52, 77, 90`).
Only `maximumWidth` differs (2560/1920/1280). And `SessionCoordinator` applies whatever `quality`
the controller sends with no entitlement check, so a trial host can be put on `sharp`.

`BETA.md` §1.1 derives the entire trial size from **$0.081 per relayed hour**, which is `auto`
*capped at 2 Mbps*. That cap does not exist. At 8 Mbps: 3.6 GB/h × $0.09 = **$0.324/relayed hour**
— 4× the figure every number downstream was derived from. Re-running `BETA.md`'s own inequalities:

| `BETA.md` says | On this tree |
|---|---|
| trial worst case $0.405 | **$1.62** |
| the grant its method justifies: N ≤ 5.34 h | **N ≤ 1.33 h** |
| §3.2's solvency check: $5 buys 50 h, all-relayed **$4.05 against $5.00**, "thin, and positive" | **$16.20 against $5.00** |

**Consequence**: §3.2's decision not to price relay at launch rests entirely on that last line.
Without the bitrate tiering, one determined all-relay user on a single $5 top-up costs three times
what they paid. At beta scale the free 100 GB/month absorbs it, which is exactly the budget
`BETA.md` §1.1 refused to rely on.

**What I would do.** Treat the quality tiering as a prerequisite of the rate, not a parallel nicety
— they are one decision. Until the ceiling lands, 10¢/hour is a promise the cost model does not
support.

---

### 5. Three trial grants per IP per day — reasoned for a household, deployed to the internet

**Proven.** `ratelimit.go:38-42`:

```go
// Three a day leaves room for a household or a small office replacing Macs and still
// bounds one address to $1.50 of credit a day.
limitTrialGrantIP = rule{Name: "trial_grant_ip", Limit: 3, Window: day}
```

The reasoning is explicit and it is written for a NAT of three people. Real NATs are bigger:
carrier-grade NAT puts thousands of mobile subscribers behind a handful of addresses, as do
campuses, co-working spaces and corporate egress. On any of those, the fourth sign-up of the day
silently gets no grant.

And the symptom is indistinguishable from being broke. `grantsTrial` returns false, `linkDevice`
writes `trialEndsAt = 0` (`auth.go:273-276`), no grant is appended — so a brand-new user's first
screen reads **"No balance. Top up to keep hosting."** with a Top Up button to a 404 (finding 1).
`trial_test.go:85-107` confirms the link still succeeds and nothing is said.

**Consequence**: a tester on a phone hotspot or an office network may never see the product work,
and will be told they have no money on the day they signed up. This one is ranked here rather than
lower because the failure is silent, is attributed to the user, and the limit is invisible to the
owner too — only an `Info` log records it (`auth.go:313`).

**What I would do.** Keep a per-IP budget, but raise it well past household scale, and make the
withheld case say something other than "no balance" — the two states are not the same and the app
cannot currently tell them apart. This is also the item `BETA.md` §1.4 flags as needing a sign-up
rate limit before any public link.

---

### 6. `bye{error}` means both "your other Mac is busy" and "the backend hiccuped"

**Proven.** `BETA.md` §3.3 decided the only change needed for the two-hosts-one-account race was
the *message*: the controller must read "That account is already in a session on another Mac."
That sentence exists (`EntitlementPresentation.swift:68`) and is unreachable from this path.

`internalSessionStart` refuses on concurrency with a 402 (`entitlement.go:163-167`). That becomes
`reports.ErrDenied`, which fires `OnDenied` → `endDeniedSession` →
`endUnregisteredSessionLocked` → `closeSessionLocked(s, protocol.ByeError)` (`hub.go:335-350`).
The `bye` frame carries only `{SessionID, Reason}` (`hub.go:232-233`) — no code, no detail — so the
app falls through `connectFailureSentence`'s `default` to a generic fallback.

The same `ByeError` is produced when the start report simply fails to deliver: `Attempts = 6`,
`MaxBackoff = 8s` (`reports.go:49-56`), and on exhaustion `OnDenied` fires too (`reports.go:197`).
So an rc-api blip of about eight seconds and a legitimate concurrency refusal are the same frame.

**Consequence**: `BETA.md` §3.3's acceptance ("the other's controller shows that sentence") fails,
and the owner cannot tell a policy refusal from an outage from the client side. Moderate — it
makes beta reports uninterpretable more than it harms a user directly.

---

### 7. `relayUsed` is plumbed but never filled, so every beta session is a lost datum

**Proven.** `SessionStopReport` has `RelayUsed` and `BytesRelayed` (`api.go:368-374`); the hub
builds `SessionStopReport{SessionID, EndedAt, Reason}` and nothing else (`hub.go:368-369`); the
reconciliation sweep passes `false, nil` (`entitlement.go:299`). So `/v1/sessions` will report
`relayUsed: false` for every session, including genuinely relayed ones.

`BETA.md` §3.2 confirmed this and its "Cheap now, expensive later" table says the consequence
plainly: the relay fraction can only be measured over sessions that happened, and no later change
recovers a session run without the field. This is in flight (§F) — flagging it because it is the
one finding here whose cost is *time-sensitive*: every session run before it lands is gone.

---

### 8. The published protocol spec contradicts the implementation on access-code strength

**Proven.** `PROTOCOL.md:347-349`:

> **8 characters from a 32-symbol Crockford-style alphabet** (`23456789ABCDEFGHJKMNPQRSTVWXYZ`
> minus look-alikes) … ≈ 40 bits of entropy. Server-side rate limiting (§3.3) is what makes that
> sufficient.

`core/crates/rc-identity/src/lib.rs:25-59`: `LENGTH = 12`, over the full 32-symbol
`0123456789ABCDEFGHJKMNPQRSTVWXYZ` **including** `0` and `1`, with `normalize` folding `O→0` and
`I|L→1`. That is ~60 bits, and `canonicalize` requires **exactly** 12 — an 8-character code built
to the published spec is rejected outright. The doc is also internally inconsistent: it says
"32-symbol" and then lists 30 symbols.

**Consequence**: the implementation is *stronger* than the doc, so this is not a security hole.
It matters because `PROTOCOL.md` is the public contract for an open-source project about to invite
scrutiny: the stated justification for the PAKE guess budget is computed from a number that is not
the product's, and an independent implementation written to the spec cannot interoperate. The fix
is to the document.

---

### 9. A published 5-second promise that nothing enforces and nothing tests

**Proven.** `protocol/api.go:72` declares `RevocationEffectiveInSec = 5` and `API.md:268` promises
"effective server-side within 5 seconds". I grepped the whole repo: **the constant is read by
nothing** — its declaration is the only match. Meanwhile `registry.CacheTTL = 5 * time.Minute`
(`registry/http.go:17`) is how long rc-signal trusts a cached device binding.

**Suspicion, not proof, about impact**: the paths someone thought about are covered — `BumpEpoch`
invalidates the entry, `closeDeviceSessions` ends live sessions, and crucially the *entitlement*
gate is not cached, so an unlinked device is still refused at `connect`. My reading is that the
exposure is the pubkey/epoch binding rather than the authorization, which is much narrower than
"60× slower than promised". But no test asserts any of it, so the promise rests on nobody having
added a revocation path that forgets to bump the epoch.

---

### 10. The launch gate opts out silently, and still exits 0 when it does

**Proven.** `scripts/verify-launch.sh:18-21`:

```bash
if pgrep -x SkipperDesk >/dev/null 2>&1; then
    echo "skip  SkipperDesk is already running; not disturbing it"
    exit 0
fi
```

`ci-local.sh` runs it under `set -euo pipefail`, so exit 0 is a pass and the next two lines are
`check-isolation.sh` and **`PREFLIGHT PASSED`**. The script's own header says why it exists: a
recursive static initialisation once trapped SkipperDesk on launch *while all 421 tests passed*,
because the suite builds the app and never starts it. Starting the process is the one thing nothing
else in the gate does — and the single condition under which this check declines to do it is "a
SkipperDesk is already running", which is most likely to be true on **the owner's own Mac**, the
machine that cuts the release (`BETA.md` §7 step 3).

`pgrep -x SkipperDesk` also does not care *which* SkipperDesk: an installed copy from a previous
release, or a build left running by an earlier verify script, satisfies it. The gate can be
discharged by the very binary the new build is meant to replace.

The repo already holds the opposite principle, written out at `scripts/test-partition.sh:14`,
which refuses to run without root rather than skipping, because "a partition test that quietly
does nothing is worse than no test, because it reports success for the one behaviour this whole
phase exists for." The launch check is the same shape and goes the other way.

**Consequence**: `PREFLIGHT PASSED` can print over a build that has never been started, and the
only trace is one `skip` line in several hundred lines of compiler output. Ranked above the
disk-space finding below: a gate that fails loudly cannot ship a broken build, and one that passes
quietly can. It is conditional on the app running, which makes it the kind of defect that holds
for months and then doesn't, on the one day it matters.

**What I would do.** Stop the skip from being a pass. Either quit the running app and run the
check — the script already quits the app it starts, so the non-disruption it is protecting is
thin — or exit non-zero with `launch check not run; quit SkipperDesk and re-run`, so `ci-local.sh`
stops before `PREFLIGHT PASSED`. If being non-disruptive must stay possible, put it behind an
explicit `RC_LAUNCH_ALLOW_SKIP=1`, so opting out of the gate is a decision someone made rather
than the default on the owner's machine. Either way it is a few lines in one script, and it
restores the only check that would have caught the crash it was written for.

---

### 11. The release gate cannot currently be run

**Proven.** `CLAUDE.md` makes `scripts/ci-local.sh` the gate until the repo goes public. My first
run failed with `No space left on device` after ~8 minutes of Rust compilation. The disk is at
**100%, 67 MiB free**, holding **14 abandoned agent worktrees of ~1.8 GB of Rust `target/` each**
— roughly 25 GB of dead build output, plus 6.7 GB in the main checkout.

This is an environment problem rather than a repo defect, but it means the only release gate the
project has is not runnable on demand, and the owner will meet this exactly when they try to cut
the build in `BETA.md` §7 step 3. Worth one `git worktree prune` plus a `cargo clean` sweep before
anything else.

**Resolved for now**: the dead `target/` directories were cleared (~32 GB freed) and the gate then
ran clean — §G has the output. The finding stays because nothing prevents it recurring: fourteen
worktrees accumulated without anyone noticing, and the gate's failure mode was an eight-minute
wait followed by a linker error, not a message about disk.

---

### 12. Smaller things, grouped

| | Evidence | Why it is here |
|---|---|---|
| The client caps the server's own back-pressure | `APIClient.swift:315` — `min($0, 30)` on `Retry-After`. `WireBounds` accepts up to 86 400 and the signaling path honours it in full; only HTTP clamps | A server shedding load with `retryAfterSec: 300` is retried at 30 s. The app overrides the server on the one question only the server can answer |
| The client ignores the TTLs the server sends | `ttlSec` is decoded in four places and read in **none** (`AccountModels.swift:14`, `SignalMessages.swift:324,374,389`). `DeviceTokenStore.swift:33` hardcodes a 7-day refresh window; session renewal hardcodes 300 s in three places (`Config.swift:29`, `SessionStateMachine.swift:96`, `rc-session/src/lib.rs:194`) | Works only because `DeviceTokenTTLSec = 90 days` and `SessionTokenTTLSec = 600`. Shorten either server-side and shipped clients break. Contrast `SignalingClient.swift:315`, which correctly prefers the server's heartbeat interval |
| Unknown entitlement status fails closed to "no balance" | `AccountModels.swift:55` — `?? .exhausted` | `BETA.md` §1.5 promises the enum stays closed, so it is consistent today. But it means any future status makes every shipped build tell the customer they are broke |
| A second compiled-in domain | `Config.swift:149` `defaultWebBaseURLString = "https://skipperdesk.app"`, a second default beside the API base | `CLAUDE.md` says "one config value, the API base domain". The signaling URL *is* derived from it (`Config.swift:56-66`); the web base is not. No cert pin, IP, or team ID anywhere in the client — that half of the rule is clean |
| The domain baked into user-facing copy | `UpdateChecker.swift:65`, `UpdateViews.swift:28` — "Reinstall from skipperdesk.app" / "Open skipperdesk.app" while the URL opened is config-derived | A staging build names the wrong host to the user |
| `MinGiftAmountCents = 500` | `protocol/api.go:61`, enforced `credits.go:158` | Gifting is unreachable in beta: nobody can meet a $5 minimum out of a 50¢ grant. It equals the minimum *top-up*, which looks copied rather than decided — gift your entire first top-up or nothing |
| Clipboard text over 192 KB is dropped silently | `ClipboardSync.swift:9`, both directions, log only; `HostView.swift:150` advertises the feature with no limit | Presumably headroom under `MaxFrameBytes = 256 KB`, but that relationship is written nowhere and the tests assert relative to the constant, so they pass at any value |
| Unattended updates install only 03:00–05:00 | `UpdateChecker.swift:27` `quietHours = 3..<5`; `installUpdatesAutomatically` defaults true | A Mac asleep in that window never auto-updates, including the security updates `UpdateViews.swift:40` describes |
| Concurrent expiry can double-claw-back | `settleExpiredGrant` (`entitlement.go:71-88`) reads grant and balance outside the transaction, then `Append`s | **Suspicion.** Two entitlement reads landing together at expiry on an account holding both grant and top-up could write the clawback twice. The balance floor stops it going negative; it would take 50¢ of paid credit. Narrow, but it is money outside a transaction |
| Unlinking the granted device orphans the grant window | `UnlinkDevice` sets `account_id=''` (`apidb.go:768`); `TrialWindowForAccount` filters `unlinked=0`, so the window reads 0 → `settleExpiredGrant` returns early | **Suspicion, low value.** The 50¢ grant then never expires and reads as `active` rather than `trial`. Re-linking restores it, because `UpdateDeviceLink` preserves a non-zero `trial_ends_at`. Worth at most a line |
| Two latent env-var traps, correct in production today | `RC_TOKEN_SECRET` unset ⇒ a random ephemeral session-token key with **no warning** (`rc-signal/main.go:255-262`), unlike the two sibling secrets which do warn; `RC_TRUSTED_PROXIES` unset ⇒ every per-IP limit collapses onto one address | I verified production is correct: `bootstrap.sh:160` writes the token secret from SSM, and the live process runs `-trusted-proxies 127.0.0.1/32` with Caddy on the same host. Reported as hardening, **not** as live defects |

---

## What I checked and found sound

- **The charge arithmetic and the carry.** `policy.Charge` holds cost in seconds-at-the-hourly-rate
  and carries the remainder on the account. I could not make it lose or invent money: twenty
  90-second sessions cost the same as one 30-minute session, one hour costs exactly 10¢, 100
  repeats of a 59-second session cost what one 59-minute session costs (the C1 regression is
  genuinely closed — the free window is an account allowance, not a per-session gift), and
  `billed × 3600 + carry == seconds × rate` over arbitrary runs. Verified: 50¢ buys exactly 300
  minutes, $5 buys exactly 50 hours, 6 minutes costs exactly 1¢.
- **The balance floor.** `appendTx` refuses any entry taking an account below zero;
  `SettleCharge` clamps a charge to the available balance inside one transaction, drops the carry
  so the shortfall never lands on a later top-up, and returns `Clamped` so the session is closed.
  A negative balance is not reachable through the ledger.
- **The clawback.** `ExpiredGrantClawback` takes `min(unconsumed grant, balance)` and never a cent
  of paid credit; `UnconsumedGrant`'s window logic is idempotent (a `trial_expiry` closes the
  window whatever it was worth, and only a later `trial_grant` opens a new one).
- **The grant key (review5 H4).** Keyed on the verified mailbox with plus-tags folded, with the
  client-chosen device inputs kept only as further withholding. Well tested: five invented hardware
  IDs on one account earn one grant; three plus-tags on one mailbox earn one grant without merging
  the accounts; a withheld grant never fails the link.
- **The grant window is an account property**, read per account (`TrialWindowForAccount`), so a
  second device reports the same `trialEndsAt` and spends the same starting credits.
- **The live account matches what was promised.** Read-only off the instance: one account,
  `unbilled_units: 0`, one ledger entry `trial_grant +50` → balance 50, `trial_ends_at` exactly
  14 days after the grant's `created_at`, zero sessions ever. `BETA.md` §1.6's migration landed
  correctly, and no session has been metered in production yet.
- **The overrun bound is real and tiny.** `reconcileEvery = time.Minute`, and the live process
  runs with `-signal-internal-url` set (`"reconcile":true` in its startup log), so a session can
  outrun a zero balance by about a minute — roughly 0.17¢.
- **The client holds no secrets it should not.** No certificate pin, no IP, no STUN/TURN literal,
  no team ID: ICE servers come entirely from the server, and `UpdateTrust` takes the team ID from
  the running code's own signature.
- **The money arithmetic is not duplicated in the client.** `hostingTime` and `moneyString` do no
  policy arithmetic; `minutesRemaining` is computed server-side as `API.md` §4.2 requires. Rounding
  down to whole hours means the figure is never a promise the balance cannot keep. The carry is
  ignored by `MinutesRemaining`, which is under a minute of error — not worth changing.
- **Consent and PAKE guess limits live in the Rust core**, with no thresholds duplicated in Swift.
- `scripts/ci-local.sh` result: see §G.

## What I could not check, and why

- **Anything requiring a browser sign-in or a second Mac.** The whole of `BETA.md` §5.2 — install,
  Cognito handoff, TCC prompts, "online · Trial · about 5 hours left" — needs the owner's hands.
  I verified the *server* side of the grant and the *source* of the strings, not the walk-through.
- **A real metered session end to end.** Production has zero session rows, so the clamp, the
  cut-off and the `trial_expiry` entry have never run against live data. Everything in §1-§3 of
  "sound" is verified by code and tests, not by a session that happened.
- **The expiry at the 14-day boundary.** The live window is ~13.9 days out and I changed nothing,
  so `settleExpiredGrant` has never fired in production.
- **`relayUsed` against coturn's own count.** Finding 7 makes it unmeasurable today, and
  `BETA.md` §3.2 is right that it needs coturn accounting, which needs a config-deploy path the
  repo does not have.
- **Whether the quality clamp works**, since it does not exist yet (§F).
- **Anything that would change the instance.** I ran only read-only `describe`/`list` calls and
  read-only SSM diagnostics (`systemctl is-active`, `/proc/<pid>/cmdline`, a `mode=ro` SQLite open,
  log tails). Nothing was provisioned, deployed or modified.

---

## F. For the parallel agent (quality tiers, `bye`, `server/internal/hub`)

Three of my findings land inside that work:

1. **Finding 4 raises the stakes on the bitrate tiering.** It is not a polish item that can ship
   after the rate — the 10¢/hour rate is insolvent without it ($16.20 of relay against $5). The
   `auto` ceiling of 2 Mbps is load-bearing for the trial size, the rate, and §3.2's decision not
   to price relay. Worth saying so in the commit, so it is never deferred as cosmetic.
2. **Finding 3 wants a new bye reason, and you are in that frame.** Adding `relayUsed` to `bye`
   is the cheap moment to add a reason meaning "the account ran out", so
   `closeDeviceSessions` stops delivering it as `host_ended`. Note `ByeReasons` is a closed
   validated list (`protocol.go:134`) and the Swift side mirrors it, so it is a protocol change
   either way — better once than twice.
3. **Finding 6 is also in `hub`.** `endUnregisteredSessionLocked` collapses a concurrency refusal
   and an rc-api outage into one `ByeError`. If the `bye` frame is being touched, carrying a detail
   alongside the reason would discharge `BETA.md` §3.3's acceptance at the same time.

Nothing in my findings contradicts that work; finding 7 is simply the thing it fixes.

## G. The tree this audited

`main` at `33d72bd`, worktree `worktree-agent-a77dad5e0cec90855`, 2026-10-07.

`SKIPPER_TEAM_ID=3UB3KZP9WH ./scripts/ci-local.sh`: **first run failed** after the dependency gate
and partway through `cargo test --workspace`, with `No space left on device` — see finding 11, not
a code failure. **Re-run on 2026-10-08, once ~32 GB had been freed: it passes.**

```
== dependency gate
== rust format, lint, tests
== go format, vet, tests
== macOS core, tests, app, release gate
431/431 passed, 0 failed
  ok    the app launched and stayed up for 6s
ISOLATION CHECK PASSED — transport is native; the controlled browser is untouched.

PREFLIGHT PASSED
```

Exit status 0. `cargo fmt --check` and `cargo clippy -D warnings` clean on the four core crates;
23 Rust test binaries, 142 tests, 0 failures; `gofmt` clean, `go vet` clean, every Go package `ok`;
`swift run rc-tests` 431/431; `build-core.sh`, `test-provision-profile.sh` and `build.sh` silent;
`check-isolation.sh` all nine sections ok.

Two things to read honestly rather than as a green light:

- **Every Go package reported `(cached)`.** Nothing in `server/` or `protocol/` was recompiled or
  re-executed on this run; the result is Go's memo of an earlier identical run. It is a true pass
  of unchanged code, not fresh evidence.
- **The launch check really ran this time** — no SkipperDesk was running when I started it, so it
  took the `open`/`pgrep` path and reported `ok    the app launched and stayed up for 6s`. That is
  a genuine launch, and it is also the only reason `PREFLIGHT PASSED` means what it says here; had
  the app been running, finding 10 says the same line would have printed over an unstarted build.
  `swift run rc-tests` also emitted two benign `could not determine XCTest paths` warnings from
  `xcrun` (Command Line Tools without a full Xcode platform path); no test depends on XCTest.

I changed no tracked file other than this one, pushed nothing, and merged nothing.
