Yes. For your own machines, a lightweight “personal AnyDesk” with **unlimited session duration, screen streaming, mouse and keyboard control** is very doable.

You actually need far less than the full AnyDesk feature set. The core architecture can be:

```text
Controller laptop
      │
      │ encrypted WebRTC
      ▼
Remote machine agent
 ├─ Screen capture
 ├─ Mouse injection
 ├─ Keyboard injection
 └─ Connection/auth service

        ▲
        │ signaling
        │
 Small VPS / server
```

The main pieces are:

* **Screen capture:** Windows Desktop Duplication API / `Windows.Graphics.Capture`; macOS ScreenCaptureKit.
* **Video transport:** WebRTC. It already gives you low-latency video, encryption, congestion control and data channels.
* **Keyboard/mouse:** send input events over a WebRTC DataChannel. The remote client translates those into native OS input events.
* **Signaling:** tiny Node/TypeScript WebSocket service that helps your two machines find each other.
* **NAT traversal:** STUN first, TURN relay when direct P2P connectivity isn't possible.
* **Authentication:** device keys rather than passwords. Pair a controller with the remote PC once.
* **Persistence:** install the remote component as a Windows service/macOS background agent so you can reconnect after reboot.
* **No timeout:** that's entirely under your control. There is no technical reason for a session to expire.

For something you want to vibe-code rapidly, I'd probably structure it as:

```text
apps/
  controller/       # Tauri + React/TypeScript
  agent/            # Rust native agent
  signaling/        # Node/TypeScript

packages/
  protocol/         # shared messages/types
```

**Tauri + Rust** is particularly attractive here. React gives you the interface quickly, while Rust can handle screen capture, WebRTC/native bindings and OS-level input without shipping a huge Electron process.

Your first version could be extremely simple:

```text
Remote machine:
[Start Remote Access]

Device ID: HOME-PC-01
Status: Online

Controller:
[HOME-PC-01]
     ↓
[Connect]
     ↓
Remote desktop fills window
Mouse works
Keyboard works
```

You don't initially need file transfer, clipboard syncing, chat, recording, multi-monitor management, address books, session billing, user accounts, etc.

There are two particularly annoying parts you'll encounter. **NAT traversal** is one, which is why WebRTC + TURN is preferable to inventing your own socket protocol. The other is **OS permissions**. macOS requires Screen Recording and Accessibility permissions; Windows gets more complicated when you want control over elevated/UAC windows and login screens.

Also, don't invent your own encryption. Use WebRTC's established encrypted transport, authenticate devices using public/private keys, and make the remote agent reject any controller that hasn't previously been paired.

For your use case, though, I'd seriously consider one shortcut before building everything from zero: **RustDesk is open source and self-hostable**. You could either study its architecture or strip/fork it into a very small private client. Self-hosting removes the commercial-service timeout problem while giving you mature screen/input/NAT handling immediately.

If the purpose is primarily **“I have another computer somewhere and want permanent remote access to it”**, I think this is absolutely a reasonable weekend-style vibe-code project, particularly if we constrain V1 to **Windows remote machine → Mac controller, one monitor, screen + keyboard + mouse only**.


User
I don't need any file transfer, all I need is complete windows access and simple access code referesh, that the remote system saves like something that if they want to change the code they would manually click on referehs, installation on macbook to macbook for a start... clipboard syncing is important, so that I can copy and paste syncs across both... the hosting over an EC2 instance on AWS, like a t2 medium if that would be fast enough

Yes. With that scope, I’d simplify it substantially and **not use the EC2 instance as the normal video path**.

For the first version, I’d make it **Mac → Mac**, with Windows as phase 2.

### What the app would actually do

On the Mac you want to access remotely:

```text
Remote Access
──────────────────────────

Device ID
482 719 351

Access Code
K7FM-3Q8P-W2

[ Refresh Access Code ]

● Ready for connection
● Unattended access enabled
● Clipboard sync enabled
```

The important behavior is exactly what you described:

* Device ID remains permanent.
* Access code remains permanent until somebody physically clicks **Refresh Access Code**.
* Refresh immediately invalidates the old code.
* No 5-minute/30-minute/session timeout.
* Reconnect as many times as you want.
* Full mouse.
* Full keyboard.
* Keyboard shortcuts.
* Scroll/trackpad.
* Text clipboard sync in both directions.
* No file-transfer subsystem whatsoever.

I would actually **not automatically rotate the code**. That's unnecessary for your use case.

Internally, however, the code shouldn't really be the device's fundamental identity. On first install, the app generates a cryptographic device keypair and stores the private key locally. The human-readable access code is simply authorization to control that device.

So:

```text
Permanent:
Device ID       482719351
Device Key      [hidden cryptographic key]

Rotatable:
Access Code     K7FM-3Q8P-W2
```

Click:

```text
Refresh Access Code
```

and you get:

```text
Old: K7FM-3Q8P-W2  ❌ invalid

New: VM4R-7L9N-XC  ✅ active
```

I'd also rate-limit failed code attempts so somebody can't hammer the device ID/access-code endpoint.

### AWS should coordinate, not normally carry the desktop

The architecture I'd use is:

```text
               AWS EC2
        ┌───────────────────┐
        │ Device registry   │
        │ Signaling         │
        │ Authentication    │
        │ STUN/TURN         │
        └─────────┬─────────┘
                  │
              negotiation
             ↙             ↘

      Mac A  ═══════════════  Mac B
      remote     WebRTC       controller
                   P2P
```

That `══════════` is important.

Once the two Macs establish a WebRTC connection, **the screen should normally travel directly from Mac A to Mac B**, not:

```text
Mac A → AWS → Mac B
```

The AWS server helps them find/authenticate each other and negotiate the connection.

When NAT/firewalls make P2P impossible, your EC2-hosted TURN server becomes the fallback:

```text
Mac A → TURN/EC2 → Mac B
```

That gives you reliability without paying AWS bandwidth for every minute you use the application.

### About the `t2.medium`

A `t2.medium` can certainly run this, but I wouldn't provision one for a new build.

AWS currently lists T2 networking as only **“Low to Moderate”**, whereas a `t3.small` has a documented baseline of **0.128 Gbps with bursts up to 5 Gbps**, and `t3.medium` has **0.256 Gbps baseline / 5 Gbps burst**. ([AWS Documentation][1])

So I'd start with:

```text
EC2:        t3.small
OS:         Ubuntu
Storage:    10–20 GB gp3
Public IP:  Elastic IP

Processes:
  relay-api
  signaling websocket server
  coturn
```

A `t3.small` is already **massively sufficient** if most sessions are P2P.

Even if TURN temporarily handles a single desktop session, I'd deliberately configure your Mac encoder for something like:

```text
Resolution:     dynamic up to native
FPS:            30 default
Idle FPS:       1–5
Codec:          H.264 initially
Target bitrate: ~3–8 Mbps
```

A mostly static desktop compresses extremely well compared with normal video.

The bigger issue with using AWS as a permanent relay isn't CPU. It's **data transfer**. AWS documents internet data-transfer charges separately from the EC2 compute charge, so continuously relaying desktop video can eventually cost more in bandwidth than the tiny server doing signaling. ([AWS Documentation][2])

So: **P2P first, EC2 TURN fallback.**

### Mac implementation

For macOS, I'd use Apple's **ScreenCaptureKit** for the desktop stream. Apple specifically designed it for high-performance screen sharing, including native display resolution/frame rates and cursor handling. ([Apple Developer][3])

The stack I'd choose now is:

```text
Desktop UI
Tauri + React + TypeScript
        │
        ▼
Rust Core
├── WebRTC
├── protocol
├── encryption/session handling
├── clipboard transport
└── connection management
        │
        ▼
Small Swift/macOS native layer
├── ScreenCaptureKit
├── CGEvent keyboard/mouse injection
├── NSPasteboard clipboard
├── Accessibility permission
└── Screen Recording permission
```

That last native layer is worth having rather than fighting macOS completely through Rust FFI.

macOS requires explicit screen-recording permission for capturing the display, and Accessibility permission is relevant to injecting keyboard/mouse interaction. Apple's current ScreenCaptureKit behavior remains integrated with macOS's screen-sharing/privacy controls. ([Apple Developer][4])

After initial setup, we'd want the user to grant:

```text
✓ Screen & System Audio Recording
✓ Accessibility
```

and then the remote host can sit quietly in the menu bar.

### Clipboard should be very simple

I wouldn't stream the clipboard constantly.

Watch for clipboard changes:

```text
Mac A clipboard changed

"npm run build"
        │
        ▼
encrypted WebRTC DataChannel
        │
        ▼
Mac B NSPasteboard

"npm run build"
```

And vice versa.

For V1 I'd deliberately support **text only**.

No images.
No copied files.
No rich HTML.
No drag-and-drop.

That eliminates most clipboard complexity while giving you the feature you actually care about.

### Your communication protocol could be tiny

Essentially:

```text
CONTROL CHANNEL
mouse_move
mouse_down
mouse_up
scroll
key_down
key_up

CLIPBOARD CHANNEL
clipboard_text

SYSTEM CHANNEL
ping
display_info
resolution_change
session_close

MEDIA
WebRTC H.264 stream
```

That's practically the entire protocol.

### And Windows later fits neatly

Then phase 2 becomes:

```text
                 Shared Rust Core
                       │
          ┌────────────┴────────────┐
          ▼                         ▼
       macOS                     Windows

ScreenCaptureKit           Windows.Graphics.Capture
CGEvent                    SendInput
NSPasteboard               Windows Clipboard API
```

So we aren't writing the application twice.

And when you say **complete Windows access**, we can specifically design the Windows agent to eventually run as a service so that remote control survives logout/reboot and can reach the Windows sign-in/UAC environment where permitted, rather than merely controlling an application inside the currently logged-in desktop.

### V1 I would build

I'd keep the entire first milestone brutally small:

```text
1. Install app on Mac A
2. Grant Screen Recording
3. Grant Accessibility

4. App displays:
   Device ID: 482 719 351
   Code: K7FM-3Q8P-W2

5. Install same app on Mac B

6. Enter:
   482719351
   K7FM3Q8PW2

7. Connect

8. See Mac A
9. Move Mac A's cursor
10. Type on Mac A
11. Cmd+C on Mac A → Cmd+V on Mac B
12. Cmd+C on Mac B → Cmd+V on Mac A

13. Disconnect.
14. Reconnect tomorrow with same credentials.

15. Clicking Refresh on Mac A invalidates
    the previous access code.
```

**That is enough for the product.** No accounts, file explorer, contacts, chat, session limits, subscriptions, recording, or other AnyDesk baggage.

And I'd use **`t3.small` + WebRTC P2P + coturn fallback**, rather than `t2.medium`. That gives you a surprisingly cheap backend while the actual Mac hardware handles screen capture/encoding and your internet connections carry the normal screen stream. ([AWS Documentation][1])

This is small enough that we could define the exact repo architecture and V1 engineering specification next, including the signaling protocol, access-code lifecycle, EC2 services, and the precise implementation order so a coding agent could start building it without wandering.

[1]: https://docs.aws.amazon.com/ec2/latest/instancetypes/gp.html "Specifications for Amazon EC2 general purpose instances - Amazon EC2"
[2]: https://docs.aws.amazon.com/cur/latest/userguide/cur-data-transfers-charges.html?utm_source=chatgpt.com "Understanding data transfer charges"
[3]: https://developer.apple.com/videos/play/wwdc2023/10136/ "What’s new in ScreenCaptureKit - WWDC23 - Videos - Apple Developer"
[4]: https://developer.apple.com/forums/tags/screencapturekit?utm_source=chatgpt.com "ScreenCaptureKit | Apple Developer Forums"



so the main thing is to know a remote macs token that is online to be able to join right?

Basically, yes, but I’d separate **identity** from **authorization**.

The remote Mac would register with your AWS signaling server while it is online. To connect, the controller needs:

* a **Device ID** to identify which Mac it wants, e.g. `482719351`
* the current **Access Code** to prove it is allowed to control that Mac

So the flow is:

```text
Remote Mac comes online
        ↓
Registers Device ID with AWS
        ↓
Controller enters:
Device ID + Access Code
        ↓
AWS confirms that device is online
        ↓
Remote Mac verifies authorization
        ↓
WebRTC connection negotiated
        ↓
Remote screen + keyboard/mouse + clipboard
```

I would **not** make one permanent secret token both the address and password. The Device ID can effectively be public, while the access code stays secret.

Internally, each Mac can also have a long-lived cryptographic device token/key that the user never sees:

```text
Visible to user:
Device ID:    482 719 351
Access Code:  K7FM-3Q8P-W2

Hidden:
Device private key
Device authentication token
```

So from your perspective when using it, yes: **know the remote Mac's ID/code, and if that Mac is online, you can connect to it.** The AWS server's main job is essentially knowing, “Device `482719351` is currently connected and reachable here.”


Not necessarily. **Unusual interaction patterns are only one possible signal**, and often not the strongest one.

With OS-level remote control like the app you’re describing, the browser still runs normally on the remote Mac, so most sites would mainly see:

* the remote Mac’s IP/network
* its browser/device fingerprint
* normal browser-generated mouse/keyboard events
* timing and movement characteristics of those interactions

The remote-control layer itself usually isn’t exposed to the webpage as “this is remote access.” Slightly delayed clicks, less-natural mouse movement, bursts of typing, or odd timing could contribute to behavioral detection, but sophisticated anti-abuse systems can also look at IP reputation, browser consistency, cookies/account history, WebGL/device properties, screen configuration, and many other signals.

So I wouldn’t design around “making remote control invisible.” Design it so it behaves like a proper **OS-level input and screen-sharing tool**; then the browser remains genuinely resident on the remote machine rather than being proxied or browser-automated.

User:
most caveats come from unusual interaction pattern?

Not necessarily. **Unusual interaction patterns are only one possible signal**, and often not the strongest one.

With OS-level remote control like the app you’re describing, the browser still runs normally on the remote Mac, so most sites would mainly see:

* the remote Mac’s IP/network
* its browser/device fingerprint
* normal browser-generated mouse/keyboard events
* timing and movement characteristics of those interactions

The remote-control layer itself usually isn’t exposed to the webpage as “this is remote access.” Slightly delayed clicks, less-natural mouse movement, bursts of typing, or odd timing could contribute to behavioral detection, but sophisticated anti-abuse systems can also look at IP reputation, browser consistency, cookies/account history, WebGL/device properties, screen configuration, and many other signals.

So I wouldn’t design around “making remote control invisible.” Design it so it behaves like a proper **OS-level input and screen-sharing tool**; then the browser remains genuinely resident on the remote machine rather than being proxied or browser-automated.
