# Decisions and lessons

The distilled record of the build. Full phase-by-phase notes: [archive/PLAN.md](archive/PLAN.md).

## Decisions that depart from the brief

| Decision | Why |
|---|---|
| **Single native Swift/SwiftUI app** instead of Tauri + React + Rust | libwebrtc (`stasel/WebRTC`) gives VideoToolbox H.264, Google BWE, ICE, DTLS and data channels for free. A webview can't capture unattended (`getDisplayMedia` prompts every time). Two languages (Swift, Go) instead of four. Builds with `swift build` and no Xcode |
| **Go** signaling server instead of Node | One static binary, idle-cheap next to a production service |
| ~~**File-based secrets** (`~/Library/Application Support/RemoteControl/identity.json`, 0600) instead of Keychain~~ | **REVERSED 2026-09-16** — see below. Held while there was no Developer ID account: Keychain ACLs bind to the code signature, so every ad-hoc rebuild re-prompted, and the Secure Enclave returned `-34018` |
| **No Apple Developer account** | Local stable signing cert (`make-signing-cert.sh`); `build.sh` keeps the identity in one variable so Developer ID is a config change later |
| **Self-signed cert pinned by SHA-256** instead of a domain + public CA | No DNS for the box; pinning is stronger for a private two-device system |
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

## Lessons (read before changing things)

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
