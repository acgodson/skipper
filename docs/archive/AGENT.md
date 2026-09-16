Build a minimal private remote-desktop application. Do not add features outside this specification.

## Product goal

Two Macs running the application should be able to establish unattended remote-control sessions with no arbitrary session timeout.

The remote Mac exposes:

* Permanent Device ID
* Persistent Access Code
* Manual **Refresh Access Code** button
* Online/offline status
* Enable/disable unattended access
* Enable/disable clipboard sync

The access code must **never rotate automatically**. It changes only when the user manually refreshes it.

## Core architecture

Use:

* **Tauri + React + TypeScript** for desktop UI
* **Rust** for connection/session logic
* Small native **Swift/macOS layer** where Apple APIs are cleaner
* **ScreenCaptureKit** for screen capture
* **CGEvent** for keyboard/mouse injection
* **NSPasteboard** for clipboard
* **WebRTC** for remote media and control transport
* AWS EC2 for signaling/authentication/device presence
* **coturn** on AWS as TURN fallback

Normal traffic path must be:

`Mac A ↔ Mac B`

AWS should only coordinate the connection whenever direct WebRTC is possible.

Fallback:

`Mac A ↔ AWS TURN ↔ Mac B`

Do not unnecessarily proxy every desktop session through AWS.

## Identity and authentication

Keep these concepts separate:

**Device ID**

* Permanent.
* Public identifier.
* Generated on first installation.

**Access Code**

* Secret.
* Persistent across app restarts and machine reboots.
* Manually refreshable.
* Refresh immediately invalidates the previous code.

**Device cryptographic identity**

* Generate a public/private keypair on installation.
* Store the private key in macOS Keychain.
* Never expose it in the UI.

Never store access codes in plaintext on the server.

A successful access-code authentication should produce a short-lived session credential rather than continuously sending the access code during the session.

## Connection flow

1. Remote app launches.
2. Remote device authenticates itself to signaling server using its device key.
3. Server records the Device ID as online.
4. Controller enters Device ID + Access Code.
5. Server confirms the device is online and authenticates the request.
6. Controller and remote exchange WebRTC signaling.
7. Attempt direct P2P connection.
8. Fall back to TURN if P2P fails.
9. Establish encrypted remote-control session.
10. Continue until either side disconnects. No artificial timeout.

The app should automatically reconnect its signaling WebSocket after temporary network loss.

## Remote-control channels

Use WebRTC media for desktop video.

Use WebRTC DataChannels for control.

Example control events:

```text
mouse_move
mouse_down
mouse_up
mouse_scroll

key_down
key_up

clipboard_text

ping
pong
display_info
resolution_change
session_close
```

Do not implement browser automation.

Input must be injected at the operating-system level into the remote Mac.

## Screen

V1 requirements:

* One display initially
* 30 FPS target while active
* Reduce frame rate substantially when desktop is static
* Adaptive bitrate
* H.264 is acceptable initially
* Cursor visible
* Resize controller viewport without changing remote display resolution unnecessarily

Optimize for responsiveness rather than perfect image quality.

## Keyboard and mouse

Support:

* Mouse movement
* Left/right click
* Click-and-drag
* Scrolling
* Normal keys
* Modifier keys
* Cmd
* Option
* Control
* Shift
* Common shortcuts such as Cmd+C, Cmd+V, Cmd+Tab

Preserve key-down/key-up state correctly so modifier keys cannot become logically "stuck" after packet loss or disconnect.

On disconnect, explicitly clear all active keyboard/mouse states.

## Clipboard

V1 clipboard support is **text only**.

Do not implement:

* File clipboard transfer
* Images
* Rich HTML
* Drag-and-drop files

Clipboard synchronization must work both ways.

Add an event ID/hash/origin marker so:

`Mac A → Mac B`

does not cause Mac B's clipboard watcher to resend the same clipboard back to Mac A indefinitely.

Set a reasonable maximum clipboard text size.

## macOS permissions

Detect and clearly surface whether these permissions are granted:

* Screen Recording / Screen & System Audio Recording
* Accessibility

Do not silently fail when permissions are missing.

Show the user exactly which capability is unavailable.

## Background operation

The remote machine should remain reachable after closing the main UI window.

Use a menu-bar/background component.

Provide:

`Launch at Login`

Unattended access must be an explicit local setting.

Do not attempt to bypass macOS security/privacy dialogs.

For V1, supporting the currently logged-in user's desktop is sufficient. Do not let login-screen/FileVault/pre-login control delay the first working version.

## Session UX

Controller:

```text
Device ID
[___________]

Access Code
[___________]

[ Connect ]
```

Remote host:

```text
Remote Access

Device ID
482 719 351

Access Code
K7FM-3Q8P-W2

[ Refresh Access Code ]

● Online
Unattended Access: ON
Clipboard Sync: ON
```

During a session, the host should visibly indicate:

`Remote session active`

Do not design the app as covert or hidden remote-control software.

## Security rules

Mandatory:

* TLS for signaling/API traffic
* WebRTC encrypted transport
* Cryptographically secure random access codes
* Keychain for private secrets
* No plaintext access-code logging
* No clipboard-content logging
* No screen recording/history on the server
* No keystroke logging
* No analytics required for V1
* Authentication rate limiting
* Session tokens expire
* Old access code invalid immediately after refresh
* Remote device can terminate the active session locally
* Only one controller session initially unless explicitly expanded later

AWS must never need to inspect the contents of the desktop/video/control stream.

## AWS V1

Start with something like:

```text
EC2: t2.medium
OS: Ubuntu
Elastic IP
HTTPS/WSS
coturn
signaling service
small device-presence/auth service
```

Do not add Kubernetes, Redis, Kafka, microservices, or unnecessary infrastructure.

An in-memory online-device registry is acceptable for the first prototype, with persistent device/auth information in a small database.

## Repository

Prefer:

```text
apps/
  desktop/
  signaling/

crates/
  core/
  protocol/
  webrtc/

native/
  macos/

infra/
  aws/
  coturn/
```

Keep protocol definitions shared rather than duplicating message shapes across frontend/backend/native code.

## Build order

Do not build everything simultaneously.

Milestone 1:
Two Macs connect through signaling and establish WebRTC.

Milestone 2:
Mac A screen appears on Mac B.

Milestone 3:
Mouse control.

Milestone 4:
Keyboard control.

Milestone 5:
Bidirectional text clipboard.

Milestone 6:
Permanent Device ID + persistent Access Code.

Milestone 7:
Manual access-code refresh and invalidation.

Milestone 8:
Unattended/background operation and reconnect.

Milestone 9:
TURN fallback.

Milestone 10:
Packaging, code signing, permission UX and reliability.

A milestone is complete only when it works between two actual Macs, not merely through mocks.

## Non-goals

Do not implement:

* File transfer
* Chat
* Voice
* Recording
* User directory
* Contacts
* Teams
* Billing
* Browser automation
* Session time limits
* Remote shell
* Terminal execution
* Cloud file storage
* Mobile apps
* Windows support yet
* Anti-detection/evasion functionality

The V1 definition of success is simple:

> Install the application on two Macs, leave one Mac somewhere else, enter its Device ID and persistent Access Code from the other Mac, connect, see its desktop, fully control its mouse and keyboard, copy/paste text in either direction, disconnect, and reconnect later using the same credentials without someone being physically present at the remote Mac.


Yes, you can absolutely use the **existing `t2.medium` you already have**. I would not migrate instances just for this project. AWS still supports `t2.medium`; it is a burstable instance, and for signaling/authentication plus a TURN relay for a small number of personal sessions, it is a perfectly reasonable place to start. ([AWS Documentation][1])

### 1. Browser isolation should be an explicit requirement

I would add this strongly to the agent notes.

Your remote-control app should **never modify or participate in the remote Mac's browser networking**.

The architecture should remain:

```text
                         WEBSITE
                            ▲
                            │ HTTPS
                            │
                    Remote Mac Browser
                    Safari / Chrome
                            │
                            │ normal Mac
                            │ internet connection
                            ▼
                         Internet


Your Mac  ═══════════  Remote Access App
             P2P             │
                             │
                     ScreenCaptureKit
                     CGEvent
                     NSPasteboard
```

When you remotely click Chrome, **Chrome itself makes the request**.

Your remote-control application should not make the browser's request on Chrome's behalf.

So Chrome DevTools → Network should contain things like:

```text
GET example.com/
POST example.com/api/...
GET cdn.example.com/...
```

It should **not** suddenly contain:

```text
your-aws-server.com
turn.yourapp.com
signal.yourapp.com
```

because those connections belong to another application/process.

At the system networking level, of course, the Mac will have both sets of connections:

```text
Chrome
   → example.com

YourRemoteApp
   → signaling.yourdomain.com
   → STUN/TURN when necessary
   → controller Mac
```

Someone doing a machine-wide packet capture or looking at active sockets could therefore see that remote-access traffic exists. But a webpage's Chrome Network tab does not normally get a list of unrelated network connections opened by other macOS processes.

I'd put a hard rule in the spec:

> **Network isolation:** The remote-access client must never install or configure a system proxy, HTTP/SOCKS proxy, PAC configuration, VPN, browser extension, browser proxy, DNS interceptor, local HTTP interception proxy, or Network Extension that routes browser traffic. Browser traffic must remain entirely independent of remote-control transport.

Also:

```text
DO NOT:

RemoteApp → proxy browser request → website
RemoteApp → inject request into Chrome
RemoteApp → change macOS proxy
RemoteApp → change Chrome proxy
RemoteApp → install browser extension
RemoteApp → become a VPN
```

We don't need any of those things to remote-control the computer.

---

## 2. P2P simply means Mac talks directly to Mac

**P2P = peer-to-peer.**

Say you're in Newcastle and the other Mac is somewhere else.

Initially:

```text
Your Mac
   │
   │ "I want device 482719351"
   ▼
AWS
   │
   │ "Here is how you can reach each other"
   ▼
Remote Mac
```

AWS introduces the machines.

Then ideally:

```text
Your Mac  ══════════════════  Remote Mac
           screen/control
```

AWS drops out of the actual screen path.

Technically, ICE is the standard mechanism that searches for a viable network path between the two endpoints. It uses STUN and, when needed, TURN. That's precisely what ICE was designed for. ([RFC Editor][2])

### TURN is basically the middleman

If the Macs cannot establish that direct connection:

```text
Your Mac  ══════► AWS TURN ══════► Remote Mac
```

TURN doesn't mean:

```text
Your Browser → AWS → websites
```

It's only:

```text
Remote-control video
mouse
keyboard
clipboard
```

TURN is specifically a relay protocol for cases where NAT prevents two peers from communicating directly. ([RFC Editor][3])

---

# 3. Why could P2P fail?

This isn't really something good software can completely eliminate because **the networks belong to somebody else**.

Imagine:

```text
Mac A
 ↓
Home router
 ↓
ISP CGNAT
 ↓
Internet
 ↓
Corporate firewall
 ↓
Router
 ↓
Mac B
```

The machines may not have a usable direct route.

Situations include:

* CGNAT at an ISP.
* Particularly restrictive NAT configurations.
* Corporate/university networks.
* Firewalls blocking UDP.
* Public Wi-Fi restricting peer connectivity.
* Double NAT.
* Networks allowing ordinary HTTPS but heavily restricting other traffic.

The TURN specification exists specifically because there are NAT situations where direct communication between peers isn't possible. ([RFC Editor][4])

So when I wrote:

> Attempt P2P. Fall back to TURN.

I don't mean:

> "Our P2P implementation might be bad."

I mean:

> "Try the cheapest, lowest-latency route first. If the networks physically won't allow it, use our server."

And for **unattended remote access**, I actually think TURN is important.

Imagine you're overseas and your remote Mac is sitting somewhere inaccessible:

```text
You click Connect.

P2P: ❌

No TURN:
"Connection failed."

You're stuck.
```

Versus:

```text
P2P: ❌
TURN: ✅

Connected.
```

That's worth having.

### But we can make TURN strictly fallback-only.

I think that's exactly right for your project:

```text
Priority 1
DIRECT P2P
Mac ↔ Mac

Priority 2
TURN
Mac ↔ your t2.medium ↔ Mac
```

Not:

```text
Everything → AWS
```

---

# 4. Your existing `t2.medium` is fine

Yes.

Don't buy another EC2 instance.

I suggested T3 previously only because I thought you were selecting a **new instance**. Since you already have a running `t2.medium`, I'd use it.

Put these alongside whatever you're already running:

```text
t2.medium
│
├── existing services
│
├── remote-access API
│
├── WebSocket signaling
│
└── coturn
```

We should monitor:

```text
CPU
memory
network throughput
TURN bandwidth
```

and only upgrade if actual measurements demonstrate a problem.

T2 is burstable infrastructure, so sustained workloads need some awareness of CPU credits, but signaling itself is extremely light. ([AWS Documentation][1])

The potentially heavy component is TURN because **video packets actually pass through EC2** whenever a session is relayed.

But that's another reason to prefer:

```text
P2P whenever possible
TURN only when necessary
```

---

# 5. And yes, sacrifice image perfection

I agree with you here.

This isn't Parsec for gaming or a movie-streaming service.

We care about:

**interaction responsiveness > visual perfection.**

I would tell the agent to target something more like:

```text
Normal desktop use

Resolution:
adaptive, perhaps 1080p effective initially

Active:
15–24 FPS

Fast movement:
up to 30 FPS if useful

Static screen:
1–5 FPS

Codec:
H.264 hardware encoding through VideoToolbox

Typical target:
~1–3 Mbps

Temporary fast-changing screen:
allow higher bitrate

Text:
must remain readable
```

Those are **design targets**, not hard requirements.

If you're reading code:

```text
Screen mostly static
        ↓
Very few changed frames
        ↓
Low bandwidth
```

Scroll:

```text
Large visual change
        ↓
temporarily increase frames/bitrate
```

Stop scrolling:

```text
static again
        ↓
reduce traffic
```

And mouse/keyboard traffic itself is microscopic compared with video.

I'd even make the default quality mode:

```text
Remote Desktop
Quality: Efficient

○ Best Quality
● Balanced
○ Low Bandwidth
```

with **Balanced** biased substantially toward bandwidth efficiency.

---

## One addition I'd make to your agent instructions

Add this verbatim:

## Browser and Network Isolation

The remote-control application must remain completely independent of browser and application network traffic on the controlled machine.

Remote control must operate exclusively through:

* OS-level screen capture
* OS-level keyboard/mouse input injection
* OS clipboard APIs
* Its own dedicated signaling/WebRTC sockets

The application must NOT:

* Configure or modify macOS system proxy settings
* Configure HTTP, HTTPS, SOCKS or PAC proxies
* Install a VPN for remote-control purposes
* Route browser traffic through AWS
* Intercept browser HTTP/HTTPS traffic
* Install browser extensions
* Modify browser proxy configuration
* Inject HTTP requests into browsers
* Use browser automation as the remote-control mechanism
* Modify system DNS for remote-control purposes

When the remote user opens Chrome, Safari or another application, that application must continue making its own network requests directly through the remote Mac's normal network configuration.

The AWS signaling/TURN infrastructure is exclusively for communication between remote-access clients.

Browser DevTools network activity must therefore remain independent from signaling, STUN, TURN and remote-control traffic.

TURN must never function as a general Internet proxy. It is exclusively a fallback relay for authenticated remote-control sessions.

That gives the coding agent a much clearer boundary.


[1]: https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/burstable-performance-instances.html?utm_source=chatgpt.com "Burstable performance instances"
[2]: https://www.rfc-editor.org/info/rfc8445/?utm_source=chatgpt.com "RFC 8445: Interactive Connectivity Establishment (ICE)"
[3]: https://www.rfc-editor.org/rfc/rfc8656.html?utm_source=chatgpt.com "RFC 8656: Traversal Using Relays around NAT (TURN)"
[4]: https://www.rfc-editor.org/info/rfc5766/?utm_source=chatgpt.com "RFC 5766: Traversal Using Relays around NAT (TURN)"


 That stack **compiles down to a normal installable macOS application**. The user would not need Rust, Node, TypeScript, or Swift installed on the target Mac.

For Apple Silicon, we can build an ARM64 release like:

```text
RemoteAccess.app
```

and package it as:

```text
RemoteAccess.dmg
```

Tauri officially supports building macOS application bundles and DMG installers, so the React/TypeScript frontend gets bundled together with the compiled Rust/native components into the Mac app. ([Tauri][1])

The flow would be:

```text
Source code
   │
   ├── React / TypeScript UI
   ├── Rust core
   └── Swift/macOS native code
          │
          ▼
       Build
          │
          ▼
RemoteAccess.app
          │
          ▼
RemoteAccess.dmg
```

Then on your Silicon Mac:

```text
Open RemoteAccess.dmg
        ↓
Drag RemoteAccess.app → Applications
        ↓
Open app
        ↓
Grant:
• Screen Recording
• Accessibility
        ↓
Ready
```

### We should target Apple Silicon directly

Since you're starting with Silicon Macs, I'd have the agent initially produce:

```text
aarch64-apple-darwin
```

meaning native ARM64 for M1/M2/M3/M4/M5-class Macs.

Later, if you want support for older Intel Macs as well, we can produce a **Universal Binary** containing both:

```text
arm64
+
x86_64
```

But there's no reason to complicate V1 with that if both of your machines are Apple Silicon.

### Development build vs proper installer

While you're building/testing it, you can compile a raw `.app` yourself and run it locally.

But for the finished version, I strongly recommend:

```text
Signed
+
Notarized by Apple
+
.dmg
```

Apps distributed outside the Mac App Store can be signed with a Developer ID and notarized so Gatekeeper recognizes them normally. Apple documents Developer ID signing and notarization specifically for software distributed outside the App Store. ([Apple Developer][2])

So instead of macOS yelling:

> “Apple cannot verify this developer.”

you get a normal installation experience.

You **do not need to put it on the Mac App Store**. Direct `.dmg` distribution is supported. Tauri's current documentation explicitly supports direct DMG distribution for macOS. ([Tauri][3])

### One important architecture adjustment

I'd actually tell the coding agent that the final macOS program should look like **one application to the user**, even though internally we have several technologies:

```text
RemoteAccess.app
│
├── UI
│   React + TypeScript
│
├── compiled Rust core
│   WebRTC
│   signaling
│   protocol
│   authentication
│
└── native macOS code
    ScreenCaptureKit
    Accessibility/input
    clipboard
```

Not:

```text
Install Node
Install Rust
Run npm
Run another daemon
Start Swift helper
```

Absolutely not.

Those are **development dependencies only**.

The installed machine should just get:

```text
RemoteAccess.dmg
```

and after installation:

```text
/Applications/RemoteAccess.app
```

That's it.

And because Tauri uses the system webview instead of packaging an entire Chromium runtime like Electron, the resulting application can remain relatively compact. Tauri describes its architecture as producing small native binaries across desktop platforms. ([Tauri][4])

So yes, **the Rust + TypeScript + Swift architecture is specifically compatible with your requirement that we ultimately hand somebody one normal file they can install on an Apple Silicon Mac.**

[1]: https://v2.tauri.app/distribute/dmg/?utm_source=chatgpt.com "DMG"
[2]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution?utm_source=chatgpt.com "Notarizing macOS software before distribution"
[3]: https://v2.tauri.app/distribute/?utm_source=chatgpt.com "Distribute"
[4]: https://v2.tauri.app/blog/tauri-20/?utm_source=chatgpt.com "Tauri 2.0 Stable Release"
