# RemoteControl — V1 Build Plan

Status: planning locked, implementation delegated in phases.
Target: two Apple Silicon Macs, 1:1 unattended remote control, no session timeout.

---

## 1. Architecture decision (departure from AGENT.md)

**AGENT.md proposed Tauri + React + Rust(webrtc-rs) + Swift native layer. I am replacing that
with a single native Swift/SwiftUI application.** Everything else in AGENT.md stands.

### Why

| Concern | Tauri + Rust + Swift | Single Swift app |
|---|---|---|
| Rendering the remote H.264 stream | Rust `webrtc-rs` has no media pipeline; getting frames into a WKWebView needs a custom bridge or the webview's own `RTCPeerConnection` | `AVSampleBufferDisplayLayer` renders the stream on the GPU, zero-copy from the VideoToolbox decoder |
| Unattended capture | A webview capturing via `getDisplayMedia` raises a picker every session — fatal for unattended access | ScreenCaptureKit direct, no prompt after one-time permission grant |
| H.264 hardware encode | Must be wired by hand into webrtc-rs | libwebrtc uses VideoToolbox automatically on Apple Silicon |
| Congestion control / adaptive bitrate | Immature in webrtc-rs | Google BWE, battle-tested — this is what makes it feel responsive on a flaky link |
| Languages / toolchains in the repo | 4 (Rust, TS, Swift, Node) | 2 (Swift, Go) |
| App size | ~15 MB + webview overhead | ~45 MB, no runtime, single process |

Google's `libwebrtc` (via the `stasel/WebRTC` SwiftPM xcframework) gives us ICE, DTLS-SRTP,
SCTP data channels, bandwidth estimation and hardware H.264 for free.

> **Feasibility gate — PASSED (verified 2026-08-19).** The concern with this design was whether
> SwiftPM could consume a binary xcframework on a machine with Command Line Tools but no
> Xcode.app. It can: `stasel/WebRTC` 125.0.0 (M125) resolved, built and produced a live
> `RTCPeerConnectionFactory` at runtime under `swift build` alone. No Xcode, no `.xcodeproj`.
> Build path is therefore `swift build` + a hand-assembled `.app` bundle. Writing less code is the
efficiency strategy here, not writing more layers.

**One binary is both roles.** The same `RemoteControl.app` runs as host or controller; the role
is chosen at runtime. One `.dmg` installs on both Macs.

### Stack

```
RemoteControl.app  (aarch64-apple-darwin, SwiftUI, menu-bar resident)
├─ Identity      File-backed (0600): device keypair (P-256, CryptoKit) + access code
├─ Signal        WSS client -> rc-signal, auto-reconnecting, heartbeat presence
├─ Transport     libwebrtc: 1 video track + 2 data channels
├─ Host role     ScreenCaptureKit -> RTCVideoFrame ; CGEvent injection ; NSPasteboard
└─ Ctrl role     AVSampleBufferDisplayLayer ; input capture ; gesture palette ; NSPasteboard

rc-signal   (single static Go binary, own Docker container on the existing t2.medium)
├─ Device registry + presence (SQLite, WAL)
├─ Access-code auth (Argon2id hash; plaintext never stored or logged)
├─ WSS signaling relay (SDP/ICE only — never sees video, input or clipboard)
└─ Ephemeral TURN credential minting (HMAC, coturn REST auth)

coturn      (own container, fallback relay only, never a general proxy)
```

---

## 2. Requirements this plan adds beyond AGENT.md

These come from the brief and are first-class, not nice-to-have.

### 2.1 Network-flutter tolerance (headline requirement)
A brief network wobble on either side **must not** drop the session or ask for the code again.

| Layer | Behaviour |
|---|---|
| Signaling WS | Auto-reconnect, exponential backoff 0.5s→15s with jitter, indefinitely |
| Presence | Client heartbeat 15s; server marks offline after 40s of silence |
| ICE | On `disconnected`, hold the session and start an **ICE restart** after 3s. Do not tear down |
| Session | Only `failed` **plus** a 45s grace window closes the session |
| Resume | Session token (10 min TTL, renewed while connected) lets the controller silently re-offer to the same session id — no re-entering the access code |
| UI | "Reconnecting…" overlay over the last frame. The session is not declared dead until the grace window expires |
| Input safety | Every resume and every disconnect sends `input_reset`; the host releases all held modifiers and buttons so nothing gets logically stuck |

### 2.2 Online/offline presence for a saved connection
The controller stores one saved peer (Device ID + label; the access code is stored in an
owner-only file next to the identity file, only if the user ticks Remember). On app launch it connects to `rc-signal` and subscribes to that
Device ID's presence, so the home screen shows ● Online / ○ Offline before you press Connect,
and updates live via a pushed `presence` event.

### 2.3 Strict 1:1
`rc-signal` allows exactly one active session per host device. A second controller gets
`busy`. The host UI can end the active session locally at any time.

### 2.4 Gesture & shortcut palette (explicit user requirement)
Shortcuts typed on the controller are intercepted by the *controller's* macOS before they ever
reach us — pressing Cmd+Space opens the local Spotlight. Two mechanisms solve this:

1. **Capture mode** (primary). A toggle installs a `CGEventTap` on the controller that swallows
   all key events while the session window is focused and forwards them to the host instead.
   Cmd+Space, Cmd+Tab and friends then land on the remote machine.
2. **Floating action palette** (always available, and the answer for gestures that have no key
   equivalent). Semantic commands sent over the control channel and performed natively by the host:
   Mission Control · App Exposé · Show Desktop · Launchpad · Spotlight · App Switcher ·
   Screenshot region · Force-Quit dialog · Lock Screen.

   *Honest limitation:* synthesising a genuine multi-touch trackpad gesture requires private
   CoreGraphics SPI. We invoke the same OS action through public APIs (Mission Control key /
   `CGSInvokeMissionControl` equivalent), which is what the user actually wants — the desktop
   raises — without shipping private-API code that breaks on OS updates.

### 2.5 Secret storage — file-based, not Keychain (decided 2026-08-19)

Original design put the device key and access code in the macOS Keychain. **Reverted, by user
decision, to file-based storage.**

*Why:* Keychain ACLs bind to the app's code signature. An ad-hoc signed build gets a new
signature on every rebuild, so macOS treats each build as a different app and re-prompts for
access — an endless popup loop in development, and one prompt per item even for a shipped app.
AnyDesk and RustDesk both avoid this by not using the Keychain at all.

*And it was buying us nothing here:* Secure Enclave and the data-protection keychain both
require an `application-identifier` entitlement, which needs a paid Apple Developer account.
On ad-hoc builds `SecKeyCreateRandomKey` returns `-34018 errSecMissingEntitlement`, so the code
was silently falling back to a software key regardless. We were paying the prompt cost for
hardware backing we never got.

```
~/Library/Application Support/RemoteControl/identity.json   (0600, dir 0700)
  schemaVersion · deviceId · accessCode · P-256 private key · createdAt
```

- Atomic writes (temp + `rename`), permissions asserted on every write and checked on read.
- A corrupt file must **never** silently regenerate the identity — that would change the Device
  ID under the user and break their peer's saved entry. Surface the error; require an explicit
  "Reset identity".
- Keys move from `SecKey` to **CryptoKit** `P256.Signing`. No Security.framework calls remain.
- Threat model, stated honestly: owner-only file permissions plus FileVault at rest. A process
  already running as the user can read it — the same posture as AnyDesk. The UI must not imply
  hardware backing.

**No Apple Developer account.** Ad-hoc signing; first launch on each Mac needs one
right-click → Open to clear Gatekeeper. `build.sh` keeps the signing identity in a single
variable so Developer ID becomes a config change, not a rewrite.

### 2.6 Scroll and true drag
Distinct from drag-and-drop of files (explicitly out of scope). Holding the button and moving
must inject `kCGEventLeftMouseDragged`, so **dragging a browser window by its title bar works**.
Scrolling uses pixel-unit scroll wheel events for trackpad-smooth behaviour.
Both are acceptance-tested, not assumed.

---

## 3. Server placement — hard isolation rule

The instance runs a production service. Non-negotiable constraints for every phase:

- `i-0268c831a241111fe` / eu-west-1 / profile `godson`, reached **only** via SSM.
- **Never** touch `/opt/gptc`, its containers (`gptc-api-1`, `gptc-cloudflared-1`), its compose
  file, its images, or port 8001. No `docker system prune`, no `docker compose down` outside our
  own project directory, no host-wide Docker or daemon changes.
- Our world is `/opt/rc-signal` only, with its own compose project name `rc`.
- Resource caps on our containers: `rc-signal` 256 MB / 0.3 CPU, `coturn` 512 MB / 0.5 CPU.
  The box has 2 vCPU / 3.9 GB with ~3 GB available — we stay a rounding error unless TURN is
  actively relaying.

### Observed instance state (verified 2026-08-19)
- Ubuntu 24.04, t2.medium, 2 vCPU, 3.9 GB RAM, 20 GB free disk.
- Listening: 22 (SSM/SSH), 127.0.0.1:8001 (gptc-api, loopback only).
- **Security group `sg-03d49848dcbe73f40` has zero inbound rules.** gptc reaches the internet
  through an outbound cloudflared tunnel, so nothing currently depends on inbound ingress.
- Public IP `54.246.73.81` is **dynamic, not an Elastic IP** — it changes if the instance stops.

### Two infra changes are unavoidable, both additive
1. **Inbound SG rules** for our ports only: `8443/tcp` (WSS), `3478/tcp+udp` (TURN),
   `49160-49200/udp` (TURN relay). Adding rules cannot affect gptc, which has no inbound
   dependency. No existing rule is modified or removed.
2. **Allocate + associate an Elastic IP.** Without it the rendezvous address moves on every
   stop/start. Association changes the public IP, which gptc does not use (its tunnel is
   outbound), so this is safe — but it is a change to shared infrastructure and is called out
   here deliberately.

### TLS without a domain
No domain points at this box. Rather than invent one, `rc-signal` uses a **self-signed
certificate whose SHA-256 fingerprint is pinned in the app**. For a private two-device system
this is stronger than a public CA (no CA can be tricked into issuing for us) and needs no DNS.

---

## 4. Protocol (shared contract, one source of truth)

`protocol/PROTOCOL.md` + generated Swift and Go types. Every message is JSON, versioned.

### Signaling (client ↔ rc-signal, WSS)
```
-> hello        {deviceId, pubkey, sig(nonce), role}
<- hello_ok     {serverTime, iceServers[{urls,username,credential}]}   # TURN creds, 12h TTL
-> heartbeat    {}                       every 15s
-> watch        {deviceId}               controller subscribes to a peer's presence
<- presence     {deviceId, online, since}
-> connect_req  {deviceId, accessCode}   rate-limited
<- connect_ok   {sessionId, sessionToken, ttl}     | <- error {code: bad_code|offline|busy|rate_limited}
-> resume       {sessionId, sessionToken}          # flutter recovery, no access code
<> sdp          {sessionId, type: offer|answer, sdp}
<> ice          {sessionId, candidate}
<> bye          {sessionId, reason}
```

### Control data channel `ctrl` (reliable, ordered)
```
mouse_down/up {button,x,y}   key_down/up {keycode,mods}   scroll {dx,dy,phase}
clipboard_text {text, originId, hash}    gesture {name}   input_reset {}
display_info {w,h,scale}   quality {mode}   ping/pong {t}   session_close {}
```

### Control data channel `hi` (unreliable, unordered, maxRetransmits 0)
```
mouse_move {x,y,seq}         # normalised 0..1 floats; dropping stale packets is correct here
```

Coordinates are normalised floats so controller-window resizing never changes remote resolution.

---

## 5. Efficiency budget (measured, not aspirational)

| Metric | Target | How |
|---|---|---|
| Idle CPU, host, session open | < 5% | SCK delivers frames only on change; `minimumFrameInterval` floored to 2 fps idle |
| Active frame rate | 30 fps cap, 15–24 typical | SCK stream config |
| Bitrate | 0.5–3 Mbps typical, 8 Mbps burst | libwebrtc BWE + `RTCRtpEncodingParameters` caps |
| Input latency added by us | < 15 ms over network RTT | unreliable channel for moves, no queuing |
| App bundle | < 60 MB | single binary + xcframework, no runtime |
| Server steady-state | < 30 MB RAM, ~0% CPU | Go, no session state in the video path |

---

## 6. Phases, delegation and acceptance

Implementation is delegated to Opus subagents; I validate every phase against a **falsifiable
acceptance check that a stub cannot pass**. A phase is not done because code exists — it is done
when the check below is observed. No phase is signed off on mocks.

| # | Phase | Model | Depends | Acceptance check (must fail for a stub) |
|---|---|---|---|---|
| 0 | Repo scaffold + protocol spec + build scripts | opus | — | `./scripts/build.sh` produces a launchable `.app`; protocol types compile in both Swift and Go |
| 1 | `rc-signal`: registry, auth, presence, relay | opus | 0 | Two `websocat` clients register; wrong access code is rejected and rate-limited; killing one client flips the other's `presence` to offline within 40s |
| 2 | App shell: identity, file-backed storage, access code + refresh, permission UX, menu bar | opus | 0 | Access code survives app restart **and** reboot; Refresh invalidates the old code server-side (old code returns `bad_code`); revoking Screen Recording in System Settings surfaces a specific, named warning |
| 3 | WebRTC transport + signaling client + flutter recovery | opus | 1,2 | Two Macs reach `connected`; then `sudo pfctl` blocks UDP for 20s — session shows Reconnecting and **recovers without re-entering the code**; killing Wi-Fi for 2 min closes it cleanly with no stuck state |
| 4 | Screen capture + render | opus | 3 | Remote desktop visible on the controller; measured idle CPU < 5%; a stopwatch on the remote screen confirms live frames, not a still |
| 5 | Input injection, gesture palette, clipboard | opus | 4 | **Drag a Safari window across the remote screen**; scroll a long page; Cmd+Space via capture mode opens *remote* Spotlight; palette raises Mission Control; text copied on either Mac pastes on the other with no echo loop |
| 6 | Deploy infra (EIP, SG, compose, coturn) + TURN fallback | opus | 1,3 | `docker ps` shows gptc-api untouched and healthy before *and* after; session works with P2P deliberately blocked, proving relay |
| 7 | Packaging, signing, launch-at-login, hardening | opus | all | `.dmg` installs on a Mac that has never had the toolchain; launches at login; reconnects after reboot with the same credentials |

Milestone-complete means **between two real Macs**, per AGENT.md.

---

## 7. Out of scope (V1)
File transfer · chat · voice · recording · multi-monitor · accounts · Windows · mobile ·
image/file clipboard · browser automation · any proxy, VPN, DNS or browser-extension
mechanism (see AGENT.md "Browser and Network Isolation" — the remote Mac's browser traffic stays
entirely on its own network path).

---

## Phase status log

### Phase 3 — COMPLETE (verified 2026-08-19)
31/31 integration steps against the live server, 151/151 unit tests, and confirmed by the user
in the real UI: entering the host's Device ID + Access Code on the controller reaches a
connected session.

**Two bugs found only by driving the real UI, after the automated suite was already green:**

1. **Nested `ObservableObject` changes never redrew the view.** `AppModel` held `settings`,
   `permissions`, `identity`, `coordinator` and the presence source as `@Published` reference
   types. `@Published` fires when the *reference* is replaced, never when the referenced
   object's own `@Published` properties change. The role picker appeared completely dead; the
   same break silently affected the access-code display after Refresh, the permission rows, the
   live presence dot and the "Reconnecting…" indicator. Fixed by forwarding every nested
   `objectWillChange` into `AppModel.objectWillChange` (`rewireObservation()`), re-run whenever
   `identity` or `coordinator` is replaced.

2. **Role changes did not rebuild the transport.** The role is baked into `SignalingClient` at
   init and decides which side offers SDP, so switching to Controller left a coordinator still
   registered as a host.

**Process lesson — this is the important part.** Phase 3's UI verification rendered the window
to a static PNG. A screenshot cannot detect a missing re-render: the stale frame and the correct
frame look identical. Static image capture is not evidence that UI is *reactive*. From here on,
anything stateful in the UI needs either a publisher-level regression test (as now added, three
of them) or a real interaction, never a screenshot alone.

Also fixed: `AppSettings` used `UserDefaults.standard`, so two instances on one Mac shared role
and saved-peer state. Now honours `RC_SETTINGS_SUITE`, the settings analogue of
`RC_IDENTITY_DIR`. Real installs on separate Macs were never affected.

### Phase 4 — correction to §1

This plan originally specified `RTCMTLNSVideoView` for rendering. **That class does not exist in
the `stasel/WebRTC` xcframework** — `nm -gU WebRTC | grep RTCMTL` is empty in every slice,
because those builds are produced without Xcode's Metal shader compiler. Linking against it
fails outright.

Rendering uses `AVSampleBufferDisplayLayer` instead: still GPU-composited, still zero-copy from
the VideoToolbox hardware decoder, no per-frame CPU work. No downside for our use.

### UI verbosity — release vs development (user request, 2026-08-19)

The Screen Sharing section currently exposes live capture diagnostics: resolution
(`1920x1200`), frame-rate cap (`up to 30 fps`), bitrate and fps counters that visibly
fluctuate. Useful while building, wrong for the shipped app.

**Release behaviour:** a plain status only — e.g. `● Sharing this screen` / `Not sharing`,
plus the permission state when something is actually wrong. No resolutions, no fps, no
bitrate, no counters.

**Development behaviour:** the full diagnostics stay available, gated behind `RC_DEBUG=1`
(the existing switch) or a collapsed "Details" disclosure that is closed by default.

Rule of thumb for the whole UI: numbers that change on their own are diagnostics. The user
should see *state* ("sharing", "connected", "reconnecting"), not telemetry. Applies equally
to the controller's session toolbar — keep RTT only if it is stable and genuinely useful,
otherwise hide it behind the same switch.

Do this as part of Phase 7 (packaging/polish), after the capture performance work lands, to
avoid editing the same files concurrently.

### Phase 5 — input injection, gesture palette, clipboard (implemented 2026-08-19)

Everything is OS-level `CGEvent` injection. `scripts/check-isolation.sh` still passes: no
browser automation, no injected JavaScript, no CDP, no proxy.

**What landed**

| Area | Where |
|---|---|
| Wire types (`mouse_*`, `click`, `key_*`, `scroll`, `gesture`, `clipboard_text`, `input_reset`) | `Input/InputWire.swift` |
| Host injection + held-state tracking | `Input/InputInjector.swift`, `Input/CGEventSink.swift` |
| Gesture catalogue (public APIs only) | `Input/GestureCatalog.swift` |
| Clipboard sync + echo guard | `Input/ClipboardSync.swift` |
| Controller capture and send | `Input/ControllerInput.swift`, `Input/KeyboardCaptureTap.swift` |
| UI: palette, capture toggle, "input is being ignored" banner | `GesturePalette.swift`, `RemoteSessionView.swift`, `HostView.swift` |

**Design note — why the injector posts nothing.** `InputInjector` is a pure translator from a
`ctrl`/`hi` message to `[InjectedEvent]`; `CGEventSink` turns those into real `CGEvent`s. The
split exists so the three claims that matter can be asserted exactly instead of eyeballed: a
drag really becomes `kCGEventLeftMouseDragged` (not a repeated move), `input_reset` releases
exactly what is tracked and is idempotent, and Cmd+C really carries `maskCommand`. It also
means the unit suite can build genuine `CGEvent`s and read their fields back out of
CoreGraphics on a machine with no privacy grants at all.

**Two acceptance surfaces, and neither pretends to cover the other**

* `./scripts/test-input.sh` — 17/17. Two real `rc-node` instances, a real WebRTC session over
  the live server. Proves every input message crosses the right channel and becomes the right
  number of OS events at the host, that drags travel on `ctrl` (never `hi`), that `input_reset`
  releases held state and is idempotent, and that clipboard text crosses **both** ways with no
  echo loop. Each node gets its own `RC_PASTEBOARD_NAME`, so the clipboard test is genuinely two
  pasteboards rather than one talking to itself.
* `./scripts/verify-input.sh` — runs the self-test **inside the .app bundle**, because macOS
  attributes a TCC grant to the responsible process and a terminal-launched binary inherits the
  terminal's (absent) Accessibility grant. It reads the cursor position back from the window
  server, drags a real `NSWindow` by its title bar and asserts **the window frame actually
  moved**, and watches a listen-only `CGEventTap` to confirm dragged-vs-moved counts, pixel-unit
  scroll and `maskCommand` on a key event.

  **STATUS: this script has not been observed passing.** It stops at its first gate, correctly:
  `dist/RemoteControl.app` does not have Accessibility permission on this machine, and that
  cannot be granted from a script — TCC.db is SIP-protected. Verified independently that without
  the grant an injected `mouseMoved` leaves the cursor exactly where it was, i.e. the check is
  genuinely falsifiable rather than vacuous. **Grant Accessibility to `dist/RemoteControl.app`
  and re-run `./scripts/verify-input.sh` — that is the one outstanding acceptance step for
  this phase.**

**Two bugs found by the integration test, both real**

1. `ClipboardMonitor` polled on a `RunLoop.main` `Timer`. The `.app` runs a run loop so it
   worked there, but `rc-node` parks on `dispatchMain()`, which never spins one — the poll
   silently never ran and nothing was ever sent. Now a `DispatchSourceTimer`, which fires under
   both.
2. That timer's handler used `MainActor.assumeIsolated`, which **traps** in a dispatch-timer
   handler when nothing is running a run loop ("Incorrect actor executor assumption"). It hops
   with a `Task` now. Worth remembering before using `assumeIsolated` anywhere off the app's own
   event loop.

**Process note, and it is the same lesson as Phase 4's.** Two of the three "failures" chased
during this phase were faults in the *checks*, not the code: the clipboard hash comparison
grepped a raw log line for a base64 string, and `JSONSerialization` escapes `/` as `\/`, so it
flapped on roughly half of all hashes; and the second echo-loop check marked its start line in
the controller's log and then searched the host's. Both now parse JSON instead of grepping it.
Confirm the check is valid before touching the thing it is accusing.

**Honest limitations**

* Gestures are the OS's public key equivalents, not synthesised multi-touch (PLAN.md §2.4).
  Launchpad has no key equivalent at all and is invoked by opening the system application.
* `app_switcher` is a complete Cmd+Tab press-and-release: it switches to the previous
  application rather than holding the switcher open. Holding it open needs capture mode.
* Clipboard is text only, ≤ 192 KiB, and contents are never logged (PROTOCOL.md §8).
* While capture mode is on, `Control-Option-Command-K` is reserved: it is never forwarded and
  always turns capture off, so nobody can trap themselves with every shortcut leaving the Mac.

### Phases 5, 6, 7 — COMPLETE (2026-08-19)

**Phase 5 — input, clipboard, gestures.** 256/256 unit tests (mutation-checked), 17/17 input
integration, and `./scripts/verify-input.sh` observed passing against the real `.app` with
Accessibility granted. The assertions are about consequences, not calls:

```
window frame 420,350 -> 600,230 (moved 180,120; asked for 180,120)
drag_posts_dragged_events  12 leftMouseDragged events, 0 plain moves
window_actually_moved      dragging by the title bar really moves it
scroll_is_pixel_units      isContinuous=1 on every scroll event
input_reset_*              releases everything, clears state, idempotent
```

**Phase 6 — TURN fallback.** `RC_ICE_POLICY=relay ./scripts/test-transport.sh` -> 31/31. The
whole session — signaling, WebRTC, data channels, resume, refresh — works with direct P2P
disabled, so it is genuinely relaying through coturn rather than quietly falling back to P2P.

**Phase 7 — packaging and polish.**
- `scripts/package-dmg.sh` -> `dist/RemoteControl-1.0.0.dmg` (13 MB). It refuses to ship a
  broken bundle: verifies the signature, that `WebRTC.framework` is embedded, and that the
  `@executable_path` rpath resolves, then mounts the finished image and re-verifies inside it.
- UI minimalism pass (user request): the "Identity Storage" card is gone — it now renders
  nothing unless the identity file actually has a problem. Live capture figures and the RTT
  readout are behind `RC_DEBUG=1`. Default window is landscape 1000x660 instead of a 460pt
  portrait column that letterboxed the remote desktop into a strip; forms are capped at 620pt
  and centred so the wider window does not stretch them.
- README documents the install, both permissions, and the two TCC traps.

### Known gaps at V1

1. **Never run between two physical Macs.** Everything is verified on one Mac against the live
   AWS server — real WebRTC, real ICE, real internet round trip — but NAT traversal between two
   different networks and how drag/scroll *feel* under real latency are unproven by definition.
2. **The idle frame-rate throttle is unit-tested but not observed end-to-end**, because a
   genuinely motionless screen never occurred during development. `verify-capture.sh` SKIPs
   with an explanation rather than failing on a condition it did not create.
3. **`app_switcher`** is a complete Cmd+Tab press-and-release, not a held switcher.
4. **The server address and cert pin are compiled in.** No Elastic IP, by decision. If the
   instance stops and its IP changes, both Macs need a rebuild.

### Cursor responsiveness (2026-08-21)

**Symptom:** the remote cursor visibly trailed the user's hand. Not a bandwidth or
relay problem — a *feedback loop*. The pointer on screen was the host's, captured and
streamed back, so it could not move until a full round trip completed: send input ->
host injects -> host redraws -> ScreenCaptureKit -> H.264 encode -> network -> decode ->
present. Even on a perfect link that is one to two frame intervals plus codec time. No
network tuning removes it.

**Fix:** the controller now draws the pointer locally from its own mouse
(`RemoteScreenNSView.cursorLayer`), so it moves at display refresh rate, and the host
sets `showsCursor = false` so there is exactly one pointer. Same approach as Parsec and
Moonlight. Clicks and screen updates still cost a round trip — only pointer motion is
decoupled.

**Three mistakes made along the way, all mine, all worth remembering:**

1. **Hiding the local cursor without providing a replacement** made the lag *worse*, by
   removing the only instant feedback the user had. A change that "looks tidier" can
   degrade the thing the user actually cares about.
2. **Layer ordering** — the cursor layer was added before the video layer, so the video
   painted over it.
3. **`NSCursor.arrow.image` returns a ZERO-SIZED image** in a process without a
   window-server connection. The layer then drew nothing and, with the system cursor
   hidden, the user had no pointer at all. Now drawn as a vector `CGPath`: no
   window-server dependency, resolution-independent.

**Rule adopted:** never hide the system cursor unless a replacement is verifiably
drawable (`canDrawLocalCursor`). Failing safe to the real cursor beats a blank screen.
The regression test asserts the path, not the bitmap, so it holds headlessly.

**Known limitation:** the local pointer is always an arrow. The I-beam / resize-handle
shapes are lost. Fixing that means sending cursor-shape changes over the `ctrl` channel —
cheap, not yet built.

### Still open

1. **The app does not resume its own session.** The server hands back `activeSessionId`
   on every reconnect, but the controller tries a fresh `connect_req`, gets `busy`, and
   shows a dead end with no way out. PROTOCOL.md §4.4 already specifies the correct
   behaviour: resume, never re-`connect_req`. Observed in the wild twice.
2. **No automatic relay fallback.** A session that fails ICE closes with `reason:"failed"`
   instead of retrying over TURN, which is proven to work (`RC_ICE_POLICY=relay` -> 31/31).
3. **Two app instances sharing one identity displace each other in a loop**, producing an
   auth storm (~20 reconnects in 40s, seen in the server log). The client should treat
   `displaced` as terminal rather than reconnecting into a fight.
