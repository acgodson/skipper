# Decisions and lessons

The distilled record of the build. Full phase-by-phase notes: [archive/PLAN.md](archive/PLAN.md).

## Decisions that depart from the brief

| Decision | Why |
|---|---|
| **Single native Swift/SwiftUI app** instead of Tauri + React + Rust | libwebrtc (`stasel/WebRTC`) gives VideoToolbox H.264, Google BWE, ICE, DTLS and data channels for free. A webview can't capture unattended (`getDisplayMedia` prompts every time). Two languages (Swift, Go) instead of four. Builds with `swift build` and no Xcode |
| **Go** signaling server instead of Node | One static binary, idle-cheap next to a production service |
| ~~**File-based secrets** (`~/Library/Application Support/RemoteControl/identity.json`, 0600) instead of Keychain~~ | **REVERSED 2026-09-16** — see below. Held while there was no Developer ID account: Keychain ACLs bind to the code signature, so every ad-hoc rebuild re-prompted, and the Secure Enclave returned `-34018` |
| ~~**No Apple Developer account**~~ | **REVERSED** — a Developer ID account now exists (see Phase 2.2 below); it is what unblocked the Keychain/Secure Enclave move |
| ~~**Self-signed cert pinned by SHA-256** instead of a domain + public CA~~ | **REVERSED** — see the 2026-09-16/17 Protocol v2 block below |
| **No Elastic IP** (user decision, 2026-08-19) | Instance is long-running; if the IP ever changes, the recovery is scripted (~2 min) plus rebuilding both Macs |
| **Controller draws the cursor locally**, host hides it | A streamed cursor always lags by a full capture→encode→network→decode round trip. Same approach as Parsec/Moonlight |
| **Gestures via public key equivalents**, not synthesised multi-touch | Multi-touch synthesis needs private CGS SPI that breaks on OS updates |
| **Capture mode** (`CGEventTap`) with a reserved escape `⌃⌥⌘K` | Otherwise Cmd+Space/Cmd+Tab hit the controller's own macOS |
| **H.264 forced in SDP** | libwebrtc otherwise picked VP8 — software encode, ~94% of a core |
| **`AVSampleBufferDisplayLayer`** for rendering | `RTCMTLNSVideoView` isn't in the `stasel/WebRTC` binary at all |
| **coturn quotas by allocation count**, not bandwidth | `bps-capacity` caused error 486 on every allocation; `max-bps` would have throttled the stream |
| **Diagnostics hidden** unless `RC_DEBUG=1` | The user sees state ("sharing", "reconnecting"), not fluctuating numbers |

## Reversals

### 2026-09-16 — the device private key leaves the identity file (Phase 2.2)

A Developer ID account now exists, so the reason for file-based secrets is gone. `SCOPE.md` §5
has always said the device identity is a hardware-held P-256 key; this makes it true.

**Selection order at startup:** Secure Enclave → Keychain → file. The file is reachable only
under `SKIPPER_DEV_FILE_IDENTITY=1` or an overridden identity directory (`RC_IDENTITY_DIR`), which
is what lets `rc-node` and the multi-instance scripts run several identities on one Mac — the
Keychain and the Secure Enclave each hold exactly one device key. Never a release path.

**Migration rule.** A Secure Enclave key cannot be imported, so an existing identity can never
become hardware-backed without changing its Device ID, and the Device ID is permanent. So: an
existing `identity.json` with a software key keeps that key and keeps its Device ID, but the key
*moves* into the Keychain (`KeychainDeviceKey`) and is removed from the file. Only brand-new
identities get Secure Enclave keys. If the Keychain refuses, the key stays in the file, the UI
says so, and nothing is regenerated. The existing rule stands unchanged: an identity is never
silently regenerated, whatever fails.

**What stays in the file:** Device ID, access code, `createdAt`, `serverRegistered`. The access
code moves out when SPAKE2 lands.

**Storage:** a generic-password Keychain item, service `app.skipperdesk.desktop`, accounts
`device-key` (the Secure Enclave blob) and `device-key-software` (the P-256 scalar), both
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so an unattended host comes back after a reboot
and the key never travels to another Mac. The Secure Enclave key uses `.privateKeyUsage` with no
user-presence factor, for the same reason.

**Build:** `scripts/build.sh` adds `com.apple.application-identifier` and `keychain-access-groups`
(`<TEAMID>.app.skipperdesk.desktop`) when a Team ID is available from `SKIPPER_TEAM_ID` or from the
selected `Developer ID Application: … (TEAMID)` identity. Without one it prints "No Developer ID
identity; Secure Enclave unavailable in this build" and the app falls back to the Keychain.

**The UI states which of the three is in use** — "Key: Secure Enclave" / "Key: Keychain" /
"Key: file (dev)" — and must never claim the strongest one when it fell back.

### 2026-09-16/17 — Protocol v2

Phase 1–2 replaced three V1 shortcuts, all taken while the project was a private two-Mac tool
with no domain and no Developer ID account. Neither condition still holds.

- **Self-signed cert pinned by SHA-256 → public-CA TLS on a domain.** The client is
  backend-agnostic: it knows one config value, the API domain, and validates TLS the normal way.
  No IP, no cert pin, `NSAllowsArbitraryLoads` removed. This is independent of which backend
  answers that domain — local dev server, tunnel, or the eventual AWS account.
- **Server-side Argon2id code check → SPAKE2 between the two peers.** The `code` verifier object
  is removed from the protocol entirely (PROTOCOL.md v2 change #1); the server relays opaque
  SPAKE2 messages (`pake`, §2.17) and never learns the access code, correct or not. Access-code
  rate limiting moves to the host, which is the only side left that can tell success from
  failure (v2 change #9).
- **Why SPAKE2 over OPAQUE:** the access code is symmetric — both the host and the controller
  already know it, unlike a password-and-verifier scheme where only one side holds the secret.
  SPAKE2 fits that shape directly and is available as an audited RustCrypto crate (`spake2` 0.4).
- **Both device public keys are bound into the PAKE transcript.** A Phase 2.4 finding: without
  this, a relay could mix messages from two different sessions. `connect_ok` carries
  `hostPubkey`, and both `pake` steps carry the sender's pubkey, so each side's SPAKE2 transcript
  is keyed to the specific peer it is talking to.
- **SDP fingerprints are signed by the device key** (`fp`, `pubkey`, `sig` on `sdp`, v2 change
  #8), so a compromised server cannot substitute its own key and MITM the media, even though it
  still relays the SDP itself.
- **Trusted-controller semantics:** the controller remembers a host's code (so it isn't re-typed
  every connection); the host keeps an allow-list of controller public keys it has seen a
  successful code from. Refresh Code clears both sides at once — the host's allow-list and,
  implicitly, the controller's remembered code stops working the moment the host rejects it.
- **Keychain for all secrets**, not just the device key: the access code moves out of the
  identity file once SPAKE2 lands, per the Phase 2.2 migration note above.

## Lessons (read before changing things)

**This round (Phase 1–2)**
- Parallel agents on the same repo need separate worktrees — two agents editing the same
  language's protocol files in one working tree stomp each other's edits.
- A protocol version bump in one language must be mirrored in all three surfaces at once:
  `protocol/protocol.go`, the Rust `rc-proto` crate, and the Swift mirror — plus regenerating
  `protocol/vectors/`. Bumping one and forgetting the others produces a passing local build that
  fails cross-language vector checks.
- `URLComponents` does not percent-escape `+` or `=` in query items; a base64 value (e.g. a
  `pubkey` or `sig`) placed straight into a query string corrupts silently unless it's escaped
  first or sent in the body instead.
- CryptoKit's Secure Enclave key-generation API (`SecureEnclave.P256.Signing.PrivateKey`) creates
  a key without the Keychain access-group entitlement; it only gains one if the app has the
  matching `keychain-access-groups` entitlement at creation time, not retroactively.

**Verification**
- A milestone counts only when observed on the real thing; every acceptance check must be one a
  stub would fail.
- A screenshot can't show that a view actually re-renders — a stale frame looks the same as a
  correct one. Test state changes at the publisher level, or through real interaction.
- Before blaming the code, make sure the check itself is valid. Two of three "failures" in Phase 5 were broken
  checks (grepping JSON for base64 when `/` is escaped as `\/`; searching the wrong node's log). Parse
  JSON; don't grep it.

**macOS**
- TCC grants belong to the *responsible process*: launch the bundle with `open`, or grants read
  as denied. Grants are also tied to the signature — keep the signing identity stable.
- TCC.db is SIP-protected; the Accessibility grant can't be scripted.
- `@Published` on a nested `ObservableObject` never fires for the child's own changes — forward
  `objectWillChange` (`AppModel.rewireObservation()`).
- `RunLoop.main` timers never fire under `dispatchMain()` (as in `rc-node`); use `DispatchSourceTimer`.
- `MainActor.assumeIsolated` **traps** when called from a dispatch-timer handler; hop with a `Task` instead.
- `NSCursor.arrow.image` is zero-sized without a window-server connection. Draw the cursor as a
  `CGPath`, and never hide the system cursor unless the replacement is verifiably drawable.
- Layer order matters: the cursor layer goes above the video layer.

**Sessions**
- Changing the role must rebuild the transport (the role decides who offers SDP).
- `displaced` is terminal. Two instances sharing one identity otherwise fight in a reconnect storm (fixed).
- If the server reports our own active session but we hold no token, `bye` it by device identity
  and connect fresh. Never loop on `busy` (fixed in `SessionStateMachine.signalingAuthenticated`).
- Send `input_reset` on every disconnect and resume.

**Server / deploy**
- `server/go.mod` uses `replace rcprotocol => ../protocol`, so the Docker build runs inside
  `server/` with `protocol/` beside it.
- The container runs as uid 10001; `data/` and certs must be chowned. SQLite reports this as
  "out of memory" (`SQLITE_CANTOPEN`).
- A deploy isn't done until `/healthz` and `RestartCount` are checked.
- `RC_TOKEN_SECRET` isn't set, so a server restart invalidates resume tokens. That's acceptable
  because sessions are in memory anyway.
