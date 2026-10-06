# Product spec (V1)

Condensed from the original brief ([archive/AGENT.md](archive/AGENT.md),
[archive/outline.md](archive/outline.md)). Where the build deliberately departed from the
brief, [DECISIONS.md](DECISIONS.md) says so.

## Goal

Install the app on two Macs, leave one somewhere else, enter its Device ID and persistent
Access Code from the other, connect, see its desktop, fully control mouse and keyboard, copy and
paste text either way, disconnect, and reconnect later with the same credentials — with nobody
at the remote Mac. No session time limit.

## Host exposes
- **Device ID** — permanent, public, 9 digits, generated on first launch.
- **Access Code** — secret, persists across restarts/reboots, changes **only** on manual
  *Refresh*; the old code is invalid immediately. The code itself never reaches the server;
  it is proved peer-to-peer by a SPAKE2 exchange the server only relays.
- Device keypair (P-256) — Secure Enclave for a new identity on a Mac that has one, a Keychain-held
  software key otherwise — never shown in the UI. Signs the SDP fingerprint and the SPAKE2
  transcript so a compromised server cannot forge either side.
- Trusted controllers list: hosts remember a controller's public key after a successful code, as an
  informational record of who has connected. It does not skip the code exchange — every connect
  still runs the full SPAKE2 proof; what a remembered controller skips is only its own user being
  asked to retype the code. Refresh Code clears the list.
- Online/offline status · Unattended access on/off · Clipboard sync on/off.
- Unattended access off (the default on a new install): after a controller proves the code, the
  host asks "Allow … to control this Mac?" and waits up to 30 s; no answer declines. On: the code
  alone is permission. The toggle decides consent only; keeping the Mac awake follows being a
  reachable host (see Background operation).
- A visible "Remote session active" indicator and a local way to end the session.
  Never covert.

## Connection flow
Host authenticates to the signaling server with its device key → controller sends
`connect_req{deviceId}` → server authorises by **entitlement** (host paid up, not already busy),
not by any code → issues a short-lived session token → access code proved directly between the
two peers by SPAKE2, relayed opaquely by the server → WebRTC offer/answer/ICE relayed, SDP
fingerprints signed by each device key → direct P2P first, TURN fallback → session runs until
either side ends it. Signaling reconnects automatically; brief network wobbles must not drop the
session or re-ask for the code.

## Channels
- Video: WebRTC media, H.264 (hardware), one display, ~30 fps cap, throttled when static,
  adaptive bitrate. Responsiveness over image quality; text must stay readable.
  Quality modes: Best / Balanced (default) / Low Bandwidth.
- `ctrl` (reliable): clicks, drag, scroll, keys + modifiers, clipboard, gestures, input reset,
  display info, quality, ping/pong, session close.
- `hi` (unreliable): mouse moves.
- On disconnect/resume, release all held keys and buttons.

## Clipboard
Text only, both directions, origin/hash marker to prevent echo loops, size-capped.
No files, images, rich text or drag-and-drop.

## macOS
Detect and name missing **Screen Recording** / **Accessibility** grants — never fail silently.
Keep running from the menu bar after the window closes; Launch at Login; unattended access is
an explicit setting. Current user's desktop only (no login-screen/FileVault control). Never
bypass privacy dialogs.

## Background operation
A Mac in the host role keeps itself from idle-sleeping for as long as it is online and reachable,
so that someone can connect to it later; no setting controls this. While a session is connecting,
waiting for consent, live or reconnecting, the display is kept on as well, because capture stops
when it sleeps. Both are power assertions, named "SkipperDesk" in `pmset -g assertions` whatever
the state, because that listing is readable by every process on the Mac; both are dropped when the
Mac leaves the host role, goes offline, or the session ends. When a controller connects, the host declares local user
activity, which brings a display that has gone dark back on.

What this cannot do: a Mac already in system sleep stays asleep — nothing in an app can wake it
(that is Wake-on-LAN, outside V1) — and none of this unlocks a locked Mac or shows the login
screen, which needs a privileged helper and is a separate future phase.

## Security rules
TLS for signaling · WebRTC encryption · CSPRNG access codes · no plaintext code on the server or
in logs · no clipboard, keystroke or screen logging/recording · no analytics · auth rate limiting
· expiring session tokens · one controller per host · the server never inspects session content.

## Browser and network isolation (hard rule)
Remote control works only through OS screen capture, OS input injection, OS clipboard, and the
app's own signaling/WebRTC sockets. The app must **never**: change system or browser proxy
settings (HTTP/SOCKS/PAC), install a VPN or Network Extension, change DNS, intercept or inject
browser traffic, install browser extensions, or use browser automation. Remote-Mac browsers keep
their own normal network path. TURN relays authenticated remote-control sessions only — it is
never a general proxy. Enforced by `scripts/check-isolation.sh` and `turnserver.conf`.

## Infrastructure
The legacy shared EC2 box ([../infra/legacy/README.md](../infra/legacy/README.md)) is **frozen**:
no deploys, no changes. A new backend, on a fresh AWS account, is Phase 5 (docs/SCOPE.md §11)
— not built yet. No Kubernetes, Redis, queues or microservices. In-memory presence, small SQLite
for devices.

## Distribution
One `SkipperDesk.app` in a `.dmg`, arm64. No toolchains on the target Mac.

## Non-goals
File transfer · chat · voice · recording · user directory/contacts/teams · billing · browser
automation · session time limits · remote shell · cloud storage · mobile · anti-detection.
Windows was a V1 non-goal (later explored in `apps/windows/`, now parked).
