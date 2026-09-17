# SkipperDesk — Security (public draft)

This is the factual security page for skipperdesk.app. No marketing language; every
claim below traces to `docs/SCOPE.md` §5 and `docs/DECISIONS.md` ("Protocol v2").
See `SECURITY.md` at the repo root for how to report a vulnerability.

## Threat model, in plain words

SkipperDesk connects two devices you own — a host and a controller — so you can
drive one from the other. Our servers exist only to introduce the two devices and
to relay bytes neither of them can reach directly.

**What the operator (us) can see:**
- That a device with a given Device ID exists and is online.
- When a session started, when it ended, and how many bytes moved — kept for
  billing, nothing else.
- The relay server sees encrypted media/data when a session cannot connect
  peer-to-peer and falls back to a TURN relay; it cannot decrypt it.

**What the operator cannot see:**
- The access code. It never reaches the server in any form — it is proved between
  the two devices directly with a PAKE exchange (below).
- The screen, keyboard, mouse, or clipboard content of a session — end-to-end
  encrypted, and never logged or persisted server-side.
- Which SDP/ICE messages are authentic. Both sides sign their SDP with a
  hardware-held device key, so even a fully compromised server cannot substitute
  its own key and man-in-the-middle the media.

**What a compromised or subpoenaed server can still do:** deny service (refuse to
relay), see connection metadata (who/when/bytes), and see TURN-relayed ciphertext
it cannot open. It cannot see plaintext of anything, and cannot silently insert
itself into a session because of the signed-SDP step above.

## Cryptography

| Purpose | Algorithm |
|---|---|
| Device identity | ECDSA P-256, held in the Secure Enclave (Mac) or TPM (Windows, DPAPI-wrapped software key as fallback) |
| Access code exchange | SPAKE2 (RustCrypto `spake2` 0.4) — the server relays opaque messages and learns nothing, correct guess or not |
| Key derivation | HKDF-SHA256 |
| Message authentication | HMAC-SHA256 |
| Session media transport | WebRTC DTLS-SRTP, AES-GCM |
| Signaling/API transport | TLS 1.2+ from a public CA |

No hand-written primitives. All of the above come from audited libraries
(RustCrypto crates, Apple's Secure Enclave APIs, Google's libwebrtc).

## What is logged

Session metadata only: device IDs involved, session start/end time, and bytes
transferred, kept for billing and abuse detection. No screen content, no
keystrokes, no clipboard content, no access code, no session key — in any form,
ever.

## Isolation

SkipperDesk never touches the controlled machine's system or browser networking:
no proxy, no VPN, no DNS interception, no browser extension, no `WKWebView`/
`JavaScriptCore` in the remote-control path. This is enforced by
`scripts/check-isolation.sh`, which greps the source for forbidden APIs, inspects
the *built* binary for linked WebKit/JavaScriptCore/proxy/VPN symbols, and checks
the bundle's entitlements — and is a release gate, not just a style check.

## Supply-chain gates

Every push and PR to `main` runs, before anything else builds:

- `scripts/verify-deps.sh` — fails the build if a lockfile is missing, if a git
  dependency isn't pinned to an exact commit, if the Swift WebRTC package isn't
  pinned to an exact version, if `go.sum` is out of sync with `go.mod`, or if the
  Go toolchain in `go.mod` differs from the one CI builds with.
- `cargo audit` and `govulncheck`, pinned to exact versions. Any finding fails
  the build. The server builds on a current, patched Go toolchain (pinned via the
  `toolchain` directive) because most Go advisories are in the standard library.
- `cargo fmt --check` and `cargo clippy -D warnings` on every crate in the shared
  core.
- The full cross-language protocol test vectors (`protocol/vectors/`).
- `scripts/sbom.sh` — generates a CycloneDX SBOM per language (Rust, Go, Swift)
  and uploads it as a CI artifact on every run.
- `scripts/check-isolation.sh` on the actual built `.app`, every PR and every push
  to `main`.

`./scripts/build.sh --reproducible` pins `SOURCE_DATE_EPOCH` to the commit being
built and normalises the Swift compiler's embedded debug paths, for anyone who
wants to verify a build matches its source. The one component that cannot be
reproduced bit-for-bit is `WebRTC.framework`: it is Google's prebuilt binary
xcframework (via `stasel/WebRTC`), not something this repo compiles.

This page will be updated as Phase 4 (client security pass) and Phase 5 (backend)
land. Last updated 2026-09-17.
