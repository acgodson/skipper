# RemoteControl

A private, 1:1, unattended remote-desktop app for Apple Silicon Macs — a personal AnyDesk.
One native Swift/SwiftUI app is both **host** (screen shared, input injected) and
**controller**. A small Go signaling server (`rc-signal`) plus coturn on a shared EC2 box do
rendezvous and TURN fallback only; they never see video, input or clipboard.

| Doc | What it's for |
|---|---|
| [docs/SPEC.md](docs/SPEC.md) | Product scope, security rules, non-goals — what the app must and must not do |
| [docs/DECISIONS.md](docs/DECISIONS.md) | Where we departed from the spec, and the lessons learned building it |
| [protocol/PROTOCOL.md](protocol/PROTOCOL.md) | Normative wire contract (signaling + `ctrl`/`hi` data channels) |
| [infra/legacy/README.md](infra/legacy/README.md) | The AWS box: isolation rules, SSM access, deploy runbook, live state |
| [apps/windows/WINDOWS-HOST.md](apps/windows/WINDOWS-HOST.md) | Windows host port — **parked**, see below |
| [docs/archive/](docs/archive/) | The original brief, build plan and phase log. Code comments cite `PLAN.md §x` / `AGENT.md` — those live here |

## Status (2026-09-16)

**Mac ↔ Mac: V1 working.** Screen, mouse (incl. true drag + pixel scroll), keyboard with
capture mode, gesture palette, two-way text clipboard, persistent Device ID + access code with
manual refresh, menu-bar background operation, launch at login, reconnect/resume across network
wobbles, TURN fallback. Installed and in use across two Macs. `dist/RemoteControl-1.0.0.dmg`
(build 3, 2026-08-26).

**Windows host: parked.** A Rust port lives in `apps/windows/` (shared crates in `core/crates/`); it builds and passes its tests from
macOS but crashed on real Windows and has never been debugged on a Windows machine. Not the
current goal.

### Known gaps
- No **automatic relay-only retry**: TURN servers are in the normal ICE config, but a session
  whose ICE fails closes (`bye: failed`) rather than retrying with `RC_ICE_POLICY=relay`.
- Local cursor is always an arrow (I-beam/resize shapes not sent over `ctrl`).
- `app_switcher` gesture is a full Cmd+Tab tap, not a held switcher (use capture mode).
- Main display only · text-only clipboard (≤ 192 KiB) · arm64 only.
- No Developer ID: first launch needs `xattr -cr` / "Open Anyway".
- Server IP + cert pin are compiled in; no Elastic IP (see infra/legacy/README.md for recovery).
- Leftover Phase-2 stubs: `PreviewTransport` (`Transport/SessionTransport.swift`) and
  `PreviewPresenceSource`, only reached in tests/debug.

## Layout

| Path | What lives there |
|---|---|
| `apps/macos/` | SwiftPM package (no Xcode needed). Targets: `RemoteControl` (app), `RemoteControlCore`, `RCCrypto` (Argon2id/BLAKE2b, always `-O`), `rc-node` (headless driver for scripts), `rc-tests` (test runner). WebRTC = `stasel/WebRTC` 125.0.0 |
| `apps/windows/` | Parked Windows host: `rc-host`, `rc-input`, `rc-transport`, `rc-signal-client` crates, plus `WINDOWS-HOST.md` |
| `core/crates/` | Shared Rust core: `rc-proto`, `rc-session`, `rc-identity` |
| `Cargo.toml` | Single root Cargo workspace over `core/crates/*` and `apps/windows/crates/*` |
| `server/` | `rc-signal` (Go): device registry (SQLite/WAL), Argon2id access-code auth, presence, sessions + resume tokens, SDP/ICE relay, TURN REST credentials. Plus `smokeclient`, `interopverify`, `rustcompat` |
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
cd apps/macos && swift run rc-tests              # ~262 unit/scenario tests (swift test needs Xcode)
./scripts/make-signing-cert.sh            # once: stable identity so TCC grants survive rebuilds
./scripts/build.sh                        # -> dist/RemoteControl.app
./scripts/package-dmg.sh                  # -> dist/RemoteControl-<version>.dmg, self-verifying
```

Integration against the **live** server (two `rc-node` instances, real WebRTC):
`test-transport.sh` (add `RC_ICE_POLICY=relay` to prove TURN), `test-media.sh`,
`test-input.sh`, `test-partition.sh` (root, `pfctl` blackouts). Inside the real `.app`
(needs the TCC grants): `verify-capture.sh`, `verify-input.sh`. Guards: `check-isolation.sh`
(no proxy/browser hooks), `interop-sig.sh` (Swift signature ↔ Go verifier).

Useful env: `RC_DEBUG=1` (diagnostics in UI/logs), `RC_ICE_POLICY=relay`,
`RC_IDENTITY_DIR` / `RC_SETTINGS_SUITE` / `RC_PASTEBOARD_NAME` (run two instances on one Mac).

## Installing on another Mac

1. Copy the `.dmg` by AirDrop, USB or `scp` (a browser download adds quarantine).
2. Drag **RemoteControl.app** to Applications, then once: `xattr -cr /Applications/RemoteControl.app`
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
- Plaintext access code never stored or logged server-side (client-computed Argon2id verifier).
- Session payloads (SDP, ICE, clipboard, input) never logged or persisted.
- Refreshing the access code bumps the device epoch: every session and token dies immediately.
- The app never touches browser/system networking (no proxy, VPN, PAC, DNS, extensions).
