# SkipperDesk

A private, 1:1, unattended remote-desktop app for Apple Silicon Macs — a personal AnyDesk.
One native Swift/SwiftUI app is both **host** (screen shared, input injected) and
**controller**. A small Go signaling server (`rc-signal`) plus coturn do rendezvous and TURN
fallback only; they never see video, input, clipboard, or the access code. The desktop app and
protocol are open source; a hosted backend and paid tiers (see `docs/SCOPE.md`) come later.

| Doc | What it's for |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | Product scope, security rules, non-goals — what the app must and must not do |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Where we departed from the spec, and the lessons learned building it |
| [protocol/PROTOCOL.md](protocol/PROTOCOL.md) | Normative wire contract (signaling + `ctrl`/`hi` data channels) |
| [infra/legacy/README.md](infra/legacy/README.md) | The AWS box: isolation rules, SSM access, deploy runbook, live state |
| [apps/windows/WINDOWS-HOST.md](apps/windows/WINDOWS-HOST.md) | Windows host port — **parked**, see below |
| [docs/archive/](docs/archive/) | The original brief, build plan and phase log. Code comments cite `PLAN.md §x` / `AGENT.md` — those live here |

## Status (2026-09-17)

**Phases 1–2 implemented, green locally, awaiting two-Mac verification.** Protocol v2:
backend-agnostic client (one config value, the API domain), browser sign-in / account link,
entitlement-gated connect, Secure Enclave/Keychain device keys, SPAKE2 access-code exchange
between peers (server relays opaque bytes only), signed SDP fingerprints, trusted-controller
list, Refresh revokes everything. All carried over from V1: screen, mouse (incl. true drag +
pixel scroll), keyboard with capture mode, gesture palette, two-way text clipboard, menu-bar
background operation, launch at login, reconnect/resume across network wobbles, TURN fallback.
Per `docs/DECISIONS.md`, a phase counts only once observed working between two real Macs — that
observation hasn't happened yet for Phase 1–2, so treat this as tested in isolation (unit tests,
local server, shared vectors), not as field-verified.

**Windows host: parked.** A Rust port lives in `apps/windows/` (shared crates in `core/crates/`); it builds and passes its tests from
macOS but crashed on real Windows and has never been debugged on a Windows machine. Not the
current goal. Still v1: it predates protocol v2.

### Known gaps
- No **automatic relay-only retry**: TURN servers are in the normal ICE config, but a session
  whose ICE fails closes (`bye: failed`) rather than retrying with `RC_ICE_POLICY=relay`.
- Local cursor is always an arrow (I-beam/resize shapes not sent over `ctrl`).
- Main display only · text-only clipboard (≤ 192 KiB) · arm64 only.
- No Developer ID build has been verified yet.
- Real backend not built: Phase 5. Locally this is `rc-signal` (Go) plus `scripts/dev-web-stub.py`
  standing in for the web sign-in flow.

## Layout

| Path | What lives there |
|---|---|
| `apps/macos/` | SwiftPM package (no Xcode needed). Targets: `RemoteControl` (app), `RemoteControlCore`, `SkipperCore` + `CSkipperCore` (the shared Rust core, as Swift sees it), `RCCrypto`, `rc-node` (headless driver for scripts), `rc-tests` (test runner). WebRTC = `stasel/WebRTC` 125.0.0 |
| `apps/windows/` | Parked Windows host: `rc-host`, `rc-input`, `rc-transport`, `rc-signal-client` crates, plus `WINDOWS-HOST.md`. Still speaks protocol v1 |
| `core/crates/` | Shared Rust core: `rc-proto`, `rc-session`, `rc-identity`, `rc-ffi` |
| `Cargo.toml` | Single root Cargo workspace over `core/crates/*` and `apps/windows/crates/*` |
| `server/` | `rc-signal` (Go): device registry (SQLite/WAL), entitlement-gated connect, opaque SPAKE2 relay, presence, sessions + resume tokens, SDP/ICE relay, TURN REST credentials. Plus `smokeclient`, `interopverify`, `rustcompat` |
| `protocol/` | `PROTOCOL.md`, `protocol.go`, and cross-language test vectors (`vectors.json`, `session-scenarios.json`) |
| `infra/legacy/` | **Frozen** legacy deployment: compose (`rc-signal` + coturn), Dockerfile, coturn config, cert + deploy scripts |
| `scripts/` | Build, packaging, and integration/verification scripts |
| `dist/` | Built `.app` and `.dmg` (git-ignored) |

## Build & test

```sh
# Server
cd server && go test ./... && go build -o bin/rc-signal ./cmd/rc-signal

# Rust core + Windows host crates
cargo test --workspace                    # from the repo root
./scripts/smoke-signal.sh                 # local server + two WS clients, PASS/FAIL per step

# App
./scripts/build-core.sh                   # builds librc_ffi.a — required before swift build/run
cd apps/macos && swift run rc-tests              # 270 unit/scenario tests (swift test needs Xcode)
./scripts/make-signing-cert.sh            # once: stable identity so TCC grants survive rebuilds
./scripts/build.sh                        # -> dist/SkipperDesk.app
./scripts/package-dmg.sh                  # -> dist/SkipperDesk-<version>.dmg, self-verifying
```

Local end-to-end (no real backend needed yet): `./scripts/smoke-signal.sh` and
`./scripts/test-transport.sh` run `rc-signal` on `127.0.0.1:18443`; account linking is exercised
against `scripts/dev-web-stub.py` standing in for the web sign-in page, with
`SKIPPER_API_BASE_URL` pointed at it.

Integration against the **live** server (two `rc-node` instances, real WebRTC):
`test-transport.sh` (add `RC_ICE_POLICY=relay` to prove TURN), `test-media.sh`,
`test-input.sh`, `test-partition.sh` (root, `pfctl` blackouts). Inside the real `.app`
(needs the TCC grants): `verify-capture.sh`, `verify-input.sh`. Guards: `check-isolation.sh`
(no proxy/browser hooks), `interop-sig.sh` (Swift signature ↔ Go verifier).

Useful env: `SKIPPER_API_BASE_URL` (backend to talk to; defaults to
`https://api.skipperdesk.app`, or `http://127.0.0.1:18443` for the integration
scripts — `http://`/`ws://` is only accepted for `localhost`/`127.0.0.1`), `SKIPPER_WEB_BASE_URL`
(web sign-in page for account link), `SKIPPER_DEV_FILE_IDENTITY` (dev-only file-backed identity,
never a release path), `SKIPPER_TEAM_ID` (Developer ID team, enables Secure Enclave entitlements
in `build.sh`), `RC_DEBUG=1` (diagnostics in UI/logs), `RC_ICE_POLICY=relay`,
`RC_IDENTITY_DIR` / `RC_SETTINGS_SUITE` / `RC_PASTEBOARD_NAME` (run two instances on one Mac).

## Installing on another Mac

1. Copy the `.dmg` by AirDrop, USB or `scp` (a browser download adds quarantine).
2. Drag **SkipperDesk.app** to Applications, then once: `xattr -cr /Applications/SkipperDesk.app`
   (`-r` matters). Without Terminal: try to open it, then System Settings → Privacy &
   Security → "Open Anyway" (only appears after a blocked attempt, for about an hour).
3. Grant **Screen & System Audio Recording** (else a black screen) and **Accessibility**
   (else input does nothing).
4. Note Device ID + Access Code, turn on **Launch at Login**, close the window — it stays in
   the menu bar.

Two traps: TCC grants are tied to the code signature (hence `make-signing-cert.sh`), and TCC
is attributed to the *responsible process* — always launch the bundle with `open`, never the
inner binary from a shell.

## Security invariants
- The server never sees the access code in any form: it is proved peer-to-peer by a SPAKE2
  exchange, and the server only relays opaque bytes between the two peers.
- SDP is signed by each side's hardware-held device key (Secure Enclave, Keychain fallback), so a
  compromised server cannot MITM the media.
- `connect_req` is authorised by server-checked entitlement, not by the access code.
- No session payload (SDP, ICE, clipboard, input) is ever logged or persisted.
- Refresh Code revokes everything at once: every session, every token, and both peers' trusted-
  controller state.

## Supply chain & CI

`.github/workflows/ci.yml` runs on every push and PR to `main`: a `verify-deps` gate first, then
Rust (`cargo fmt --check` / `cargo clippy -D warnings` / `cargo test --workspace` for the four
shared-core crates — the parked Windows crates are excluded, they need a mingw toolchain no
runner here has), Go (`gofmt`, `go vet`, `go test`, `go build`, `scripts/smoke-signal.sh`), an
SBOM job, and — only for non-docs changes, on `macos-14` — a full app build plus
`scripts/check-isolation.sh` against the built `.app`.

- `scripts/verify-deps.sh` — fails if a lockfile is missing or incomplete, if a git dependency
  isn't pinned to an exact commit, or if the Swift `stasel/WebRTC` package isn't pinned to an
  exact version; prints the third-party dependency count per language; runs `cargo audit` /
  `govulncheck` when they install within a minute (a slow install is not fatal, a real finding
  is).
- `scripts/sbom.sh` — writes a CycloneDX 1.5 JSON SBOM per language to `dist/sbom/` (Rust from
  `cargo metadata`, Go from `go list -m -json all`, Swift from `Package.resolved`), uploaded as a
  CI artifact on every run.
- `./scripts/build.sh --reproducible` pins `SOURCE_DATE_EPOCH` to the building commit's timestamp
  and passes `-Xswiftc -debug-prefix-map` so the repo's local path isn't embedded in the binary,
  then normalises file timestamps in the built bundle to that same epoch. What this does **not**
  make reproducible: `WebRTC.framework` is Google's prebuilt binary xcframework (fetched via
  `stasel/WebRTC`), not something this repo compiles, so its bytes are whatever that release
  shipped, unrelated to `SOURCE_DATE_EPOCH`. Two `--reproducible` builds from the same commit are
  not guaranteed to be byte-identical beyond that either — Swift's own build metadata (module
  timestamps, `swiftmodule` UUIDs) is not fully addressed by these flags; treat this as
  best-effort determinism, not a verified reproducible-build guarantee.

See `SECURITY.md` (how to report a vulnerability) and `docs/SECURITY.md` (the public security
page: threat model, crypto table, what is logged, isolation rule, these gates).
