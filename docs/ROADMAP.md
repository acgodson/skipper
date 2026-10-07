# SkipperDesk — roadmap and progress

The single place to see what is done, what is running, and what is queued.
Scope and rationale live in `docs/SCOPE.md`; this file tracks state. Updated 2026-10-07.

A phase is **Done** only when observed working, per `CLAUDE.md` — tests alone never close one.

## Done

| # | Item | Evidence |
|---|---|---|
| 1 | Backend-agnostic client (one config value, no compiled-in address) | `test-transport.sh` 89/89 against a real backend |
| 1 | Browser sign-in, device linked to an account, entitlement-gated connect | live `/link` flow; refusals for unlinked / expired trial |
| 2 | Security core: Secure Enclave keys, SPAKE2 access code, signed SDP, trusted controllers, host consent | three adversarial reviews, all findings fixed (`docs/SECURITY.md`) |
| 2 | Protocol v5: strict relay, session-scoped TURN, fair rate limits, device-ID certificates | shared vectors in `protocol/vectors/`, cross-language |
| 3 | SkipperDesk design system and UI | `docs/DESIGN.md`, screenshots in `docs/design/` |
| 3 | Signed self-update with rollback, no third-party updater | U2 run on a notarized build (0/60 tampered, 60/60 refused); the earlier 850-run review harness is not in the repo and cannot be re-run (`docs/SECURITY.md`) |
| 4 | Supply chain: dependency gates, vulnerability audit, SBOM, release gate | `scripts/ci-local.sh`, `scripts/check-isolation.sh` |
| — | Signed + notarized build, Developer ID, data-protection keychain | `spctl` → "Notarized Developer ID" |
| — | One-Mac verification | `docs/VERIFY.md`, all items except those needing two machines |
| — | Gesture palette acts on the host (Mission Control, App Exposé and the rest) | fixed 2026-10-06; `verify-input.sh` now asserts the host really enters them |
| — | Every gesture-palette entry acts on the host, including Force Quit | `verify-input.sh` 19 checks; Lock Screen is held back from the palette until it is observed (`docs/VERIFY.md`) |
| — | A host Mac stays awake while reachable, never sleeps during a session, and wakes its display on connect — no setting | `pmset -g assertions` readings in `scripts/verify-stay-awake.sh` |

## In progress

**Phase 5 — AWS backend.** Planned in `docs/PHASE5.md`, built but not yet applied.

| Step | State |
|---|---|
| Member account under the existing organization, scoped Identity Center access, spend budget | done |
| `infra/aws`: Terraform, cloud-init, systemd, Caddy, coturn, backups, deploy — carrying nothing from `infra/legacy` | done |
| `rc-api` signs device-ID certificates inside KMS; no private key on the box | done |
| Databases on their own encrypted volume; Terraform state in S3 before any secret reaches it | done |
| IAM scoping, CloudTrail, Session Manager logging | done |
| Applied. `api.skipperdesk.app` and `turn.skipperdesk.app` live on `3.8.76.202`, TLS from Let's Encrypt | done |
| **5.1 acceptance**: health 200 on a trusted chain, `/internal/*` 404 from the internet, `/signal/healthz` 200, TURN 3478 udp+tcp open | done |
| Reboot proven: the data volume remounts and all four services start unattended | done |
| Sign-in website built, on its own stack and its own Terraform state (`web/`, `infra/web/`) | done |
| CORS on the link call, the Cognito ID token pinned by `token_use`, a sign-in that cannot double-open | done |
| Website live at `skipperdesk.app` on CloudFront, private bucket, full security headers | done |
| **5.1 closed** — a real Mac signed in against the live backend: link 201, device registered, certificate signed in KMS in 6 ms, entitlement 200 | done |
| 5.2 TURN credentials end to end: the secret matches, a minted credential allocates on the live coturn over udp and tcp, a tampered or foreign-session one is refused, and the credential dies at 600 s to the second. `scripts/verify-turn.sh` re-proves it on demand | done |
| 5.2 found the relay broken: `denied-peer-ip=::` denies every IPv4 peer on coturn 4.6.1, so the relay allocated and then refused every peer — and every "private peer refused" check had been passing for the wrong reason. One line removed, deployed 2026-10-07, coturn restarted; `verify-turn.sh` now passes 7 checks with a public peer relayable and private peers refused | done |
| Launch is **email sign-in only** (decided 2026-10-07). Apple and Google come after launch: both need a Services ID, a `.p8`, a Google OAuth client and a custom Cognito domain, and none of it is needed to sell the product. The Terraform and the SSM parameters already exist, inert, behind `enable_social_idp = false` | decided |
| 5.3 found that **nothing writes `relayUsed` or `bytesRelayed`** — the columns exist, the hub's stop report sets neither, and no wire field carries them, so 5.3's written acceptance cannot be met by any run (`docs/PHASE5.md` §8.2). The client can now *see* the route at all: `ICEPathStatistics` reads the selected candidate pair, `rc-node ice-path` prints it, `scripts/verify-relay.sh` proves relay-only really excludes every other route. Deployed coturn logs no allocations and no bytes, so the relay side corroborates nothing | found |
| 5.2 remainder + 5.3: `ice_servers` observed on a real production session, media forced over the relay. Both need one owner action apiece — a second linked device for the first, unattended access plus the host's access code for the second (`docs/VERIFY.md`) | blocked on owner |
| 5.4 fifth review; 5.5 cutover | queued |

## Queued, in order

| # | Item | Why it is here | Done when |
|---|---|---|---|
| 1 | **Cross-network + relay proof** | The riskiest untested thing: two endpoints on different networks, and the TURN fallback. Needs TURN, so it rides with Phase 5; a cloud peer stands in for a second Mac (the headless host must come from v1 to v5 first) | A session across two real networks, and one forced onto the relay |
| 2 | **Fourth security review** | Read-only pass done 2026-10-06; its one HIGH and the nine other findings are fixed on `sec/review4-fixes`. What remains is a re-read of the fixes | No HIGH or CRITICAL findings outstanding |
| 3 | **Phase 5 — AWS backend** | Fresh account: Cognito, API, signaling, relays, the domain, TURN. First real money. Planned in `docs/PHASE5.md`; waits on the owner-only steps there | Two Macs connect through `skipperdesk.app`, relay fallback proven |
| 4 | **Phase 6 — business logic** | Trial length, rate per hour, lock-outs, credits, gifting, tiers | Priced, metered and enforced end to end |
| 5 | **Phase 7 — Skipper agent** | Observability and liveness for paid tiers; also explains *why* a Mac is offline | Opt-in, never silent |
| 6 | **Lock-screen support** | Designed (`docs/LOCKSCREEN.md`). Viewing is feasible on Apple's supported path; typing needs DriverKit HID entitlements Apple grants by request, the same route Karabiner uses. Ships a root component, so it keeps its own review | L1: the lock screen is visible from a controller |
| 7 | **Phase 8 — crypto payments** | x402-style streaming, USDC/USDT, on the user's criteria | Deferred until the criteria are given |
| 8 | **Phase 9 — Windows host** | Parked Rust port in `apps/windows/`, still protocol v1 | Windows Mac↔PC session |
| 9 | **Open the repo** | Deliberately after launch, not before | The user says so |

## Before the repo is ever public (history rewrite — plan deliberately)

Found by the fourth security review. Nothing is exposed today (the repo is private), but each needs removing from the tree AND from history:

| Item | Where |
|---|---|
| Full targeting details for the frozen EC2 box (account, instance, region, IAM profile, security group, public IP, open ports) | `infra/legacy/**`, `docs/archive/aws.md`, `docs/archive/PLAN.md` |
| Another company's private image reference | `infra/legacy/.baseline.txt` |
| That public IP baked into generated vectors and the parked Windows host | `protocol/vectors/*`, `apps/windows/**` — regenerate against `192.0.2.1` |
| A deleted 17 MB server binary still in history (936 local build paths) | blob from commit `8f7080b` |
| Decide first, since they need the same pass | commit author email; bundle id still `com.godson.remotecontrol` while the product is SkipperDesk |
| Re-check immediately before the first public push | `infra/legacy/.env` and `certs/server.key` are gitignored and were never committed |

## Waiting on Apple (request early — they take time)

| Entitlement | Needed for |
|---|---|
| `com.apple.developer.persistent-content-capture` | Unattended capture without macOS 15 re-asking for Screen Recording weekly and after every reboot |
| DriverKit HID (five) | Typing and clicking at the lock screen at all |

## Deferred to beta (decided 2026-10-06, recorded as unproven)

| Item | Why it is safe to defer |
|---|---|
| Window drag by title bar (VERIFY 9) | One Mac has one pointer: the host's injected mouse-down steals the grab from the controller window. The wire half passes (`test-input.sh`: drags cross as drags, not moves) |
| "Send shortcuts" ON half (VERIFY 11) | The controller's capture tap re-captures the host's injected keystroke on the same Mac. The OFF half passes, and the ON half is proven to reach the host |
| I-beam cursor over text (VERIFY 14) | macOS only sets cursor rects for the active app, and on one Mac that must be the controller |
| Lock Screen gesture | Held back from the palette; proving it locks this Mac needs a second machine |

These are observed on a second machine during beta, not before.

## Smaller items, not blocking

| Item | Note |
|---|---|
| Permissions refresh live in the UI | Today a grant needs an app relaunch |
| Identity folder still named `RemoteControl` | Rename with migration before launch |
| Relay path untested end to end | Needs TURN, so Phase 5 |
| GitHub Actions out of minutes while private | `scripts/ci-local.sh` is the gate |
| macOS has no "busy" or diagonal-resize cursor | Cosmetic, documented |
| Lock Screen gesture unverified | Held back from the palette (fourth review); the wire name and plumbing stay, it returns when lock-screen viewing lands |
| `ci-local.sh` fails if a dev backend holds its ports | Stop `dev-backend.sh` first |
| The app icon ships as-is for launch (decided 2026-10-07) | The compass in `apps/macos/Resources/AppIcon.iconset` was generated by the design agent in Phase 3, not chosen. It shares Safari's metaphor and is confusable with it in a Dock at small sizes. Deliberately accepted for launch; a designed mark comes in a post-launch update |
| No deploy path for a configuration change | `deploy.sh` ships binaries only. Changing `turnserver.conf`, the Caddyfile or a unit means `terraform apply` to update the S3 object, then installing it on the box and restarting the service by hand over SSM. That is how the TURN deny-line fix had to be shipped, and it should be a script |
| rc-api's plaintext warning says "local testing only" in production | It is correct — Caddy terminates TLS and rc-api is on loopback — but it reads like a misconfiguration, and it is worded identically whether the listener is loopback or `0.0.0.0`. The dangerous case should be the loud one |
| ~~Intermittent: signing in twice while a sign-out is unfinished opens two browser windows~~ | Fixed. `beginLink()` spawned a sign-out-then-link task per call, and two whose retries both succeeded each opened a window; one runs at a time now. The test waited on `Task.yield()`, which does not wait for a URLSession answer — that is why it failed one run in ten rather than every time. It waits on the clock now, and both cases fail 3/3 with the fix reverted |
