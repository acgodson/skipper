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
  *Refresh*; the old code is invalid immediately.
- Device keypair (P-256) — never shown in the UI.
- Online/offline status · Unattended access on/off · Clipboard sync on/off.
- A visible "Remote session active" indicator and a local way to end the session.
  Never covert.

## Connection flow
Host authenticates to the signaling server with its device key → controller enters Device ID +
Access Code → server checks presence + code (rate-limited) → issues a short-lived session token
→ WebRTC offer/answer/ICE relayed → direct P2P first, TURN fallback → session runs until either
side ends it. Signaling reconnects automatically; brief network wobbles must not drop the
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
Reuse the existing t2.medium (shared with a production service — see
[../infra/legacy/README.md](../infra/legacy/README.md)). No Kubernetes, Redis, queues or microservices.
In-memory presence, small SQLite for devices.

## Distribution
One `RemoteControl.app` in a `.dmg`, arm64. No toolchains on the target Mac.

## Non-goals
File transfer · chat · voice · recording · user directory/contacts/teams · billing · browser
automation · session time limits · remote shell · cloud storage · mobile · anti-detection.
Windows was a V1 non-goal (later explored in `apps/windows/`, now parked).
