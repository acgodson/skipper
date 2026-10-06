# SkipperDesk — engineering rules

Read `docs/SCOPE.md` first. These rules are binding for every agent working in this repo.

## Code
- **No inline comments.** Only `TODO:` lines and rare title comments on a file or a genuinely
  non-obvious block. Code explains itself through names and structure.
- **No duplicated code.** Anything used twice becomes a shared package (`core/crates/*` for
  Rust, a Swift target under `apps/macos`, a Go package under `server/internal`).
- **Shared Rust core owns** wire protocol types, session state machine, identity/crypto (PAKE,
  key schedule), and the C FFI. Platform apps own only UI, capture, input, clipboard, key storage,
  and the WebSocket transport.
- **Backend-agnostic client:** one config value, the API base domain. Never a compiled-in IP or
  certificate pin.
- **Standard algorithms only:** P-256 for hardware-held device keys, AES-GCM, HKDF-SHA256,
  SPAKE2 for the access code. No hand-written primitives.
- **Dependencies:** OS-native or AWS-managed first; third-party only when widely audited
  (RustCrypto, Google libwebrtc, golang.org/x). Every new dependency is named in the PR.
- **Never** touch system/browser networking (proxy, VPN, DNS, extensions). `scripts/check-isolation.sh`
  is a release gate.

## Tests
- Test logic, not rendering. No unit tests for UI, layouts, or anything that only proves a
  framework works. No mocks of platform APIs to "test" a view.
- Cross-language behaviour is proven by shared vectors in `protocol/vectors/`; every
  implementation must pass them.
- Platform-specific behaviour (capture, input, keychain, TCC) is verified on real machines at
  the end of a phase, using the `scripts/verify-*.sh` pattern.

## Infra
- The legacy shared EC2 box (`infra/legacy`) is **frozen**. No deploys, no changes.
- New backend lives in a fresh AWS account; nothing is provisioned until Phase 5.

## Process
- The overseer (Claude) delegates: **sonnet** for clear, patterned, repetitive work; **opus**
  for implementational work. Every delegated task states its acceptance check.
- When two options exist, pick the one that best serves `docs/SCOPE.md` — do not ask.
- A phase is complete only when observed working between two real Macs.
- Commit small, on branches; PR descriptions list new dependencies and any protocol change.
- GitHub Actions is out of free minutes while the repo is private (jobs are cancelled before a runner
  starts). `scripts/ci-local.sh` is the gate until the repo goes public — run it before every push.
