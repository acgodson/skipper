# Decisions and lessons

The distilled record of the build. Full phase-by-phase notes: [archive/PLAN.md](archive/PLAN.md).

## Decisions that depart from the brief

| Decision | Why |
|---|---|
| **Single native Swift/SwiftUI app** instead of Tauri + React + Rust | libwebrtc (`stasel/WebRTC`) gives VideoToolbox H.264, Google BWE, ICE, DTLS and data channels for free. A webview can't capture unattended (`getDisplayMedia` prompts every time). Two languages (Swift, Go) instead of four. Builds with `swift build` and no Xcode |
| **Go** signaling server instead of Node | One static binary, idle-cheap next to a production service |
| **File-based secrets** (`~/Library/Application Support/RemoteControl/identity.json`, 0600) instead of Keychain | Keychain ACLs bind to the code signature, so every ad-hoc rebuild re-prompted; Secure Enclave needs a paid Developer account anyway (`-34018`). Same posture as AnyDesk/RustDesk. A corrupt file is surfaced, never silently regenerated |
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
