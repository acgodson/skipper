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
(RustCrypto crates, Apple's CryptoKit and Secure Enclave APIs, Google's libwebrtc).
The Mac app's former hand-written BLAKE2b/Argon2id target (`RCCrypto`, used only by
the protocol v1 server-side code check) has been deleted; nothing in the client
implements a primitive itself.

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
the *built* binary for linked WebKit/JavaScriptCore/proxy/VPN symbols, reads the
signed entitlements (`codesign -d --entitlements -`) and fails on
`disable-library-validation`, `get-task-allow`, `allow-jit`,
`allow-unsigned-executable-memory`, DYLD-environment, networking-extension or
system-extension entitlements, requires the hardened runtime on any Team ID build,
and fails if a development hook is still present in the binary. It is a release
gate, not just a style check.

## Development hooks

A handful of environment variables exist only so scripts can drive the app:
`RC_IDENTITY_DIR`, `SKIPPER_DEV_FILE_IDENTITY`, `RC_DUMP_FRAME`, `RC_INPUT_SELFTEST`,
`RC_CAPTURE_SOURCE`, `RC_PASTEBOARD_NAME`, `RC_SETTINGS_SUITE`, `RC_AUTOLINK`,
`RC_AUTOCONNECT` and `RC_LOG_FILE`. Every read of them is compiled only under
`#if DEBUG || SKIPPER_TEST_HOOKS` (centrally in `DevelopmentHooks`), so a release
build of SkipperDesk.app does not contain the code that reads them — no runtime
flag, bundle check or environment value can switch them back on, and
`check-isolation.sh` confirms their names are absent from the shipped binary
(except `SKIPPER_DEV_FILE_IDENTITY`, which also appears in an error message).
`rc-node` and `rc-tests` are built in debug by every script, so they keep them; the
on-device `scripts/verify-*.sh` checks need `./scripts/build.sh --test-hooks`, which
defines `SKIPPER_TEST_HOOKS`, marks the bundle `SkipperTestHooks` in Info.plist, and
is refused by `check-isolation.sh`. `SKIPPER_API_BASE_URL` and `SKIPPER_WEB_BASE_URL`
stay available in release (self-hosting and the two-Mac test need them); both are
validated by one rule (https only, plain http only for localhost/127.0.0.1) and the
app shows a permanent "Using a development server" banner whenever either points
away from the shipped backend.

## Signing

A Developer ID build runs under the hardened runtime with library validation on
and no `disable-library-validation`; `WebRTC.framework` is signed with the same
identity. A build signed without an Apple-issued certificate has no Team ID, so
library validation could never admit its own framework: such local builds are
signed without the hardened runtime and are for development only.

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
reproduced bit-for-bit is `WebRTC.framework`: it is prebuilt by the stasel/WebRTC
project from Google's libwebrtc, pinned by exact version and checksum, and not
something this repo compiles. `Package.swift` pins it with `exact:`,
`build.sh` resolves with `--force-resolved-versions`, `build-core.sh` builds with
`cargo build --locked`, and the Rust core is linked by absolute path.

This page will be updated as Phase 4 (client security pass) and Phase 5 (backend)
land. Last updated 2026-09-17.
