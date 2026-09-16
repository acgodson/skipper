# SkipperDesk — Project Scope

Status: research and planning, no product code yet. Baseline: the working Mac↔Mac
RemoteControl V1 in this repo (see README.md, docs/DECISIONS.md). Written 2026-09-16.

---

## 1. Vision and positioning

**SkipperDesk** (skipperdesk.app) is a private, unattended remote desktop: *you driving your own
other computer*, from anywhere, with no session limits and encryption the operator cannot break.

Positioning, in one line: **"Your other computer, in your pocket — private by design, cheaper
than AnyDesk."**

Not what we are: an AI computer-use agent (Claude/Codex "control my browser") — those drive
*your* machine for you. We connect *you* to *your* machine. The optional **Skipper** agent
(§3.3) sits on top of that, it is not the product.

Goal for launch: **5,000 paying hosts or $25,000 revenue**, whichever first.

## 2. Principles (every decision is checked against these)

1. **Security first, features paced.** Open-source client that survives public scrutiny.
2. **Zero-knowledge operator.** Our servers must not be able to see a desktop, an access code, or
   a session key — even if compromised or subpoenaed.
3. **Windows is a front end, not a rebuild.** Standard algorithms; per-platform code only where
   the OS truly differs (capture, input, key storage, UI).
4. **Minimal, audited dependencies.** Prefer OS-native and AWS-managed over third-party packages.
5. **Cost scales with revenue.** A paying host must cover their own infrastructure cost with
   margin; idle users must cost ~nothing.
6. **Simple.** The app shows state, not telemetry. One screen to connect, one screen to host.

## 3. Product surface

### 3.1 Desktop app (open source) — macOS first, Windows later
| Role | Needs account? | Pays? |
|---|---|---|
| **Host** (machine being controlled) | Yes — links the device to the account holding the subscription/trial | Yes |
| **Controller** | No — Device ID + access code works without sign-in. Sign-in is optional (device list, presence) | No |

Host screen: Device ID · Access Code · Refresh · online status · unattended access · clipboard sync
· "Remote session active" banner · end session · trusted controllers list.
Controller screen: Device ID + code → connect; saved devices with live presence; full-window
remote desktop with capture-mode toggle and gesture palette; quality mode.

Carried over from V1 unchanged: screen streaming (H.264 hardware), mouse incl. true drag and
pixel scroll, keyboard with capture mode, gesture palette, two-way text clipboard, menu-bar
background operation, launch at login, reconnect/resume through network wobbles, TURN fallback.

Design system: one documented visual language (tokens: colour, type, spacing, components,
motion, states) implemented natively per platform (SwiftUI now, WinUI later). No cross-platform
UI toolkit.

### 3.2 Web (skipperdesk.app)
Sign-in (Cognito under our own UI), account and devices, subscription/credits, gifting, payment
(crypto, last phase), download, docs. The app never handles passwords: sign-in happens in the
browser and hands the app a short-lived token via a custom URL scheme.

### 3.3 Skipper agent (paid tier, later)
A remote AI helper for the host machine, gated by tier/usage. Starts small and observable:
1. **Observability** — "is my Mac up, what's it doing, screenshot on demand."
2. **Liveness** — keep the host awake and reachable, detect and report when it goes offline,
   recover the app if it crashes.
3. Later, opt-in tasks on the host. Never on by default; never able to act without the owner's
   explicit setting. Design so it cannot become a covert backdoor.

## 4. Architecture

```
skipperdesk.app (web)        api.skipperdesk.app            Desktop app (open source)
┌──────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────────┐
│ sign-in (Cognito)│   │ REST: account, devices,  │   │ Platform layer (Swift / Win)  │
│ billing, credits │◄─►│  entitlements, trial     │◄─►│  UI · capture · input ·       │
│ gifting, web3    │   │ WS: signaling (PROTOCOL) │   │  clipboard · key storage      │
└──────────────────┘   │ TURN creds (coturn REST) │   ├──────────────────────────────┤
                       └──────────────────────────┘   │ Shared core (Rust)            │
                                  │                   │  protocol · PAKE · key sched. │
                             coturn relays            │  session state machine        │
                        (only when P2P fails)         └──────────────────────────────┘
```

**Backend-agnostic client.** The app knows one config value: the API domain. No IP, no cert
pin. Anything implementing the contract (signaling WS + REST) is a valid backend:
local dev server → temporary tunnel → fresh AWS account, with no app change.

**Shared Rust core** — decided: the security-critical logic — wire protocol, PAKE, key schedule,
session state machine — is written once, in `core/crates` (`rc-proto`, `rc-session`,
`rc-identity`, `rc-ffi`), and used by the Mac app through the `rc-ffi` C interface
(`SkipperCore`/`CSkipperCore` in `apps/macos`). Every platform still passes the same shared test
vectors (`protocol/vectors/`) before shipping.

**Existing AWS box is frozen.** No changes until the new account exists; then migrate and retire.

## 5. Security model

| Layer | Mechanism | Notes |
|---|---|---|
| Device identity | ECDSA **P-256** key, hardware-held: **Secure Enclave** (Mac), **TPM** (Windows; DPAPI-wrapped software key as honest fallback) | Same bytes on the wire from either. Requires Apple Developer account |
| Access code | **PAKE** — decided: **SPAKE2** (RustCrypto `spake2` 0.4) | Server relays opaque messages, learns nothing. Host rate-limits guesses itself |
| Trusted controllers | Host remembers a controller's public key after a successful code; later connects are key-only | **Refresh Code** revokes the list too — one button revokes everyone |
| Session transport | WebRTC DTLS-SRTP (AES-GCM) | Already E2E vs outsiders; SDP fingerprints now **signed by the device key** so a compromised server cannot MITM |
| Signaling/API | TLS from a public CA on skipperdesk.app | Replaces self-signed pin; `NSAllowsArbitraryLoads` removed |
| Concurrency | **One controller per host at any time**; one active pair per subscription | Enforced server-side at connect |
| Abuse / trial | Trial keyed by **host device key** (not account); plus server-salted hash of hardware serial for trial purposes only (as AnyDesk/RustDesk machine-id) | OS wipe = new device; acceptable, made expensive by the serial hash |
| Privacy | No screen, keystroke, clipboard or code on the server. Session metadata (who/when/bytes) only, for billing | Documented in a public security page |
| Isolation | Never touches system/browser networking (no proxy/VPN/DNS/extension) | `check-isolation.sh` stays a release gate |
| Supply chain | Reproducible builds, signed + notarized, signed auto-update, dependency pinning, SBOM | Required for open source credibility |

Explicitly out: browser-style fingerprinting (spoofable, disliked by reviewers). The hardware key
*is* the fingerprint.

## 6. Accounts, entitlements, abuse rules

- Sign-in via **Cognito** (free to ~10k MAU): email, Apple, Google; passkeys when practical.
- Account holds: subscription/credits, linked host devices, trial state, gifts.
- Rules enforced server-side at every `connect`:
  1. Host device must be linked to an account with a valid trial or positive balance.
  2. One active session per host; a second controller gets `busy`.
  3. One active pair per subscription/credit pool at a time.
- Multiple accounts are allowed; the device rules make trial farming pointless.
- Lock-outs/timeouts that require payment are defined in the business phase (§7), not hard-coded
  in the client — the client obeys entitlement responses, so the policy can change server-side.

## 7. Business model (to be refined in its own phase)

Stated intent, recorded so the architecture supports it:

- Host pays; controllers free.
- **Metered, prepaid:** minimum top-up **$5**, consumed at **cents per hour** of connected
  session time (rate TBD by tier). Streamed/settled against the balance.
- **No withdrawals** (policy to be drafted legally). Unused balance stays as **platform credits**.
- **Gifting:** credits can be gifted to another user by email (Codex-style).
- **Tiers:** base remote desktop; higher tier unlocks Skipper agent usage.
- Free trial: per host device, duration/hours TBD.
- Pricing target: visibly below AnyDesk's personal/professional plans while covering relay cost
  with margin (relay bandwidth is the dominant cost — see §8).

Deferred to that phase: exact rates, trial length, what "addictive interactions" means concretely
(likely: instant connect, saved devices, presence, wake-on-demand), referral mechanics, launch plan.

## 8. Infrastructure and cost (fresh AWS account; detailed in the backend phase)

- **Auth:** Cognito.
- **API + signaling:** small Go service(s) — container or Lambda+API Gateway WebSocket; shared
  presence state (DynamoDB or ElastiCache) so it can scale horizontally.
- **Relays:** coturn on the cheapest instances with the right egress; regional placement to
  keep latency low and P2P success high. **Egress is the cost** (~1 GB/hour relayed); pricing
  must assume a relay share and charge accordingly.
- **Cloudflare (Workers/Pages/Tunnel):** candidate for website hosting, edge caching, DDoS
  protection, and the *free persistent dev tunnel* before the domain is live. Not for relays
  (UDP). Role finalised in the backend phase.
- **Dev/tunnel before domain:** local Go backend + Cloudflare Tunnel (free, persistent, no
  timeout) — preferred over ngrok free tier.
- Budget principle: near-zero at idle; every component pay-per-use or smallest instance.

## 9. Payments (last phase, on criteria to be given)

Crypto only at launch, streaming-style (x402-family) settlement. Chains: Algorand, EVM, Base,
BNB. Stablecoins only: USDC, USDT. Handled entirely on the web, never in the desktop app.
The credit ledger (§7) is designed now so any payment rail just credits it.

## 10. Open source

- **Public:** desktop app, shared core, protocol, test vectors, design system.
- **Private:** backend, billing, Skipper agent server side, infra.
- **Licence:** decision pending (AGPL protects against closed forks; Apache/MIT invites
  contributors). Trademark on the name and logo either way.
- Contributor surface: UI, interactions, platform ports, translations. Security-critical core
  changes require maintainer review and pass the vectors.
- Public security page + responsible disclosure policy before the code is public.

## 11. Phases

| # | Phase | Deliverable / exit check |
|---|---|---|
| 0 | **Foundations** | git repo; Apple Developer account; skipperdesk.app; licence chosen; API contract (REST + existing WS) written beside PROTOCOL.md |
| 1 | **Backend-agnostic client** | App runs against a *local* backend by config; IP/pin removed; browser sign-in handoff; device linked to account; entitlement gate at connect — **implemented 2026-09-17, pending two-Mac verification** |
| 2 | **Security core** | Secure Enclave keys; PAKE access code; signed SDP fingerprints; trusted controllers; Refresh revokes all. Cross-language vectors green. Decide shared Rust core vs native — **implemented 2026-09-17, pending two-Mac verification** |
| 3 | **SkipperDesk UI** | Design system documented; new host/controller/session screens; state-only UI; notarized, signed, auto-updating build |
| 4 | **Client security pass** | Third-party or structured review of the open-source surface; supply-chain gates; security page; then go public |
| 5 | **Backend on fresh AWS** | Cognito, API, signaling, relays, presence store, metering ledger; migrate off the shared box; load and cost measured |
| 6 | **Business logic** | Trial, metering rates, lock-outs, credits, gifting, tiers; launch plan |
| 7 | **Skipper agent v1** | Observability + liveness for paid tier |
| 8 | **Crypto payments** | On the user's criteria |
| 9 | **Windows host/controller** | New platform layer on the shared core; same design system |

Each phase is complete only when observed working between two real Macs (and, from Phase 9,
a real Windows PC). Never on mocks.

## 12. Open decisions

1. Licence: AGPL vs Apache-2.0/MIT.
2. Signaling runtime: containers vs Lambda WebSocket (cost at idle vs latency).
3. Relay placement and provider for egress cost.
4. Trial length and metering rates.
