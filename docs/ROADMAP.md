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
| IAM scoping, CloudTrail, Session Manager logging | in progress |
| `terraform apply`, then the two DNS records at the registrar | next |

Nothing is provisioned yet beyond the budget alarm.

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
